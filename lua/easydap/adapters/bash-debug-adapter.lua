-- bash-debug-adapter has adapter-specific path fields; runInTerminal is omitted
-- because the adapter manages its own terminal via terminalKind. Field set follows
-- rogalmic/vscode-bash-debug's launch attributes — note it has no stopOnEntry
-- (bashdb always breaks at the first line).
---@type easydap.AdapterDef
return {
    command = "bash-debug-adapter",
    configurations = {
        -- `quick_run bash-debug-adapter bash_script script=./run.sh`.
        bash_script = {
            description = "debug a bash script",
            request = "launch",
            inputs = {
                script = { type = "file", description = "bash script to debug" },
                cwd    = { type = "cwd", description = "working directory" },
                env    = { type = "env", description = "environment variables" },
            },
            template = {
                type = "bashdb",
                name = "Launch Bash Script",
                program = "./run.sh",
                cwd     = vim.fn.getcwd,
                env     = { EXAMPLE = "value" },
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
            fill = function(params, inputs)
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
