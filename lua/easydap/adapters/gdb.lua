-- GDB speaks DAP natively via `--interpreter=dap`. Unlike the VS Code C/C++
-- adapters, GDB defines its own launch/attach parameters; these mirror the GDB
-- manual's "Debugger Adapter Protocol" chapter
-- (https://sourceware.org/gdb/current/onlinedocs/gdb.html/Debugger-Adapter-Protocol.html).
-- GDB has no `runInTerminal`/`type`/body-level `request` field, so none are set here.
---@type easydap.AdapterDef
return {
    command = { "gdb", "--interpreter=dap" },
    configurations = {
        launch = {
            request = "launch",
            parameters = {
                program = "{target:file}",
                args    = "{args:shell_args}",
                cwd     = "{cwd:cwd}",
                env     = "{env:env}",
            },
        },
        -- One of pid / target / coreFile identifies what to attach to; GDB
        -- checks them in that order and uses the first present.
        attach = {
            request    = "attach",
            parameters = { pid = "{pid:integer}" },
        },
    },
}
