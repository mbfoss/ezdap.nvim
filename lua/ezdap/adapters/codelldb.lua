-- codelldb — the CodeLLDB VS Code extension's adapter binary. Field set follows
-- vadimcn/codelldb's launch.json attributes
-- (https://github.com/vadimcn/codelldb/blob/master/MANUAL.md). `type` is always
-- "lldb"; `name` is a display label.
--
-- Beyond the fields exposed as inputs below, codelldb accepts a few more keys —
-- add them to a run file directly: `cargo` (a Cargo build description),
-- `gracefulShutdown`, and the raw `targetCreateCommands`/`processCreateCommands`
-- that the `core` and `gdb_remote` profiles assemble for you.

local shared = require("ezdap.shared")

---Attributes codelldb accepts on both a launch and an attach. Declared once and
---merged into every profile, so a field is described in one place.
---@type table<string, ezdap.Input>
local _common_inputs = {
    source_map             = { type = "table", format = "map", description = "source path remappings, from=to" },
    relative_path_base     = { type = "string", format = "dir", description = "base directory for relative source paths" },
    source_languages       = { type = "table", format = "list", description = "source languages in the program, for language-specific features" },
    expressions            = { type = "string", description = "default expression evaluator: simple|python|native" },
    breakpoint_mode        = { type = "string", description = "how source breakpoints resolve: path|file" },
    reverse_debugging      = { type = "boolean", description = "enable reverse debugging" },
    init_commands          = { type = "table", format = "list", description = "LLDB commands run at debugger startup, before the target exists" },
    pre_run_commands       = { type = "table", format = "list", description = "LLDB commands run just before launching/attaching" },
    post_run_commands      = { type = "table", format = "list", description = "LLDB commands run just after launching/attaching" },
    pre_terminate_commands = { type = "table", format = "list", description = "LLDB commands run just before the debuggee is terminated" },
    exit_commands          = { type = "table", format = "list", description = "LLDB commands run at the end of the session" },
}

---A profile's own inputs on top of the common set.
---@param extra table<string, ezdap.Input>
---@return table<string, ezdap.Input>
local function _inputs(extra)
    return vim.tbl_extend("error", vim.deepcopy(_common_inputs), extra)
end

---Assign the common attributes, plus the `name`/`type` every codelldb body carries.
---@param params table
---@param inputs table<string, any>
local function _common_build(params, inputs)
    params.name                 = "codelldb"
    params.type                 = "lldb"
    params.sourceMap            = inputs.source_map
    params.relativePathBase     = inputs.relative_path_base
    params.sourceLanguages      = inputs.source_languages
    params.expressions          = inputs.expressions
    params.breakpointMode       = inputs.breakpoint_mode
    params.reverseDebugging     = inputs.reverse_debugging
    params.initCommands         = inputs.init_commands
    params.preRunCommands       = inputs.pre_run_commands
    params.postRunCommands      = inputs.post_run_commands
    params.preTerminateCommands = inputs.pre_terminate_commands
    params.exitCommands         = inputs.exit_commands
end

---@type ezdap.AdapterDef
return {
    command = "codelldb",
    profiles       = {
        -- One `command` input carries the whole command line; `build` splits it into
        -- `program` (the first word) and `args` (the rest).
        launch_program = {
            description = "debug an executable",
            request = "launch",
            inputs = _inputs {
                command       = { type = "string", required = true, description = "command line to debug" },
                cwd           = { type = "string", format = "cwd", description = "working directory" },
                env           = { type = "table", format = "map", description = "environment variables, added to the inherited ones" },
                env_file      = { type = "string", format = "file", description = "file of additional environment variables" },
                stdio         = { type = "table", format = "list", description = "redirections for stdin, stdout, stderr, in that order" },
                terminal      = { type = "string", description = "where the debuggee's stdio goes: console|integrated|external" },
                stop_on_entry = { type = "boolean", description = "break at program entry" },
            },
            build = function(params, _, inputs)
                _common_build(params, inputs)
                params.program, params.args = shared.split_command(inputs.command)
                params.cwd         = inputs.cwd
                params.env         = inputs.env
                params.envFile     = inputs.env_file
                params.stdio       = inputs.stdio
                params.terminal    = inputs.terminal
                params.stopOnEntry = inputs.stop_on_entry
            end,
        },
        attach_process = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = _inputs {
                pid           = { type = "integer", description = "process id to attach to" },
                program       = { type = "string", format = "file", description = "executable to read symbols from" },
                stop_on_entry = { type = "boolean", description = "break immediately after attaching" },
            },
            build = function(params, _, inputs)
                local pid, err = shared.resolve_pid(inputs.pid)
                if not pid then return err end
                _common_build(params, inputs)
                params.pid         = pid
                params.program     = inputs.program
                params.stopOnEntry = inputs.stop_on_entry
            end,
        },
        attach_by_name = {
            description = "attach to a process by executable, optionally waiting for it to launch",
            request = "attach",
            inputs = _inputs {
                program       = { type = "string", format = "file", required = true, description = "executable to attach to" },
                wait_for      = { type = "boolean", description = "wait for the process to launch" },
                stop_on_entry = { type = "boolean", description = "break immediately after attaching" },
            },
            build = function(params, _, inputs)
                _common_build(params, inputs)
                params.program     = inputs.program
                params.waitFor     = inputs.wait_for
                params.stopOnEntry = inputs.stop_on_entry
            end,
        },
        -- A custom launch drives LLDB by command rather than by `program`, so both
        -- inputs land inside a command string instead of a field of their own.
        core = {
            description = "post-mortem debug from a core file (custom launch)",
            request = "launch",
            inputs = _inputs {
                program  = { type = "string", format = "file", description = "executable that produced the core" },
                corefile = { type = "string", format = "file", description = "core file to load" },
            },
            build = function(params, _, inputs)
                _common_build(params, inputs)
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
            inputs = _inputs {
                program = { type = "string", format = "file", description = "executable for symbols" },
                host    = { type = "string", format = "host", description = "gdbserver host" },
                port    = { type = "integer", format = "port", description = "gdbserver port" },
            },
            build = function(params, _, inputs)
                _common_build(params, inputs)
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
