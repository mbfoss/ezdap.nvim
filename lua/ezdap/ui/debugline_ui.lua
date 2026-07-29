---@brief Singleton that shows the current execution position as a sign + line highlight.
---Tracks the active session; clears/moves the sign on stopped/continued/terminated.

local exception_info = require("ezdap.ui.exception_info")
local fileextmarks   = require("ezdap.util.fileextmarks")
local manager        = require("ezdap.manager")
local ui_util        = require("ezdap.util.ui")
local config         = require("ezdap.config")
local format         = require("ezdap.ui.format")
local timer          = require("ezdap.util.timer")

local M              = {}

local _init_done

---@type ezdap.util.fileextmarks.GroupFunctions?
local _sign_group
---@type ezdap.util.fileextmarks.GroupFunctions?
local _line_group
local _sign_id     = 1 -- fixed id: we only ever show one debugline sign at a time
local _ex_id       = 2 -- the exception annotation, the frameline group's other mark
local _gen         = 0 -- generation counter to guard stale session callbacks
---@type function?  stop fn for the pending deferred clear, if any
local _stop_clear_timer

local _SIGN_HL     = format.hl.debug_frame
local _LINE_HL     = format.hl.debug_frame_line
local _EX_HL       = format.hl.exception

---Is `sess` still the paused active session at that frame line? Guards the
---annotation against the session having resumed, ended or moved on while the
---adapter answered.
---@param sess ezdap.dap.Session
---@param path string
---@param lnum integer
---@return boolean
local function _still_stopped_at(sess, path, lnum)
    if sess ~= manager.session() or sess.state ~= "stopped" then return false end
    local frame = sess:current_stack_frame()
    if not frame or not frame.source or frame.source.path ~= path then return false end
    return ((frame.line and frame.line > 0) and frame.line or 1) == lnum
end

---Annotate the frame line with what the session stopped on, once the adapter
---has told us. Nothing is placed for a stop that is not an exception, or one no
---adapter text describes.
---@param sess ezdap.dap.Session
---@param path string
---@param lnum integer
local function _show_exception(sess, path, lnum)
    if sess.state_reason ~= "exception" then return end
    local gen = _gen
    exception_info.oneline(sess, function(text)
        if not text or gen ~= _gen or not _line_group then return end
        if not _still_stopped_at(sess, path, lnum) then return end
        _line_group.set_file_extmark(_ex_id, path, lnum, 0, {
            virt_text     = { { "  " .. config.signs.exception_breakpoint .. " " .. text, _EX_HL } },
            virt_text_pos = "eol",
            hl_mode       = "combine",
            priority      = 100,
        }, nil)
    end)
end

---@param sess ezdap.dap.Session
local function _show_stopped(sess)
    if not _sign_group or not _line_group then return end
    local frame = sess:current_stack_frame()
    if not frame then return end
    local src = frame.source
    if not src or not src.path or src.path == "" then return end
    local lnum = (frame.line and frame.line > 0) and frame.line or 1
    -- Above Neovim's default sign priority (DECOR_PRIORITY_BASE = 4096), which is
    -- what an extmark sign placed without an explicit priority gets (e.g. keystone
    -- bookmarks). The current frame must win the gutter cell against those.
    _sign_group.set_file_extmark(_sign_id, src.path, lnum, 0,
        { sign_text = config.signs.debug_frame, sign_hl_group = _SIGN_HL, priority = 5000, hl_mode = "blend", }, nil)
    _line_group.set_file_extmark(_sign_id, src.path, lnum, 0, { line_hl_group = _LINE_HL, priority = 40 }, nil)
    if sess.state_reason == "function call" then
        return -- spurious stop triggered by gdp
    end
    local activate = not vim.b.ezdap_disasm
    local col = frame.column and (frame.column - 1) or nil
    ui_util.smart_open_file(src.path, lnum, col, activate)
    _show_exception(sess, src.path, lnum)
end

local function _remove_marks()
    if _sign_group then _sign_group.remove_extmarks() end
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

    fileextmarks.init("ezdap")
    _sign_group = fileextmarks.define_group("framesign")
    _line_group = fileextmarks.define_group("frameline")

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
