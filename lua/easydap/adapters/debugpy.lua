local S = require("easydap.adapters._shared")

-- Attach to a remote Python process running debugpy via `connect.*`.
-- task.host / task.port point to the REMOTE process; the local debugpy adapter
-- is spawned by S.debugpy_setup and connects to it via the `connect` args.
-- The `connect` group targets the REMOTE process and goes in the body's
-- `connect`, not the task-level connection (the local adapter port is chosen
-- by S.debugpy_setup). `justMyCode`/`showReturnValue` keep easydap's existing
-- behaviour (debug all code, show return values); debugpy applies its own
-- documented defaults for everything else, per its wiki
-- (https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings).
---@type easydap.AdapterDef
return {
    command  = "python3",
    setup    = S.debugpy_setup,
    teardown = function(_, ctx) if ctx then ctx.handle.stop() end end,
    presets  = {
        program = {
            request = "launch",
            parameters = {
                type            = "python",
                program         = "{target:file}",
                args            = "{args:shell_args}",
                cwd             = "{cwd:cwd}",
                env             = "{env:env}",
                justMyCode      = false,
                showReturnValue = true,
            },
        },
        pid = {
            request = "attach",
            parameters = {
                type            = "python",
                processId       = "{pid:integer}",
                justMyCode      = false,
                showReturnValue = true,
            },
        },
        -- The `connect.*` body group targets the remote process — not the
        -- preset-level `connect` block (that's reserved for a task-level TCP
        -- endpoint, which this adapter's def doesn't declare).
        remote = {
            request = "attach",
            parameters = {
                type = "python",
                connect = {
                    host = "{host:host}",
                    port = "{port:port}",
                },
                justMyCode      = false,
                showReturnValue = true,
            },
        },
    },
}
