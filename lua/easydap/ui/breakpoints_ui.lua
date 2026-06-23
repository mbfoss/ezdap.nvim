---@brief Singleton that renders breakpoints in source buffers.
---Subscribes to breakpoints.on_change and keeps the marks in sync.
---
---Line breakpoints are gutter signs. Column breakpoints render an inline glyph
---right before their column instead. Both drive the extmarks module directly
---(the signs module only ever places marks in the gutter at column 0).

local extmarks    = require("easydap.ui.extmarks")
local breakpoints = require("easydap.dap.breakpoints")
local config      = require("easydap.config")
local manager     = require("easydap.manager")

local M           = {}

---@type easydap.ui.extmarks.GroupFunctions?
local _group
local _init_done

local _BP_HL      = "EasydapBreakpoint"
vim.api.nvim_set_hl(0, _BP_HL, { link = "Debug", default = true })

---Glyph per sign name, resolved locally now that `_group` is a raw extmarks
---group with no `define_sign`. Populated in `init` from `config.signs`.
---@type table<string, string>
local _glyphs = {}

---@param bp easydap.dap.SourceBreakpoint
---@param st easydap.dap.BpStatus?
local function _sign_name(bp, st)
    local has_cond = bp.condition or bp.hit_condition
    if bp.disabled then
        if bp.log_message then return "disabled_logpoint" end
        if has_cond then return "disabled_cond_breakpoint" end
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
    if not _group then return end
    _group.remove_extmarks()
    for _, bp in ipairs(breakpoints.all()) do
        if bp.source ~= "" then
            assert(bp.internal_id > 0, "breakpoint internal_id must be positive")
            -- While a session is live the adapter may bind the breakpoint to a
            -- different line; show the sign there. Falls back to the stored line
            -- when there is no session (st is nil) or it was not moved.
            local st    = manager.bp_status(bp.internal_id)
            local lnum  = (st and st.line) or bp.line
            local name  = _sign_name(bp, st)
            local glyph = _glyphs[name]
            ---@type vim.api.keyset.set_extmark
            local opts  = {}
            local col   = 0
            if bp.column then
                -- Column breakpoint: inline glyph just before the column only, no
                -- gutter sign.
                col                = math.max(0, bp.column - 1)
                opts.virt_text     = { { glyph, _BP_HL } }
                opts.virt_text_pos = "inline"
            else
                -- Line breakpoint: gutter sign.
                opts.sign_text     = glyph
                opts.sign_hl_group = _BP_HL
            end
            _group.set_file_extmark(bp.internal_id, bp.source, lnum, col, opts, { name = name })
        end
    end
end

function M.init()
    if _init_done then return end
    _init_done   = true
    local s      = config.signs
    local defs   = {
        { "active_breakpoint",        s.active_breakpoint },
        { "inactive_breakpoint",      s.inactive_breakpoint },
        { "cond_breakpoint",          s.cond_breakpoint },
        { "inactive_cond_breakpoint", s.inactive_cond_breakpoint },
        { "logpoint",                 s.logpoint },
        { "inactive_logpoint",        s.inactive_logpoint },
        { "disabled_breakpoint",      s.disabled_breakpoint },
        { "disabled_cond_breakpoint", s.disabled_cond_breakpoint },
        { "disabled_logpoint",        s.disabled_logpoint },
    }
    _group       = extmarks.define_group("breakpoints", { priority = 10 })
    for _, d in ipairs(defs) do
        _glyphs[d[1]] = d[2]
    end

    breakpoints.on_change:subscribe(_refresh)
    -- Adapter-verified status is session-scoped; repaint signs when it changes.
    manager.on_breakpoint_updated:subscribe(function() _refresh() end)
    manager.on_active_changed:subscribe(function() _refresh() end)

    extmarks.on_synced:subscribe(function(file)
        local marks = _group.get_file_extmarks(file, false)
        if #marks == 0 then return end
        local positions = {}
        for _, mark in ipairs(marks) do
            positions[mark.id] = { lnum = mark.lnum, col = mark.col }
        end
        breakpoints.relocate_batch(positions)
    end)

    _refresh()
end

return M
