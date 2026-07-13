local S = require("easydap.adapters._shared")

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
        processId = { type = "integer", role = "pid", desc = "PID to attach to" },
    }, S.debugpy_common),
}
