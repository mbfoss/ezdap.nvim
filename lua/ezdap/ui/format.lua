---@brief Shared presentation of breakpoint state: sign name, glyph, highlight.
---
---Every place that draws a breakpoint (gutter signs in source buffers, the
---DebugView breakpoints section) resolves its glyph here, so a `config.signs`
---override shows up everywhere at once.

local config = require("ezdap.config")

local M = {}

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

---A key of `ezdap.Signs` naming one breakpoint appearance.
---@alias ezdap.ui.format.SignName string

---@type table<ezdap.ui.format.SignName, string>
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
}

---@param spec ezdap.ui.format.BreakpointSpec
---@return ezdap.ui.format.SignName
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

---@param name ezdap.ui.format.SignName
---@return string glyph
---@return string highlight
function M.sign(name)
    return config.signs[name] or "●", _HIGHLIGHTS[name] or "Debug"
end

---@param spec ezdap.ui.format.BreakpointSpec
---@return string glyph
---@return string highlight
---@return ezdap.ui.format.SignName name
function M.breakpoint_sign(spec)
    local name = M.breakpoint_sign_name(spec)
    local glyph, hl = M.sign(name)
    return glyph, hl, name
end

return M
