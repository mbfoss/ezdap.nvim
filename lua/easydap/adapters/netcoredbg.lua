-- netcoredbg uses `stopAtEntry` instead of the standard stopOnEntry. Field set
-- matches the keys netcoredbg's VS Code protocol handler reads
-- (Samsung/netcoredbg, src/protocols/vscodeprotocol.cpp); `justMyCode` and
-- `enableStepFiltering` default to true there. No runInTerminal/console arg.
---@type easydap.AdapterDef
return {
    command = { "netcoredbg", "--interpreter=vscode" },
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
        attach = {
            request    = "attach",
            parameters = { processId = "{pid:integer}" },
        },
    },
}
