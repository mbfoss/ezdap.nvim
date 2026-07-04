---@brief Built-in DAP adapter definitions.
---
---The module is a plain table: each key is an adapter name, each value is a
---Config — pure native DAP (command, host/port, setup/teardown, request, …).
---Translating a generic task (command/cwd/env/…) into a native launch/attach
---body is an opt-in concern that lives in `easydap.derive`, not here.
---Users can add adapters or override existing ones directly:
---  local adapters = require("easydap.adapters")
---  adapters.myAdapter = { command = "...", request = "launch" }

local M = {}

-- ── Type annotations ──────────────────────────────────────────────────────

---Context passed to `config.setup()` so the adapter can report progress and
---register terminal buffers with the task runner.
---@class easydap.AdapterSetupCtx
---@field add_bufnr fun(bufnr: integer, opts?: easydap.AddBufOpts)
---@field report    fun(message: string)

---@class easydap.dap.Config
---@field adapter?               string
---@field command?               string|string[]
---@field command_cwd?           string
---@field command_env?           table<string,string>
---@field command_insert_stderr? boolean
---@field host?                  string
---@field port?                  integer
---@field modes?                 string[]
---@field defer_launch_attach?   boolean
---@field prefix_local?          string
---@field prefix_remote?         string
---@field request?               string
---@field setup?                 fun(config: easydap.dap.Config, ctx: easydap.AdapterSetupCtx, callback: fun(err?: string, state?: any))
---@field teardown?              fun(config: easydap.dap.Config, ctx: any)

-- ── Utilities ─────────────────────────────────────────────────────────────

---@return integer
local function _free_port()
    local tcp = assert(vim.uv.new_tcp(), "uv.new_tcp failed")
    tcp:bind("127.0.0.1", 0)
    local addr = assert(tcp:getsockname(), "getsockname failed")
    tcp:close()
    return addr.port
end

-- ── Built-in adapter configs ───────────────────────────────────────────────

---Shared setup for debugpy and debugpy-module (both launch the same adapter process).
---@param config   easydap.dap.Config
---@param ctx      easydap.AdapterSetupCtx
---@param callback fun(err?: string, state?: any)
local function _debugpy_setup(config, ctx, callback)
    local term = require("easydap.util.term")
    local function resolve_python()
        local base = vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "debugpy", "venv")
        local path = vim.fn.has("win32") == 1
            and vim.fs.joinpath(base, "Scripts", "python.exe")
            or vim.fs.joinpath(base, "bin", "python")
        if vim.fn.filereadable(path) == 1 then return path end
        local sys = vim.fn.exepath("python3")
        local fallback = type(config.command) == "table" and config.command[1] or config.command --[[@as string]]
        return sys ~= "" and sys or fallback
    end
    local python = resolve_python()
    if vim.fn.executable(python) == 0 then return callback(python .. " not found") end
    if vim.fn.system(python .. " -c 'import debugpy.adapter'"):match("^Error") then
        return callback("debugpy is not installed for " .. python)
    end
    local port   = _free_port()
    local called = false
    local function done(err, state)
        if called then return end
        called = true
        callback(err, state)
    end
    local handle = term.spawn(
        { python, "-m", "debugpy.adapter", "--host", "127.0.0.1", "--port", tostring(port) },
        {
            cwd     = config.command_cwd or vim.fn.getcwd(),
            on_exit = function() done("debugpy adapter exited unexpectedly") end,
        }
    )
    if not handle then return callback("failed to start debugpy adapter") end
    ctx.add_bufnr(handle.bufnr, { label = "debugpy", priority = -2 })
    config.port = port
    vim.defer_fn(function() done(nil, { handle = handle }) end, 500)
end

M.debugpy = {
    command            = "python3",
    setup              = _debugpy_setup,
    teardown           = function(_, ctx) if ctx then ctx.handle.stop() end end,
}

-- task.command maps to `module` (the Python module name, not a file path)
M["debugpy-module"] = {
    command            = "python3",
    setup              = _debugpy_setup,
    teardown           = function(_, ctx) if ctx then ctx.handle.stop() end end,
}

