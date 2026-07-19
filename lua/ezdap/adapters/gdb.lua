-- GDB speaks DAP natively via `--interpreter=dap`. Unlike the VS Code C/C++
-- adapters, GDB defines its own launch/attach parameters; these mirror the GDB
-- manual's "Debugger Adapter Protocol" chapter
-- (https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html).
-- GDB has no `runInTerminal`/`type`/body-level `request` field, so none are set here.
-- `program` is a parameter common to launch and attach (it maps to GDB's `file`
-- command, so the adapter can find symbols); the niche `adaSourceCharset` common
-- parameter is omitted — add it to a run file directly if debugging Ada.

local shared = require("ezdap.shared")

---@type ezdap.AdapterDef
return {
    command = { "gdb", "--interpreter=dap" },
    profiles       = {
        -- One `command` input carries the whole command line; `build` splits it into
        -- GDB's `program` (the first word) and `args` (the rest).
        launch_program = {
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
                params.env     = vim.tbl_extend("force", vim.fn.environ(), inputs.env or {}) -- gdb does not merge env variables on it's own (unlike lldb)
                params.stopOnEntry = inputs.stop_on_entry
                params.stopAtBeginningOfMainSubprogram = inputs.stop_at_main
            end,
        },
        attach_process = {
            description = "attach to a running process by pid",
            request    = "attach",
            inputs = {
                pid = { type = "integer", description = "process id to attach to" },
            },
            build = function(params, _, inputs)
                local pid, err = shared.resolve_pid(inputs.pid)
                if not pid then return err end
                params.pid = pid
            end,
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
        },
    },
}
