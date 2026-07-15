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
                params.name    = "codelldb"
                params.type    = "lldb"
                params.program = vim.fn.expand(inputs.command[1] or "")
                params.args    = { unpack(inputs.command, 2) }
                params.cwd     = inputs.cwd
                params.env     = inputs.env
                params.stopOnEntry = inputs.stop_on_entry
            end,
            template = [[
                name    = "codelldb",
                type    = "lldb",
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
                params.name = "codelldb"
                params.type = "lldb"
                params.pid  = inputs.pid
            end,
            template = [[
                name = "codelldb",
                type = "lldb",
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
                params.name    = "codelldb"
                params.type    = "lldb"
                params.program = inputs.program
                params.waitFor = inputs.wait_for
            end,
            template = [[
                name    = "codelldb",
                type    = "lldb",
                program = "./a.out",  -- executable to attach to
                waitFor = false,      -- wait for the process to launch
            ]],
        },
        -- A custom launch drives LLDB by command rather than by `program`, so both
        -- inputs land inside a command string instead of a field of their own.
        core = {
            description = "post-mortem debug from a core file (custom launch)",
            request = "launch",
            inputs = {
                program  = { type = "string", format = "file", description = "executable that produced the core" },
                corefile = { type = "string", format = "file", description = "core file to load" },
            },
            build = function(params, _, inputs)
                params.name = "codelldb"
                params.type = "lldb"
                if inputs.program then
                    params.targetCreateCommands = { "target create " .. inputs.program }
                end
                if inputs.corefile then
                    params.processCreateCommands = { "target create -c " .. inputs.corefile }
                end
            end,
            template = [[
                name = "codelldb",
                type = "lldb",
                targetCreateCommands  = { "target create ./a.out" },    -- executable that produced the core
                processCreateCommands = { "target create -c ./core" },  -- core file to load
            ]],
        },
        gdb_remote = {
            description = "attach over a gdb-remote (gdbserver) connection (custom launch)",
            request = "launch",
            inputs = {
                program = { type = "string", format = "file", description = "executable for symbols" },
                host    = { type = "string", format = "host", description = "gdbserver host" },
                port    = { type = "integer", format = "port", description = "gdbserver port" },
            },
            build = function(params, _, inputs)
                params.name = "codelldb"
                params.type = "lldb"
                if inputs.program then
                    params.targetCreateCommands = { "target create " .. inputs.program }
                end
                if inputs.host and inputs.port then
                    params.processCreateCommands = { ("gdb-remote %s:%d"):format(inputs.host, inputs.port) }
                end
            end,
            template = [[
                name = "codelldb",
                type = "lldb",
                targetCreateCommands  = { "target create ./a.out" },      -- executable for symbols
                processCreateCommands = { "gdb-remote 127.0.0.1:1234" },  -- gdbserver host:port
            ]],
        },
    },
}
