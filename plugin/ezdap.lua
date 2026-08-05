if vim.fn.has("nvim-0.10") ~= 1 then
    error("ezdap.nvim requires Neovim >= 0.10")
end

-- `:Debug` and the project-state autocmds are registered here at startup
-- without requiring any Lua: every callback pulls in what it needs on first
-- use. `util/usercmd` is the command plumbing -- it splits the arguments and
-- drives completion, and knows nothing about what the subcommands do -- and
-- `ezdap` is the plugin proper. Neither is read until the command is first run
-- or completed.
-- Both modules are cached in a local on first use, so the callbacks pay for a
-- `require` lookup once rather than on every invocation.
local usercmd ---@type table?
local ezdap ---@type table?

---@return table
local function _usercmd()
    usercmd = usercmd or require("ezdap.util.usercmd")
    return usercmd
end

---@return table
local function _ezdap()
    ezdap = ezdap or require("ezdap")
    return ezdap
end

--- The plugin proper, but only once something has loaded it. The autocmds below
--- fire in every session; one that never touched ezdap has no breakpoints,
--- expressions or sessions to save, restore or disconnect.
---@return table?
local function _loaded()
    if package.loaded["ezdap"] then return _ezdap() end
end

vim.api.nvim_create_user_command("Debug", function(opts)
    _usercmd().handle(opts, function(cmd, args, cmd_opts)
        return _ezdap().command(cmd, args, cmd_opts)
    end)
end, {
    nargs = "*",
    range = true,
    desc = "ezdap commands",
    complete = function(arg_lead, cmd_line, _)
        return _usercmd().complete(arg_lead, cmd_line,
            function(cmd, rest, lead)
                return _ezdap().complete(cmd, rest, lead)
            end)
    end,
})

local group = vim.api.nvim_create_augroup("ezdap", { clear = true })

-- Persist before leaving the current project (cwd change) and on exit.
vim.api.nvim_create_autocmd({ "DirChangedPre", "VimLeavePre" }, {
    group    = group,
    callback = function()
        local m = _loaded()
        if m then m.save_state() end
    end,
    desc     = "ezdap: persist breakpoints and expressions",
})

-- Gracefully stop active sessions on exit: an adapter killed without a completed
-- `disconnect` orphans its debuggee, and nvim SIGKILLs adapter jobs as it exits.
vim.api.nvim_create_autocmd("VimLeavePre", {
    group    = group,
    callback = function()
        local m = _loaded()
        if m then m.shutdown() end
    end,
    desc     = "ezdap: disconnect sessions so debuggees are terminated on exit",
})

-- After a cwd change, re-resolve the project root and restore its state
-- (or clear it, when the new cwd is not inside a project).
vim.api.nvim_create_autocmd("DirChanged", {
    group    = group,
    callback = function()
        local m = _loaded()
        if m then m.reload_state() end
    end,
    desc     = "ezdap: restore project state after cwd change",
})
