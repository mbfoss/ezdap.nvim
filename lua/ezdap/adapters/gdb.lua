-- https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html

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
                command       = { type = "string", required = true, description = "command line to debug" },
                cwd           = { type = "string", format = "cwd", description = "working directory" },
                env           = { type = "table", format = "map", description = "environment variables" },
                stop_on_entry = { type = "boolean", description = "break at program entry" },
                stop_at_main  = { type = "boolean", description = "break at the start of main" },
                ada_charset   = { type = "string", description = "Ada source character set" },
            },
            build = function(params, _, inputs)
                params.program, params.args = shared.split_command(inputs.command)
                params.cwd     = inputs.cwd
                params.env     = vim.tbl_extend("force", vim.fn.environ(), inputs.env or {}) -- gdb does not merge env variables on it's own (unlike lldb)
                params.stopOnEntry = inputs.stop_on_entry
                params.stopAtBeginningOfMainSubprogram = inputs.stop_at_main
                params.adaSourceCharset = inputs.ada_charset
            end,
        },
        attach_process = {
            description = "attach to a running process by pid",
            request    = "attach",
            inputs = {
                pid    = { type = "integer", description = "process id to attach to" },
                program = { type = "string", format = "file", description = "local binary for symbols" },
            },
            build = function(params, _, inputs)
                local pid, err = shared.resolve_pid(inputs.pid)
                if not pid then return err end
                params.pid     = pid
                params.program = inputs.program
            end,
        },
        -- GDB's body `target` key is the remote connection string, not a binary.
        remote = {
            description = "connect to a gdbserver / remote target",
            request    = "attach",
            inputs = {
                connection = { type = "string", required = true, description = "remote target, e.g. host:port" },
                program    = { type = "string", format = "file", description = "local binary for symbols" },
            },
            build = function(params, _, inputs)
                params.target  = inputs.connection
                params.program = inputs.program
            end,
        },
        core = {
            description = "post-mortem debug from a core file",
            request    = "attach",
            inputs = {
                corefile = { type = "string", format = "file", required = true, description = "core file to load" },
                program  = { type = "string", format = "file", description = "executable that produced the core" },
            },
            build = function(params, _, inputs)
                params.coreFile = inputs.corefile
                params.program  = inputs.program
            end,
        },
    },
}
