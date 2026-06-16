---@brief Built-in DAP adapter definitions.
---
---The module is a plain table: each key is an adapter name, each value is a Config.
---Users can add adapters or override existing ones directly:
---  local adapters = require("easydap.adapters")
---  adapters.myAdapter = { command = "...", derive_launch_args = function(task) … end }
---  adapters.codelldb.derive_launch_args = function(task) … end

local str_util = require("easydap.util.str_util")

local M = {}

-- ── Type annotations ──────────────────────────────────────────────────────

---Context passed to `config.setup()` so the adapter can report progress and
---register terminal buffers with the task runner.
---@class easydap.AdapterSetupCtx
---@field add_bufnr fun(bufnr: integer, label?: string, priority?: integer)
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
---@field derive_launch_args?    fun(task: table): table  build launch args from generic task fields
---@field derive_attach_args?    fun(task: table): table  build attach args from generic task fields
---@field setup?                 fun(config: easydap.dap.Config, ctx: easydap.AdapterSetupCtx, callback: fun(err?: string, state?: any))
---@field teardown?              fun(config: easydap.dap.Config, ctx: any)

-- ── Small shared helpers ──────────────────────────────────────────────────

---Split task.command (string or string[]) into the program path and any extra args.
---@param task table
---@return string?  program
---@return string[]? args
local function _split_command(task)
    if not task.command then return end
    local parts = type(task.command) == "table"
        and task.command
        or str_util.split_shell_args(task.command)
    local args = {}
    for i = 2, #parts do args[#args + 1] = parts[i] end
    return parts[1], args
end

---Resolve task.env, merging with the process environment unless task.clear_env is set.
---@param task table
---@return table<string,string>|nil
local function _resolve_env(task)
    return task.clear_env and task.env or vim.tbl_extend("force", vim.fn.environ(), task.env or {})
end

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
    ctx.add_bufnr(handle.bufnr, "debugpy", -2)
    config.port = port
    vim.defer_fn(function() done(nil, { handle = handle }) end, 500)
end

M.debugpy = {
    command            = "python3",
    setup              = _debugpy_setup,
    teardown           = function(_, ctx) if ctx then ctx.handle.stop() end end,

    derive_launch_args = function(task)
        local program, extra_args = _split_command(task)
        local args = {
            type            = "python",
            program         = program,
            args            = extra_args,
            cwd             = task.cwd or vim.fn.getcwd(),
            justMyCode      = false,
            console         = "integratedTerminal",
            stopOnEntry     = false,
            showReturnValue = true,
        }
        args.env = _resolve_env(task)
        if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,

    derive_attach_args = function(task)
        local args = { processId = 0 }
        if task.cwd ~= nil then args.cwd = task.cwd end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,
}

-- task.command maps to `module` (the Python module name, not a file path)
M["debugpy-module"] = {
    command            = "python3",
    setup              = _debugpy_setup,
    teardown           = function(_, ctx) if ctx then ctx.handle.stop() end end,

    derive_launch_args = function(task)
        local module_name, extra_args = _split_command(task)
        local args = {
            type        = "python",
            module      = module_name,
            args        = extra_args,
            cwd         = task.cwd or vim.fn.getcwd(),
            justMyCode  = false,
            console     = "integratedTerminal",
            stopOnEntry = false,
        }
        args.env = _resolve_env(task)
        if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,

    derive_attach_args = function(task)
        local args = { processId = 0 }
        if task.cwd ~= nil then args.cwd = task.cwd end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,
}

-- Attach to a remote Python process running debugpy.
-- task.host / task.port point to the REMOTE process; the local debugpy adapter
-- is spawned by _debugpy_setup and connects to it via the `connect` args.
M["debugpy-remote"] = {
    command            = "python3",
    setup              = _debugpy_setup,
    teardown           = function(_, ctx) if ctx then ctx.handle.stop() end end,
    request            = "attach",

    derive_attach_args = function(task)
        return {
            type       = "python",
            connect    = {
                host = task.host or "127.0.0.1",
                port = task.port or 5678,
            },
            justMyCode = false,
        }
    end,
}

M.codelldb = {
    command            = "codelldb",
    derive_launch_args = function(task)

        local program, extra_args = _split_command(task)
        local args = {
            type        = "lldb",
            program     = program,
            args        = extra_args,
            cwd         = task.cwd or vim.fn.getcwd(),
            stopOnEntry = false,
        }
        args.env = _resolve_env(task)
        if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,

    derive_attach_args = function(task)
        local args = { type = "lldb", pid = 0 }
        if task.cwd ~= nil then args.cwd = task.cwd end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,
}

M["lldb-dap"] = {
    command = "lldb-dap",

    derive_launch_args = function(task)
        local program, extra_args = _split_command(task)
        local args = {
            type    = "lldb-dap",
            program = program,
            args    = extra_args,
            cwd     = task.cwd or ".",
        }
        args.env = _resolve_env(task)
        if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,

    derive_attach_args = function(task)
        local args = { type = "lldb-dap", pid = 0 }
        if task.cwd ~= nil then args.cwd = task.cwd end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,
}

M.gdb = {
    command            = { "gdb", "--interpreter=dap" },
    derive_launch_args = function(task)
        local program, extra_args = _split_command(task)
        local args = {
            request                         = "launch",
            program                         = program,
            args                            = extra_args,
        }
        if task.cwd ~= nil then args.cwd = task.cwd end
        args.env = _resolve_env(task)
        if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,

    derive_attach_args = function(task)
        local args = { pid = 0 }
        if task.cwd ~= nil then args.cwd = task.cwd end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,
}

