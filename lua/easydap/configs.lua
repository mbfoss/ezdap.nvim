---@brief Adapter configuration registry.
---
---A config is a plain table with two classes of keys:
---  • Internal (snake_case) — consumed by the client, not forwarded to the adapter:
---      command, command_args, command_cwd, command_env, command_insert_stderr,
---      host, port, adapter, modes, fn,
---      defer_launch_attach, prefix_local, prefix_remote, compile
---  • Protocol — stored in `launch_args`/`attach_args` and forwarded verbatim in the DAP request.
---
---Values (including values inside `launch_args` and `attach_args`) can be plain values or
---zero-argument functions evaluated at session start.
---
---`launch_args` (optional): table — protocol args used when request="launch".
---`attach_args` (optional): table — protocol args used when request="attach".
---`fn`          (optional): fn(config) → config — transform config before launch.
---`setup`        (optional): coroutine fn(config) — async setup; may yield; return value is passed to teardown.
---`teardown`     (optional): fn(config, ctx) — called on session termination with setup's return value.

local M = {}

---@class easydap.Config
---@field adapter?               string
---@field command?               string                  adapter executable
---@field command_args?          string[]|fun():string[] arguments for the adapter process
---@field command_cwd?           string                  working directory for the adapter process
---@field command_env?           table<string,string>
---@field command_insert_stderr? boolean                 pipe adapter stderr into session output
---@field host?                  string                  TCP host (default "127.0.0.1")
---@field port?                  integer
---@field modes?                 string[]
---@field defer_launch_attach?   boolean
---@field prefix_local?          string
---@field prefix_remote?         string
---@field compile?               table
---@field launch_args?           table<string,any>  protocol args forwarded verbatim when request="launch"
---@field attach_args?           table<string,any>  protocol args forwarded verbatim when request="attach"
---@field request?               string
---@field setup?                 fun(config: easydap.Config, ctx: easydap.SetupCtx): any  coroutine fn driven by async.go; yield a waker-registration fn to wait asynchronously; return value is passed to teardown
---@field teardown?              fun(config: easydap.Config, ctx: any)  called on session termination with setup's return value

---@class easydap.SetupCtx
---@field add_bufnr fun(bufnr: integer, label?: string, priority?: integer)
---@field report    fun(message: string)

---@type table<string, easydap.Config>
local _registry = {}

---Register a named adapter config (or override an existing one).
---@param name   string
---@param config easydap.Config
function M.register(name, config)
    _registry[name] = config
end

---Retrieve a config by name.
---@param name string
---@return easydap.Config?
function M.get(name)
    return _registry[name]
end

---All registered config names, sorted.
---@return string[]
function M.names()
    local names = vim.tbl_keys(_registry)
    table.sort(names)
    return names
end

-- ── Config evaluation ──────────────────────────────────────────────────────

---Evaluate any function values in a config (called at session start).
---@param config easydap.Config
---@return easydap.Config  shallow copy with functions replaced by their return values
function M.eval(config)
    local function eval_val(v)
        if type(v) == "function" then
            local ok, val = pcall(v)
            return ok and val or v
        end
        return v
    end
    local function eval_args(t)
        local out = {}
        for ak, av in pairs(t) do out[ak] = eval_val(av) end
        return out
    end
    -- lifecycle callbacks are not data-providers; evaluating them would run setup as a side-effect
    local skip      = { setup = true, teardown = true }
    local eval_tbl  = { launch_args = true, attach_args = true, request_args = true }
    local result    = {}
    for k, v in pairs(config) do
        if skip[k] then
            result[k] = v
        elseif eval_tbl[k] and type(v) == "table" then
            result[k] = eval_args(v)
        else
            result[k] = eval_val(v)
        end
    end
    return result
end


-- ── Utilities ─────────────────────────────────────────────────────────────

---Return an available TCP port by binding a socket to port 0.
---@return integer
local function _free_port()
    local tcp = assert(vim.uv.new_tcp(), "uv.new_tcp failed")
    tcp:bind("127.0.0.1", 0)
    local addr = assert(tcp:getsockname(), "getsockname failed")
    tcp:close()
    return addr.port
