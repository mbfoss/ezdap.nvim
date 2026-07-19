-- netcoredbg uses `stopAtEntry` instead of the standard stopOnEntry. Field set
-- matches the keys netcoredbg's VS Code protocol handler reads
-- (Samsung/netcoredbg, src/protocols/vscodeprotocol.cpp); `justMyCode` and
-- `enableStepFiltering` default to true there. No runInTerminal/console arg.

local shared = require("ezdap.shared")

---@type ezdap.AdapterDef
return {
    command = { "netcoredbg", "--interpreter=vscode" },
    profiles       = {
        -- One `command` input carries the whole command line; `build` splits it into
        -- `program` (the first word) and `args` (the rest).
        launch_program = {
            description = "debug a .NET assembly",
            request = "launch",
            inputs = {
                command = { type = "table", format = "shell_args", description = "command line to debug" },
                cwd     = { type = "string", format = "cwd", description = "working directory" },
                env     = { type = "table", format = "env", description = "environment variables" },
            },
            build = function(params, _, inputs)
                if inputs.command then
                    params.program = vim.fn.expand(inputs.command[1] or "")
                    params.args    = { unpack(inputs.command, 2) }
                end
                params.cwd = inputs.cwd
                params.env = inputs.env
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
                params.processId = pid
            end,
        },
    },
}
