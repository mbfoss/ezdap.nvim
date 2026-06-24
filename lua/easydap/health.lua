---@brief Health check for easydap.nvim — run with `:checkhealth easydap`.
---
---Reports the Neovim version, whether `setup()` has run, the resolved project /
---store state, and which built-in DAP adapters have their dependencies in place
---(process-based adapters need their executable on PATH; connection-based
---adapters have nothing to verify locally).

local M = {}

local health = vim.health

---Extract the executable name from an adapter's `command` field.
---@param command string|string[]|nil
---@return string? exe
local function _exe_of(command)
    if type(command) == "table" then return command[1] end
    if type(command) == "string" then return command end
    return nil
end

---Check the Neovim version against the plugin's minimum (see plugin/easydap.lua).
local function _check_requirements()
    health.start("easydap: requirements")
    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim " .. tostring(vim.version()))
    else
        health.error("easydap.nvim requires Neovim >= 0.10")
    end
end

---Report whether setup() has run and the resolved project / store state.
local function _check_setup()
    health.start("easydap: setup")

    if vim.fn.exists(":Debug") == 2 then
        health.ok("setup() has been called (:Debug is registered)")
    else
        health.warn("setup() has not been called", {
            "Add require('easydap').setup() to your config",
        })
    end

    local store = require("easydap.store")
    local root  = store.root()
    if not root then
        health.info("cwd is not inside a project (no root marker found)")
        return
    end

    local path = store.data_path()
    if path and vim.fn.filereadable(path) == 1 then
        health.ok(("project root: %s (%s exists)"):format(root, vim.fs.basename(path)))
    else
        health.info(("project root: %s (no data file yet)"):format(root))
    end
end

---Check a single adapter's local dependencies.
---@param name string
---@param cfg  easydap.dap.Config
local function _check_adapter(name, cfg)
    local exe = _exe_of(cfg.command)

    if not exe then
        if cfg.host or cfg.port ~= nil then
            health.info(("%s: connection-based (host/port), nothing to verify"):format(name))
        elseif cfg.setup then
            health.info(("%s: provisioned on use, nothing to verify"):format(name))
        else
            health.info(("%s: no command configured"):format(name))
        end
        return
    end

    local resolved = vim.fn.exepath(exe)
    if resolved == "" then
        health.warn(("%s: '%s' not found on PATH"):format(name, exe), {
            "Install it to use the " .. name .. " adapter",
        })
        return
    end

    -- Table commands may point at an adapter file (e.g. a mason-managed .js);
    -- the executable existing does not mean the adapter itself is installed.
    if type(cfg.command) == "table" then
        for i = 2, #cfg.command do
            local arg = cfg.command[i]
            if type(arg) == "string" and arg:sub(1, 1) == "/" and arg:match("%.js$")
                and vim.fn.filereadable(arg) == 0 then
                health.warn(("%s: '%s' found but adapter file is missing: %s")
                    :format(name, exe, arg), {
                        "Install the " .. name .. " adapter (e.g. via mason)",
                    })
                return
            end
        end
    end

    health.ok(("%s: '%s' found (%s)"):format(name, exe, resolved))
end

---Check each built-in adapter for its local dependencies.
local function _check_adapters()
    health.start("easydap: adapters")

    local adapters = require("easydap.adapters")
    local names    = vim.tbl_keys(adapters)
    table.sort(names)

    for _, name in ipairs(names) do
        local cfg = adapters[name]
        if type(cfg) == "table" then
            _check_adapter(name, cfg)
        end
    end
end

function M.check()
    _check_requirements()
    _check_setup()
    _check_adapters()
end

return M
