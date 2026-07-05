---@brief Built-in DAP adapter definitions.
---
---The module is a plain table: each key is an adapter name, each value is an
---AdapterDef — native DAP process/connection config (command, host/port,
---setup/teardown, request, …) plus optional `launch_schema`/`attach_schema`
---describing that adapter's own launch/attach parameters. The schemas are what
---`:Debug new_task`/`run_target` read (via `easydap.schema`) to scaffold a task
---file / assemble a native request body; the DAP core never touches them.
---Users can add adapters or override existing ones directly:
---  local adapters = require("easydap.adapters")
---  adapters.myAdapter = { command = "...", request = "launch" }

---@type table<string, easydap.AdapterDef>
local M = {}

-- ── Type annotations ──────────────────────────────────────────────────────

---Context passed to `config.setup()` so the adapter can report progress and
---register terminal buffers with the task runner.
---@class easydap.AdapterSetupCtx
---@field add_bufnr fun(bufnr: integer, opts?: easydap.AddBufOpts)
---@field report    fun(message: string)

---One parameter of an adapter's launch/attach schema. `type` is the value's pure
---Lua/JSON type. `kind` is an optional *data* refinement (file/dir/env/enum/host/
---port/list) driving CLI-string coercion, completion and validation (a `kind`
---implies its `type`). `role` is an optional *value-meaning* marker (target/args)
---tagging the program/arguments fields so `run_target` can find them across
---adapters.
---
---A schema is a `table<string, easydap.ParamSpec>`. A value may instead be a nested
---group — a ParamSpec with `type = "schema"` holding its children under `fields`
---— which produces a nested body table (e.g. a `connect` group → body.connect).
---Group children are addressed by their dotted path (`connect.host`).
---@class easydap.ParamSpec
---@field type?     "string"|"boolean"|"integer"|"number"|"table"|"list"|"schema"
---@field kind?     "env"|"enum"|"host"|"port"|"file"|"dir"   data refinement
---@field role?     "target"|"args"    value meaning; maps program/args for run_target
---@field fields?   table<string, easydap.ParamSpec>  child specs when `type == "schema"`
---@field enum?     any[]              allowed values when `kind == "enum"`
---@field desc?     string
---@field default?  any|fun():any      value used when the caller omits the key
---@field required? boolean

---A static adapter definition — the launch/attach template for one adapter.
---Entries of this module are values of this type. It is NOT the per-run config
---the DAP layer consumes: the task runner resolves an `AdapterDef` + a task into
---an `easydap.dap.Config` (see [dap/client.lua](dap/client.lua)). No
---`request_args` here — that is a per-run value carried by the resolved config.
---`setup`/`teardown` receive that resolved config (setup may mutate host/port).
---`launch_schema`/`attach_schema` describe the adapter's own DAP parameters and
---are consumed only by `easydap.schema` (for new_task/run_target), never by the DAP core.
---@class easydap.AdapterDef
---@field command?               string|string[]
---@field command_cwd?           string
---@field command_env?           table<string,string>
---@field command_insert_stderr? boolean
---@field host?                  string
---@field port?                  integer
---@field type?                  string   DAP adapterID override (defaults to the adapter name)
---@field defer_launch_attach?   boolean
---@field request?               string
---@field launch_schema?         table<string, easydap.ParamSpec>
---@field attach_schema?         table<string, easydap.ParamSpec>
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

-- ── Common param specs ─────────────────────────────────────────────────────
-- Read-only ParamSpec fragments reused across the process-launching adapters.
-- Adapters whose defaults differ (e.g. lldb's runInTerminal, delve's program)
-- spell those entries out inline instead of sharing these.

-- `role = "target"` marks the launch program — the thing `run_target` fills from
-- its `<program>` argument. It coerces like a file path; the role is what lets
-- run_target locate this field generically across adapters (which name it
-- `program`/`module`/`file`). `role = "args"` similarly marks the arguments field.
-- (`kind = "file"`/`"dir"` are plain path params, split only so completion knows
-- which to offer.)
---@type easydap.ParamSpec
local _program = { type = "string", role = "target", desc = "program to debug" }
---@type easydap.ParamSpec
local _args = { type = "list", role = "args", desc = "program arguments" }
---@type easydap.ParamSpec
local _cwd = { type = "string", kind = "dir", desc = "working directory" }
---@type easydap.ParamSpec
local _env = { type = "table", kind = "env", desc = "environment: VAR=VAL,VAR2=VAL2" }
---@type easydap.ParamSpec
local _run_in_terminal = { type = "boolean", desc = "run in the integrated terminal" }

