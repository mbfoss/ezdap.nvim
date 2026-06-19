---@brief Active session manager and user-facing command surface.
---Owns the "which session is active" concept and exposes all user commands.
---The DAP client (dap/client.lua) is session-id-explicit; this module wraps it
---with the active-session notion that keymaps and UI subscribe to.

local select  = require("easydap.util.select").select
local client   = require("easydap.dap.client")
local Signal   = require("easydap.util.Signal")
local inputwin   = require("easydap.util.inputwin")

local M = {}

-- ── Re-exported types ─────────────────────────────────────────────────────
---@alias easydap.manager.SessionInfo easydap.client.SessionInfo
---@alias easydap.manager.StartOpts   easydap.client.StartOpts

-- ── Re-exported client signals ─────────────────────────────────────────────
-- Consumers import only manager; client is an implementation detail.

M.on_session_added    = client.on_session_added    ---@type easydap.util.Signal<fun(id:number, sess:easydap.dap.Session, info:easydap.client.SessionInfo)>
M.on_session_removed  = client.on_session_removed  ---@type easydap.util.Signal<fun(id:number)>
M.on_session_updated  = client.on_session_updated  ---@type easydap.util.Signal<fun(id:number, info:easydap.client.SessionInfo)>
M.on_session_stopped  = client.on_session_stopped  ---@type easydap.util.Signal<fun(id:number, info:easydap.client.SessionInfo)>
M.on_raw_message      = client.on_raw_message      ---@type easydap.util.Signal<fun(id:number, direction:"in"|"out", msg:table)>
M.on_variable_changed = client.on_variable_changed ---@type easydap.util.Signal<fun(id:number, sess:easydap.dap.Session)>

---@param id number
---@return easydap.dap.Session?
function M.get_session(id) return client.get_session(id) end

---@return table<number, easydap.dap.Session>
function M.sessions() return client.sessions() end

---@param config string|table
---@param opts? easydap.client.StartOpts
function M.start(config, opts) return client.start(config, opts) end

-- ── Active session ─────────────────────────────────────────────────────────

---Fires when the active (stepping) session changes: (id?, sess?)
M.on_active_changed    = Signal.new() ---@type easydap.util.Signal<fun(id:number?, sess:easydap.dap.Session?)>
---Fires when thread or frame selection changes in the active session: (id, sess)
M.on_selection_changed = Signal.new() ---@type easydap.util.Signal<fun(id:number, sess:easydap.dap.Session)>

---@type number?
local _active_id = nil

---@param id number?
local function _set_active(id)
    if _active_id == id then return end
    _active_id = id
    M.on_active_changed:emit(id, id and client.get_session(id) or nil)
end

-- forward selection changes from the active session only
client.on_selection_changed:subscribe(function(id, sess)
    if id == _active_id then M.on_selection_changed:emit(id, sess) end
end)

-- auto-promote: new session → active
client.on_session_added:subscribe(function(id)
    _set_active(id)
end)

-- auto-promote: a session stopped → bring it into focus
client.on_session_stopped:subscribe(function(id)
    _set_active(id)
end)

-- auto-reassign: active session removed → pick any remaining, or nil
client.on_session_removed:subscribe(function(id)
    if _active_id ~= id then return end
    local new_id
    for k in pairs(client.sessions()) do new_id = k; break end
    _set_active(new_id)
end)

---@return easydap.dap.Session?
function M.session()
    return _active_id and client.get_session(_active_id) or nil
end

---Return the active session's adapter-verified status for a breakpoint, or nil if no session.
---@param bp_id integer  internal stable id (bp.internal_id)
---@return easydap.dap.BpStatus?
function M.bp_status(bp_id)
    local sess = M.session()
    return sess and sess:bp_status(bp_id)
end

---@return number?
function M.active_id()
    return _active_id
end

---Manually promote a session to the active slot.
---@param id number
function M.select_session(id)
    if client.get_session(id) then _set_active(id) end
end

-- ── Stepping (delegate to client with active id) ───────────────────────────

