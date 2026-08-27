---@brief Health check for ezdap.nvim — run with `:checkhealth ezdap`.
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

---Check the Neovim version against the plugin's minimum (see `ezdap.setup`).
local function _check_requirements()
    health.start("ezdap: requirements")
    if vim.fn.has("nvim-0.10") == 1 then
        health.ok("Neovim " .. tostring(vim.version()))
    else
        health.error("ezdap.nvim requires Neovim >= 0.10")
    end
end

---Report whether setup() has run and the resolved project / store state.
local function _check_setup()
    health.start("ezdap: setup")

    -- Read through package.loaded rather than requiring: an unloaded ezdap is
    -- itself the answer, and loading it here would not have run setup anyway.
    local ezdap = package.loaded["ezdap"]
    if ezdap and ezdap.is_setup() then
        health.ok(("setup() has been called (:%s is registered)")
            :format(require("ezdap.config").command))
    else
        health.warn("setup() has not been called", {
            "Add require('ezdap').setup() to your config",
        })
    end

    local store = require("ezdap.store")
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
---@param cfg  ezdap.AdapterDef
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

---Check each registered adapter for its local dependencies.
local function _check_adapters()
    health.start("ezdap: adapters")

    local adapters = require("ezdap.adapters")
    local names    = vim.tbl_keys(adapters)
    table.sort(names)

    for _, name in ipairs(names) do
        local cfg = adapters[name]
        if type(cfg) == "table" then
            _check_adapter(name, cfg)
        end
    end
end

---Check every registered definition for declaration mistakes — the ones that
---otherwise surface only when someone runs that mode.
local function _check_definitions()
    health.start("ezdap: adapter definitions")

    local problems = require("ezdap.schema").validate_all()
    local names = vim.tbl_keys(problems)
    table.sort(names)

    if #names == 0 then
        health.ok("every registered definition resolves")
        return
    end
    for _, name in ipairs(names) do
        health.warn(name .. ":\n  " .. table.concat(problems[name], "\n  "))
    end
end

function M.check()
    _check_requirements()
    _check_setup()
    _check_adapters()
    _check_definitions()
end

return M