---A comma-separated list of verbatim LLDB command lines (each kept whole).
---@param desc string
---@return easydap.ParamSpec
local function _lldb_cmds(desc)
    return { type = "list", desc = desc }
end

-- ParamSpecs common to lldb-dap's launch and attach requests (see
-- https://lldb.llvm.org/use/lldbdap.html). Merged into both schemas below.
---@type table<string, easydap.ParamSpec>
local _lldb_common = {
    sourcePath                    = { type = "string", kind = "dir",
        desc = "remap './' so relative-source binaries resolve breakpoints" },
    sourceMap                     = { type = "table",
        desc = "source path re-mappings (array of [from, to] pairs)" },
    debuggerRoot                  = { type = "string", kind = "dir",
        desc = "working directory lldb-dap uses to locate sources/objects" },
    commandEscapePrefix           = { type = "string",
        desc = "prefix for running LLDB commands in the debug console (default '`')" },
    customFrameFormat             = { type = "string", desc = "format string for stack frame labels" },
    customThreadFormat            = { type = "string", desc = "format string for thread labels" },
    displayExtendedBacktrace      = { type = "boolean", desc = "enable language-specific extended backtraces" },
    enableAutoVariableSummaries   = { type = "boolean", desc = "auto-generate variable summaries when none exist" },
    enableSyntheticChildDebugging = { type = "boolean", desc = "show synthetic children alongside raw contents" },
    initCommands                  = _lldb_cmds("LLDB commands run when the debugger starts"),
    preRunCommands                = _lldb_cmds("LLDB commands run before launch/attach"),
    stopCommands                  = _lldb_cmds("LLDB commands run after each stop"),
    exitCommands                  = _lldb_cmds("LLDB commands run when the program exits"),
    terminateCommands             = _lldb_cmds("LLDB commands run when the session ends"),
}

-- Shared by debugpy and debugpy-module (both attach the same way).
---@type table<string, easydap.ParamSpec>
local _debugpy_attach_schema = {
    processId   = { type = "integer", desc = "PID to attach to" },
    cwd         = _cwd,
    stopOnEntry = { type = "boolean", desc = "stop at entry" },
}

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
    launch_schema      = {
        type            = { default = "python" },
        program         = _program,
        args            = _args,
        cwd             = _cwd,
        env             = _env,
        justMyCode      = { type = "boolean", desc = "debug only user code", default = false },
        console         = { type = "string", kind = "enum", default = "integratedTerminal",
            enum = { "integratedTerminal", "internalConsole", "externalTerminal" }, desc = "console kind" },
        stopOnEntry     = { type = "boolean", desc = "stop at entry", default = false },
        showReturnValue = { type = "boolean", desc = "show function return values", default = true },
        runInTerminal   = _run_in_terminal,
    },
    attach_schema      = _debugpy_attach_schema,
}

-- `module` is the Python module name (not a file path); everything else mirrors debugpy.
M["debugpy-module"] = {
    command            = "python3",
    setup              = _debugpy_setup,
    teardown           = function(_, ctx) if ctx then ctx.handle.stop() end end,
    launch_schema      = {
        type          = { default = "python" },
        module        = { type = "string", role = "target", desc = "python module name" },
        args          = _args,
        cwd           = _cwd,
        env           = _env,
        justMyCode    = { type = "boolean", desc = "debug only user code", default = false },
        console       = { type = "string", kind = "enum", default = "integratedTerminal",
            enum = { "integratedTerminal", "internalConsole", "externalTerminal" }, desc = "console kind" },
        stopOnEntry   = { type = "boolean", desc = "stop at entry", default = false },
        runInTerminal = _run_in_terminal,
    },
    attach_schema      = _debugpy_attach_schema,
}