---Granularity used for subsequent steps. Derived from the focused buffer:
---instruction while the disassembly pane is current, line everywhere else.
---@return easydap.dap.proto.SteppingGranularity
function M.granularity()
    if vim.b.easydap_disasm then return "instruction" end
    return "line"
end

---Run `fn(sess)` on the active session, but only if it advertises `capability`.
---Shows an error when the adapter lacks the capability, a warning when there is
---no active session. Use for any user command gated on a DAP capability.
---@param capability string  e.g. "supportsRestartFrame"
---@param label      string  human-readable command name for the error message
---@param fn         fun(sess: easydap.dap.Session, id: number)
local function _with_capability(capability, label, fn)
    local id = _active_id
    if not id then return end
    local sess = M.session()
    if not sess then vim.notify("[dap] no active session", vim.log.levels.WARN); return end
    if not sess:capable(capability) then
        vim.notify("[dap] adapter does not support " .. label, vim.log.levels.ERROR)
        return
    end
    fn(sess, id)
end

function M.continue()     if _active_id then client.continue(_active_id) end end
function M.next()         if _active_id then client.next(_active_id, M.granularity()) end end
function M.step_in()      if _active_id then client.step_in(_active_id, M.granularity()) end end
function M.step_out()     if _active_id then client.step_out(_active_id, M.granularity()) end end
function M.step_back()
    _with_capability("supportsStepBack", "step back", function(_, id)
        client.step_back(id, M.granularity())
    end)
end
function M.reverse_continue()
    _with_capability("supportsStepBack", "reverse continue", function(_, id)
        client.reverse_continue(id)
    end)
end
function M.pause()        if _active_id then client.pause(_active_id) end end
function M.restart()
    _with_capability("supportsRestartRequest", "restart", function(_, id)
        client.restart(id)
    end)
end

---@param cb fun()?
function M.stop(cb)       if _active_id then client.stop(_active_id, cb) end end
---@param cb fun()?
function M.disconnect(cb) if _active_id then client.disconnect(_active_id, cb) end end

---@param thread_id integer
function M.select_thread(thread_id)
    if _active_id then client.select_thread(_active_id, thread_id) end
end

---@param frame_id integer
function M.select_frame(frame_id)
    if _active_id then client.select_frame(_active_id, frame_id) end
end

---@param text   string
---@param column integer
---@param cb     fun(targets: table[])
function M.complete(text, column, cb)
    if not _active_id then cb({}); return end
    client.complete(_active_id, text, column, cb)
end

---@param expr    string
---@param context string
---@param cb      fun(body: table?, err: string?)
function M.evaluate(expr, context, cb)
    if not _active_id then cb(nil, "no active session"); return end
    client.evaluate(_active_id, expr, context, cb)
end

-- ── Helpers ───────────────────────────────────────────────────────────────

---@return string?
---@return integer
local function _cursor_location()
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].buftype ~= "" then
        vim.notify("[dap] current buffer is not a regular buffer", vim.log.levels.WARN)
        return nil, 0
    end
    local file  = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then
        vim.notify("[dap] current buffer has no file path", vim.log.levels.WARN)
        return nil, 0
    end
    return file, vim.api.nvim_win_get_cursor(0)[1]
end

local function _sync_bp(file)
    local sess = M.session()
    if sess then sess:sync_breakpoints(file) end
end

-- ── Breakpoints ───────────────────────────────────────────────────────────

M.breakpoint = {}

---Find an existing source breakpoint in `file` whose currently displayed line
---(the adapter-resolved line if the session moved it, else the stored line) is
---`row`. Returns its stored line, which is the registry key to operate on.
---A breakpoint the adapter relocated elsewhere has no sign at its stored line
---anymore, so it does not match there — toggling acts on what is actually shown.
---@param file string
---@param row  integer
---@return integer?
local function _existing_bp_line(file, row)
    local bps = require("easydap.dap.breakpoints")
    for _, bp in ipairs(bps.for_source(file)) do
        -- Column breakpoints are managed by their own command, not the line toggle.
        if bp.column == nil then
            local st    = M.bp_status(bp.internal_id)
            local shown = (st and st.line) or bp.line
            if shown == row then return bp.line end
        end
    end