-- Attach to a remote Python process running debugpy.
-- task.host / task.port point to the REMOTE process; the local debugpy adapter
-- is spawned by _debugpy_setup and connects to it via the `connect` args.
M["debugpy-remote"] = {
    command            = "python3",
    setup              = _debugpy_setup,
    teardown           = function(_, ctx) if ctx then ctx.handle.stop() end end,
    request            = "attach",
}

M.codelldb = {
    command = "codelldb",
}

M.gdb = {
    command = { "gdb", "--interpreter=dap" },
}

-- netcoredbg uses stopAtEntry instead of the standard stopOnEntry
M.netcoredbg = {
    command = { "netcoredbg", "--interpreter=vscode" },
}

-- Generic TCP attach — connect to a DAP server already listening on host:port.
-- Set host/port in the task definition; request_args are forwarded verbatim for
-- adapters that also want them in the DAP attach body (e.g. delve remote mode).
M.remote = {
    host    = "127.0.0.1",
    port    = 0,
    request = "attach",
}

-- Java — expects an external debug server (e.g. started by nvim-jdtls).
-- Set host and port via task-level overrides or request_args.
M["java-debug-server"] = {
    host    = "127.0.0.1",
    port    = 0,
    request = "attach",
}

M.lldb = {
    command = "lldb-dap",
}

-- Go — dlv dap communicates over stdio; no TCP setup required.
M.delve = {
    command = { "dlv", "dap" },
}

-- JavaScript / TypeScript — starts js-debug's TCP server, then connects to it.
M["js-debug"] = {
    setup = function(config, ctx, callback)
        local term = require("easydap.util.term")
        local server_js = vim.fs.joinpath(
            vim.fn.stdpath("data"), "mason", "packages",
            "js-debug-adapter", "js-debug", "src", "dapDebugServer.js"
        )
        if vim.fn.filereadable(server_js) == 0 then
            return callback("js-debug-adapter not found at " .. server_js)
        end
        local resolved_host = nil
        local resolved_port = nil
        local called        = false
        local function done(err, state)
            if called then return end
            called = true
            callback(err, state)
        end
        local handle
        handle = term.spawn({ "node", server_js }, {
            on_stdout = function(_, data)
                if resolved_port then return end
                for _, line in ipairs(data) do
                    -- format: "Debug server listening at <host>:<port>"
                    -- (.+) is greedy so it captures up to the last colon,
                    -- correctly handling IPv6 addresses like ::1
                    local h, p = line:match("Debug server listening at (.+):(%d+)")
                    if h and p then
                        resolved_host = h
                        resolved_port = tonumber(p)
                        config.host   = resolved_host
                        config.port   = resolved_port
                        done(nil, { handle = handle })
                        return
                    end
                end
            end,
            on_exit = function()
                if not resolved_port then
                    done("js-debug server exited before reporting a port")
                end
            end,
        })
        if not handle then return callback("failed to start js-debug server") end
        ctx.add_bufnr(handle.bufnr, { label = "js-debug server", priority = -2 })
        ctx.report("js-debug: waiting for server port")
        vim.defer_fn(function()
            if not resolved_port then
                done("js-debug server did not start within 5 s")
            end
        end, 5000)
    end,

    teardown = function(_, ctx)
        if ctx then ctx.handle.stop() end
    end,
}

M["bash-debug-adapter"] = {
    command = "bash-debug-adapter",
}

M["php-debug-adapter"] = {
    command = "php-debug-adapter",
}

-- Lua
local _lua_debugger_adapter_js = vim.fs.joinpath(
    vim.fn.stdpath("data"), "mason", "packages",
    "local-lua-debugger-vscode", "extension", "extension", "debugAdapter.js"
)
M["local-lua-debugger"] = {
    command     = { "node", _lua_debugger_adapter_js },
    command_env = {
        LUA_PATH = vim.fs.joinpath(
            vim.fn.stdpath("data"), "mason", "packages",
            "local-lua-debugger-vscode", "debugger", "?.lua"
        ) .. ";;",
    },
}

return M
