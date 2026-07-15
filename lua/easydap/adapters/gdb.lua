-- GDB speaks DAP natively via `--interpreter=dap`. Unlike the VS Code C/C++
-- adapters, GDB defines its own launch/attach parameters; these mirror the GDB
-- manual's "Debugger Adapter Protocol" chapter
-- (https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html).
-- GDB has no `runInTerminal`/`type`/body-level `request` field, so none are set here.
-- `program` is a parameter common to launch and attach (it maps to GDB's `file`
-- command, so the adapter can find symbols); the niche `adaSourceCharset` common
-- parameter is omitted — add it to a run file directly if debugging Ada.
---@type easydap.AdapterDef
return {
    command = { "gdb", "--interpreter=dap" },
    configurations = {
        -- One `command` input carries the whole command line; `fill` splits it into
        -- GDB's `program` (the first word) and `args` (the rest).
        launch = {
            description = "debug a native executable",
            request = "launch",
            inputs = {
                command       = { type = "shell_args", required = true, description = "command line to debug" },
                cwd           = { type = "cwd", description = "working directory" },
                env           = { type = "env", description = "environment variables" },
                stop_on_entry = { type = "boolean", description = "break at program entry" },
                stop_at_main  = { type = "boolean", description = "break at the start of main" },
            },
            template = {
                program = "./a.out",
                args    = { "--verbose" },
                cwd     = vim.fn.getcwd,
                env     = { EXAMPLE = "value" },
                stopOnEntry = false,
                stopAtBeginningOfMainSubprogram = false,
            },
            fill = function(params, inputs)
                params.program = vim.fn.expand(inputs.command[1] or "")
                params.args    = { unpack(inputs.command, 2) }
                params.cwd     = inputs.cwd
                params.env     = inputs.env
                params.stopOnEntry = inputs.stop_on_entry
                params.stopAtBeginningOfMainSubprogram = inputs.stop_at_main
            end,
        },
        attach = {
            description = "attach to a running process by pid",
            request    = "attach",
            inputs = {
                pid = { type = "integer", required = true, description = "process id to attach to" },
            },
            template = { pid = 0 },
            fill = function(params, inputs)
                params.pid = inputs.pid
            end,
        },
        -- The body's `target` key takes the remote `connection` string; the
        -- `target` input is the local binary GDB loads symbols from.
        remote = {
            description = "connect to a gdbserver / remote target",
            request    = "attach",
            inputs = {
                connection = { type = "string", required = true, description = "remote target, e.g. host:port" },
                target     = { type = "file", description = "local binary for symbols" },
            },
            template = {
                target  = "localhost:1234",
                program = "./a.out",
            },
            fill = function(params, inputs)
                params.target  = inputs.connection
                params.program = inputs.target
            end,
        },
        core = {
            description = "post-mortem debug from a core file",
            request    = "attach",
            inputs = {
                corefile = { type = "file", required = true, description = "core file to load" },
                target   = { type = "file", description = "executable that produced the core" },
            },
            template = {
                coreFile = "./core",
                program  = "./a.out",
            },
            fill = function(params, inputs)
                params.coreFile = inputs.corefile
                params.program  = inputs.target
            end,
        },
    },
}
