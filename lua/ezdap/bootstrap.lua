---@brief Startup wiring: the `:Ezdap` command and the project-state autocmds.
---
---Sourced from `plugin/ezdap.lua` on every startup, so it requires as little as
---it can get away with: `config` for the command name, and `project` at
---`VimEnter` to ask whether this project has state worth restoring. The plugin
---proper (`ezdap`) is pulled in by demand alone — a `:Ezdap` invocation, a
---public API call, or a state file found — and a Neovim that never debugs pays
---for this file and `config`, nothing else.

local M = {}

local _initialised = false
local _probed = false

-- The canonical command. Hardcoded on purpose: every message, every doc line
-- and every `:help` reference can name it outright, and nothing has to be
-- deferred or re-registered to get the name right.
local COMMAND = "Ezdap"

-- One callback, shared by `:Ezdap` and every alias. It doubles as the ownership
-- proof: `nvim_get_commands` hands back the very same function, which nothing
-- else can be holding, so a name another plugin took over cannot be mistaken
-- for one of ours.
---@type function?
local _callback
-- The alias we registered, if any. `:Ezdap` is never one of them: it is
-- registered once and never renamed or removed.
---@type string?
local _alias

---Whether the plugin proper has been loaded. Reading `package.loaded` rather
---than asking `ezdap` is the whole point: the question must not be what
---answers it.
---@return boolean
local function _hot()
    return package.loaded["ezdap"] ~= nil
end

---Whether the command currently named `name` is one of ours.
---@param name string
---@return boolean
local function _owns_command(name)
    if not _callback then return false end
    local cmd = vim.api.nvim_get_commands({})[name]
    return cmd ~= nil and cmd.callback == _callback
end

---Register the command under `name`. Every name shares one callback and one
---completion function, so an alias is the command, not a forwarder.
---@param name string
local function _register_command(name)
    _callback = _callback or function(opts)
        require("ezdap.util.usercmd").handle(opts, function(cmd, args, cmd_opts)
            return require("ezdap").command(cmd, args, cmd_opts)
        end)
    end
    vim.api.nvim_create_user_command(name, _callback, {
        nargs = "*",
        range = true,
        desc = "ezdap commands",
        complete = function(arg_lead, cmd_line, _)
            return require("ezdap.util.usercmd").complete(arg_lead, cmd_line,
                function(cmd, rest, lead)
                    return require("ezdap").complete(cmd, rest, lead)
                end)
        end,
    })
end

---Bring the plugin up if — and only if — this project has state worth
---restoring. Deferred to `VimEnter` so that a `setup()` anywhere in the user's
---config — including a plugin manager's `config` function, which runs after
---`plugin/` — settles `root_markers` and `data_filename` before the lookup.
---
---`project` is the light way to ask: it reads `config` and nothing else, so a
---project without a state file never touches the persistence machinery.
function M.probe()
    _probed = true
    local path = require("ezdap.project").data_path()
    if path and vim.uv.fs_stat(path) then
        require("ezdap")._ensure_loaded()
    end
end

---Whether the saved-state probe has already run.
---@return boolean
function M.probed()
    return _probed
end

---Install the project-state autocmds.
local function _create_autocmds()
    local group = vim.api.nvim_create_augroup("ezdap", { clear = true })

    -- Cold means nothing was ever created and nothing was ever run: no state to
    -- persist, no session to disconnect. Loading ezdap to be told as much is
    -- the startup cost this file exists to avoid.
    vim.api.nvim_create_autocmd({ "DirChangedPre", "VimLeavePre" }, {
        group    = group,
        callback = function() if _hot() then require("ezdap").save_state() end end,
        desc     = "ezdap: persist breakpoints and expressions",
    })

    -- Gracefully stop active sessions on exit: an adapter killed without a
    -- completed `disconnect` orphans its debuggee, and nvim SIGKILLs adapter
    -- jobs as it exits.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group    = group,
        callback = function() if _hot() then require("ezdap").shutdown() end end,
        desc     = "ezdap: disconnect sessions so debuggees are terminated on exit",
    })

    -- After a cwd change, re-resolve the project root and restore its state (or
    -- clear it, when the new cwd is not inside a project). While cold this is
    -- the `VimEnter` question asked again, and answered as cheaply.
    vim.api.nvim_create_autocmd("DirChanged", {
        group    = group,
        callback = function()
            if _hot() then
                require("ezdap").reload_state()
            else
                require("ezdap.project").invalidate()
                M.probe()
            end
        end,
        desc     = "ezdap: restore project state after cwd change",
    })

    if vim.v.vim_did_enter == 1 then
        M.probe()
    else
        vim.api.nvim_create_autocmd("VimEnter", {
            group    = group,
            once     = true,
            callback = function() M.probe() end,
            desc     = "ezdap: restore saved project state once the config has run",
        })
    end
end

---Register `config.command_alias` alongside `:Ezdap`, dropping any alias a
---previous call left behind. The alias shares the canonical command's handler
---and completion, so the two are one command under two names.
---
---An alias whose name is already taken is registered anyway — the user asked
---for that name, and silently dropping the request is worse than honouring it —
---but never silently: whoever is displaced is named in the warning.
---@param name? string
function M.sync_alias(name)
    if name == _alias then return end
    if _alias and _owns_command(_alias) then
        vim.api.nvim_del_user_command(_alias)
    end
    _alias = nil

    if not name or name == COMMAND then return end

    local existing = vim.api.nvim_get_commands({})[name]
    if existing and existing.callback ~= _callback then
        vim.notify(("[ezdap] command_alias %q replaces an existing command (%s)")
            :format(name, existing.definition ~= "" and existing.definition or "no description"),
            vim.log.levels.WARN)
    end
    _register_command(name)
    _alias = name
end

---Whether `init()` has run — the command and the autocmds are in place.
---@return boolean
function M.is_initialised()
    return _initialised
end

---Install the command and the autocmds. Called from `plugin/ezdap.lua` at
---startup, and from `setup()` for an ezdap required by hand.
function M.init()
    if _initialised then return end
    if vim.fn.has("nvim-0.10") ~= 1 then
        vim.notify("[ezdap] ezdap.nvim requires Neovim >= 0.10", vim.log.levels.ERROR)
        return
    end
    _initialised = true

    -- Someone else holding `:Ezdap` is not something to paper over: taking it
    -- would destroy their command silently, and `plugin/` runs after init.lua,
    -- so the loser would be the user's own. Everything else still comes up —
    -- neither the Lua API nor the saved state goes through the command — and
    -- `command_alias` is the way back to one.
    if vim.api.nvim_get_commands({})[COMMAND] then
        vim.notify(("[ezdap] :%s is already taken, so it was left alone; " ..
            "set `command_alias` for a command under another name"):format(COMMAND),
            vim.log.levels.WARN)
    else
        _register_command(COMMAND)
    end

    _create_autocmds()
    M.sync_alias(require("ezdap.config").command_alias)
end

return M
