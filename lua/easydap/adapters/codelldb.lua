-- codelldb (vscode-lldb) — its own key set, distinct from lldb-dap. Field set
-- follows the CodeLLDB MANUAL
-- (https://github.com/vadimcn/codelldb/blob/master/MANUAL.md). codelldb uses
-- `terminal` (not `runInTerminal`) to pick the debuggee's stdio destination.
---@type easydap.AdapterDef
return {
    command = "codelldb",
    configurations = {
        launch = {
            description = "debug an executable",
            request = "launch",
            parameters = {
                type    = "lldb",
                program = "{command:shell_program}",
                args    = "{command:shell_rest_args}",
                cwd     = "{cwd:cwd}",
                env     = "{env:env}",
            },
        },
        attach = {
            request = "attach",
            parameters = {
                type = "lldb",
                pid  = "{pid:integer}",
            },
        },
    },
}
