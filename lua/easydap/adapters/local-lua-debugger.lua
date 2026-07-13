local S = require("easydap.adapters._shared")

-- Lua
local _adapter_js = vim.fs.joinpath(
    vim.fn.stdpath("data"), "mason", "packages",
    "local-lua-debugger-vscode", "extension", "extension", "debugAdapter.js"
)

---@type easydap.AdapterDef
return {
    command       = { "node", _adapter_js },
    env           = {
        LUA_PATH = vim.fs.joinpath(
            vim.fn.stdpath("data"), "mason", "packages",
            "local-lua-debugger-vscode", "debugger", "?.lua"
        ) .. ";;",
    },
    -- `program` is a nested table the js-based adapter consumes; the target file
    -- is set as `program.file`. Field set follows tomblind/local-lua-debugger-vscode's
    -- launch configuration.
    launch_schema = {
        type        = { default = "lua-local", fixed = true },
        name        = { default = "Debug", fixed = true },
        program     = {
            type   = "schema",
            fields = {
                lua           = { default = function() return vim.fn.exepath("lua") end },
                communication = {
                    type = "string",
                    kind = "enum",
                    enum = { "stdio", "pipe" },
                    default = "stdio",
                    desc = "extension<->debugger communication method"
                },
                file          = { type = "string", role = "target", desc = "lua file to debug" },
            },
        },
        args        = S.args,
        cwd         = S.cwd,
        env         = S.env,
        stopOnEntry = { type = "boolean", desc = "stop at entry", default = false },
        scriptRoots = { type = "list", desc = "additional roots for resolving required scripts" },
        verbose     = { type = "boolean", desc = "enable verbose debugger logging" },
    },
}
