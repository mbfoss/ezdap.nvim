---@brief User-facing command surface: the `breakpoint`, `debug` and `view`
---command tables reached through `:Debug …`. These sit on top of `manager`
---(active session + control primitives) and own all the command-level UI —
---pickers, prompts, notifications and cursor handling.

local select   = require("ezdap.util.select")
local inputwin = require("ezdap.tk.inputwin")
local manager  = require("ezdap.manager")

local M        = {}

-- Everything reaching the DAP layer goes through `manager` (the programmatic API);
-- this module owns only the user interaction — cursor reads, prompts, pickers and
-- notifications — resolving those into the concrete details `manager` takes.

-- Helpers

---@return string?
---@return integer
local function _cursor_location()
    local bufnr = vim.api.nvim_get_current_buf()
    if vim.bo[bufnr].buftype ~= "" then
        vim.notify("[dap] current buffer is not a regular buffer", vim.log.levels.WARN)
        return nil, 0
    end
    local file = vim.api.nvim_buf_get_name(bufnr)
    if file == "" then
        vim.notify("[dap] current buffer has no file path", vim.log.levels.WARN)
        return nil, 0
    end
    return file, vim.api.nvim_win_get_cursor(0)[1]
end

---Run `fn(sess)` on the active session, but only if it advertises `capability`.
---Shows an error when the adapter lacks the capability, a warning when there is
---no active session. Use for any command gated on a DAP capability.
---@param capability string  e.g. "supportsRestartFrame"
---@param label      string  human-readable command name for the error message
---@param fn         fun(sess: ezdap.dap.Session)
local function _with_capability(capability, label, fn)
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    if not sess:capable(capability) then
        vim.notify("[dap] adapter does not support " .. label, vim.log.levels.ERROR)
        return
    end
    fn(sess)
end

-- Live sessions now push breakpoint changes themselves by subscribing to
-- breakpoints.on_change (see session.lua), so the commands below only mutate the
-- registry — no explicit per-command sync is needed.

---Cursor-follow records, keyed by breakpoint internal_id. Armed when the user adds
---a source breakpoint while a session is live; consumed one-shot once the adapter
---reports where it bound it, and only while the user is still parked there.
---@class ezdap.command.PendingFollow
---@field win  integer  window the breakpoint was added from
---@field file string   source file that window must still show
---@field line integer  line it was added at; the cursor must still sit here
---@type table<integer, ezdap.command.PendingFollow>
local _pending_follow = {}

-- A follow is keyed to the active session's binding; once the active session
-- changes any armed follow is stale, so drop them all rather than risk acting on
-- the wrong session's resolved line.
manager.on_active_changed:subscribe(function() _pending_follow = {} end)

-- Breakpoints

M.breakpoint = {}

---Find an existing source breakpoint in `file` whose displayed line (adapter-resolved
---if the session moved it, else stored) is `row`, returning its stored line — the
---registry key. A relocated breakpoint has no sign there, so toggling acts on what shows.
---@param file string
---@param row  integer
---@return integer?
local function _existing_bp_line(file, row)
    local bps = manager.breakpoints
    for _, bp in ipairs(bps.for_source(file)) do
        -- Column breakpoints are managed by their own command, not the line toggle.
        if bp.column == nil then
            local st    = manager.bp_status(bp.internal_id)
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
    local bps = manager.breakpoints
    for _, bp in ipairs(bps.for_source(file)) do
        if bp.column == nil and bp.line == row then
            local st = manager.bp_status(bp.internal_id)
            if st and st.line and st.line ~= bp.line then return st.line end
        end
    end
end

