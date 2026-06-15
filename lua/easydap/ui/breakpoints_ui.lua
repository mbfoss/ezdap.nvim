---@brief Singleton that renders breakpoints as signs in source buffers.
---Subscribes to breakpoints.on_change and keeps signs in sync.

local signs       = require("easydap.ui.signs")
local breakpoints = require("easydap.dap.breakpoints")
local config      = require("easydap.config")
local manager     = require("easydap.manager")

local M = {}

---@type easydap.ui.signs.Group?
local _group
local _init_done

local _BP_HL = "EasydapBreakpoint"
vim.api.nvim_set_hl(0, _BP_HL, { link = "Debug", default = true })

local function _sign_name(bp)
    local has_cond = bp.condition or bp.hit_condition
    if bp.disabled then
        if bp.log_message then return "disabled_logpoint"        end
        if has_cond       then return "disabled_cond_breakpoint" end
        return "disabled_breakpoint"
    end
    local st       = manager.bp_status(bp.internal_id)
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
    if not _group then return end
    _group.remove_signs()
    for _, bp in ipairs(breakpoints.all()) do
        if bp.source ~= "" then
            _group.set_file_sign(bp.internal_id, bp.source, bp.line, _sign_name(bp), nil)
        end
    end
end

function M.init()
    if _init_done then return end
    _init_done = true
    _group = signs.define_group("easydap_breakpoints", { priority = 10 })
    local s = config.signs
    _group.define_sign("active_breakpoint",        s.active_breakpoint,        _BP_HL)
    _group.define_sign("inactive_breakpoint",      s.inactive_breakpoint,      _BP_HL)
    _group.define_sign("cond_breakpoint",          s.cond_breakpoint,          _BP_HL)
    _group.define_sign("inactive_cond_breakpoint", s.inactive_cond_breakpoint, _BP_HL)
    _group.define_sign("logpoint",                 s.logpoint,                 _BP_HL)
    _group.define_sign("inactive_logpoint",        s.inactive_logpoint,        _BP_HL)
    _group.define_sign("disabled_breakpoint",      s.disabled_breakpoint,      _BP_HL)
    _group.define_sign("disabled_cond_breakpoint", s.disabled_cond_breakpoint, _BP_HL)
    _group.define_sign("disabled_logpoint",        s.disabled_logpoint,        _BP_HL)

    breakpoints.on_change:subscribe(_refresh)
    manager.on_active_changed:subscribe(function() _refresh() end)
    _refresh()
end

return M
