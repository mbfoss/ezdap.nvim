local S = require("easydap.adapters._shared")

-- Attach to a remote Python process running debugpy via `connect.*`.
-- task.host / task.port point to the REMOTE process; the local debugpy adapter
-- is spawned by S.debugpy_setup and connects to it via the `connect` args.
-- The `connect` group targets the REMOTE process and goes in the body's
-- `connect`, not the task-level connection (the local adapter port is chosen
-- by S.debugpy_setup). Set them as `connect.host` / `connect.port`.
---@type easydap.AdapterDef
return {
    command       = "python3",
    setup         = S.debugpy_setup,
    teardown      = function(_, ctx) if ctx then ctx.handle.stop() end end,
    launch_schema = vim.tbl_extend("error", {
        type        = { default = "python", fixed = true },
        program     = S.program,
        args        = S.args,
        cwd         = S.cwd,
        env         = S.env,
        console     = {
            type = "string",
            kind = "enum",
            default = "integratedTerminal",
            enum = { "integratedTerminal", "internalConsole", "externalTerminal" },
            desc = "where to launch the target"
        },
        stopOnEntry = { type = "boolean", desc = "stop at the first line of user code", default = false },
    }, S.debugpy_common),
    attach_schema = vim.tbl_extend("error", {
        type      = { default = "python", fixed = true },
        processId = { type = "integer", desc = "PID to attach to (local)" },
        connect   = {
            type   = "schema",
            fields = {
                host = { type = "string", kind = "host", desc = "remote host", default = "127.0.0.1" },
                port = { type = "integer", kind = "port", desc = "remote port", default = 5678 },
            },
        },
    }, S.debugpy_common),
    templates     = {
        program = {
            request    = "launch",
            parameters = { program = "{target}", args = "{args}", cwd = "{cwd}", env = "{env}" },
        },
        pid     = {
            request    = "attach",
            parameters = { processId = "{pid}" },
        },
        -- The `connect.*` body group above targets the remote process — not the
        -- template-level `connect` block (that's reserved for a task-level TCP
        -- endpoint, which this adapter's def doesn't declare).
        remote  = {
            request    = "attach",
            parameters = { connect = { host = "{host}", port = "{port}" } },
        },
    },
}
