-- lldb-dap — the launch/attach parameters mirror the LLVM docs
-- (https://lldb.llvm.org/use/lldbdap.html).
---@type easydap.AdapterDef
return {
    command = "lldb-dap",
    configurations = {
        launch = {
            description = "debug an executable",
            request = "launch",
            parameters = {
                name    = "lldb",
                type    = "lldb-dap",
                program = "{target:file}",
                args    = "{args:shell_args}",
                cwd     = "{cwd:cwd}",
                env     = "{env:env}",
            },
        },
        attach = {
            description = "attach to a running process by pid",
            request = "attach",
            parameters = {
                type = "lldb",
                pid  = "{pid:integer}",
            },
        },
        -- lldb-dap's `gdb-remote-*` are plain body fields (this stdio adapter is
        -- not task-level TCP), so this configuration has no `connect` block.
        gdb_remote = {
            description = "attach over a gdb-remote (gdbserver) connection",
            request = "attach",
            parameters = {
                type                 = "lldb",
                ["gdb-remote-host"]  = "{host:host}",
                ["gdb-remote-port"]  = "{port:port}",
            },
        },
    },
}
