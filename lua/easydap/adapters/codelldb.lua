-- codelldb (vscode-lldb) — its own key set, distinct from lldb-dap. Field set
-- follows the CodeLLDB MANUAL
-- (https://github.com/vadimcn/codelldb/blob/master/MANUAL.md). codelldb uses
-- `terminal` (not `runInTerminal`) to pick the debuggee's stdio destination.
---@type easydap.AdapterDef
return {
    command = "codelldb",
    presets = {
        program = {
            request = "launch",
            parameters = {
                type    = "lldb",
                program = "{target:file}",
                args    = "{args:shell_args}",
                cwd     = "{cwd:cwd}",
                env     = "{env:env}",
            },
        },
        pid = {
            request = "attach",
            parameters = {
                type = "lldb",
                pid  = "{pid:integer}",
            },
        },
    },
}
