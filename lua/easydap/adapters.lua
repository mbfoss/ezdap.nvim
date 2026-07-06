---@brief Built-in DAP adapter definitions.
---
---The module is a plain table: each key is an adapter name, each value is an
---AdapterDef — native DAP process/connection config (command, host/port,
---setup/teardown, request, …) plus optional `launch_schema`/`attach_schema`
---describing that adapter's own launch/attach parameters. The schemas are what
---`:Debug new_run_file`/`run_target` read (via `easydap.schema`) to scaffold a run
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
---implies its `type`). `role` is an optional *value-meaning* marker
---(target/args/cwd/env for launch, pid/host/port for attach) tagging a field so
---`quick_run` can map its `role=value` inputs onto the adapter's native keys
---across adapters.
---
---A schema is a `table<string, easydap.ParamSpec>`. A value may instead be a nested
---group — a ParamSpec with `type = "schema"` holding its children under `fields`
---— which produces a nested body table (e.g. a `connect` group → body.connect).
---Group children are addressed by their dotted path (`connect.host`).
---@class easydap.ParamSpec
---@field type?     "string"|"boolean"|"integer"|"number"|"table"|"list"|"schema"
---@field kind?     "env"|"enum"|"host"|"port"|"file"|"dir"   data refinement
---@field role?     "target"|"args"|"cwd"|"env"|"pid"|"host"|"port"  value meaning; maps a field to a quick_run role
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
---are consumed only by `easydap.schema` (for new_run_file/run_target), never by the DAP core.
---@class easydap.AdapterDef
---@field command?               string|string[]
---@field cwd?                   string
---@field env?                   table<string,string>
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
-- Adapters whose defaults differ (e.g. delve's program, which defaults to cwd)
-- spell those entries out inline instead of sharing these.

-- These `role` tags let `quick_run` map its `role=value` inputs onto whatever
-- native keys an adapter uses. `role = "target"` marks the launch program (named
-- `program`/`module`/`file` across adapters), `args` the argument vector, `cwd`
-- the working directory, `env` the environment; the attach schemas below add
-- `pid` and the `host`/`port` endpoint. The role only *locates* the field —
-- coercion still follows its `kind`/`type`. (`kind = "file"`/`"dir"` are plain
-- path params, split only so completion knows which to offer.)
---@type easydap.ParamSpec
local _program = { type = "string", role = "target", desc = "program to debug" }
---@type easydap.ParamSpec
local _args = { type = "list", role = "args", desc = "program arguments" }
---@type easydap.ParamSpec
local _cwd = { type = "string", kind = "dir", role = "cwd", desc = "working directory" }
---@type easydap.ParamSpec
local _env = { type = "table", kind = "env", role = "env", desc = "environment: VAR=VAL,VAR2=VAL2" }

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

-- debugpy's "Debugger Settings" — the toggles shared by launch and attach per the
-- debugpy wiki (https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings).
-- `justMyCode`/`showReturnValue` keep easydap's existing defaults (debug all code,
-- show return values); the rest are omitted unless set, so debugpy applies its own
-- documented defaults.
---@type table<string, easydap.ParamSpec>
local _debugpy_common = {
    justMyCode      = { type = "boolean", desc = "debug only user-written code", default = false },
    showReturnValue = { type = "boolean", desc = "show function return values when stepping", default = true },
    django          = { type = "boolean", desc = "enable Django template debugging" },
    jinja           = { type = "boolean", desc = "enable Jinja2 template debugging (e.g. Flask)" },
    gevent          = { type = "boolean", desc = "debug gevent monkey-patched code" },
    pyramid         = { type = "boolean", desc = "debug Pyramid applications" },
    subProcess      = { type = "boolean", desc = "debug child processes (debugpy default true)" },
    redirectOutput  = { type = "boolean", desc = "redirect program output to the debug console" },
    logToFile       = { type = "boolean", desc = "log debugger events to a file" },
    sudo            = { type = "boolean", desc = "run the program with elevated privileges (Unix)" },
    pathMappings    = { type = "table", desc = "local<->remote path maps: array of {localRoot, remoteRoot}" },
}