-- Attach to a remote Python process running debugpy.
-- task.host / task.port point to the REMOTE process; the local debugpy adapter
-- is spawned by _debugpy_setup and connects to it via the `connect` args.
M["debugpy-remote"] = {
    command            = "python3",
    setup              = _debugpy_setup,
    teardown           = function(_, ctx) if ctx then ctx.handle.stop() end end,
    request            = "attach",
    -- The `connect` group targets the REMOTE process and goes in the body's
    -- `connect`, not the task-level connection (the local adapter port is chosen
    -- by _debugpy_setup). Set them as `connect.host` / `connect.port`.
    attach_schema      = {
        type       = { default = "python" },
        connect    = {
            type   = "schema",
            fields = {
                host = { type = "string", kind = "host", desc = "remote host", default = "127.0.0.1" },
                port = { type = "integer", kind = "port", desc = "remote port", default = 5678 },
            },
        },
        justMyCode = { type = "boolean", desc = "debug only user code", default = false },
    },
}

M.codelldb = {
    command       = "codelldb",
    launch_schema = {
        type          = { default = "lldb" },
        program       = _program,
        args          = _args,
        cwd           = _cwd,
        env           = _env,
        stopOnEntry   = { type = "boolean", desc = "stop at entry", default = false },
        runInTerminal = _run_in_terminal,
    },
    attach_schema = {
        type        = { default = "lldb" },
        pid         = { type = "integer", desc = "PID to attach to" },
        cwd         = _cwd,
        stopOnEntry = { type = "boolean", desc = "stop at entry" },
    },
}

M.gdb = {
    command       = { "gdb", "--interpreter=dap" },
    launch_schema = {
        request       = { default = "launch" },
        program       = _program,
        args          = _args,
        cwd           = _cwd,
        env           = _env,
        stopOnEntry   = { type = "boolean", desc = "stop at entry" },
        runInTerminal = _run_in_terminal,
    },
    attach_schema = {
        pid         = { type = "integer", desc = "PID to attach to" },
        cwd         = _cwd,
        stopOnEntry = { type = "boolean", desc = "stop at entry" },
    },
}

-- netcoredbg uses stopAtEntry instead of the standard stopOnEntry
M.netcoredbg = {
    command       = { "netcoredbg", "--interpreter=vscode" },
    launch_schema = {
        program       = _program,
        args          = _args,
        cwd           = _cwd,
        env           = _env,
        stopAtEntry   = { type = "boolean", desc = "stop at entry", default = false },
        runInTerminal = _run_in_terminal,
    },
    attach_schema = {
        processId   = { type = "integer", desc = "PID to attach to" },
        cwd         = _cwd,
        stopAtEntry = { type = "boolean", desc = "stop at entry" },
    },
}

-- Generic TCP attach — connect to a DAP server already listening on host:port.
-- host/port live at the task level (they set the connection), so the attach body
-- itself stays minimal.
M.remote = {
    host          = "127.0.0.1",
    port          = 0,
    request       = "attach",
    attach_schema = {
        stopOnEntry = { type = "boolean", desc = "stop at entry" },
    },
}

-- Java — expects an external debug server (e.g. started by nvim-jdtls). Unlike
-- `remote`, this adapter also wants host/port echoed into the attach body.
M["java-debug-server"] = {
    host          = "127.0.0.1",
    port          = 0,
    request       = "attach",
    attach_schema = {
        host = { type = "string", kind = "host", desc = "debug server host" },
        port = { type = "integer", kind = "port", desc = "debug server port" },
    },
}

