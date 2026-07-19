-- lldb-dap — LLVM's native DAP adapter. The launch/attach parameters mirror the
-- LLDB docs (https://lldb.llvm.org/use/lldbdap.html). `type` is always
-- "lldb-dap" and `name` is a required display label. Attaching by process name
-- (rather than pid) is done by supplying `program` and omitting `pid`.
--
-- Beyond the fields exposed as inputs below, lldb-dap accepts many optional
-- keys — add them to a run file directly:
--   * common (launch & attach): preRunCommands, stopCommands, exitCommands,
--     terminateCommands, sourcePath, sourceMap, debuggerRoot,
--     commandEscapePrefix, customFrameFormat, customThreadFormat,
--     displayExtendedBacktrace, enableAutoVariableSummaries,
--     enableSyntheticChildDebugging.
--   * launch: runInTerminal, stdio, launchCommands.
--   * attach: attachCommands.
-- An attach must specify exactly one target: pid, program, coreFile,
-- attachCommands, or gdb-remote-port.
--
-- lldb-dap's `gdb-remote-*` are plain body fields (this stdio adapter is not
-- task-level TCP), so the gdb_remote configuration has no `connect`.

local shared = require("ezdap.shared")

---@type ezdap.AdapterDef
return {
    command = "lldb-dap",
    profiles       = {
        -- One `command` input carries the whole command line; `build` splits it into
        -- `program` (the first word) and `args` (the rest).
        launch_program = {
            description = "debug an executable",
            request = "launch",
            inputs = {
                command       = { type = "table", format = "shell_args", required = true, description = "command line to debug" },
                cwd           = { type = "string", format = "cwd", description = "working directory" },
                env           = { type = "table", format = "env", description = "environment variables" },
                stop_on_entry = { type = "boolean", description = "break at program entry" },
                console       = { type = "string", description = "where to run: internalConsole|integratedTerminal|externalTerminal" },
                init_commands = { type = "table", format = "list", description = "LLDB commands run at debugger startup" },
            },
            build = function(params, _, inputs)
                params.name    = "lldb"
                params.type    = "lldb-dap"
                params.program = vim.fn.expand(inputs.command[1] or "")
                params.args    = { unpack(inputs.command, 2) }
                params.cwd     = inputs.cwd
                params.env     = inputs.env
                params.stopOnEntry  = inputs.stop_on_entry
                params.console      = inputs.console
                params.initCommands = inputs.init_commands
            end,
        },
        attach_process = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = {
                pid           = { type = "integer", description = "process id to attach to" },
                init_commands = { type = "table", format = "list", description = "LLDB commands run at debugger startup" },
            },
            build = function(params, _, inputs)
                local pid, err = shared.resolve_pid(inputs.pid)
                if not pid then return err end
                params.name = "lldb"
                params.type = "lldb-dap"
                params.pid  = pid
                params.initCommands = inputs.init_commands
            end,
        },
        attach_by_name = {
            description = "attach to a process by executable, optionally waiting for it to launch",
            request = "attach",
            inputs = {
                program       = { type = "string", format = "file", required = true, description = "executable to attach to" },
                wait_for      = { type = "boolean", description = "wait for the process to launch" },
                init_commands = { type = "table", format = "list", description = "LLDB commands run at debugger startup" },
            },
            build = function(params, _, inputs)
                params.name    = "lldb"
                params.type    = "lldb-dap"
                params.program = inputs.program
                params.waitFor = inputs.wait_for
                params.initCommands = inputs.init_commands
            end,
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
        },
    },
}