-- netcoredbg uses stopAtEntry instead of the standard stopOnEntry
M.netcoredbg = {
    command = { "netcoredbg", "--interpreter=vscode" },

    derive_launch_args = function(task)
        local program, extra_args = _split_command(task)
        local args = {
            program     = program,
            args        = extra_args,
            cwd         = task.cwd or vim.fn.getcwd(),
            stopAtEntry = false,
        }
        args.env = _resolve_env(task)
        if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
        if task.stop_on_entry ~= nil then args.stopAtEntry = task.stop_on_entry end
        return args
    end,

    derive_attach_args = function(task)
        local args = { processId = 0 }
        if task.cwd ~= nil then args.cwd = task.cwd end
        if task.stop_on_entry ~= nil then args.stopAtEntry = task.stop_on_entry end
        return args
    end,
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
    host               = "127.0.0.1",
    port               = 0,
    request            = "attach",

    derive_attach_args = function(task)
        local args = {}
        if task.host ~= nil then args.host = task.host end
        if task.port ~= nil then args.port = task.port end
        return args
    end,
}

M.lldb = {
    command            = "lldb-dap",
    derive_launch_args = function(task)
        local program, extra_args = _split_command(task)
        local args = {
            type          = "lldb",
            program       = program,
            args          = extra_args,
            cwd           = task.cwd or vim.fn.getcwd(),
            stopOnEntry   = false,
            runInTerminal = true,
        }
        args.env = _resolve_env(task)
        if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,

    derive_attach_args = function(task)
        local args = { type = "lldb", pid = 0 }
        if task.cwd ~= nil then args.cwd = task.cwd end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,
}

-- Go — dlv dap communicates over stdio; no TCP setup required.
-- program defaults to the current directory (debug the package at cwd).
M.delve = {
    command            = { "dlv", "dap" },
    derive_launch_args = function(task)
        local program, extra_args
        if task.command ~= nil then
            program, extra_args = _split_command(task)
        else
            program    = vim.fn.getcwd()
            extra_args = {}
        end
        local args = {
            mode    = "debug",
            program = program,
            args    = extra_args,
            cwd     = task.cwd or vim.fn.getcwd(),
        }
        args.env = _resolve_env(task)
        if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,

    derive_attach_args = function(task)
        local args = { mode = "local", processId = 0 }
        if task.cwd ~= nil then args.cwd = task.cwd end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,
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
        ctx.add_bufnr(handle.bufnr, "js-debug server", -2)
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

    derive_launch_args = function(task)
        local program, extra_args = _split_command(task)
        local args = {
            type              = "pwa-node",
            program           = program,
            args              = extra_args,
            cwd               = task.cwd or vim.fn.getcwd(),
            runtimeExecutable = "node",
        }
        args.env = _resolve_env(task)
        if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,

    derive_attach_args = function(task)
        local args = { type = "pwa-node", port = 9229 }
        if task.cwd ~= nil then args.cwd = task.cwd end
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,
}

-- bash-debug-adapter has adapter-specific path fields; run_in_terminal is excluded
-- because the adapter manages its own terminal kind via terminalKind.
M["bash-debug-adapter"] = {
    command            = "bash-debug-adapter",
    derive_launch_args = function(task)
        local program, extra_args = _split_command(task)
        local data_dir            = vim.fn.stdpath("data")
        local bashdb_path         = vim.fs.joinpath(data_dir, "mason", "packages", "bash-debug-adapter", "bashdb")
        local args                = {
            type          = "bashdb",
            name          = "Launch Bash Script",
            program       = program,
            args          = extra_args,
            cwd           = task.cwd or vim.fn.getcwd(),
            pathBash      = "bash",
            pathBashdb    = vim.fn.filereadable(bashdb_path) == 1 and bashdb_path or "bashdb",
            pathBashdbLib = vim.fs.joinpath(data_dir, "mason", "packages", "bash-debug-adapter"),
            pathCat       = "cat",
            pathMkfifo    = "mkfifo",
            pathPkill     = "pkill",
            terminalKind  = "integrated",
        }
        args.env                  = _resolve_env(task)
        if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
        return args
    end,
}

-- PHP — listens for an Xdebug connection; task fields do not apply.
M["php-debug-adapter"] = {
    command            = "php-debug-adapter",
    derive_launch_args = function(_)
        return { type = "php", name = "Listen for Xdebug", cwd = vim.fn.getcwd(), port = 9003 }
    end,
}

-- Lua — task.command maps to program.file (first token); remaining args are not forwarded
-- because the js-based adapter embeds them inside the program table, not at the top level.
local _lua_debugger_adapter_js = vim.fs.joinpath(
    vim.fn.stdpath("data"), "mason", "packages",
    "local-lua-debugger-vscode", "extension", "debugAdapter.js"
)
M["local-lua-debugger"] = {
    command            = { "node", _lua_debugger_adapter_js },
    command_env        = {
        LUA_PATH = vim.fs.joinpath(
            vim.fn.stdpath("data"), "mason", "packages",
            "local-lua-debugger-vscode", "debugger", "?.lua"
        ) .. ";;",
    },

    derive_launch_args = function(task)
        local file = _split_command(task)
        return {
            type    = "lua-local",
            name    = "Debug",
            program = {
                lua           = vim.fn.exepath("lua"),
                file          = file,
                communication = "stdio",
            },
        }
    end,
}

return M
