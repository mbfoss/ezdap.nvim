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
        -- One `command` input carries the whole command line; `build` splits it into
        -- the script (`program.file`) and `args` (the rest).
        launch = {
            description = "debug a Lua script",
            request = "launch",
            inputs = {
                command = { type = "table", format = "shell_args", description = "command line to debug" },
                cwd     = { type = "string", format = "cwd", description = "working directory" },
                env     = { type = "table", format = "env", description = "environment variables" },
            },
            build = function(params, _, inputs)
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
            template = [[
                type = "lua-local",
                name = "Debug",
                program = {
                    lua           = vim.fn.exepath("lua"),  -- Lua interpreter to run under
                    communication = "stdio",
                    file          = "./main.lua",           -- Lua script to run
                },
                args = { "--verbose" },        -- arguments passed to the script
                cwd  = vim.fn.getcwd(),        -- working directory
                env  = { EXAMPLE = "value" },  -- environment variables
            ]],
        },
    },
}