-- lldb-dap — the launch/attach parameters mirror the LLVM docs
-- (https://lldb.llvm.org/use/lldbdap.html). `_lldb_common` supplies the source
-- remapping / formatting / command-hook fields shared by both requests.
M.lldb = {
    command       = "lldb-dap",
    launch_schema = vim.tbl_extend("error", {
        type           = { default = "lldb" },
        program        = _program,
        args           = _args,
        cwd            = _cwd,
        env            = _env,
        stdio          = { type = "list", desc = "redirection targets for the program's stdio streams" },
        stopOnEntry    = { type = "boolean", desc = "stop at entry", default = false },
        console        = { type = "string", kind = "enum", default = "integratedTerminal",
            enum = { "internalConsole", "integratedTerminal", "externalTerminal" },
            desc = "where to launch the program (supersedes runInTerminal)" },
        launchCommands = _lldb_cmds("LLDB commands run to launch the program (replaces the default launch)"),
    }, _lldb_common),
    attach_schema = vim.tbl_extend("error", {
        type             = { default = "lldb" },
        program          = { type = "string", kind = "file", desc = "path to the executable (helps locate the binary)" },
        pid              = { type = "integer", desc = "PID to attach to" },
        waitFor          = { type = "boolean", desc = "wait for the next process matching `program` to launch" },
        attachCommands   = _lldb_cmds("LLDB commands run to perform the attach (replaces the default attach)"),
        coreFile         = { type = "string", kind = "file", desc = "core file to debug" },
        ["gdb-remote-port"] = { type = "integer", kind = "port", desc = "TCP port to attach to on a remote system" },
        ["gdb-remote-host"] = { type = "string", kind = "host", desc = "hostname of the remote system (default localhost)" },
    }, _lldb_common),
}

-- Go — dlv dap communicates over stdio; no TCP setup required. `program` defaults
-- to the current directory (debug the package at cwd).
M.delve = {
    command       = { "dlv", "dap" },
    launch_schema = {
        mode          = { type = "string", kind = "enum", default = "debug",
            enum = { "debug", "test", "exec", "replay", "core" }, desc = "dlv launch mode" },
        program       = { type = "string", role = "target", desc = "package or binary (defaults to cwd)",
            default = function() return vim.fn.getcwd() end },
        args          = _args,
        cwd           = _cwd,
        env           = _env,
        stopOnEntry   = { type = "boolean", desc = "stop at entry" },
        runInTerminal = _run_in_terminal,
    },
    attach_schema = {
        mode        = { type = "string", kind = "enum", enum = { "local", "remote" }, default = "local", desc = "dlv attach mode" },
        processId   = { type = "integer", desc = "PID to attach to" },
        cwd         = _cwd,
        stopOnEntry = { type = "boolean", desc = "stop at entry" },
    },
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

    launch_schema = {
        type              = { default = "pwa-node" },
        program           = _program,
        args              = _args,
        runtimeExecutable = { type = "string", desc = "node executable", default = "node" },
        cwd               = _cwd,
        env               = _env,
        stopOnEntry       = { type = "boolean", desc = "stop at entry" },
        runInTerminal     = _run_in_terminal,
    },
    attach_schema = {
        type        = { default = "pwa-node" },
        port        = { type = "integer", kind = "port", desc = "inspector port", default = 9229 },
        cwd         = _cwd,
        stopOnEntry = { type = "boolean", desc = "stop at entry" },
    },
}

-- bash-debug-adapter has adapter-specific path fields; runInTerminal is omitted
-- because the adapter manages its own terminal via terminalKind.
M["bash-debug-adapter"] = {
    command       = "bash-debug-adapter",
    launch_schema = {
        type          = { default = "bashdb" },
        name          = { default = "Launch Bash Script" },
        program       = { type = "string", role = "target", desc = "bash script to debug" },
        args          = _args,
        cwd           = _cwd,
        env           = _env,
        pathBash      = { default = "bash" },
        pathBashdb    = { default = "bash-debug-adapter" },
        pathBashdbLib = { default = function()
            return vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter")
        end },
        pathCat       = { default = "cat" },
        pathMkfifo    = { default = "mkfifo" },
        pathPkill     = { default = "pkill" },
        terminalKind  = { default = "integrated" },
        stopOnEntry   = { type = "boolean", desc = "stop at entry" },
    },
}

-- PHP — listens for an Xdebug connection; there is no program to launch.
M["php-debug-adapter"] = {
    command       = "php-debug-adapter",
    launch_schema = {
        type = { default = "php" },
        name = { default = "Listen for Xdebug" },
        cwd  = { type = "string", kind = "dir", desc = "working directory", default = function() return vim.fn.getcwd() end },
        port = { type = "integer", kind = "port", desc = "Xdebug port", default = 9003 },
    },
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
    -- `program` is a nested table the js-based adapter consumes; the target file
    -- is set as `program.file`.
    launch_schema = {
        type    = { default = "lua-local" },
        name    = { default = "Debug" },
        program = {
            type   = "schema",
            fields = {
                lua           = { default = function() return vim.fn.exepath("lua") end },
                communication = { default = "stdio" },
                file          = { type = "string", role = "target", desc = "lua file to debug" },
            },
        },
    },
}

return M
