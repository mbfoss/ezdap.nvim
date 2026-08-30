---@brief Health check for ezdap.nvim — run with `:checkhealth ezdap`.
---
---Reports the Neovim version, whether `setup()` has run, the resolved project /
---store state, and which adapters are registered — by name only, since loading a
---definition to check it is `:Debug adapter_info <adapter>`.

local M = {}

local health = vim.health

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

---List the registered adapters. Their names are read from the registry's
---filenames, so nothing here loads a definition; checking one is
---`:Debug adapter_info <adapter>`, which reports its modes, inputs and tooling.
local function _check_adapters()
    health.start("ezdap: adapters")

    local names = require("ezdap").available_adapters()
    health.ok(("%d registered: %s"):format(#names, table.concat(names, ", ")))
    health.info((":%s adapter_info <adapter> loads one and reports its modes, inputs and tooling")
        :format(require("ezdap.config").command))
end

function M.check()
    _check_requirements()
    _check_setup()
    _check_adapters()
end

return M
