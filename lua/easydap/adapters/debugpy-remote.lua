local S = require("easydap.adapters._shared")

-- Attach to a remote Python process running debugpy.
-- task.host / task.port point to the REMOTE process; the local debugpy adapter
-- is spawned by S.debugpy_setup and connects to it via the `connect` args.
---@type easydap.AdapterDef
return {
    command       = "python3",
    setup         = S.debugpy_setup,
    teardown      = function(_, ctx) if ctx then ctx.handle.stop() end end,
    request       = "attach",
    -- The `connect` group targets the REMOTE process and goes in the body's
    -- `connect`, not the task-level connection (the local adapter port is chosen
    -- by S.debugpy_setup). Set them as `connect.host` / `connect.port`.
    attach_schema = vim.tbl_extend("error", {
        type    = { default = "python", fixed = true },
        connect = {
            type   = "schema",
            fields = {
                host = { type = "string", kind = "host", role = "host", desc = "remote host", default = "127.0.0.1" },
                port = { type = "integer", kind = "port", role = "port", desc = "remote port", default = 5678 },
            },
        },
    }, S.debugpy_common),
}