function M.breakpoint.toggle()
    local file, row = _cursor_location()
    if not file then return end
    local bps = manager.breakpoints
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
        -- The registry change pushes to the adapter on its own; arm the follow so
        -- the cursor tracks the breakpoint if the adapter relocates it.
        local bp = bps.add(file, row)
        if bp and manager.session() then
            _pending_follow[bp.internal_id] = {
                win  = vim.api.nvim_get_current_win(),
                file = file,
                line = row,
            }
        end
    end
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
    local bps    = manager.breakpoints
    local exists = false
    for _, bp in ipairs(bps.for_source(file)) do
        if bp.line == row and bp.column == column then
            exists = true; break
        end
    end
    if exists then
        bps.remove(file, row, column)
    else
        bps.add(file, row, { column = column })
    end
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
    local sess       = manager.session()

    -- If a column bp already exists at this position, clear it directly so
    -- existing bps can always be removed even when a session is active.
    local bps_mod    = manager.breakpoints
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
    ---@type ezdap.dap.proto.Source
    local source = { path = file, name = vim.fn.fnamemodify(file, ":t") }
    sess:breakpoint_locations({ source = source, line = row }, function(locations, _)
        local cols, seen = {}, {}
        for _, loc in ipairs(locations or {}) do
            local c = loc.column
            if c and (loc.line == nil or loc.line == row) and not seen[c] then
                seen[c] = true
                cols[#cols + 1] = c
            end
        end
        if #cols == 0 then
            _toggle_column_bp(file, row, cursor_col); return
        end
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
    local bps = manager.breakpoints
    bps.add(file, row, { condition = condition })
end

function M.breakpoint.remove()
    local file, row = _cursor_location()
    if not file then return end
    local bps = manager.breakpoints
    -- Remove the breakpoint shown at the cursor (resolved or stored line).
    local existing = _existing_bp_line(file, row)
    if existing then
        bps.remove(file, existing)
    end
end

function M.breakpoint.clear_file()
    local file, _ = _cursor_location()
    if not file then return end
    local bps = manager.breakpoints
    for _, bp in ipairs(bps.for_source(file)) do bps.remove(file, bp.line, bp.column) end
end

---Removes every source, function and exception-name breakpoint. Exception
---filters are adapter-supplied rows, so they are disabled rather than removed.
function M.breakpoint.clear_all()
    local bps = manager.breakpoints
    for _, bp in ipairs(bps.all()) do bps.remove(bp.source, bp.line, bp.column) end
    for _, bp in ipairs(bps.function_breakpoints()) do bps.remove_function(bp.name) end
    for _, bp in ipairs(bps.exception_name_breakpoints()) do bps.remove_exception_name(bp.name) end
    for _, bp in ipairs(bps.exception_breakpoints()) do bps.set_exception_enabled(bp.filter, false) end
end

function M.breakpoint.clear_fn()
    local bps = manager.breakpoints
    for _, bp in ipairs(bps.function_breakpoints()) do bps.remove_function(bp.name) end
end

function M.breakpoint.enable()
    local file, row = _cursor_location()
    if not file then return end
    local bps   = manager.breakpoints
    local found = false
    for _, bp in ipairs(bps.for_source(file)) do
        if bp.line == row then
            found = true; break
        end
    end
    if not found then
        vim.notify("[dap] no breakpoint at current line", vim.log.levels.WARN); return
    end
    bps.patch(file, row, { disabled = false })
end

function M.breakpoint.disable()
    local file, row = _cursor_location()
    if not file then return end
    local bps   = manager.breakpoints
    local found = false
    for _, bp in ipairs(bps.for_source(file)) do
        if bp.line == row then
            found = true; break
        end
    end
    if not found then
        vim.notify("[dap] no breakpoint at current line", vim.log.levels.WARN); return
    end
    bps.patch(file, row, { disabled = true })
end

---Toggle the enabled/disabled state of the breakpoint at the current line.
function M.breakpoint.toggle_enabled()
    local file, row = _cursor_location()
    if not file then return end
    local bps = manager.breakpoints
    local bp
    for _, b in ipairs(bps.for_source(file)) do
        if b.line == row then
            bp = b; break
        end
    end
    if not bp then
        vim.notify("[dap] no breakpoint at current line", vim.log.levels.WARN); return
    end
    bps.patch(file, row, { disabled = not bp.disabled })
end

function M.breakpoint.enable_all()
    manager.breakpoints.enable_all()
end

function M.breakpoint.disable_all()
    manager.breakpoints.disable_all()
end

function M.breakpoint.condition()
    local file, row = _cursor_location()
    if not file then return end
    local bps = manager.breakpoints
    local bp
    for _, b in ipairs(bps.for_source(file)) do
        if b.line == row then
            bp = b; break
        end
    end
    inputwin.open({ prompt = "Condition (empty to clear): ", default = bp and bp.condition or "" },
        function(cond)
            if cond == nil then return end
            inputwin.open({ prompt = "Hit condition (empty to clear): ", default = bp and bp.hit_condition or "" },
                function(hit)
                    if hit == nil then return end
                    bps.patch(file, row, { condition = cond, hit_condition = hit })
                end)
        end)
end

function M.breakpoint.logpoint()
    local file, row = _cursor_location()
    if not file then return end
    local bps = manager.breakpoints
    local bp
    for _, b in ipairs(bps.for_source(file)) do
        if b.line == row then
            bp = b; break
        end
    end
    inputwin.open({ prompt = "Log message (empty to clear): ", default = bp and bp.log_message or "" },
        function(input)
            if input == nil then return end
            bps.patch(file, row, { log_message = input })
        end)
end

---@param name? string
function M.breakpoint.fn(name)
    local bps = manager.breakpoints
    local function _toggle(n)
        local found = false
        for _, bp in ipairs(bps.function_breakpoints()) do
            if bp.name == n then
                found = true; break
            end
        end
        if found then bps.remove_function(n) else bps.add_function(n) end
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
    local bps = manager.breakpoints
    local all = bps.exception_breakpoints()
    if #all == 0 then
        vim.notify("[dap] no exception filters available (start a session first)", vim.log.levels.WARN)
        return
    end
    select.open({
        prompt = "Toggle exception breakpoint",
        items  = vim.tbl_map(function(bp)
            return { label = (bp.disabled and "○ " or "● ") .. bp.label, data = bp }
        end, all),
    }, function(bp)
        if not bp then return end
        bps.set_exception_enabled(bp.filter, bp.disabled)
    end)
end

---@param name?       string
---@param break_mode? string
function M.breakpoint.exception_type(name, break_mode)
    local bps    = manager.breakpoints
    local _modes = { "always", "unhandled", "userUnhandled", "never" }
    local function _toggle(n, mode)
        local result = bps.toggle_exception_name(n, mode)
        vim.notify(
            result
            and ("[dap] exception breakpoint added: " .. n .. " (" .. result.break_mode .. ")")
            or ("[dap] exception breakpoint removed: " .. n),
            vim.log.levels.INFO)
    end
    local function _pick_mode(n)
        select.open({ prompt = "Break mode for " .. n .. ": ", items = _modes }, function(mode)
            if mode then _toggle(n, mode) end
        end)
    end
    if name and name ~= "" then
        local existing
        for _, bp in ipairs(bps.exception_name_breakpoints()) do
            if bp.name == name then
                existing = bp; break
            end
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
    local bps      = manager.breakpoints
    local cur_path = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":p")
    local cur_line = vim.api.nvim_win_get_cursor(0)[1]
    local initial ---@type integer?
    local items    = {}
    for i, bp in ipairs(bps.all()) do
        ---@cast bp ezdap.dap.SourceBreakpoint
        local icon = bp.disabled and "○"
            or bp.log_message and "◆"
            or (bp.condition or bp.hit_condition) and "■"
            or "●"
        local label = icon .. " " .. vim.fn.fnamemodify(bp.source, ":~:.") .. ":" .. bp.line
        if bp.column then label = label .. ":" .. bp.column end
        if bp.condition then label = label .. "  [" .. bp.condition .. "]" end
        if bp.hit_condition then label = label .. "  [hits:" .. bp.hit_condition .. "]" end
        if bp.log_message then label = label .. "  [log: " .. bp.log_message .. "]" end
        if not initial and bp.line == cur_line and vim.fn.fnamemodify(bp.source, ":p") == cur_path then
            initial = i
        end
        items[i] = { label = label, data = { filepath = bp.source, lnum = bp.line, bp = bp } }
    end
    if #items == 0 then
        vim.notify("[dap] no breakpoints", vim.log.levels.INFO); return
    end
    select.open({
        prompt         = "Breakpoints",
        enable_preview = true,
        items          = items,
        initial        = initial,
    }, function(data)
        if not data then return end
        require("ezdap.util.ui_util").smart_open_file(data.bp.source, data.bp.line)
    end)
end

-- Data breakpoints (watchpoints)

---Resolve `name` against the active session and either add a data breakpoint
---(prompting for an access type when several are offered) or, if one already
---exists for the resolved dataId, remove it.
---@param sess ezdap.dap.Session
---@param name string
---@param variables_reference integer?
local function _toggle_data_bp(sess, name, variables_reference)
    sess:data_breakpoint_info({ name = name, variablesReference = variables_reference }, function(body, err)
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
            select.open({ prompt = "Access type for " .. name .. ": ", items = types }, function(t)
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
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
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
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    sess:clear_data_breakpoints()
end

---List data breakpoints on the active session; selecting one removes it.
function M.breakpoint.data_list()
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    local bps = sess:data_breakpoints()
    if #bps == 0 then
        vim.notify("[dap] no data breakpoints", vim.log.levels.INFO); return
    end
    select.open({
        prompt = "Remove data breakpoint",
        items  = vim.tbl_map(function(bp)
            local icon = bp.verified == false and "◌" or "◉"
            local at   = bp.access_type and ("  [" .. bp.access_type .. "]") or ""
            return { label = icon .. " " .. bp.name .. at, data = bp }
        end, bps),
    }, function(bp)
        if bp then sess:remove_data_breakpoint(bp.data_id) end
    end)
end

-- Debug controls

M.debug = {}

function M.debug.continue() manager.continue() end

function M.debug.continue_all() manager.continue_all() end

function M.debug.step_over() manager.next() end

function M.debug.step_in() manager.step_in() end

function M.debug.step_out() manager.step_out() end

function M.debug.step_back() manager.step_back() end

function M.debug.reverse_continue() manager.reverse_continue() end

function M.debug.pause() manager.pause() end

function M.debug.restart() manager.restart() end

function M.debug.stop() manager.stop() end

function M.debug.stop_all() manager.stop_all() end

---Step into a specific call on the current line. Prompts when the line has
---multiple call targets; falls back to a plain step-in when unsupported or
---there is only one target.
function M.debug.step_into_targets()
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    local frame = sess:current_stack_frame()
    if not frame then
        vim.notify("[dap] no selected frame", vim.log.levels.WARN); return
    end
    manager.step_in_targets(frame.id, function(targets, _)
        if not targets or #targets == 0 then
            manager.step_in(); return
        end
        if #targets == 1 then
            manager.step_in(targets[1].id)
            return
        end
        select.open({
            prompt = "Step into",
            items  = vim.tbl_map(function(t) return { label = t.label, data = t } end, targets),
        }, function(t)
            if t then manager.step_in(t.id) end
        end)
    end)
end

---Jump-to-cursor: set the next statement to execute to the line under the
---cursor in the current buffer. Prompts when the line has multiple targets.
function M.debug.jump_to_cursor()
    _with_capability("supportsGotoTargetsRequest", "jump to cursor", function()
        local path = vim.api.nvim_buf_get_name(0)
        if path == "" then
            vim.notify("[dap] current buffer has no file", vim.log.levels.WARN); return
        end
        local line = vim.api.nvim_win_get_cursor(0)[1]
        ---@type ezdap.dap.proto.Source
        local source = { path = path, name = vim.fn.fnamemodify(path, ":t") }
        manager.goto_targets(source, line, function(targets, err)
            if not targets or #targets == 0 then
                vim.notify("[dap] no jump target at this line" .. (err and (": " .. err) or ""),
                    vim.log.levels.WARN)
                return
            end
            if #targets == 1 then
                manager.set_next_statement(targets[1].id)
                return
            end
            select.open({
                prompt = "Jump to",
                items  = vim.tbl_map(function(t)
                    return { label = t.label .. (t.line and ("  :" .. t.line) or ""), data = t }
                end, targets),
            }, function(t)
                if t then manager.set_next_statement(t.id) end
            end)
        end)
    end)
end

---Restart execution of the currently selected stack frame.
function M.debug.restart_frame()
    _with_capability("supportsRestartFrame", "restart frame", function(sess)
        local frame = sess:current_stack_frame()
        if not frame then
            vim.notify("[dap] no selected frame", vim.log.levels.WARN); return
        end
        manager.restart_frame(frame.id)
    end)
end

---Show detailed information about the exception at the current stop in a float.
function M.debug.exception_info()
    _with_capability("supportsExceptionInfoRequest", "exception info", function()
        manager.exception_info(function(body, err)
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
                focus_id = "ezdap_exception",
            })
        end)
    end)
end

---Return the active visual selection as one string (lines joined with newlines), or
---nil when there is none. Reads the `v`/`.` positions while still in visual mode
---(leaving it afterwards), or the `'<`/`'>` marks when `from_range` is true.
---@param from_range? boolean
---@return string?
local function _visual_selection(from_range)
    local mode = vim.fn.mode()
    local p1, p2, kind
    if mode:match("^[vV\22]") then
        p1, p2, kind = vim.fn.getpos("v"), vim.fn.getpos("."), mode
        vim.api.nvim_feedkeys(
            vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    elseif from_range then
        p1, p2, kind = vim.fn.getpos("'<"), vim.fn.getpos("'>"), vim.fn.visualmode()
    else
        return nil
    end
    local region = vim.fn.getregion(p1, p2, { type = kind ~= "" and kind or "v" })
    if vim.tbl_isempty(region) then return nil end
    return table.concat(region, "\n")
end

-- Cap the inspected expression: a huge selection is almost always a mistake, and
-- an oversized `evaluate` body just burdens the adapter for no useful result.
local _MAX_INSPECT_LEN = 1000

---@param expr? string       defaults to the visual selection, else the word under cursor
---@param from_range? boolean true when invoked with a command range (`:'<,'>Debug inspect`)
function M.debug.inspect(expr, from_range)
    expr = expr or _visual_selection(from_range) or vim.fn.expand("<cword>")
    if not expr or expr == "" then
        vim.notify("[dap] nothing to inspect", vim.log.levels.WARN)
        return
    end
    if #expr > _MAX_INSPECT_LEN then
        vim.notify(
            ("[dap] expression too long to inspect (%d > %d chars)"):format(#expr, _MAX_INSPECT_LEN),
            vim.log.levels.WARN)
        return
    end
    require("ezdap.ui.InspectView").open(expr)
end

---Open the disassembly pane for the active session's current frame.
function M.debug.disassemble() require("ezdap").open_disassembly_view() end

function M.debug.session()
    local sessions = manager.sessions()
    local ids      = vim.tbl_keys(sessions)
    if #ids == 0 then
        vim.notify("[dap] no active sessions", vim.log.levels.WARN); return
    end
    table.sort(ids)
    local active = manager.active_id()
    select.open({
        prompt = "Select session",
        items  = vim.tbl_map(function(id)
            local s     = sessions[id]
            local label = (s.config.name or s.config.adapter or "session") .. "  [" .. s.state .. "]"
            if id == active then label = label .. "  *" end
            return { label = label, data = id }
        end, ids),
    }, function(id)
        if id then manager.select_session(id) end
    end)
end

function M.debug.thread()
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    local threads = sess.threads
    if #threads == 0 then
        vim.notify("[dap] no threads available", vim.log.levels.WARN); return
    end
    select.open({
        prompt = "Select thread",
        items  = vim.tbl_map(function(t)
            return { label = "[" .. t.status .. "] " .. t.id .. ": " .. t.name, data = t }
        end, threads),
    }, function(t)
        if t then manager.select_thread(t.id) end
    end)
end

---Prompt for a thread and terminate it (requires supportsTerminateThreadsRequest).
function M.debug.terminate_thread()
    _with_capability("supportsTerminateThreadsRequest", "terminate thread", function(sess)
        local threads = sess.threads
        if #threads == 0 then
            vim.notify("[dap] no threads available", vim.log.levels.WARN); return
        end
        select.open({
            prompt = "Terminate thread",
            items  = vim.tbl_map(function(t)
                return { label = t.id .. ": " .. t.name .. "  [" .. t.status .. "]", data = t }
            end, threads),
        }, function(t)
            if t then manager.terminate_threads({ t.id }) end
        end)
    end)
end

function M.debug.frame()
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    local thread = sess:current_thread()
    if not thread then
        vim.notify("[dap] no selected thread", vim.log.levels.WARN); return
    end
    if thread.status ~= "stopped" then
        vim.notify("[dap] cannot select frame while running", vim.log.levels.WARN); return
    end
    local frames = thread.stack_frames or {}
    if #frames == 0 then
        vim.notify("[dap] no stack frames available", vim.log.levels.WARN); return
    end
    local cur_frame = sess:current_stack_frame()
    ---@param f ezdap.dap.proto.StackFrame
    ---@return string
    local function frame_key(f)
        local loc = f.source and f.source.path
            and ("  " .. vim.fn.fnamemodify(f.source.path, ":~:.") .. ":" .. (f.line or "?"))
            or ""
        return f.name .. loc
    end
    local cur_key = cur_frame and frame_key(cur_frame) or nil
    local initial ---@type integer?
    local items   = {}
    for i, f in ipairs(frames) do
        -- Match the active frame by its rendered string, not its id.
        local key    = frame_key(f)
        local is_cur = cur_key ~= nil and not initial and key == cur_key
        if is_cur then initial = i end
        local data = { frame = f }
        if f.source and f.source.path then
            data.filepath = f.source.path
            data.lnum     = f.line
        end
        items[i] = { label = key .. (is_cur and "  *" or ""), data = data }
    end
    select.open({
        prompt         = "Select frame",
        enable_preview = true,
        list_wrap      = false,
        items          = items,
        initial        = initial,
    }, function(data)
        if not data then return end
        -- The thread may have resumed while the picker was open.
        local t = sess:current_thread()
        if not t or t.status ~= "stopped" then
            vim.notify("[dap] cannot select frame while running", vim.log.levels.WARN); return
        end
        manager.select_frame(data.frame.id)
    end)
end

-- Debug view

M.view = {}

function M.view.toggle()
    require("ezdap").open_debug_view()
end

---Toggle the bottom output window, which holds the run's highest-priority buffer.
function M.view.output_toggle()
    require("ezdap.ui.output_win").toggle()
end

return M
