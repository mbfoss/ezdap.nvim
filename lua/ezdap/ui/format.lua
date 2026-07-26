---@brief Shared UI presentation: how debug state becomes glyphs, highlights and
---display strings. Every view resolves its icons here, so a `config.signs`
---override lands everywhere at once. Pure — no buffers, windows or state.

local config   = require("ezdap.config")
local str_util = require("ezdap.util.strutil")

local M        = {}

---One piece of a rendered row: its text and an optional highlight group.
---@alias ezdap.ui.Chunk { [1]: string, [2]: string? }

---A key of `ezdap.Signs` naming one appearance.
---@alias ezdap.ui.SignName string

---Highlight per sign name. A name missing here falls back to `Debug`.
---@type table<ezdap.ui.SignName, string>
local _HIGHLIGHTS = {
    active_breakpoint                = "DiagnosticOk",
    inactive_breakpoint              = "DiagnosticWarn",
    cond_breakpoint                  = "DiagnosticWarn",
    inactive_cond_breakpoint         = "DiagnosticWarn",
    logpoint                         = "DiagnosticHint",
    inactive_logpoint                = "DiagnosticWarn",
    disabled_breakpoint              = "NonText",
    disabled_cond_breakpoint         = "NonText",
    disabled_logpoint                = "NonText",
    exception_breakpoint             = "DiagnosticInfo",
    exception_breakpoint_unsupported = "DiagnosticError",
    data_breakpoint                  = "DiagnosticInfo",
    inactive_data_breakpoint         = "DiagnosticWarn",
    session_running                  = "DiagnosticOk",
    session_paused                   = "DiagnosticWarn",
    session_stopped                  = "NonText",
}

---@param name ezdap.ui.SignName
---@return string glyph
---@return string highlight
function M.sign(name)
    return config.signs[name] or "●", _HIGHLIGHTS[name] or "Debug"
end

-- Breakpoints

---What a breakpoint looks like, independent of how it is stored. `verified` is
---the adapter-reported status: nil when no session has reported on it yet.
---@class ezdap.ui.format.BreakpointSpec
---@field kind          ("source"|"function"|"exception_filter"|"exception_type"|"data")?  defaults to "source"
---@field disabled      boolean?
---@field verified      boolean?
---@field condition     string?
---@field hit_condition string?
---@field log_message   string?
---@field unsupported   boolean?  exception type the adapter does not support

---@param spec ezdap.ui.format.BreakpointSpec
---@return ezdap.ui.SignName
function M.breakpoint_sign_name(spec)
    local kind     = spec.kind or "source"
    local pending  = spec.verified == false
    local has_cond = spec.condition or spec.hit_condition

    if spec.disabled then
        if spec.log_message then return "disabled_logpoint" end
        if has_cond then return "disabled_cond_breakpoint" end
        return "disabled_breakpoint"
    end
    if kind == "exception_type" and spec.unsupported then
        return "exception_breakpoint_unsupported"
    end
    if kind == "exception_filter" or kind == "exception_type" then
        return "exception_breakpoint"
    end
    if kind == "data" then
        return pending and "inactive_data_breakpoint" or "data_breakpoint"
    end
    if spec.log_message then
        return pending and "inactive_logpoint" or "logpoint"
    end
    if has_cond then
        return pending and "inactive_cond_breakpoint" or "cond_breakpoint"
    end
    return pending and "inactive_breakpoint" or "active_breakpoint"
end

---@param spec ezdap.ui.format.BreakpointSpec
---@return string glyph
---@return string highlight
---@return ezdap.ui.SignName name
function M.breakpoint_sign(spec)
    local name = M.breakpoint_sign_name(spec)
    local glyph, hl = M.sign(name)
    return glyph, hl, name
end

-- Sessions

---Anything carrying a session's lifecycle: an `ezdap.dap.Session`, a
---`ezdap.client.SessionInfo`, or a stored row's remembered state.
---@alias ezdap.ui.format.SessionSpec { state: string?, is_paused: boolean? }

---@param state string?  a `ezdap.dap.Session.state` value
---@return boolean
function M.session_finished(state)
    return state == "terminated" or state == "exited"
end

---The user-facing name of a session state: DAP's vocabulary reads oddly in a UI
---("stopped" means paused at a breakpoint, "terminated" means the run is over).
---@param state string?  a `ezdap.dap.Session.state` value
---@return string
function M.session_state(state)
    if state == "stopped" then return "paused" end
    if M.session_finished(state) then return "stopped" end
    return state or "unknown"
end

---@param spec ezdap.ui.format.SessionSpec?
---@return ezdap.ui.SignName
function M.session_sign_name(spec)
    local state = spec and spec.state
    if M.session_finished(state) then return "session_stopped" end
    if (spec and spec.is_paused) or state == "stopped" then return "session_paused" end
    return "session_running"
end

---@param spec ezdap.ui.format.SessionSpec?
---@return string glyph
---@return string highlight
---@return ezdap.ui.SignName name
function M.session_sign(spec)
    local name = M.session_sign_name(spec)
    local glyph, hl = M.sign(name)
    return glyph, hl, name
end

---Capability keys the adapter reports as supported, `supports` prefix dropped
---and sorted, ready to list in a hover.
---@param sess ezdap.dap.Session?
---@return string[]
function M.capability_names(sess)
    local names = {}
    for key, val in pairs(sess and sess.capabilities or {}) do
        if val == true then
            local name = key:gsub("^supports", "")
            names[#names + 1] = name:sub(1, 1):lower() .. name:sub(2)
        end
    end
    table.sort(names)
    return names
end

-- Values and paths

---A value on one line: newlines become `⏎`, nothing is cropped.
---@param value any
---@return string
function M.oneline(value)
    return (tostring(value or ""):gsub("\n", "⏎"))
end

---A value on one line, cropped to `max_len` columns (`debug_value_max_len` by
---default).
---@param value any
---@param max_len integer?
---@return string
function M.value(value, max_len)
    return (str_util.crop_for_ui(M.oneline(value), max_len or config.debug_value_max_len))
end

---Split a path into a directory prefix and its last segment, cropping only the
---prefix (from the left) so the whole fits `budget` columns. The tail is kept
---intact even when it alone overflows.
---@param path string
---@param budget integer  columns available for the whole path
---@return string dir
---@return string tail
function M.fit_path(path, budget)
    local dir, tail = path:match("^(.*/)(.-)$")
    if not dir then return "", path end
    local room = budget - vim.fn.strdisplaywidth(tail)
    if #dir > room then dir = str_util.crop_for_ui(dir, room, true) end
    return dir, tail
end

return M
