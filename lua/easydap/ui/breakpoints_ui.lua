---@brief Singleton that renders breakpoints as signs in source buffers.
---Subscribes to breakpoints.on_change and keeps signs in sync.

local signs       = require("easydap.ui.signs")
local breakpoints = require("easydap.dap.breakpoints")
local config      = require("easydap.config")
local manager     = require("easydap.manager")

local M = {}

---@type easydap.ui.signs.Group?
local _group
-- Origin markers live in their own group so they can reuse bp.internal_id as the
-- sign id (extmark ids must be positive, and would collide within one group).
---@type easydap.ui.signs.Group?
local _moved_group
local _init_done

local _BP_HL = "EasydapBreakpoint"
vim.api.nvim_set_hl(0, _BP_HL, { link = "Debug", default = true })

-- Dimmed marker left at the original line when the adapter moves a breakpoint.
local _MOVED_HL = "EasydapBreakpointMoved"
vim.api.nvim_set_hl(0, _MOVED_HL, { link = "Comment", default = true })

---@param bp easydap.dap.SourceBreakpoint
---@param st easydap.dap.BpStatus?
local function _sign_name(bp, st)
    local has_cond = bp.condition or bp.hit_condition
    if bp.disabled then
        if bp.log_message then return "disabled_logpoint"        end
        if has_cond       then return "disabled_cond_breakpoint" end
        return "disabled_breakpoint"
    end
    local verified = st and st.verified
    if bp.log_message then
        return verified == false and "inactive_logpoint" or "logpoint"
    end
    if has_cond then
        return verified == false and "inactive_cond_breakpoint" or "cond_breakpoint"
    end
    return verified == false and "inactive_breakpoint" or "active_breakpoint"
end

local function _refresh()
    if not _group or not _moved_group then return end
    _group.remove_signs()
    _moved_group.remove_signs()
    for _, bp in ipairs(breakpoints.all()) do
        if bp.source ~= "" then
            assert(bp.internal_id > 0, "breakpoint internal_id must be positive")
            -- While a session is live the adapter may bind the breakpoint to a
            -- different line; show the sign there. Falls back to the stored line
            -- when there is no session (st is nil) or it was not moved.
            local st   = manager.bp_status(bp.internal_id)
            local lnum = (st and st.line) or bp.line
            _group.set_file_sign(bp.internal_id, bp.source, lnum, _sign_name(bp, st), nil)
            -- When the adapter moved the breakpoint, leave a dimmed copy of the
            -- same glyph at its origin.
            if st and st.line and st.line ~= bp.line then
                _moved_group.set_file_sign(bp.internal_id, bp.source, bp.line,
                    _sign_name(bp, st), nil)
            end
        end
    end
end

function M.init()
    if _init_done then return end
    _init_done = true
    local s = config.signs
    local defs = {
        { "active_breakpoint",        s.active_breakpoint        },
        { "inactive_breakpoint",      s.inactive_breakpoint      },
        { "cond_breakpoint",          s.cond_breakpoint          },
        { "inactive_cond_breakpoint", s.inactive_cond_breakpoint },
        { "logpoint",                 s.logpoint                 },
        { "inactive_logpoint",        s.inactive_logpoint        },
        { "disabled_breakpoint",      s.disabled_breakpoint      },
        { "disabled_cond_breakpoint", s.disabled_cond_breakpoint },
        { "disabled_logpoint",        s.disabled_logpoint        },
    }
    _group       = signs.define_group("easydap_breakpoints",       { priority = 10 })
    _moved_group = signs.define_group("easydap_breakpoints_moved", { priority = 10 })
    -- Both groups share the glyphs; the origin marker just uses a dimmer highlight.
    for _, d in ipairs(defs) do
        _group.define_sign(d[1], d[2], _BP_HL)
        _moved_group.define_sign(d[1], d[2], _MOVED_HL)
    end

    breakpoints.on_change:subscribe(_refresh)
    manager.on_active_changed:subscribe(function() _refresh() end)
    _refresh()
end

return M
