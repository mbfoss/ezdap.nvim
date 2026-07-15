-- Lua
local _adapter_js = vim.fs.joinpath(
    vim.fn.stdpath("data"), "mason", "packages",
    "local-lua-debugger-vscode", "extension", "extension", "debugAdapter.js"
)

---@type easydap.AdapterDef
return {
    command = { "node", _adapter_js },
    env     = {
        LUA_PATH = vim.fs.joinpath(
            vim.fn.stdpath("data"), "mason", "packages",
            "local-lua-debugger-vscode", "debugger", "?.lua"
        ) .. ";;",
    },
    -- `program` is a nested table the js-based adapter consumes; the target file
    -- is set as `program.file`. Field set follows tomblind/local-lua-debugger-vscode's
    -- launch configuration.
    configurations = {
        -- One `command` input carries the whole command line; `fill` splits it into
        -- the script (`program.file`) and `args` (the rest).
        launch = {
            description = "debug a Lua script",
            request = "launch",
            inputs = {
                command = { type = "shell_args", description = "command line to debug" },
                cwd     = { type = "cwd", description = "working directory" },
                env     = { type = "env", description = "environment variables" },
            },
            template = {
                type = "lua-local",
                name = "Debug",
                program = {
                    lua           = function() return vim.fn.exepath("lua") end,
                    communication = "stdio",
                    file          = "./main.lua",
                },
                args = { "--verbose" },
                cwd  = vim.fn.getcwd,
                env  = { EXAMPLE = "value" },
            },
            fill = function(params, inputs)
                params.type = "lua-local"
                params.name = "Debug"
                params.program = {
                    lua           = vim.fn.exepath("lua"),
                    communication = "stdio",
                    file          = inputs.command and vim.fn.expand(inputs.command[1] or ""),
                }
                if inputs.command then
                    params.args = { unpack(inputs.command, 2) }
                end
                params.cwd = inputs.cwd
                params.env = inputs.env
            end,
        },
    },
}
