local S = require("easydap.adapters._shared")

-- GDB speaks DAP natively via `--interpreter=dap`. Unlike the VS Code C/C++
-- adapters, GDB defines its own launch/attach parameters; these mirror the GDB
-- manual's "Debugger Adapter Protocol" chapter
-- (https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html).
-- `program` and `adaSourceCharset` are common to both requests; the rest are
-- request-specific. GDB has no `runInTerminal`/`type`/body-level `request` field,
-- so none are declared here.
---@type easydap.AdapterDef
return {
    command       = { "gdb", "--interpreter=dap" },
    launch_schema = {
        program                         = S.program,
        args                            = S.args,
        cwd                             = S.cwd,
        env                             = S.env,
        -- Temporary breakpoint at the first instruction (like `starti`).
        stopOnEntry                     = { type = "boolean", desc = "stop at the program's first instruction" },
        -- Temporary breakpoint at main (like `start`).
        stopAtBeginningOfMainSubprogram = { type = "boolean", desc = "stop at the beginning of main" },
        adaSourceCharset                = { type = "string", desc = "Ada source character set" },
    },
    -- One of pid / target / coreFile identifies what to attach to; GDB checks
    -- them in that order and uses the first present.
    attach_schema = {
        program          = {
            type = "string",
            kind = "file",
            desc = "program to debug (supply for remote targets GDB can't auto-detect)"
        },
        pid              = { type = "integer", role = "pid", desc = "process ID to attach to" },
        target           = { type = "string", desc = "target to connect to (passed to `target remote`)" },
        coreFile         = { type = "string", kind = "file", desc = "core file to debug" },
        adaSourceCharset = { type = "string", desc = "Ada source character set" },
    },
}
