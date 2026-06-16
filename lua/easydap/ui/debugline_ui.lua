---@brief Singleton that shows the current execution position as a sign + line highlight.
---Tracks the active session; clears/moves the sign on stopped/continued/terminated.

local signs      = require("easydap.ui.signs")
local extmarks   = require("easydap.ui.extmarks")
local manager    = require("easydap.manager")
local ui_util    = require("easydap.util.ui_util")
local config     = require("easydap.config")
local timer      = require("easydap.util.timer")

local M          = {}

local _init_done

local _sign_name = "easydap_frame"
---@type easydap.ui.signs.Group?
local _sign_group
---@type easydap.ui.extmarks.GroupFunctions?
local _line_group
local _sign_id   = 1 -- fixed id: we only ever show one debugline sign at a time
local _gen       = 0 -- generation counter to guard stale session callbacks
---@type function?  stop fn for the pending deferred clear, if any
local _stop_clear_timer

local _SIGN_HL   = "EasydapFrameSign"
local _LINE_HL   = "EasydapFrameLine"
local _hl_init ---@type boolean?

vim.api.nvim_set_hl(0, _SIGN_HL, { link = "Todo", default = true })
vim.api.nvim_set_hl(0, _LINE_HL, { link = "DiffChange", default = true })

local function _show_stopped(sess)
    if not _sign_group or not _line_group then return end
    local frame = sess:current_stack_frame()
    if not frame then return end
    local src = frame.source
    if not src or not src.path or src.path == "" then return end
    local lnum = (frame.line and frame.line > 0) and frame.line or 1
    _sign_group.set_file_sign(_sign_id, src.path, lnum, _sign_name, nil)
    _line_group.set_file_extmark(_sign_id, src.path, lnum, 0, { line_hl_group = _LINE_HL, priority = 40 }, nil)
    if sess.state_reason == "function call" then
        return -- spurious stop triggered by gdp
    end
    local activate = not vim.b.easydap_disasm
    local col = frame.column and (frame.column - 1) or nil
    ui_util.smart_open_file(src.path, lnum, col, activate)
end

local function _remove_marks()
    if _sign_group then _sign_group.remove_signs() end
    if _line_group then _line_group.remove_extmarks() end
end

local function _cancel_clear_timer()
    if _stop_clear_timer then
        _stop_clear_timer()
        _stop_clear_timer = nil
    end
end

local function _clear()
    _cancel_clear_timer()
    _remove_marks()
end

---Clear after `delay_ms` to avoid flicker during step-through.
---@param delay_ms integer
local function _deferred_clear(delay_ms)
    _cancel_clear_timer()
    _stop_clear_timer = timer.defer(delay_ms, function()
        _stop_clear_timer = nil
        _remove_marks()
    end)
end

function M.init()
    if _init_done then return end
    _init_done = true

    _sign_group = signs.define_group("easydap_framesign", { priority = 20 })
    _sign_group.define_sign(_sign_name, config.signs.debug_frame, _SIGN_HL)

    _line_group = extmarks.define_group("easydap_frameline", { priority = 20 })

    manager.on_active_changed:subscribe(function(_, sess)
        _clear()
        if not sess then return end

        _gen = _gen + 1
        local gen = _gen

        if sess.state == "stopped" then
            _show_stopped(sess)
        end

        sess:on("stopped", function()
            if gen ~= _gen then return end
            _clear()
            _show_stopped(sess)
        end)
        sess:on("continued", function()
            if gen ~= _gen then return end
            _deferred_clear(config.antiflicker_delay)
        end)
        sess:on("terminated", function()
            if gen ~= _gen then return end
            _clear()
        end)
    end)

    manager.on_selection_changed:subscribe(function(_, sess)
        _clear()
        if sess then _show_stopped(sess) end
    end)
end

return M
