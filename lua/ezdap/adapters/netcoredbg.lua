-- netcoredbg has no options document; the authoritative field set is the keys its
-- VS Code protocol handler reads, in Samsung/netcoredbg's
-- src/protocols/vscodeprotocol.cpp ("launch" and "attach" handlers). That set is
-- small and complete as written below — launch takes seven keys, attach only
-- `processId`. netcoredbg spells entry-stop `stopAtEntry`, not the standard
-- `stopOnEntry`, and has no runInTerminal/console argument.

local shared = require("ezdap.shared")

---@type ezdap.AdapterDef
return {
    command = { "netcoredbg", "--interpreter=vscode" },
    profiles       = {
        -- One `command` input carries the whole command line; `build` splits it into
        -- `program` (the first word) and `args` (the rest). A `program` ending in
        -- .dll is run by netcoredbg via `dotnet`; anything else runs as an executable.
        launch_program = {
            description = "debug a .NET assembly",
            request = "launch",
            inputs = {
                command               = { type = "string", required = true, description = "assembly or executable to debug, plus its arguments" },
                cwd                   = { type = "string", format = "cwd", description = "working directory" },
                env                   = { type = "table", format = "map", description = "environment variables" },
                stop_at_entry         = { type = "boolean", description = "break at program entry" },
                just_my_code          = { type = "boolean", description = "debug only user code, skipping framework code (default true)" },
                enable_step_filtering = { type = "boolean", description = "step over property accessors and operators (default true)" },
            },
            build = function(params, _, inputs)
                params.program, params.args = shared.split_command(inputs.command)
                params.cwd                 = inputs.cwd
                params.env                 = inputs.env
                params.stopAtEntry         = inputs.stop_at_entry
                params.justMyCode          = inputs.just_my_code
                params.enableStepFiltering = inputs.enable_step_filtering
            end,
        },
        -- The attach handler reads `processId` alone — the launch-side options are
        -- not consulted here, so none are offered.
        attach_process = {
            description = "attach to a running process by pid",
            request    = "attach",
            inputs = {
                pid = { type = "integer", description = "process id to attach to" },
            },
            build = function(params, _, inputs)
                local pid, err = shared.resolve_pid(inputs.pid)
                if not pid then return err end
                params.processId = pid
            end,
        },
    },
}
