---@class ezdap.Signs
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
---@field exception_breakpoint     string  exception filter/type breakpoint, enabled
---@field exception_breakpoint_unsupported string  exception type breakpoint the adapter does not support
---@field data_breakpoint          string  data breakpoint (watchpoint), verified
---@field inactive_data_breakpoint string  data breakpoint, not yet verified
---@field session_running          string  session running
---@field session_paused           string  session paused at a stop
---@field session_stopped          string  session terminated or exited

---Where to render inline variable values while stopped. Names other than "off"
---map directly to a `virt_text_pos` (see `:h nvim_buf_set_extmark`):
---  • "inline"          — a pill right after each variable occurrence (default)
---  • "eol"             — one `name: value` pill per line, after the line text
---  • "eol_right_align" — one pill per line, right-aligned after the line text
---  • "right_align"     — one pill per line, right-aligned at the window edge
---  • "off"             — do not render inline values
---@alias ezdap.InlineVarsMode "inline"|"eol"|"eol_right_align"|"right_align"|"off"

---@class ezdap.Config
---@field root_markers         string[]  filenames/dirs whose presence identifies a project root
---@field data_filename string
---@field debug_value_max_len  integer   max characters shown for variable/expression values in DebugView before truncating
---@field stack_trace_limit    integer   max number of call-stack frames shown in DebugView; extended when the current frame is deeper so it stays visible
---@field antiflicker_delay    integer   milliseconds to wait before clearing stale UI (inline vars, DebugView) to avoid flicker during step-through
---@field output_max_lines     integer   max lines kept in the Output and DAP-messages buffers; oldest lines are trimmed past this (0 = unlimited)
---@field panel_auto_open boolean   open the bottom output window as soon as a run registers its first buffer
---@field panel_height_ratio number  height of the bottom output window, as a fraction of the editor's lines
---@field debug_view_width_ratio number  width of the debug panel on first open, as a fraction of the editor's columns
---@field inline_vars          ezdap.InlineVarsMode  placement of inline variable values
---@field raw_messages         boolean   capture raw DAP protocol messages in a dedicated buffer; a debugging aid, off by default
---@field external_terminal?   string|string[]  terminal emulator (command + args) a debuggee is launched in for an "external" runInTerminal, its command line appended; unset falls back to an integrated terminal
---@field signs ezdap.Signs

---@type ezdap.Config
local M = {
	root_markers        = { ".git" },
	data_filename = ".ezdap.json",
	debug_value_max_len = 30,
	stack_trace_limit   = 10,
	antiflicker_delay   = 200,
	output_max_lines    = 10000,
	panel_auto_open = true,
	panel_height_ratio = 0.25,
	debug_view_width_ratio = 0.3,
	inline_vars         = "eol",
	raw_messages        = false,
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
		exception_breakpoint     = "↯",
		exception_breakpoint_unsupported = "✗",
		data_breakpoint          = "◉",
		inactive_data_breakpoint = "◌",
		session_running          = "▶",
		session_paused           = "■",
		session_stopped          = "●",
	},
}

return M
