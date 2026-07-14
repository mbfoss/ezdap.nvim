-- bash-debug-adapter has adapter-specific path fields; runInTerminal is omitted
-- because the adapter manages its own terminal via terminalKind. Field set follows
-- rogalmic/vscode-bash-debug's launch attributes — note it has no stopOnEntry
-- (bashdb always breaks at the first line).
---@type easydap.AdapterDef
return {
    command = "bash-debug-adapter",
    presets = {
        -- `quick_run bash-debug-adapter bash_script script=./run.sh`.
        bash_script = {
            request = "launch",
            parameters = {
                type = "bashdb",
                name = "Launch Bash Script",
                program = "{script:file}",
                cwd     = "{cwd:cwd}",
                env     = "{env:env}",
                pathBash      = "bash",
                pathBashdb    = "bash-debug-adapter",
                pathBashdbLib = function()
                    return vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter")
                end,
                pathCat      = "cat",
                pathMkfifo   = "mkfifo",
                pathPkill    = "pkill",
                terminalKind = "integrated",
            },
        },
    },
}