-- Shared by debugpy and debugpy-module (both attach to a local process the same
-- way). `cwd`/`stopOnEntry` are launch-only per the docs, so attach carries only
-- the process selector plus the shared debugger settings.
---@type table<string, easydap.ParamSpec>
local _debugpy_attach_schema = vim.tbl_extend("error", {
    processId = { type = "integer", role = "pid", desc = "PID to attach to" },
}, _debugpy_common)

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
            cwd     = config.cwd or vim.fn.getcwd(),
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
    launch_schema      = vim.tbl_extend("error", {
        type        = { default = "python" },
        program     = _program,
        args        = _args,
        cwd         = _cwd,
        env         = _env,
        console     = { type = "string", kind = "enum", default = "integratedTerminal",
            enum = { "integratedTerminal", "internalConsole", "externalTerminal" }, desc = "where to launch the target" },
        stopOnEntry = { type = "boolean", desc = "stop at the first line of user code", default = false },
    }, _debugpy_common),
    attach_schema      = _debugpy_attach_schema,
}

-- `module` is the Python module name (not a file path); everything else mirrors debugpy.
M["debugpy-module"] = {
    command            = "python3",
    setup              = _debugpy_setup,
    teardown           = function(_, ctx) if ctx then ctx.handle.stop() end end,
    launch_schema      = vim.tbl_extend("error", {
        type        = { default = "python" },
        module      = { type = "string", role = "target", desc = "python module name" },
        args        = _args,
        cwd         = _cwd,
        env         = _env,
        console     = { type = "string", kind = "enum", default = "integratedTerminal",
            enum = { "integratedTerminal", "internalConsole", "externalTerminal" }, desc = "where to launch the target" },
        stopOnEntry = { type = "boolean", desc = "stop at the first line of user code", default = false },
    }, _debugpy_common),
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
    attach_schema      = vim.tbl_extend("error", {
        type    = { default = "python" },
        connect = {
            type   = "schema",
            fields = {
                host = { type = "string", kind = "host", role = "host", desc = "remote host", default = "127.0.0.1" },
                port = { type = "integer", kind = "port", role = "port", desc = "remote port", default = 5678 },
            },
        },
    }, _debugpy_common),
}

