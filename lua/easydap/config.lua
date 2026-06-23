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

---@class easydap.Config
---@field root_markers         string[]  filenames/dirs whose presence identifies a project root
---@field data_filename string
---@field debug_value_max_len  integer   max characters shown for variable/expression values in DebugView before truncating
---@field antiflicker_delay    integer   milliseconds to wait before clearing stale UI (inline vars, DebugView) to avoid flicker during step-through
---@field signs easydap.Signs

---@type easydap.Config
local M = {
	root_markers        = { ".git" },
	data_filename = ".easydap.json",
	debug_value_max_len = 70,
	antiflicker_delay   = 200,
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
