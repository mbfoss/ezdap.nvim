---@brief easydap — generic DAP backend.
---
---Public API re-exports the client's session management and stepping methods
---at the top level, with `breakpoints` and `configs` as sub-module properties.
---
---  local dap = require("easydap")
---  dap.configs.register("mydbg", { ... })
---  dap.start("mydbg", { on_event = ..., on_session = ... })
---  dap.continue()
---  dap.breakpoints.toggle(source, line)

local _client = require("easydap.client")

local M = {}

-- ── Sub-modules ────────────────────────────────────────────────────────────

M.breakpoints = require("easydap.breakpoints")
M.configs     = require("easydap.configs")

-- ── Signals ────────────────────────────────────────────────────────────────

M.on_session_added     = _client.on_session_added
M.on_session_removed   = _client.on_session_removed
M.on_session_updated   = _client.on_session_updated
M.on_active_changed    = _client.on_active_changed
M.on_session_stopped   = _client.on_session_stopped
M.on_raw_message       = _client.on_raw_message
M.on_selection_changed = _client.on_selection_changed

-- ── Session access ─────────────────────────────────────────────────────────

M.session       = _client.session
M.active_id     = _client.active_id
M.get_session   = _client.get_session
M.sessions      = _client.sessions
M.select_session = _client.select_session

-- ── Lifecycle ──────────────────────────────────────────────────────────────

M.start      = _client.start
M.stop       = _client.stop
M.disconnect = _client.disconnect
M.quit       = _client.quit

-- ── Stepping ──────────────────────────────────────────────────────────────

M.continue      = _client.continue
M.next          = _client.next
M.step_in       = _client.step_in
M.step_out      = _client.step_out
M.step_back     = _client.step_back
M.pause         = _client.pause
M.restart       = _client.restart
M.continue_all  = _client.continue_all
M.terminate_all = _client.terminate_all
M.select_thread = _client.select_thread
M.select_frame  = _client.select_frame

-- ── Evaluate / complete ────────────────────────────────────────────────────

M.evaluate = _client.evaluate
M.complete  = _client.complete

return M