end

---Find a breakpoint stored at `row` that the adapter has relocated elsewhere.
---Returns the line it is now shown at, or nil.
---@param file string
---@param row  integer
---@return integer?
local function _moved_bp_target(file, row)
    local bps = require("easydap.dap.breakpoints")
    for _, bp in ipairs(bps.for_source(file)) do
        if bp.column == nil and bp.line == row then
            local st = M.bp_status(bp.internal_id)
            if st and st.line and st.line ~= bp.line then return st.line end
        end
    end
end

function M.breakpoint.toggle()
    local file, row = _cursor_location()
    if not file then return end
    local bps = require("easydap.dap.breakpoints")
    -- Toggling off matches the line you see, which may be the adapter-resolved
    -- line rather than the stored one.
    local existing = _existing_bp_line(file, row)
    if existing then
        bps.remove(file, existing)
    else
        -- This line is the stored origin of a breakpoint the adapter relocated
        -- elsewhere; adding here would just be relocated to the same spot, so
        -- jump to where it is actually shown instead of toggling.
        local moved_to = _moved_bp_target(file, row)
        if moved_to then
            local col = vim.api.nvim_win_get_cursor(0)[2]
            vim.api.nvim_win_set_cursor(0, { moved_to, col })
            return
        end
        bps.add(file, row)
    end
    _sync_bp(file)
end

---Snap a 1-based column to the start of the word under it.
---Returns col unchanged if the character is not a word character.
---@param line string
---@param col  integer  1-based
---@return integer
local function _word_start(line, col)
    if not line:sub(col, col):match("[%w_]") then return col end
    local i = col
    while i > 1 and line:sub(i - 1, i - 1):match("[%w_]") do
        i = i - 1
    end
    return i
end

---Add or remove a column breakpoint at (file, row, column).
---@param file   string
---@param row    integer
---@param column integer
local function _toggle_column_bp(file, row, column)
    local bps    = require("easydap.dap.breakpoints")
    local exists = false
    for _, bp in ipairs(bps.for_source(file)) do
        if bp.line == row and bp.column == column then exists = true; break end
    end
    if exists then
        bps.remove(file, row, column)
    else
        bps.add(file, row, { column = column })
    end
    _sync_bp(file)
end