end

---Resolve a Mason-managed binary, falling back to the plain name.
---@param name string
---@return string
local function _mason_bin(name)
    local bin = vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "bin", name)
    return vim.fn.executable(bin) == 1 and bin or name
end

-- ── Built-in presets ───────────────────────────────────────────────────────

M.register("debugpy", {
    command = "python3",
    setup = function(config, ctx)
        local term = require("easydap.util.term")
        local function resolve_python()
            local base = vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "debugpy", "venv")
            local path = vim.fn.has("win32") == 1
                and vim.fs.joinpath(base, "Scripts", "python.exe")
                or  vim.fs.joinpath(base, "bin", "python")
            if vim.fn.filereadable(path) == 1 then return path end
            local sys = vim.fn.exepath("python3")
            return sys ~= "" and sys or config.command
        end
        local python = resolve_python()
        if vim.fn.executable(python) == 0 then
            error(python .. " not found")
        end
        if vim.fn.system(python .. " -c 'import debugpy.adapter'"):match("^Error") then
            error("debugpy is not installed for " .. python)
        end

        local port   = _free_port()
        local failed = false
        local handle

        coroutine.yield(function(waker)
            local woken = false
            local function wake()
                if woken then return end
                woken = true
                waker()
            end

            handle = term.spawn(
                { python, "-m", "debugpy.adapter", "--host", "127.0.0.1", "--port", tostring(port) },
                { cwd = config.command_cwd or vim.fn.getcwd(), on_exit = function() failed = true; wake() end }
            )
            if not handle then failed = true; wake(); return end
            ctx.add_bufnr(handle.bufnr, "debugpy", -2)
            vim.defer_fn(wake, 500)
        end)

        if not handle then error("failed to start debugpy adapter") end
        if failed then error("debugpy adapter exited unexpectedly") end
        config.port = port
        return { handle = handle }
    end,
    teardown = function(_, ctx)
        if ctx then ctx.handle.stop() end
    end,
    launch_args = {
        type            = "python",
        cwd             = function() return vim.fn.getcwd() end,
        program         = function() return vim.fn.expand("%:p") end,
        args            = {},
        justMyCode      = false,
        console         = "integratedTerminal",
        stopOnEntry     = false,
        showReturnValue = true,
    },
})

M.register("debugpy-module", {
    command = "python3",
    setup = function(config, ctx)
        local term = require("easydap.util.term")
        local function resolve_python()
            local base = vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "debugpy", "venv")
            local path = vim.fn.has("win32") == 1
                and vim.fs.joinpath(base, "Scripts", "python.exe")
                or  vim.fs.joinpath(base, "bin", "python")
            if vim.fn.filereadable(path) == 1 then return path end
            local sys = vim.fn.exepath("python3")
            return sys ~= "" and sys or config.command
        end
        local python = resolve_python()
        if vim.fn.executable(python) == 0 then
            error(python .. " not found")
        end
        if vim.fn.system(python .. " -c 'import debugpy.adapter'"):match("^Error") then
            error("debugpy is not installed for " .. python)
        end

        local port   = _free_port()
        local failed = false
        local handle

        coroutine.yield(function(waker)
            local woken = false
            local function wake()
                if woken then return end
                woken = true
                waker()
            end

            handle = term.spawn(
                { python, "-m", "debugpy.adapter", "--host", "127.0.0.1", "--port", tostring(port) },
                { cwd = config.command_cwd or vim.fn.getcwd(), on_exit = function() failed = true; wake() end }
            )
            if not handle then failed = true; wake(); return end
            ctx.add_bufnr(handle.bufnr, "debugpy", -2)
            vim.defer_fn(wake, 500)
        end)

        if not handle then error("failed to start debugpy adapter") end
        if failed then error("debugpy adapter exited unexpectedly") end
        config.port = port
        return { handle = handle }
    end,
    teardown = function(_, ctx)
        if ctx then ctx.handle.stop() end
    end,
    launch_args = {
        type        = "python",
        cwd         = function() return vim.fn.getcwd() end,
        module      = function() return vim.fn.fnamemodify(vim.fn.getcwd(), ":t") end,
        args        = {},
        justMyCode  = false,
        console     = "integratedTerminal",
        stopOnEntry = false,
    },
})

