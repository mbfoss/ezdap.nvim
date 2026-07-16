-- bash-debug-adapter has adapter-specific path fields; runInTerminal is omitted
-- because the adapter manages its own terminal via terminalKind. Field set follows
-- rogalmic/vscode-bash-debug's launch attributes — note it has no stopOnEntry
-- (bashdb always breaks at the first line).
---@type easydap.AdapterDef
return {
    command = "bash-debug-adapter",
    profiles       = {
        -- `quick_run bash-debug-adapter bash_script script=./run.sh`.
        bash_script = {
            description = "debug a bash script",
            request = "launch",
            inputs = {
                script = { type = "string", format = "file", description = "bash script to debug" },
                cwd    = { type = "string", format = "cwd", description = "working directory" },
                env    = { type = "table", format = "env", description = "environment variables" },
            },
            build = function(params, _, inputs)
                params.type    = "bashdb"
                params.name    = "Launch Bash Script"
                params.program = inputs.script
                params.cwd     = inputs.cwd
                params.env     = inputs.env
                params.pathBash      = "bash"
                params.pathBashdb    = "bash-debug-adapter"
                params.pathBashdbLib =
                    vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter")
                params.pathCat      = "cat"
                params.pathMkfifo   = "mkfifo"
                params.pathPkill    = "pkill"
                params.terminalKind = "integrated"
            end,
        },
    },
}
