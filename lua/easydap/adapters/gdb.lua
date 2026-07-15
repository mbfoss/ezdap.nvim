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
        -- One `command` input carries the whole command line as a raw string; the
        -- per-use kind overrides split it into `program` (the first word) and
        -- `args` (the rest), so `command` needs no type of its own.
        launch = {
            description = "debug a native executable",
            request = "launch",
            placeholders = {
                command       = { required = true, description = "command line to debug" },
                cwd           = { type = "cwd", description = "working directory" },
                env           = { type = "env", description = "environment variables" },
                stop_on_entry = { type = "boolean", description = "break at program entry" },
                stop_at_main  = { type = "boolean", description = "break at the start of main" },
            },
            parameters = {
                program     = "{command:shell_program}",
                args        = "{command:shell_rest_args}",
                cwd         = "{cwd}",
                env         = "{env}",
                stopOnEntry = "{stop_on_entry}",
                stopAtBeginningOfMainSubprogram = "{stop_at_main}",
            },
        },
        attach = {
            description = "attach to a running process by pid",
            request    = "attach",
            placeholders = {
                pid = { type = "integer", required = true, description = "process id to attach to" },
            },
            parameters = { pid = "{pid}" },
        },
        -- The body's `target` key takes the remote `connection` string; the
        -- `target` placeholder is the local binary GDB loads symbols from.
        remote = {
            description = "connect to a gdbserver / remote target",
            request    = "attach",
            placeholders = {
                connection = { type = "string", required = true, description = "remote target, e.g. host:port" },
                target     = { type = "file", description = "local binary for symbols" },
            },
            parameters = {
                target  = "{connection}",
                program = "{target}",
            },
        },
        core = {
            description = "post-mortem debug from a core file",
            request    = "attach",
            placeholders = {
                corefile = { type = "file", required = true, description = "core file to load" },
                target   = { type = "file", description = "executable that produced the core" },
            },
            parameters = {
                coreFile = "{corefile}",
                program  = "{target}",
            },
        },
    },
}