M.register("codelldb", {
    command     = _mason_bin("codelldb"),
    setup       = function(config)
        if vim.fn.executable(config.command) == 0 then
            error("codelldb not found")
        end
    end,
    launch_args = {
        type        = "lldb",
        cwd         = function() return vim.fn.getcwd() end,
        program     = function() return vim.fn.getcwd() .. "/target/debug/" .. vim.fn.fnamemodify(vim.fn.getcwd(), ":t") end,
        args        = {},
        stopOnEntry = false,
    },
    attach_args = {
        type = "lldb",
        pid  = 0,
    },
})

M.register("lldb-dap", {
    command     = "lldb-dap",
    launch_args = {
        type    = "lldb-dap",
        cwd     = ".",
        program = "a.out",
        args    = {},
    },
    attach_args = {
        type = "lldb-dap",
        pid  = 0,
    },
})

M.register("gdb", {
    command      = "gdb",
    command_args = { "--interpreter=dap" },
    setup        = function(config)
        if vim.fn.executable(config.command) == 0 then
            error("gdb not found")
        end
        local ver_str = vim.fn.system("gdb --version")
        local major   = tonumber(ver_str:match("GNU gdb[^%d]*(%d+)%."))
        if not major or major < 14 then
            error("gdb >= 14.1 required (found " .. (major or "?") .. ")")
        end
    end,
    launch_args  = {
        program                         = "a.out",
        args                            = {},
        stopAtBeginningOfMainSubprogram = false,
    },
    attach_args  = {
        pid = 0,
    },
})

M.register("netcoredbg", {
    command      = "netcoredbg",
    command_args = { "--interpreter=vscode" },
    launch_args  = {
        cwd         = function() return vim.fn.getcwd() end,
        program     = function()
            local dlls = vim.fn.glob("bin/Debug/**/*.dll", false, true)
            return #dlls > 0 and dlls[1] or ".dll"
        end,
        stopAtEntry = false,
    },
    attach_args  = {
        processId = 0,
    },
})

-- Generic TCP attach — connect to a DAP server already listening on host:port.
-- Override `host` and `port` in the task definition.
M.register("remote", {
    host        = "127.0.0.1",
    port        = 0,
    request     = "attach",
    attach_args = {},
})

-- lldb-dap resolved via Mason (preferred over the plain "lldb-dap" preset when Mason is available).
M.register("lldb", {
    command     = _mason_bin("lldb-dap"),
    setup       = function(config)
        if vim.fn.executable(config.command) == 0 then
            error("lldb-dap not found — install it or add it to PATH")
        end
    end,
    launch_args = {
        type          = "lldb",
        cwd           = function() return vim.fn.getcwd() end,
        program       = "a.out",
        args          = {},
        stopOnEntry   = false,
        runInTerminal = true,
    },
    attach_args = {
        type = "lldb",
        pid  = 0,
    },
})

-- Go — dlv dap communicates over stdio; no TCP setup required.
M.register("delve", {
    command      = _mason_bin("dlv"),
    command_args = { "dap" },
    setup        = function(config)
        if vim.fn.executable(config.command) == 0 then
            error("dlv not found — install Delve or add it to PATH")
        end
        local ver = vim.fn.system(config.command .. " version")
        if not ver:match("Delve") then
            error("unexpected dlv version output: " .. ver)
        end
    end,
    launch_args  = {
        mode    = "debug",
        program = function() return vim.fn.getcwd() end,
        args    = {},
        cwd     = function() return vim.fn.getcwd() end,
    },
    attach_args  = {
        mode      = "local",
        processId = 0,
    },
})

