-- Lua — https://github.com/tomblind/local-lua-debugger-vscode
-- Fields follow the `lua-local` configurationAttributes in that extension's
-- package.json. `program` is a nested table the js-based adapter consumes, and is
-- a oneOf: a Lua interpreter plus an entry file, or a custom command.

local shared = require("ezdap.shared")

local _adapter_js = vim.fs.joinpath(
    vim.fn.stdpath("data"), "mason", "packages",
    "local-lua-debugger-vscode", "extension", "extension", "debugAdapter.js"
)

---Fields both launch shapes accept, alongside their own `program` variant.
---@type table<string, ezdap.Input>
local _common_inputs = {
    cwd                 = { type = "string", format = "cwd", description = "working directory" },
    env                 = { type = "table", format = "map", description = "environment variables" },
    communication       = { type = "string", description = "adapter transport: stdio|pipe" },
    script_roots        = { type = "table", format = "list", description = "alternate paths to find Lua scripts in" },
    script_files        = { type = "table", format = "list", description = "globs of scripts to debug (needed for source-mapped breakpoints)" },
    ignore_patterns     = { type = "table", format = "list", description = "Lua patterns matching scripts to skip when stepping" },
    step_unmapped_lines = { type = "boolean", description = "step into Lua when a source-mapped line has no mapping" },
    break_in_coroutines = { type = "boolean", description = "break on errors raised inside coroutines" },
    stop_on_entry       = { type = "boolean", description = "break on the first line after the debug hook is set" },
    verbose             = { type = "boolean", description = "enable verbose debugger output" },
}

---@param ... table<string, ezdap.Input>
---@return table<string, ezdap.Input>
local function _inputs(...)
    local out = vim.deepcopy(_common_inputs)
    for _, group in ipairs({ ... }) do
        out = vim.tbl_extend("error", out, vim.deepcopy(group))
    end
    return out
end

---Assigns everything outside `program`, which each profile fills in itself.
---@param params table
---@param inputs table<string, any>
local function _common_build(params, inputs)
    params.type              = "lua-local"
    params.name              = "Debug"
    params.cwd               = inputs.cwd
    params.env               = inputs.env
    params.scriptRoots       = inputs.script_roots
    params.scriptFiles       = inputs.script_files
    params.ignorePatterns    = inputs.ignore_patterns
    params.stepUnmappedLines = inputs.step_unmapped_lines
    params.breakInCoroutines = inputs.break_in_coroutines
    params.stopOnEntry       = inputs.stop_on_entry
    params.verbose           = inputs.verbose
end

---@type table<string, ezdap.Profile>
local _profiles = {
    -- One `command` input carries the whole command line; `build` splits it into
    -- the script (`program.file`) and `args` (the rest).
    launch_program = {
        description = "debug a Lua script",
        request = "launch",
        inputs = _inputs {
            command = { type = "string", required = true, description = "script to debug, plus its arguments" },
            lua     = { type = "string", description = "Lua interpreter to run the script with (default lua)" },
        },
        build = function(params, _, inputs)
            _common_build(params, inputs)
            -- The script goes inside `program`, not beside it, so the pair is
            -- split off first rather than assigned straight to the body.
            local file, args = shared.split_command(inputs.command)
            params.program = {
                lua           = inputs.lua or vim.fn.exepath("lua"),
                file          = file,
                communication = inputs.communication or "stdio",
            }
            params.args = args
        end,
    },
    -- The custom-command shape: an executable that embeds Lua drives the session
    -- itself, so there is no interpreter or entry file to name.
    launch_command = {
        description = "debug a custom executable that embeds Lua",
        request = "launch",
        inputs = _inputs {
            command = { type = "string", required = true, description = "custom command to run, plus its arguments" },
        },
        build = function(params, _, inputs)
            _common_build(params, inputs)
            local cmd, args = shared.split_command(inputs.command)
            params.program = {
                command       = cmd,
                communication = inputs.communication or "stdio",
            }
            params.args = args
        end,
    },
}

---@type ezdap.AdapterDef
return {
    command  = { "node", _adapter_js },
    env      = {
        LUA_PATH = vim.fs.joinpath(
            vim.fn.stdpath("data"), "mason", "packages",
            "local-lua-debugger-vscode", "debugger", "?.lua"
        ) .. ";;",
    },
    profiles = _profiles,
}