---Set a column breakpoint on the current line. With a running session that
---supports breakpointLocations, prompts to pick among the valid column
---positions on the line; otherwise sets one at the cursor column.
function M.breakpoint.column()
    local file, row = _cursor_location()
    if not file then return end
    local bufnr      = vim.api.nvim_get_current_buf()
    local cursor_col = vim.api.nvim_win_get_cursor(0)[2] + 1
    local linetext   = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    local col        = _word_start(linetext, cursor_col)
    local sess       = M.session()

    -- If a column bp already exists at this position, clear it directly so
    -- existing bps can always be removed even when a session is active.
    local bps_mod = require("easydap.dap.breakpoints")
    for _, bp in ipairs(bps_mod.for_source(file)) do
        if bp.line == row and bp.column == col then
            _toggle_column_bp(file, row, col)
            return
        end
    end

    if not (sess and sess:capable("supportsBreakpointLocationsRequest")) then
        _toggle_column_bp(file, row, col)
        return
    end
    ---@type easydap.dap.proto.Source
    local source = { path = file, name = vim.fn.fnamemodify(file, ":t") }
    sess:breakpoint_locations(source, row, nil, function(locations, _)
        local cols, seen = {}, {}
        for _, loc in ipairs(locations or {}) do
            local c = loc.column
            if c and (loc.line == nil or loc.line == row) and not seen[c] then
                seen[c] = true
                cols[#cols + 1] = c
            end
        end
        if #cols == 0 then _toggle_column_bp(file, row, cursor_col); return end
        local nearest = cols[1]
        for _, c in ipairs(cols) do
            if math.abs(c - cursor_col) < math.abs(nearest - cursor_col) then
                nearest = c
            end
        end
        _toggle_column_bp(file, row, nearest)
    end)
end

---@param condition? string
function M.breakpoint.add(condition)
    local file, row = _cursor_location()
    if not file then return end
    local bps = require("easydap.dap.breakpoints")
    bps.add(file, row, { condition = condition })
    _sync_bp(file)
end

function M.breakpoint.remove()
    local file, row = _cursor_location()
    if not file then return end
    local bps = require("easydap.dap.breakpoints")
    -- Remove the breakpoint shown at the cursor (resolved or stored line).
    local existing = _existing_bp_line(file, row)
    if existing then
        bps.remove(file, existing)
        _sync_bp(file)
    end
end

function M.breakpoint.clear_file()
    local file, _ = _cursor_location()
    if not file then return end
    local bps = require("easydap.dap.breakpoints")
    for _, bp in ipairs(bps.for_source(file)) do bps.remove(file, bp.line, bp.column) end
    _sync_bp(file)
end

function M.breakpoint.clear_all()
    local bps  = require("easydap.dap.breakpoints")
    local file = vim.api.nvim_buf_get_name(vim.api.nvim_get_current_buf())
    for _, bp in ipairs(bps.for_source(file)) do bps.remove(file, bp.line, bp.column) end
    for _, bp in ipairs(bps.function_breakpoints()) do bps.remove_function(bp.name) end
    _sync_bp(file)
end

function M.breakpoint.clear_fn()
    local bps  = require("easydap.dap.breakpoints")
    local sess = M.session()
    for _, bp in ipairs(bps.function_breakpoints()) do bps.remove_function(bp.name) end
    if sess then sess:sync_function_breakpoints() end
end

function M.breakpoint.enable()
    local file, row = _cursor_location()
    if not file then return end
    local bps   = require("easydap.dap.breakpoints")
    local found = false
    for _, bp in ipairs(bps.for_source(file)) do
        if bp.line == row then found = true; break end
    end
    if not found then vim.notify("[dap] no breakpoint at current line", vim.log.levels.WARN); return end
    bps.patch(file, row, { disabled = false })
    _sync_bp(file)
end

function M.breakpoint.disable()
    local file, row = _cursor_location()
    if not file then return end
    local bps   = require("easydap.dap.breakpoints")
    local found = false
    for _, bp in ipairs(bps.for_source(file)) do
        if bp.line == row then found = true; break end
    end
    if not found then vim.notify("[dap] no breakpoint at current line", vim.log.levels.WARN); return end
    bps.patch(file, row, { disabled = true })
    _sync_bp(file)
end

function M.breakpoint.enable_all()
    local bps  = require("easydap.dap.breakpoints")
    local sess = M.session()
    bps.enable_all()
    if sess then sess:sync_breakpoints() end
end

function M.breakpoint.disable_all()
    local bps  = require("easydap.dap.breakpoints")
    local sess = M.session()
    bps.disable_all()
    if sess then sess:sync_breakpoints() end
end

function M.breakpoint.condition()
    local file, row = _cursor_location()
    if not file then return end
    local bps = require("easydap.dap.breakpoints")
    local bp
    for _, b in ipairs(bps.for_source(file)) do if b.line == row then bp = b; break end end
    inputwin.open({ prompt = "Condition (empty to clear): ", default = bp and bp.condition or "" },
        function(cond)
            if cond == nil then return end
            inputwin.open({ prompt = "Hit condition (empty to clear): ", default = bp and bp.hit_condition or "" },
                function(hit)
                    if hit == nil then return end
                    bps.patch(file, row, { condition = cond, hit_condition = hit })
                    _sync_bp(file)
                end)
        end)
end

function M.breakpoint.logpoint()
    local file, row = _cursor_location()
    if not file then return end
    local bps = require("easydap.dap.breakpoints")
    local bp
    for _, b in ipairs(bps.for_source(file)) do if b.line == row then bp = b; break end end
    inputwin.open({ prompt = "Log message (empty to clear): ", default = bp and bp.log_message or "" },
        function(input)
            if input == nil then return end
            bps.patch(file, row, { log_message = input })
            _sync_bp(file)
        end)
end

---@param name? string
function M.breakpoint.fn(name)
    local bps = require("easydap.dap.breakpoints")
    local function _toggle(n)
        local found = false
        for _, bp in ipairs(bps.function_breakpoints()) do if bp.name == n then found = true; break end end
        if found then bps.remove_function(n) else bps.add_function(n) end
        local sess = M.session()
        if sess then sess:sync_function_breakpoints() end
    end
    if name and name ~= "" then
        _toggle(name)
    else
        vim.ui.input({ prompt = "Function name: " }, function(input)
            if input and input ~= "" then _toggle(input) end
        end)
    end
end

function M.breakpoint.exception_filter()
    local bps = require("easydap.dap.breakpoints")
    local all = bps.exception_breakpoints()
    if #all == 0 then
        vim.notify("[dap] no exception filters available (start a session first)", vim.log.levels.WARN)
        return
    end
    select(all, {
        prompt      = "Toggle exception breakpoint",
        format_item = function(bp) return (bp.disabled and "○ " or "● ") .. bp.label end,
    }, function(bp)
        if not bp then return end
        bps.set_exception_enabled(bp.filter, bp.disabled)
        local sess = M.session()
        if sess then sess:sync_exception_breakpoints() end
    end)
end

---@param name?       string
---@param break_mode? string
function M.breakpoint.exception_type(name, break_mode)
    local bps    = require("easydap.dap.breakpoints")
    local _modes = { "always", "unhandled", "userUnhandled", "never" }
    local function _toggle(n, mode)
        local result = bps.toggle_exception_name(n, mode)
        vim.notify(
            result
                and ("[dap] exception breakpoint added: " .. n .. " (" .. result.break_mode .. ")")
                or  ("[dap] exception breakpoint removed: " .. n),
            vim.log.levels.INFO)
        local sess = M.session()
        if sess then sess:sync_exception_breakpoints() end
    end
    local function _pick_mode(n)
        select(_modes, { prompt = "Break mode for " .. n .. ": " }, function(mode)
            if mode then _toggle(n, mode) end
        end)
    end
    if name and name ~= "" then
        local existing
        for _, bp in ipairs(bps.exception_name_breakpoints()) do
            if bp.name == name then existing = bp; break end
        end
        if existing then
            _toggle(name)
        elseif break_mode and break_mode ~= "" then
            _toggle(name, break_mode)
        else
            _pick_mode(name)
        end
    else
        vim.ui.input({ prompt = "Exception type: " }, function(input)
            if not input or input == "" then return end
            _pick_mode(input)
        end)
    end
end

function M.breakpoint.list()
    local bps   = require("easydap.dap.breakpoints")
    local items = vim.tbl_map(function(bp)
        ---@cast bp easydap.dap.SourceBreakpoint
        return { bp = bp, preview = { filepath = bp.source, lnum = bp.line } }
    end, bps.all())
    if #items == 0 then vim.notify("[dap] no breakpoints", vim.log.levels.INFO); return end
    select(items, {
        prompt      = "Go to breakpoint",
        format_item = function(item)
            local bp   = item.bp
            local icon = bp.disabled and "○"
                or bp.log_message and "◆"
                or (bp.condition or bp.hit_condition) and "■"
                or "●"
            local label = icon .. " " .. vim.fn.fnamemodify(bp.source, ":~:.") .. ":" .. bp.line
            if bp.column then label = label .. ":" .. bp.column end
            if bp.condition     then label = label .. "  [" .. bp.condition .. "]" end
            if bp.hit_condition then label = label .. "  [hits:" .. bp.hit_condition .. "]" end
            if bp.log_message   then label = label .. "  [log: " .. bp.log_message .. "]" end
            return label
        end,
    }, function(item)
        if not item then return end
        require("easydap.util.ui_util").smart_open_file(item.bp.source, item.bp.line)
    end)
end

-- ── Data breakpoints (watchpoints) ─────────────────────────────────────────

---Resolve `name` against the active session and either add a data breakpoint
---(prompting for an access type when several are offered) or, if one already
---exists for the resolved dataId, remove it.
---@param sess easydap.dap.Session
---@param name string
---@param variables_reference integer?
local function _toggle_data_bp(sess, name, variables_reference)
    sess:data_breakpoint_info(name, variables_reference, function(body, err)
        if err or not body or not body.dataId then
            local why = err or (body and body.description) or "not available"
            vim.notify("[dap] cannot watch '" .. name .. "': " .. why, vim.log.levels.WARN)
            return
        end
        for _, bp in ipairs(sess:data_breakpoints()) do
            if bp.data_id == body.dataId then
                sess:remove_data_breakpoint(body.dataId)
                vim.notify("[dap] data breakpoint removed: " .. name, vim.log.levels.INFO)
                return
            end
        end
        local function add(access)
            sess:add_data_breakpoint({ data_id = body.dataId, name = name, access_type = access })
            vim.notify("[dap] data breakpoint set: " .. name
                .. (access and (" (" .. access .. ")") or ""), vim.log.levels.INFO)
        end
        local types = body.accessTypes or {}
        if #types > 1 then
            select(types, { prompt = "Access type for " .. name .. ": " }, function(t)
                if t then add(t) end
            end)
        else
            add(types[1])
        end
    end)
end

---Set or toggle a data breakpoint (watchpoint) on a variable or expression.
---Requires a stopped session whose adapter advertises supportsDataBreakpoints.
---@param name? string  defaults to the word under the cursor (prompted)
function M.breakpoint.data(name)
    local sess = M.session()
    if not sess then vim.notify("[dap] no active session", vim.log.levels.WARN); return end
    if not sess:capable("supportsDataBreakpoints") then
        vim.notify("[dap] adapter does not support data breakpoints", vim.log.levels.WARN)
        return
    end
    if name and name ~= "" then
        _toggle_data_bp(sess, name)
    else
        vim.ui.input({ prompt = "Watch (data breakpoint): ", default = vim.fn.expand("<cword>") },
            function(input)
                if input and input ~= "" then _toggle_data_bp(sess, input) end
            end)
    end
end

---Remove all data breakpoints on the active session.
function M.breakpoint.data_clear()
    local sess = M.session()
    if not sess then vim.notify("[dap] no active session", vim.log.levels.WARN); return end
    sess:clear_data_breakpoints()
end

---List data breakpoints on the active session; selecting one removes it.
function M.breakpoint.data_list()
    local sess = M.session()
    if not sess then vim.notify("[dap] no active session", vim.log.levels.WARN); return end
    local bps = sess:data_breakpoints()
    if #bps == 0 then vim.notify("[dap] no data breakpoints", vim.log.levels.INFO); return end
    select(bps, {
        prompt      = "Remove data breakpoint",
        format_item = function(bp)
            local icon = bp.verified == false and "◌" or "◉"
            local at   = bp.access_type and ("  [" .. bp.access_type .. "]") or ""
            return icon .. " " .. bp.name .. at
        end,
    }, function(bp)
        if bp then sess:remove_data_breakpoint(bp.data_id) end
    end)
end

-- ── Debug controls ────────────────────────────────────────────────────────

M.debug = {}

function M.debug.continue()      M.continue()           end
function M.debug.continue_all()  client.continue_all()  end
function M.debug.step_over()     M.next()               end
function M.debug.step_in()       M.step_in()            end
function M.debug.step_out()      M.step_out()           end
function M.debug.step_back()     M.step_back()          end
function M.debug.reverse_continue() M.reverse_continue() end
function M.debug.pause()         M.pause()              end
function M.debug.restart()       M.restart()            end
function M.debug.stop()          M.stop()               end
function M.debug.terminate_all() client.quit()          end

---Step into a specific call on the current line. Prompts when the line has
---multiple call targets; falls back to a plain step-in when unsupported or
---there is only one target.
function M.debug.step_into_targets()
    if not _active_id then return end
    local sess = M.session()
    if not sess then vim.notify("[dap] no active session", vim.log.levels.WARN); return end
    local frame = sess:current_stack_frame()
    if not frame then vim.notify("[dap] no selected frame", vim.log.levels.WARN); return end
    client.step_in_targets(_active_id, frame.id, function(targets, _)
        if not targets or #targets == 0 then M.step_in(); return end
        if #targets == 1 then
            client.step_in(_active_id, M.granularity(), targets[1].id)
            return
        end
        select(targets, {
            prompt      = "Step into",
            format_item = function(t) return t.label end,
        }, function(t)
            if t then client.step_in(_active_id, M.granularity(), t.id) end
        end)
    end)
end

---Jump-to-cursor: set the next statement to execute to the line under the
---cursor in the current buffer. Prompts when the line has multiple targets.
function M.debug.jump_to_cursor()
    _with_capability("supportsGotoTargetsRequest", "jump to cursor", function(_, id)
        local path = vim.api.nvim_buf_get_name(0)
        if path == "" then vim.notify("[dap] current buffer has no file", vim.log.levels.WARN); return end
        local line = vim.api.nvim_win_get_cursor(0)[1]
        ---@type easydap.dap.proto.Source
        local source = { path = path, name = vim.fn.fnamemodify(path, ":t") }
        client.goto_targets(id, source, line, function(targets, err)
            if not targets or #targets == 0 then
                vim.notify("[dap] no jump target at this line" .. (err and (": " .. err) or ""),
                    vim.log.levels.WARN)
                return
            end
            if #targets == 1 then
                client.set_next_statement(id, targets[1].id)
                return
            end
            select(targets, {
                prompt      = "Jump to",
                format_item = function(t) return t.label .. (t.line and ("  :" .. t.line) or "") end,
            }, function(t)
                if t then client.set_next_statement(id, t.id) end
            end)
        end)
    end)
end

---Restart execution of the currently selected stack frame.
function M.debug.restart_frame()
    _with_capability("supportsRestartFrame", "restart frame", function(sess, id)
        local frame = sess:current_stack_frame()
        if not frame then vim.notify("[dap] no selected frame", vim.log.levels.WARN); return end
        client.restart_frame(id, frame.id)
    end)
end

---Show detailed information about the exception at the current stop in a float.
function M.debug.exception_info()
    _with_capability("supportsExceptionInfoRequest", "exception info", function(_, id)
        client.exception_info(id, function(body, err)
            if not body then
                vim.notify("[dap] " .. (err or "no exception info available"), vim.log.levels.WARN)
                return
            end
            local lines = { body.exceptionId or "Exception" }
            local function append(text)
                for _, l in ipairs(vim.split(text, "\n", { plain = true })) do
                    lines[#lines + 1] = l
                end
            end
            if body.description and body.description ~= "" then
                lines[#lines + 1] = ""
                append(body.description)
            end
            local d = body.details
            if d then
                if d.typeName and d.typeName ~= "" then
                    lines[#lines + 1] = ""
                    lines[#lines + 1] = "Type: " .. d.typeName
                end
                if d.message and d.message ~= "" and d.message ~= body.description then
                    append(d.message)
                end
                if d.stackTrace and d.stackTrace ~= "" then
                    lines[#lines + 1] = ""
                    lines[#lines + 1] = "Stack trace:"
                    append(d.stackTrace)
                end
            end
            vim.lsp.util.open_floating_preview(lines, "plaintext", {
                border   = "rounded",
                title    = "Exception",
                focus_id = "easydap_exception",
            })
        end)
    end)
end

---@param expr? string  defaults to word under cursor
function M.debug.inspect(expr)
    expr = expr or vim.fn.expand("<cword>")
    if not expr or expr == "" then
        vim.notify("[dap] no word under cursor", vim.log.levels.WARN)
        return
    end
    M.evaluate(expr, "hover", function(body, err)
        if err or not body then
            vim.notify("[dap] " .. expr .. ": " .. (err or "not available"), vim.log.levels.WARN)
            return
        end
        local lines = {}
        if body.type and body.type ~= "" then
            lines[#lines + 1] = body.type
            lines[#lines + 1] = ""
        end
        for _, line in ipairs(vim.split(body.result or "", "\n", { plain = true })) do
            lines[#lines + 1] = line
        end
        vim.lsp.util.open_floating_preview(lines, "plaintext", {
            border = "rounded",
            title  = expr,
            focus_id = "easydap_inspect",
        })
    end)
end

---Open the disassembly pane for the active session's current frame.
function M.debug.disassemble() require("easydap").open_disassembly_view() end

function M.debug.session()
    local sessions = client.sessions()
    local ids      = vim.tbl_keys(sessions)
    if #ids == 0 then vim.notify("[dap] no active sessions", vim.log.levels.WARN); return end
    table.sort(ids)
    local active = _active_id
    select(ids, {
        prompt      = "Select session",
        format_item = function(id)
            local s     = sessions[id]
            local label = (s.config.adapter or "session") .. "  [" .. s.state .. "]"
            if id == active then label = label .. "  *" end
            return label
        end,
    }, function(id)
        if id then M.select_session(id) end
    end)
end

function M.debug.thread()
    local sess = M.session()
    if not sess then vim.notify("[dap] no active session", vim.log.levels.WARN); return end
    local threads = sess.threads
    if #threads == 0 then vim.notify("[dap] no threads available", vim.log.levels.WARN); return end
    select(threads, {
        prompt      = "Select thread",
        format_item = function(t) return t.id .. ": " .. t.name .. "  [" .. t.status .. "]" end,
    }, function(t)
        if t then M.select_thread(t.id) end
    end)
end

---Prompt for a thread and terminate it (requires supportsTerminateThreadsRequest).
function M.debug.terminate_thread()
    _with_capability("supportsTerminateThreadsRequest", "terminate thread", function(sess, id)
        local threads = sess.threads
        if #threads == 0 then vim.notify("[dap] no threads available", vim.log.levels.WARN); return end
        select(threads, {
            prompt      = "Terminate thread",
            format_item = function(t) return t.id .. ": " .. t.name .. "  [" .. t.status .. "]" end,
        }, function(t)
            if t then client.terminate_threads(id, { t.id }) end
        end)
    end)
end

function M.debug.frame()
    local sess = M.session()
    if not sess then vim.notify("[dap] no active session", vim.log.levels.WARN); return end
    local thread = sess:current_thread()
    if not thread then vim.notify("[dap] no selected thread", vim.log.levels.WARN); return end
    local frames = thread.stack_frames or {}
    if #frames == 0 then vim.notify("[dap] no stack frames available", vim.log.levels.WARN); return end
    local cur_frame = sess:current_stack_frame()
    local items = vim.tbl_map(function(f)
        return {
            frame   = f,
            preview = f.source and f.source.path
                and { filepath = f.source.path, lnum = f.line } or nil,
        }
    end, frames)
    select(items, {
        prompt      = "Select frame",
        format_item = function(item)
            local f      = item.frame
            local loc    = f.source and f.source.path
                and ("  " .. vim.fn.fnamemodify(f.source.path, ":~:.") .. ":" .. (f.line or "?"))
                or  ""
            local marker = (cur_frame and f.id == cur_frame.id) and "  *" or ""
            return f.name .. loc .. marker
        end,
    }, function(item)
        if item then M.select_frame(item.frame.id) end
    end)
end

-- ── Panel ─────────────────────────────────────────────────────────────────

M.panel = {}

function M.panel.toggle()
    require("easydap").open_debug_view()
end

return M
