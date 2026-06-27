---@class easydap.Signs
---@field debug_frame              string  current execution position
---@field active_breakpoint        string  enabled + verified
---@field inactive_breakpoint      string  enabled but not yet verified by adapter
---@field cond_breakpoint          string  conditional, enabled + verified
---@field inactive_cond_breakpoint string  conditional, enabled but not yet verified
---@field logpoint                 string  logpoint, enabled + verified
---@field inactive_logpoint        string  logpoint, enabled but not yet verified
---@field disabled_breakpoint      string  plain breakpoint, disabled
---@field disabled_cond_breakpoint string  conditional breakpoint, disabled
---@field disabled_logpoint        string  logpoint, disabled

---Where to render inline variable values while stopped. Names other than "off"
---map directly to a `virt_text_pos` (see `:h nvim_buf_set_extmark`):
---  • "inline"          — a pill right after each variable occurrence (default)
---  • "eol"             — one `name: value` pill per line, after the line text
---  • "eol_right_align" — one pill per line, right-aligned after the line text
---  • "right_align"     — one pill per line, right-aligned at the window edge
---  • "off"             — do not render inline values
---@alias easydap.InlineVarsMode "inline"|"eol"|"eol_right_align"|"right_align"|"off"

---@class easydap.Config
---@field root_markers         string[]  filenames/dirs whose presence identifies a project root
---@field data_filename string
---@field debug_value_max_len  integer   max characters shown for variable/expression values in DebugView before truncating
---@field stack_trace_limit    integer   max number of call-stack frames shown in DebugView; extended when the current frame is deeper so it stays visible
---@field antiflicker_delay    integer   milliseconds to wait before clearing stale UI (inline vars, DebugView) to avoid flicker during step-through
---@field raw_messages_max_lines integer  max lines kept in the raw DAP-messages buffer; oldest lines are trimmed past this (0 = unlimited)
---@field inline_vars          easydap.InlineVarsMode  placement of inline variable values
---@field signs easydap.Signs

---@type easydap.Config
local M = {
	root_markers        = { ".git" },
	data_filename = ".easydap.json",
	debug_value_max_len = 30,
	stack_trace_limit   = 2,
	antiflicker_delay   = 200,
	raw_messages_max_lines = 10000,
	inline_vars         = "eol",
	signs = {
		debug_frame              = "▶",
		active_breakpoint        = "●",
		inactive_breakpoint      = "○",
		cond_breakpoint          = "■",
		inactive_cond_breakpoint = "□",
		logpoint                 = "◆",
		inactive_logpoint        = "◇",
		disabled_breakpoint      = "ø",
		disabled_cond_breakpoint = "ø",
		disabled_logpoint        = "ø",
	},
}

return M
