-- codelldb — the CodeLLDB VS Code extension's adapter binary. Field set follows
-- vadimcn/codelldb's launch.json attributes
-- (https://github.com/vadimcn/codelldb/blob/master/MANUAL.md). `type` is always
-- "lldb"; `name` is a display label.
--
-- Beyond the fields exposed as inputs below, codelldb accepts many optional
-- keys — add them to a run file directly: initCommands, preRunCommands,
-- postRunCommands, exitCommands, sourceMap, sourceLanguages, relativePathBase,
-- terminal ("console"/"integrated"/"external"), stdio, expressions.
--
-- The `core`/`gdb_remote` configurations use codelldb's "custom launch" form:
-- rather than a `program`, they drive LLDB directly through
-- `targetCreateCommands`/`processCreateCommands`.
---@type easydap.AdapterDef
return {
    command = "codelldb",
    configurations = {
        -- One `command` input carries the whole command line; `fill` splits it into
        -- `program` (the first word) and `args` (the rest).
        launch = {
            description = "debug an executable",
            request = "launch",
            inputs = {
                command       = { type = "shell_args", required = true, description = "command line to debug" },
                cwd           = { type = "cwd", description = "working directory" },
                env           = { type = "env", description = "environment variables" },
                stop_on_entry = { type = "boolean", description = "break at program entry" },
            },
            template = {
                name    = "codelldb",
                type    = "lldb",
                program = "./a.out",
                args    = { "--verbose" },
                cwd     = vim.fn.getcwd,
                env     = { EXAMPLE = "value" },
                stopOnEntry = false,
            },
            fill = function(params, inputs)
                params.name    = "codelldb"
                params.type    = "lldb"
                params.program = vim.fn.expand(inputs.command[1] or "")
                params.args    = { unpack(inputs.command, 2) }
                params.cwd     = inputs.cwd
                params.env     = inputs.env
                params.stopOnEntry = inputs.stop_on_entry
            end,
        },
        attach = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = {
                pid = { type = "integer", required = true, description = "process id to attach to" },
            },
            template = {
                name = "codelldb",
                type = "lldb",
                pid  = 0,
            },
            fill = function(params, inputs)
                params.name = "codelldb"
                params.type = "lldb"
                params.pid  = inputs.pid
            end,
        },
        attach_by_name = {
            description = "attach to a process by executable, optionally waiting for it to launch",
            request = "attach",
            inputs = {
                program  = { type = "file", required = true, description = "executable to attach to" },
                wait_for = { type = "boolean", description = "wait for the process to launch" },
            },
            template = {
                name    = "codelldb",
                type    = "lldb",
                program = "./a.out",
                waitFor = false,
            },
            fill = function(params, inputs)
                params.name    = "codelldb"
                params.type    = "lldb"
                params.program = inputs.program
                params.waitFor = inputs.wait_for
            end,
        },
        core = {
            description = "post-mortem debug from a core file (custom launch)",
            request = "launch",
            inputs = {
                program  = { type = "file", description = "executable that produced the core" },
                corefile = { type = "file", description = "core file to load" },
            },
            template = {
                name                  = "codelldb",
                type                  = "lldb",
                targetCreateCommands  = { "target create ./a.out" },
                processCreateCommands = { "target create -c ./core" },
            },
            fill = function(params, inputs)
                params.name = "codelldb"
                params.type = "lldb"
                if inputs.program then
                    params.targetCreateCommands = { "target create " .. inputs.program }
                end
                if inputs.corefile then
                    params.processCreateCommands = { "target create -c " .. inputs.corefile }
                end
            end,
        },
        gdb_remote = {
            description = "attach over a gdb-remote (gdbserver) connection (custom launch)",
            request = "launch",
            inputs = {
                program = { type = "file", description = "executable for symbols" },
                host    = { type = "host", description = "gdbserver host" },
                port    = { type = "port", description = "gdbserver port" },
            },
            template = {
                name                  = "codelldb",
                type                  = "lldb",
                targetCreateCommands  = { "target create ./a.out" },
                processCreateCommands = { "gdb-remote 127.0.0.1:1234" },
            },
            fill = function(params, inputs)
                params.name = "codelldb"
                params.type = "lldb"
                if inputs.program then
                    params.targetCreateCommands = { "target create " .. inputs.program }
                end
                if inputs.host and inputs.port then
                    params.processCreateCommands = { ("gdb-remote %s:%d"):format(inputs.host, inputs.port) }
                end
            end,
        },
    },
}