-- JavaScript / TypeScript — starts js-debug's TCP server, then connects to it.
M.register("js-debug", {
    setup = function(config, ctx)
        local term = require("easydap.util.term")
        local server_js = vim.fs.joinpath(
            vim.fn.stdpath("data"), "mason", "packages",
            "js-debug-adapter", "js-debug", "src", "dapDebugServer.js"
        )
        if vim.fn.filereadable(server_js) == 0 then
            error("js-debug-adapter not found at " .. server_js)
        end

        local resolved_host = nil
        local resolved_port = nil
        local failed        = false
        local handle        = nil

        coroutine.yield(function(waker)
            local woken = false
            local function wake()
                if woken then return end
                woken = true
                waker()
            end

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
                            wake()
                            return
                        end
                    end
                end,
                on_exit = function()
                    if not resolved_port then
                        failed = true
                        wake()
                    end
                end,
            })
            if not handle then
                failed = true
                wake()
                return
            end
            ctx.add_bufnr(handle.bufnr, "js-debug server", -2)
            ctx.report("js-debug: waiting for server port")
            vim.defer_fn(function()
                if not resolved_port then
                    failed = true
                    wake()
                end
            end, 5000)
        end)

        if not handle then error("failed to start js-debug server") end
        if failed then error("js-debug server exited before reporting a port") end
        if not resolved_port then error("js-debug server did not start within 5 s") end
        config.host = resolved_host
        config.port = resolved_port
        return { handle = handle }
    end,
    teardown = function(_, ctx)
        if ctx then ctx.handle.stop() end
    end,
    launch_args = {
        type              = "pwa-node",
        cwd               = function() return vim.fn.getcwd() end,
        program           = function() return vim.fn.expand("%:p") end,
        runtimeExecutable = "node",
        args              = {},
    },
    attach_args = {
        type = "pwa-node",
        port = 9229,
    },
})

M.register("bash-debug-adapter", {
    command     = _mason_bin("bash-debug-adapter"),
    setup       = function(config)
        if vim.fn.executable(config.command) == 0 then
            error("bash-debug-adapter not found")
        end
    end,
    launch_args = {
        type          = "bashdb",
        name          = "Launch Bash Script",
        cwd           = function() return vim.fn.getcwd() end,
        program       = function() return vim.fn.expand("%:p") end,
        args          = {},
        pathBash      = "bash",
        pathBashdb    = function()
            local p = vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter", "bashdb")
            return vim.fn.filereadable(p) == 1 and p or "bashdb"
        end,
        pathBashdbLib = function()
            return vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter")
        end,
        pathCat       = "cat",
        pathMkfifo    = "mkfifo",
        pathPkill     = "pkill",
        terminalKind  = "integrated",
    },
})

M.register("php-debug-adapter", {
    command     = _mason_bin("php-debug-adapter"),
    setup       = function(config)
        if vim.fn.executable(config.command) == 0 then
            error("php-debug-adapter not found")
        end
    end,
    launch_args = {
        type = "php",
        name = "Listen for Xdebug",
        cwd  = function() return vim.fn.getcwd() end,
        port = 9003,
    },
})

-- Java — expects an external debug server (e.g. started by nvim-jdtls).
-- Set host and port via attach_args overrides in the task definition.
M.register("java-debug-server", {
    host        = "127.0.0.1",
    port        = 0,
    request     = "attach",
    attach_args = {
        host = "127.0.0.1",
    },
})

M.register("local-lua-debugger", {
    command      = "node",
    command_args = function()
        local p = vim.fs.joinpath(
            vim.fn.stdpath("data"), "mason", "packages",
            "local-lua-debugger-vscode", "extension", "debugAdapter.js"
        )
        if vim.fn.filereadable(p) == 0 then
            error("local-lua-debugger-vscode not found at " .. p)
        end
        return { p }
    end,
    command_env  = {
        LUA_PATH = vim.fs.joinpath(
            vim.fn.stdpath("data"), "mason", "packages",
            "local-lua-debugger-vscode", "debugger", "?.lua"
        ) .. ";;",
    },
    launch_args  = {
        type = "lua-local",
        name = "Debug",
        program = function()
            return {
                lua           = vim.fn.exepath("lua"),
                file          = vim.fn.expand("%:p"),
                communication = "stdio",
            }
        end,
    },
})

return M