-- codelldb (vscode-lldb) — its own key set, distinct from lldb-dap. The command
-- hooks, source remapping and evaluator settings are shared by launch and attach;
-- the field set follows the CodeLLDB MANUAL
-- (https://github.com/vadimcn/codelldb/blob/master/MANUAL.md). codelldb uses
-- `terminal` (not `runInTerminal`) to pick the debuggee's stdio destination.
---@type table<string, easydap.ParamSpec>
local _codelldb_common = {
    initCommands          = _lldb_cmds("LLDB commands executed on debugger startup (no target yet)"),
    targetCreateCommands  = _lldb_cmds("LLDB commands executed to create the debug target"),
    preRunCommands        = _lldb_cmds("LLDB commands executed just before launch/attach"),
    processCreateCommands = _lldb_cmds("LLDB commands executed to create/attach the process"),
    postRunCommands       = _lldb_cmds("LLDB commands executed just after launch/attach"),
    exitCommands          = _lldb_cmds("LLDB commands executed at the end of the session"),
    expressions           = { type = "string", kind = "enum", enum = { "simple", "python", "native" },
        desc = "default expression evaluator type" },
    sourceMap             = { type = "table", desc = "source path re-mappings (dictionary)" },
    relativePathBase      = { type = "string", kind = "dir", desc = "base dir for resolving relative source paths" },
    sourceLanguages       = { type = "list", desc = "source languages used in the program" },
    breakpointMode        = { type = "string", kind = "enum", enum = { "path", "file" },
        desc = "how source breakpoints resolve locations" },
}

M.codelldb = {
    command       = "codelldb",
    launch_schema = vim.tbl_extend("error", {
        type        = { default = "lldb" },
        program     = _program,
        args        = _args,
        cwd         = _cwd,
        env         = _env,
        envFile     = { type = "string", kind = "file", desc = "file with additional environment variables" },
        stdio       = { type = "list", desc = "stdio redirection targets, in order [stdin, stdout, stderr]" },
        terminal    = { type = "string", kind = "enum", enum = { "console", "integrated", "external" },
            default = "integrated", desc = "destination for the debuggee's stdio streams" },
        stopOnEntry = { type = "boolean", desc = "stop the debuggee immediately after launch", default = false },
    }, _codelldb_common),
    attach_schema = vim.tbl_extend("error", {
        type        = { default = "lldb" },
        program     = { type = "string", kind = "file", desc = "path to the executable on the host" },
        pid         = { type = "integer", role = "pid", desc = "process id to attach to (omit to locate a running instance)" },
        waitFor     = { type = "boolean", desc = "wait for the process to launch" },
        stopOnEntry = { type = "boolean", desc = "stop the debuggee immediately after attaching" },
    }, _codelldb_common),
}

-- GDB speaks DAP natively via `--interpreter=dap`. Unlike the VS Code C/C++
-- adapters, GDB defines its own launch/attach parameters; these mirror the GDB
-- manual's "Debugger Adapter Protocol" chapter
-- (https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html).
-- `program` and `adaSourceCharset` are common to both requests; the rest are
-- request-specific. GDB has no `runInTerminal`/`type`/body-level `request` field,
-- so none are declared here.
M.gdb = {
    command       = { "gdb", "--interpreter=dap" },
    launch_schema = {
        program                         = _program,
        args                            = _args,
        cwd                             = _cwd,
        env                             = _env,
        -- Temporary breakpoint at the first instruction (like `starti`).
        stopOnEntry                     = { type = "boolean", desc = "stop at the program's first instruction" },
        -- Temporary breakpoint at main (like `start`).
        stopAtBeginningOfMainSubprogram = { type = "boolean", desc = "stop at the beginning of main" },
        adaSourceCharset                = { type = "string", desc = "Ada source character set" },
    },
    -- One of pid / target / coreFile identifies what to attach to; GDB checks
    -- them in that order and uses the first present.
    attach_schema = {
        program          = { type = "string", kind = "file",
            desc = "program to debug (supply for remote targets GDB can't auto-detect)" },
        pid              = { type = "integer", role = "pid", desc = "process ID to attach to" },
        target           = { type = "string", desc = "target to connect to (passed to `target remote`)" },
        coreFile         = { type = "string", kind = "file", desc = "core file to debug" },
        adaSourceCharset = { type = "string", desc = "Ada source character set" },
    },
}

-- netcoredbg uses `stopAtEntry` instead of the standard stopOnEntry. Field set
-- matches the keys netcoredbg's VS Code protocol handler reads
-- (Samsung/netcoredbg, src/protocols/vscodeprotocol.cpp); `justMyCode` and
-- `enableStepFiltering` default to true there. No runInTerminal/console arg.
M.netcoredbg = {
    command       = { "netcoredbg", "--interpreter=vscode" },
    launch_schema = {
        program             = _program,
        args                = _args,
        cwd                 = _cwd,
        env                 = _env,
        stopAtEntry         = { type = "boolean", desc = "stop at entry", default = false },
        justMyCode          = { type = "boolean", desc = "debug only user-written code (default true)" },
        enableStepFiltering = { type = "boolean", desc = "skip properties and operators while stepping (default true)" },
    },
    attach_schema = {
        processId   = { type = "integer", role = "pid", desc = "PID to attach to" },
        cwd         = _cwd,
        stopAtEntry = { type = "boolean", desc = "stop at entry" },
        justMyCode  = { type = "boolean", desc = "debug only user-written code (default true)" },
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
-- `remote`, this adapter also wants the JVM's JDWP endpoint echoed into the attach
-- body. com.microsoft.java.debug reads `hostName`/`port` (not `host`); the field
-- set follows microsoft/vscode-java-debug's attach configuration.
M["java-debug-server"] = {
    host          = "127.0.0.1",
    port          = 0,
    request       = "attach",
    attach_schema = {
        hostName    = { type = "string", kind = "host", role = "host", desc = "JVM debug (JDWP) host", default = "localhost" },
        port        = { type = "integer", kind = "port", role = "port", desc = "JVM debug (JDWP) port" },
        timeout     = { type = "integer", desc = "attach timeout in milliseconds", default = 30000 },
        projectName = { type = "string", desc = "project name (helps resolve sources/classpaths)" },
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
        pid              = { type = "integer", role = "pid", desc = "PID to attach to" },
        waitFor          = { type = "boolean", desc = "wait for the next process matching `program` to launch" },
        attachCommands   = _lldb_cmds("LLDB commands run to perform the attach (replaces the default attach)"),
        coreFile         = { type = "string", kind = "file", desc = "core file to debug" },
        ["gdb-remote-port"] = { type = "integer", kind = "port", role = "port", desc = "TCP port to attach to on a remote system" },
        ["gdb-remote-host"] = { type = "string", kind = "host", role = "host", desc = "hostname of the remote system (default localhost)" },
    }, _lldb_common),
}

-- Go — dlv dap communicates over stdio; no TCP setup required. `program` defaults
-- to the current directory (debug the package at cwd). Field set follows vscode-go's
-- launch.json attributes for dlv-dap mode
-- (https://github.com/golang/vscode-go/blob/master/docs/debugging.md); the delve /
-- source-remapping settings below are shared by launch and attach.
---@type table<string, easydap.ParamSpec>
local _delve_common = {
    backend             = { type = "string", kind = "enum", enum = { "default", "native", "lldb", "rr" },
        desc = "backend used by delve (dlv --backend)" },
    stackTraceDepth     = { type = "integer", desc = "max stack trace depth collected from delve" },
    showGlobalVariables = { type = "boolean", desc = "show global package variables" },
    showLog             = { type = "boolean", desc = "show delve log output (dlv --log)" },
    substitutePath      = { type = "table", desc = "local<->remote path maps: array of {from, to}" },
    dlvFlags            = { type = "list", desc = "extra flags passed to dlv" },
}

M.delve = {
    command       = { "dlv", "dap" },
    launch_schema = vim.tbl_extend("error", {
        mode         = { type = "string", kind = "enum", default = "debug",
            enum = { "debug", "test", "exec", "replay", "core" }, desc = "dlv launch mode" },
        program      = { type = "string", role = "target", desc = "package or binary (defaults to cwd)",
            default = function() return vim.fn.getcwd() end },
        args         = _args,
        cwd          = _cwd,
        env          = _env,
        buildFlags   = { type = "list", desc = "build flags passed to the Go compiler" },
        output       = { type = "string", kind = "file", desc = "output path for the debug binary" },
        stopOnEntry  = { type = "boolean", desc = "stop at entry" },
        coreFilePath = { type = "string", kind = "file", desc = "core dump to open (core mode)" },
        traceDirPath = { type = "string", kind = "dir", desc = "trace directory (replay mode)" },
    }, _delve_common),
    attach_schema = vim.tbl_extend("error", {
        mode        = { type = "string", kind = "enum", enum = { "local", "remote" }, default = "local", desc = "dlv attach mode" },
        processId   = { type = "integer", role = "pid", desc = "PID to attach to" },
        cwd         = _cwd,
        stopOnEntry = { type = "boolean", desc = "stop at entry" },
    }, _delve_common),
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

    -- Field set follows vscode-js-debug's `node` launch/attach options
    -- (https://github.com/microsoft/vscode-js-debug/blob/main/OPTIONS.md). js-debug
    -- picks the debuggee's console via `console`, not runInTerminal.
    launch_schema = {
        type              = { default = "pwa-node" },
        program           = _program,
        args              = _args,
        runtimeExecutable = { type = "string", desc = "runtime to launch (e.g. node, npm)", default = "node" },
        runtimeArgs       = { type = "list", desc = "arguments passed to the runtime executable" },
        runtimeVersion    = { type = "string", desc = "node version to use (requires nvm/nvs)" },
        cwd               = _cwd,
        env               = _env,
        envFile           = { type = "string", kind = "file", desc = "file with environment variable definitions" },
        console           = { type = "string", kind = "enum", default = "internalConsole",
            enum = { "internalConsole", "integratedTerminal", "externalTerminal" }, desc = "where to launch the target" },
        stopOnEntry       = { type = "boolean", desc = "stop at entry" },
        skipFiles         = { type = "list", desc = "glob patterns to skip while stepping" },
        sourceMaps        = { type = "boolean", desc = "use JavaScript source maps (default true)" },
        outFiles          = { type = "list", desc = "glob patterns locating generated JS" },
        smartStep         = { type = "boolean", desc = "automatically step over un-source-mapped lines" },
        autoAttachChildProcesses = { type = "boolean", desc = "attach to child processes automatically" },
    },
    attach_schema = {
        type             = { default = "pwa-node" },
        port             = { type = "integer", kind = "port", role = "port", desc = "inspector port", default = 9229 },
        address          = { type = "string", kind = "host", role = "host", desc = "inspector host", default = "localhost" },
        processId        = { type = "integer", role = "pid", desc = "process id to attach to" },
        continueOnAttach = { type = "boolean", desc = "continue the program if it is paused when attached" },
        restart          = { type = "boolean", desc = "reconnect if the connection is lost" },
        cwd              = _cwd,
        localRoot        = { type = "string", kind = "dir", desc = "local directory containing the program" },
        remoteRoot       = { type = "string", desc = "remote directory containing the program" },
        skipFiles        = { type = "list", desc = "glob patterns to skip while stepping" },
        sourceMaps       = { type = "boolean", desc = "use JavaScript source maps (default true)" },
        outFiles         = { type = "list", desc = "glob patterns locating generated JS" },
        timeout          = { type = "integer", desc = "retry connecting for this many milliseconds" },
    },
}

-- bash-debug-adapter has adapter-specific path fields; runInTerminal is omitted
-- because the adapter manages its own terminal via terminalKind. Field set follows
-- rogalmic/vscode-bash-debug's launch attributes — note it has no stopOnEntry
-- (bashdb always breaks at the first line).
M["bash-debug-adapter"] = {
    command       = "bash-debug-adapter",
    launch_schema = {
        type            = { default = "bashdb" },
        name            = { default = "Launch Bash Script" },
        program         = { type = "string", role = "target", desc = "bash script to debug" },
        args            = _args,
        cwd             = _cwd,
        env             = _env,
        pathBash        = { default = "bash" },
        pathBashdb      = { default = "bash-debug-adapter" },
        pathBashdbLib   = { default = function()
            return vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter")
        end },
        pathCat         = { default = "cat" },
        pathMkfifo      = { default = "mkfifo" },
        pathPkill       = { default = "pkill" },
        terminalKind    = { default = "integrated" },
        showDebugOutput = { type = "boolean", desc = "show bashdb output alongside the script output" },
    },
}

-- PHP — listens for an Xdebug connection; there is no program to launch. Listen-mode
-- settings follow xdebug/vscode-php-debug's launch.json reference.
M["php-debug-adapter"] = {
    command       = "php-debug-adapter",
    launch_schema = {
        type           = { default = "php" },
        name           = { default = "Listen for Xdebug" },
        cwd            = { type = "string", kind = "dir", role = "cwd", desc = "working directory", default = function() return vim.fn.getcwd() end },
        port           = { type = "integer", kind = "port", desc = "port to listen for Xdebug", default = 9003 },
        hostname       = { type = "string", kind = "host", desc = "address to bind when listening" },
        stopOnEntry    = { type = "boolean", desc = "break at the beginning of the script", default = false },
        pathMappings   = { type = "table", desc = "server<->local source path maps" },
        log            = { type = "boolean", desc = "log adapter<->client communication to the debug console" },
        maxConnections = { type = "integer", desc = "max parallel debugging sessions to accept" },
        ignore         = { type = "list", desc = "glob patterns of files to ignore errors from" },
        skipFiles      = { type = "list", desc = "glob patterns to skip while stepping" },
    },
}

-- Lua
local _lua_debugger_adapter_js = vim.fs.joinpath(
    vim.fn.stdpath("data"), "mason", "packages",
    "local-lua-debugger-vscode", "extension", "extension", "debugAdapter.js"
)
M["local-lua-debugger"] = {
    command     = { "node", _lua_debugger_adapter_js },
    env = {
        LUA_PATH = vim.fs.joinpath(
            vim.fn.stdpath("data"), "mason", "packages",
            "local-lua-debugger-vscode", "debugger", "?.lua"
        ) .. ";;",
    },
    -- `program` is a nested table the js-based adapter consumes; the target file
    -- is set as `program.file`. Field set follows tomblind/local-lua-debugger-vscode's
    -- launch configuration.
    launch_schema = {
        type        = { default = "lua-local" },
        name        = { default = "Debug" },
        program     = {
            type   = "schema",
            fields = {
                lua           = { default = function() return vim.fn.exepath("lua") end },
                communication = { type = "string", kind = "enum", enum = { "stdio", "pipe" },
                    default = "stdio", desc = "extension<->debugger communication method" },
                file          = { type = "string", role = "target", desc = "lua file to debug" },
            },
        },
        args        = _args,
        cwd         = _cwd,
        env         = _env,
        stopOnEntry = { type = "boolean", desc = "stop at entry", default = false },
        scriptRoots = { type = "list", desc = "additional roots for resolving required scripts" },
        verbose     = { type = "boolean", desc = "enable verbose debugger logging" },
    },
}

return M
