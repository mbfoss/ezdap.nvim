-- lldb-dap — LLVM's native DAP adapter. The launch/attach parameters mirror the
-- LLDB docs (https://lldb.llvm.org/use/lldbdap.html). `type` is always
-- "lldb-dap" and `name` is a required display label. Attaching by process name
-- (rather than pid) is done by supplying `program` and omitting `pid`.
--
-- Beyond the fields exposed as inputs below, lldb-dap accepts many optional
-- keys — add them to a run file directly:
--   * common (launch & attach): initCommands, preRunCommands, stopCommands,
--     exitCommands, terminateCommands, sourcePath, sourceMap, debuggerRoot,
--     commandEscapePrefix, customFrameFormat, customThreadFormat,
--     displayExtendedBacktrace, enableAutoVariableSummaries,
--     enableSyntheticChildDebugging.
--   * launch: console ("internalConsole"/"integratedTerminal"/
--     "externalTerminal"), stdio, launchCommands.
--   * attach: attachCommands.
-- An attach must specify exactly one target: pid, program, coreFile,
-- attachCommands, or gdb-remote-port.
--
-- lldb-dap's `gdb-remote-*` are plain body fields (this stdio adapter is not
-- task-level TCP), so the gdb_remote configuration has no `connect`.
---@type easydap.AdapterDef
return {
    command = "lldb-dap",
    configurations = {
        -- One `command` input carries the whole command line; `build` splits it into
        -- `program` (the first word) and `args` (the rest).
        launch = {
            description = "debug an executable",
            request = "launch",
            inputs = {
                command       = { type = "table", format = "shell_args", required = true, description = "command line to debug" },
                cwd           = { type = "string", format = "cwd", description = "working directory" },
                env           = { type = "table", format = "env", description = "environment variables" },
                stop_on_entry = { type = "boolean", description = "break at program entry" },
            },
            build = function(params, _, inputs)
                params.name    = "lldb"
                params.type    = "lldb-dap"
                params.program = vim.fn.expand(inputs.command[1] or "")
                params.args    = { unpack(inputs.command, 2) }
                params.cwd     = inputs.cwd
                params.env     = inputs.env
                params.stopOnEntry = inputs.stop_on_entry
            end,
            template = [[
                name    = "lldb",
                type    = "lldb-dap",
                program = "./a.out",              -- executable to debug
                args    = { "--verbose" },        -- arguments passed to it
                cwd     = vim.fn.getcwd(),        -- working directory
                env     = { EXAMPLE = "value" },  -- environment variables
                stopOnEntry = false,              -- break at program entry
            ]],
        },
        attach = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = {
                pid = { type = "integer", required = true, description = "process id to attach to" },
            },
            build = function(params, _, inputs)
                params.name = "lldb"
                params.type = "lldb-dap"
                params.pid  = inputs.pid
            end,
            template = [[
                name = "lldb",
                type = "lldb-dap",
                pid  = 41234,  -- process id to attach to
            ]],
        },
        attach_by_name = {
            description = "attach to a process by executable, optionally waiting for it to launch",
            request = "attach",
            inputs = {
                program  = { type = "string", format = "file", required = true, description = "executable to attach to" },
                wait_for = { type = "boolean", description = "wait for the process to launch" },
            },
            build = function(params, _, inputs)
                params.name    = "lldb"
                params.type    = "lldb-dap"
                params.program = inputs.program
                params.waitFor = inputs.wait_for
            end,
            template = [[
                name    = "lldb",
                type    = "lldb-dap",
                program = "./a.out",  -- executable to attach to
                waitFor = false,      -- wait for the process to launch
            ]],
        },
        core = {
            description = "post-mortem debug from a core file",
            request = "attach",
            inputs = {
                corefile = { type = "string", format = "file", required = true, description = "core file to load" },
                program  = { type = "string", format = "file", description = "executable that produced the core" },
            },
            build = function(params, _, inputs)
                params.name     = "lldb"
                params.type     = "lldb-dap"
                params.program  = inputs.program
                params.coreFile = inputs.corefile
            end,
            template = [[
                name     = "lldb",
                type     = "lldb-dap",
                program  = "./a.out",  -- executable that produced the core
                coreFile = "./core",   -- core file to load
            ]],
        },
        gdb_remote = {
            description = "attach over a gdb-remote (gdbserver) connection",
            request = "attach",
            inputs = {
                port = { type = "integer", format = "port", required = true, description = "gdbserver port" },
                host = { type = "string", format = "host", description = "gdbserver host" },
            },
            build = function(params, _, inputs)
                params.name = "lldb"
                params.type = "lldb-dap"
                params["gdb-remote-host"] = inputs.host
                params["gdb-remote-port"] = inputs.port
            end,
            template = [[
                name                = "lldb",
                type                = "lldb-dap",
                ["gdb-remote-host"] = "127.0.0.1",  -- gdbserver host
                ["gdb-remote-port"] = 1234,         -- gdbserver port
            ]],
        },
    },
}
