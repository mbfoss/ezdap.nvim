local S = require("easydap.adapters._shared")

-- bash-debug-adapter has adapter-specific path fields; runInTerminal is omitted
-- because the adapter manages its own terminal via terminalKind. Field set follows
-- rogalmic/vscode-bash-debug's launch attributes — note it has no stopOnEntry
-- (bashdb always breaks at the first line).
---@type easydap.AdapterDef
return {
    command       = "bash-debug-adapter",
    launch_schema = {
        type            = { default = "bashdb", fixed = true },
        name            = { default = "Launch Bash Script", fixed = true },
        program         = { type = "string", role = "target", desc = "bash script to debug" },
        args            = S.args,
        cwd             = S.cwd,
        env             = S.env,
        pathBash        = { default = "bash" },
        pathBashdb      = { default = "bash-debug-adapter" },
        pathBashdbLib   = {
            default = function()
                return vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "bash-debug-adapter")
            end
        },
        pathCat         = { default = "cat" },
        pathMkfifo      = { default = "mkfifo" },
        pathPkill       = { default = "pkill" },
        terminalKind    = { default = "integrated" },
        showDebugOutput = { type = "boolean", desc = "show bashdb output alongside the script output" },
    },
}
