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
        -- One `command` input carries the whole command line; `build` splits it into
        -- GDB's `program` (the first word) and `args` (the rest).
        launch = {
            description = "debug a native executable",
            request = "launch",
            inputs = {
                command       = { type = "table", format = "shell_args", required = true, description = "command line to debug" },
                cwd           = { type = "string", format = "cwd", description = "working directory" },
                env           = { type = "table", format = "env", description = "environment variables" },
                stop_on_entry = { type = "boolean", description = "break at program entry" },
                stop_at_main  = { type = "boolean", description = "break at the start of main" },
            },
            build = function(params, _, inputs)
                params.program = vim.fn.expand(inputs.command[1] or "")
                params.args    = { unpack(inputs.command, 2) }
                params.cwd     = inputs.cwd
                params.env     = inputs.env
                params.stopOnEntry = inputs.stop_on_entry
                params.stopAtBeginningOfMainSubprogram = inputs.stop_at_main
            end,
            template = [[
                program = "./a.out",                      -- executable to debug
                args    = { "--verbose" },                -- arguments passed to it
                cwd     = vim.fn.getcwd(),                -- working directory
                env     = { EXAMPLE = "value" },          -- environment variables
                stopOnEntry = false,                      -- break at program entry
                stopAtBeginningOfMainSubprogram = false,  -- break at the start of main
            ]],
        },
        attach = {
            description = "attach to a running process by pid",
            request    = "attach",
            inputs = {
                pid = { type = "integer", required = true, description = "process id to attach to" },
            },
            build = function(params, _, inputs)
                params.pid = inputs.pid
            end,
            template = [[
                pid = 41234,  -- process id to attach to
            ]],
        },
        -- The body's `target` key takes the remote `connection` string; the
        -- `target` input is the local binary GDB loads symbols from.
        remote = {
            description = "connect to a gdbserver / remote target",
            request    = "attach",
            inputs = {
                connection = { type = "string", required = true, description = "remote target, e.g. host:port" },
                target     = { type = "string", format = "file", description = "local binary for symbols" },
            },
            build = function(params, _, inputs)
                params.target  = inputs.connection
                params.program = inputs.target
            end,
            template = [[
                target  = "localhost:1234",  -- remote gdbserver, host:port
                program = "./a.out",         -- local binary for symbols
            ]],
        },
        core = {
            description = "post-mortem debug from a core file",
            request    = "attach",
            inputs = {
                corefile = { type = "string", format = "file", required = true, description = "core file to load" },
                target   = { type = "string", format = "file", description = "executable that produced the core" },
            },
            build = function(params, _, inputs)
                params.coreFile = inputs.corefile
                params.program  = inputs.target
            end,
            template = [[
                coreFile = "./core",   -- core file to load
                program  = "./a.out",  -- executable that produced the core
            ]],
        },
    },
}
