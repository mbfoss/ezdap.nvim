---@class ezdap.Symbols
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
---@field unsupported_breakpoint   string  exception type breakpoint the adapter does not support
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

---Side of the editor the debug panel's full-height vertical split lives on.
---@alias ezdap.DebugViewPosition "left"|"right"

---@class ezdap.Config
---@field command              string    name of the user command every subcommand lives under, e.g. "Dbg" for `:Dbg run`
---@field root_markers         string[]  filenames/dirs whose presence identifies a project root
---@field enabled_adapters?    string[]  names of the only adapters to make available; unset (the default) leaves every registered adapter available
---@field data_filename string
---@field stack_trace_limit    integer   max number of call-stack frames shown in DebugView; extended when the current frame is deeper so it stays visible
---@field antiflicker_delay    integer   milliseconds to wait before clearing stale UI (inline vars, DebugView) to avoid flicker during step-through
---@field output_max_lines     integer   max lines kept in the Output and DAP-messages buffers; oldest lines are trimmed past this (0 = unlimited)
---@field panel_auto_open boolean   open the bottom output window as soon as a run registers its first buffer; ignored when dock.nvim owns the panel, which has its own `auto_open`
---@field panel_height_ratio number  height of the bottom output window, as a fraction of the editor's lines; ignored when dock.nvim owns the panel, which has its own `size`
---@field debug_view_width_ratio number  width of the debug panel on first open, as a fraction of the editor's columns
---@field debug_view_position ezdap.DebugViewPosition  side of the editor the debug panel splits off
---@field inline_vars          ezdap.InlineVarsMode  placement of inline variable values
---@field raw_messages         boolean   capture raw DAP protocol messages in a dedicated buffer; a debugging aid, off by default
---@field popup_menu           boolean   add a "Debug Inspect" entry to the right-click menu while a session is live
---@field external_terminal?   string|string[]  terminal emulator (command + args) a debuggee is launched in for an "external" runInTerminal, its command line appended; unset fails such a request
---@field symbols              ezdap.Symbols  glyphs for every debug state, in the gutter and in the panels alike

---@type ezdap.Config
local M = {
	command                = "Debug",
	root_markers           = { ".git" },
	data_filename          = ".ezdap.json",
	stack_trace_limit      = 10,
	antiflicker_delay      = 200,
	output_max_lines       = 10000,
	panel_auto_open        = true,
	panel_height_ratio     = 0.25,
	debug_view_width_ratio = 0.2,
	debug_view_position    = "left",
	inline_vars            = "eol",
	raw_messages           = false,
	popup_menu             = true,
	symbols                = {
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
		unsupported_breakpoint   = "✗",
		data_breakpoint          = "◉",
		inactive_data_breakpoint = "◌",
		session_running          = "▶",
		session_paused           = "■",
		session_stopped          = "●",
	},
}

return M
