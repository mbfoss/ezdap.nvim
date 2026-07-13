local S = require("easydap.adapters._shared")

-- netcoredbg uses `stopAtEntry` instead of the standard stopOnEntry. Field set
-- matches the keys netcoredbg's VS Code protocol handler reads
-- (Samsung/netcoredbg, src/protocols/vscodeprotocol.cpp); `justMyCode` and
-- `enableStepFiltering` default to true there. No runInTerminal/console arg.
---@type easydap.AdapterDef
return {
    command       = { "netcoredbg", "--interpreter=vscode" },
    launch_schema = {
        program             = S.program,
        args                = S.args,
        cwd                 = S.cwd,
        env                 = S.env,
        stopAtEntry         = { type = "boolean", desc = "stop at entry", default = false },
        justMyCode          = { type = "boolean", desc = "debug only user-written code (default true)" },
        enableStepFiltering = { type = "boolean", desc = "skip properties and operators while stepping (default true)" },
    },
    attach_schema = {
        processId   = { type = "integer", role = "pid", desc = "PID to attach to" },
        cwd         = S.cwd,
        stopAtEntry = { type = "boolean", desc = "stop at entry" },
        justMyCode  = { type = "boolean", desc = "debug only user-written code (default true)" },
    },
}
