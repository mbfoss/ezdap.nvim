local TreeBuffer  = require("easydap.ui.TreeBuffer")
local manager     = require("easydap.manager")
local config      = require("easydap.config")
local expressions = require("easydap.ui.expressions")
local breakpoints = require("easydap.dap.breakpoints")
local str_util    = require("easydap.tk.strutil")
local inputwin    = require("easydap.tk.inputwin")
local select      = require("easydap.util.select")
local timer       = require("easydap.tk.timer")
local floatwin    = require("easydap.tk.floatwin")
local fixedwin    = require("easydap.tk.fixedwin")
local ui          = require("easydap.tk.ui")

-- Fraction of the editor width the view occupies on first open; thereafter the
-- last-used ratio (tracked by fixedwin across resizes) is reused.
local _DEFAULT_WIDTH_RATIO = 0.2

---@alias easydap.DebugView.ItemKind
---| "root"
---| "session"
---| "stackframe"
---| "scope"
---| "variable"
---| "expression"
---| "breakpoint"

---@class easydap.DebugView.ItemData
---@field kind     easydap.DebugView.ItemKind
---@field path     string
---@field name     string
---@field value    string?
---@field variablesReference number?
---@field evaluateName string?
---@field is_na    boolean?
---@field error    string?
---@field greyout  boolean?
---@field session_id number?
---@field session_info easydap.client.SessionInfo?
---@field is_current boolean?
---@field frame_id   integer?
---@field bp_kind       ("source"|"function"|"exception_filter"|"exception_type"|"data")?
---@field bp_id         integer?
---@field bp_source     string?
---@field bp_line       integer?
---@field bp_filter     string?
---@field bp_ex_name    string?
---@field bp_data_id    string?
---@field access_type   string?
---@field break_mode    string?
---@field unsupported   boolean?
---@field disabled      boolean?
---@field verified      boolean?
---@field condition     string?
---@field hit_condition string?
---@field log_message   string?

---@alias easydap.DebugView.Chunk { [1]: string, [2]: string? }

-- `vim.wo[win].opt = val` sets both the window-local value AND nvim's hidden
-- global default (the value new windows inherit), even for options with no
-- real global scope (winfixbuf, number, signcolumn, ...) — so opening the view
-- would silently leak its window settings into every future plain window, and
-- a later `setlocal opt<` reset in a split sibling would restore the polluted
-- value instead of nvim's real default. Force `scope = "local"` to confine
-- these changes to `win`.
---@param win integer
---@param opt string
---@param val any
local function _setlocal(win, opt, val)
    vim.api.nvim_set_option_value(opt, val, { win = win, scope = "local" })
end

---@param stop fun()?  stop fn returned by `_start_timer`, or nil
---@return nil
local function _cancel_timer(stop)
    if stop then stop() end
    return nil
end

---@param delay integer  milliseconds
---@param fn    fun()
---@return fun()  stop  stops and closes the timer
local function _start_timer(delay, fn)
    return timer.defer(delay, fn)
end

---@type { sessions: string, stack: string, variables: string, expressions: string, breakpoints: string }
local _roots = {
    sessions    = "sess",
    stack       = "stack",
    variables   = "vars",
    expressions = "xpr",
    breakpoints = "bps",
}

-- ── Formatters ────────────────────────────────────────────────────────────

---@param data easydap.DebugView.ItemData
---@param chunks easydap.DebugView.Chunk[]
local function _fmt_root(data, chunks)
    chunks[#chunks + 1] = { data.name, "Title" }
end

---@param data easydap.DebugView.ItemData
---@param chunks easydap.DebugView.Chunk[]
local function _fmt_session(data, chunks)
    local info = data.session_info
    if not info then return end
    local paused        = info.is_paused
    local terminated    = info.state == "terminated"
    local icon          = terminated and "●" or (paused and "■" or "▶")
    local hl            = terminated and "NonText" or (paused and "DiagnosticWarn" or "DiagnosticOk")
    chunks[#chunks + 1] = { icon, hl }
    chunks[#chunks + 1] = { " ", nil }
    chunks[#chunks + 1] = { data.name, data.is_current and "Special" or nil }
    if info.state and info.state ~= "running" then
        chunks[#chunks + 1] = { " [" .. info.state .. "]", "Tag" }
    end
end

---@param data easydap.DebugView.ItemData
---@param chunks easydap.DebugView.Chunk[]
---@param width integer  available DebugView window width
local function _fmt_stackframe(data, chunks, width)
    local hl = data.greyout and "NonText" or (data.is_current and "Special" or nil)
    chunks[#chunks + 1] = { str_util.crop_for_ui(data.name, width, true), hl }
end

---@param data easydap.DebugView.ItemData
---@param chunks easydap.DebugView.Chunk[]
local function _fmt_scope(data, chunks)
    chunks[#chunks + 1] = { data.name, "@module" }
end

---@param data easydap.DebugView.ItemData
---@param chunks easydap.DebugView.Chunk[]
local function _fmt_variable(data, chunks)
    local base_hl = data.greyout and "NonText" or nil
    chunks[#chunks + 1] = { data.name, base_hl }
    chunks[#chunks + 1] = { ": ", base_hl or "NonText" }
    local val = str_util.crop_for_ui(tostring(data.value or ""):gsub("\n", "⏎"), config.debug_value_max_len)
    chunks[#chunks + 1] = { val, base_hl or "@string" }
end

---@param data easydap.DebugView.ItemData
---@param chunks easydap.DebugView.Chunk[]
local function _fmt_expression(data, chunks)
    chunks[#chunks + 1] = { data.name}
    chunks[#chunks + 1] = { " = ", "NonText" }
    local val = str_util.crop_for_ui(tostring(data.value or ""):gsub("\n", "⏎"), config.debug_value_max_len)
    chunks[#chunks + 1] = { val, (data.is_na or data.greyout) and "NonText" or "@string" }
end

---@param data easydap.DebugView.ItemData
---@param chunks easydap.DebugView.Chunk[]
local function _fmt_breakpoint(data, chunks)
    local icon, hl
    if data.disabled then
        icon, hl = "ø", "NonText"
    elseif data.bp_kind == "exception_type" and data.unsupported then
        icon, hl = config.signs.exception_breakpoint_unsupported, "DiagnosticError"
    elseif data.bp_kind == "exception_filter" or data.bp_kind == "exception_type" then
        icon, hl = config.signs.exception_breakpoint, "DiagnosticInfo"
    elseif data.bp_kind == "data" then
        icon, hl = (data.verified == false) and "◌" or "◉",
            (data.verified == false) and "DiagnosticWarn" or "DiagnosticInfo"
    elseif data.log_message then
        icon, hl = (data.verified == false) and "◇" or "◆",
            (data.verified == false) and "DiagnosticWarn" or "DiagnosticHint"
    elseif data.condition or data.hit_condition then
        icon, hl = (data.verified == false) and "□" or "■", "DiagnosticWarn"
    elseif data.verified == false then
        icon, hl = "○", "DiagnosticWarn"
    else
        icon, hl = "●", "DiagnosticOk"
    end
    chunks[#chunks + 1] = { icon .. " ", hl }
    chunks[#chunks + 1] = { data.name, data.disabled and "NonText" or nil }
    if data.bp_kind == "exception_type" and data.unsupported then
        chunks[#chunks + 1] = { "  [unsupported]", "DiagnosticWarn" }
    elseif data.bp_kind == "exception_type" and data.break_mode then
        chunks[#chunks + 1] = { " [" .. data.break_mode .. "]", "Comment" }
    elseif data.bp_kind == "function" then
        chunks[#chunks + 1] = { " [fn]", "Comment" }
    else
        if data.bp_kind == "data" and data.access_type then
            chunks[#chunks + 1] = { " [" .. data.access_type .. "]", "Comment" }
        end
        if data.condition then
            chunks[#chunks + 1] = { " • if: " .. data.condition, "Comment" }
        end
        if data.hit_condition then
            chunks[#chunks + 1] = { " • hit: " .. data.hit_condition, "Comment" }
        end
        if data.log_message then
            chunks[#chunks + 1] = { " • log: " .. data.log_message, "Comment" }
        end
    end
end

---@type table<easydap.DebugView.ItemKind, fun(data: easydap.DebugView.ItemData, chunks: easydap.DebugView.Chunk[])>
local _formatters = {
    root       = _fmt_root,
    session    = _fmt_session,
    stackframe = _fmt_stackframe,
    scope      = _fmt_scope,
    variable   = _fmt_variable,
    expression = _fmt_expression,
    breakpoint = _fmt_breakpoint,
}

---@param data easydap.DebugView.ItemData?
---@param width integer  available DebugView window width
---@return easydap.DebugView.Chunk[], table
local function _node_formatter(data, width)
    if not data then return {}, {} end
    local chunks = {}
    local fmt = _formatters[data.kind]
    if fmt then fmt(data, chunks, width) end
    return chunks, {}
end

-- ── DebugView class ───────────────────────────────────────────────────────

---@class easydap.DebugView
---@field private _tree             easydap.ui.TreeBuffer
---@field private _width_ratio      number?   last-known width ratio, reused on the next open
---@field private _active_id        number?
---@field private _active_sess      easydap.dap.Session?
---@field private _query_ctx        number
---@field private _subs             fun()[]
---@field private _expanded         table<string,boolean>
---@field private _greyout_timer    fun()?
---@field private _session_timer    fun()?
---@field private _removal_timers   table<number,fun()>
---@field private _dbp_gen          integer?
local DebugView = {}
DebugView.__index = DebugView

---@return easydap.DebugView
function DebugView.new()
    local self = setmetatable({
        _active_id      = nil,
        _active_sess    = nil,
        _query_ctx      = 0,
        _subs           = {},
        _expanded       = {},
        _removal_timers = {},
    }, DebugView)
    self:init()
    return self
end

function DebugView:init()
    self:_init_tree()
    self:_setup_subs()
    self:_load_breakpoints()
    return self
end

-- ── Tree init ─────────────────────────────────────────────────────────────

---@private
function DebugView:_init_tree()
    self._tree = TreeBuffer.new({
        filetype  = "easydap-view",
        formatter = function(_, data, _)
            return _node_formatter(data, self:_get_win_width())
        end,
    })

    ---@param id string
    ---@param name string
    local function root(id, name)
        self._tree:add_item(nil, {
            id         = id,
            expandable = true,
            expanded   = true,
            data       = { kind = "root", path = id, name = name },
        })
    end

    root(_roots.sessions, "Sessions")
    root(_roots.stack, "Call Stack")
    root(_roots.variables, "Variables")
    root(_roots.expressions, "Expressions")
    root(_roots.breakpoints, "Breakpoints")

    self._tree:subscribe({
        on_toggle = function(id, data, expanded)
            if data and data.path then
                self._expanded[data.path] = expanded
            end
            if not expanded then return end
            local ctx = self._query_ctx
            if id == _roots.stack then
                if self._active_sess then self:_load_stack(ctx) end
            elseif id == _roots.variables then
                if self._active_sess then self:_load_vars(ctx) end
            elseif id == _roots.expressions then
                self:_load_expressions(ctx)
            elseif id == _roots.breakpoints then
                self:_load_breakpoints()
            elseif data and (data.kind == "scope" or data.kind == "variable" or data.kind == "expression") then
                local ref = data.variablesReference
                if ref and ref > 0 and self._active_sess then
                    self:_load_children(ctx, self._active_sess, ref, id, data.path)
                end
            elseif data and data.kind == "session" and data.session_id then
                manager.select_session(data.session_id)
            end
        end,
        on_selection = function(_, data)
            if not data then return end
            if data.kind == "session" and data.session_id then
                manager.select_session(data.session_id)
            elseif data.kind == "stackframe" and data.frame_id then
                manager.select_frame(data.frame_id)
            elseif data.kind == "breakpoint" and data.bp_kind == "source" and data.bp_source and data.bp_line then
                ui.smart_open_file( data.bp_source, data.bp_line, nil, false)
            end
        end,
    })
end

---@private
---@return integer
function DebugView:_get_win_width()
    local winid = self._tree:get_winid()
    return winid > 0 and vim.api.nvim_win_get_width(winid) or config.debug_value_max_len
end

-- ── Signal subscriptions ──────────────────────────────────────────────────

---@private
function DebugView:_setup_subs()
    self._subs[#self._subs + 1] = manager.on_session_added:subscribe(function(id, _, info)
        self._removal_timers[id] = _cancel_timer(self._removal_timers[id])
        self:_upsert_session_row(id, info)
    end)

    self._subs[#self._subs + 1] = manager.on_session_removed:subscribe(function(id)
        local item_id = _roots.sessions .. "/" .. id
        local item = self._tree:get_item(item_id)
        if item and item.data and item.data.session_info then
            item.data.session_info.state     = "terminated"
            item.data.session_info.is_paused = false
            self._tree:set_item_data(item_id, item.data)
        end
        if self._active_id == id then
            self:_set_active(nil, nil)
        end
        self._removal_timers[id] = _cancel_timer(self._removal_timers[id])
        self._removal_timers[id] = _start_timer(3000, function()
            self._removal_timers[id] = nil
            self._tree:remove_item(item_id)
        end)
    end)

    self._subs[#self._subs + 1] = manager.on_session_updated:subscribe(function(id, info)
        if info.is_paused then
            self._session_timer = _cancel_timer(self._session_timer)
            self:_upsert_session_row(id, info)
        else
            self._session_timer = _cancel_timer(self._session_timer)
            self._session_timer = _start_timer(config.antiflicker_delay, function()
                self._session_timer = nil
                self:_upsert_session_row(id, info)
            end)
        end
        if id == self._active_id and not info.is_paused then
            self._greyout_timer = _cancel_timer(self._greyout_timer)
            self._greyout_timer = _start_timer(config.antiflicker_delay, function()
                self._greyout_timer = nil
                self:_greyout_items()
            end)
        end
    end)

    self._subs[#self._subs + 1] = manager.on_session_stopped:subscribe(function(id, _)
        if id ~= self._active_id then return end
        self._greyout_timer = _cancel_timer(self._greyout_timer)
        -- GDB inferior function call: the stop is transient, undo any greyout from the
        -- preceding continued event and skip re-evaluation of stack/vars/expressions.
        if self._active_sess and self._active_sess.state_reason == "function call" then
            self:_ungreyout_items()
            return
        end
        self._query_ctx = self._query_ctx + 1
        local ctx = self._query_ctx
        self:_load_stack(ctx)
        self:_load_vars(ctx)
        self:_load_expressions(ctx)
    end)

    self._subs[#self._subs + 1] = manager.on_active_changed:subscribe(function(id, sess)
        self:_set_active(id, sess)
    end)

    self._subs[#self._subs + 1] = manager.on_selection_changed:subscribe(function(id, _)
        if id ~= self._active_id then return end
        self._query_ctx = self._query_ctx + 1
        local ctx = self._query_ctx
        self:_load_stack(ctx)
        self:_load_vars(ctx)
        self:_load_expressions(ctx)
    end)

    self._subs[#self._subs + 1] = expressions.on_change:subscribe(function()
        self:_load_expressions(self._query_ctx)
    end)

    self._subs[#self._subs + 1] = breakpoints.on_change:subscribe(function()
        self:_load_breakpoints()
    end)

    -- Adapter-verified status (verified flag, bound line, hits) is session-scoped
    -- and arrives via this event rather than the registry's on_change.
    self._subs[#self._subs + 1] = manager.on_breakpoint_updated:subscribe(function()
        self:_load_breakpoints()
    end)
end

function DebugView:teardown()
    for _, unsub in ipairs(self._subs) do unsub() end
    self._subs = {}
    self._greyout_timer = _cancel_timer(self._greyout_timer)
    self._session_timer = _cancel_timer(self._session_timer)
    for id, t in pairs(self._removal_timers) do
        _cancel_timer(t)
        self._removal_timers[id] = nil
    end
end

---@private
function DebugView:_greyout_items()
    for _, item in ipairs(self._tree:get_items()) do
        local k = item.data and item.data.kind
        if k == "variable" or k == "stackframe" or k == "scope" or k == "expression" then
            item.data.greyout = true
            self._tree:set_item_data(item.id, item.data)
        end
    end
end

---@private
function DebugView:_ungreyout_items()
    for _, item in ipairs(self._tree:get_items()) do
        local k = item.data and item.data.kind
        if k == "variable" or k == "stackframe" or k == "scope" or k == "expression" then
            if item.data.greyout then
                item.data.greyout = false
                self._tree:set_item_data(item.id, item.data)
            end
        end
    end
end

---@param data easydap.DebugView.ItemData
function DebugView:_show_hover(data)
    local kind = data and data.kind
    if not kind then return end
    local sess = self._active_sess

    ---@param lines string[]
    ---@param title string
    local function _float(lines, title)
        vim.lsp.util.open_floating_preview(lines, "plaintext", {
            border = "rounded",
            title = title,
            focus_id = "easydap_view",

        })
    end

    if kind == "stackframe" then
        local frame
        if sess then
            local thread = sess:current_thread()
            for _, f in ipairs(thread and thread.stack_frames or {}) do
                if f.id == data.frame_id then
                    frame = f; break
                end
            end
        end
        if not frame then return end
        local lines = { frame.name or data.name }
        local src = frame.source
        if src then
            if src.path and src.path ~= "" then
                lines[#lines + 1] = vim.fn.fnamemodify(src.path, ":~:.")
            elseif src.name then
                lines[#lines + 1] = src.name
            end
        end
        if frame.line then lines[#lines + 1] = "line " .. frame.line end
        if frame.instructionPointerReference then
            lines[#lines + 1] = frame.instructionPointerReference
        end
        _float(lines, "Stack Frame")
        return
    end

    if kind == "session" then
        if sess and sess.exception_description then
            _float(vim.split(sess.exception_description, "\n", { plain = true }), "Exception")
        end
        return
    end

    if (kind == "variable" or kind == "expression") and data.is_na then
        _float(vim.split(data.error or "not available", "\n", { plain = true }), data.name)
        return
    end

    if kind == "variable" or kind == "expression" then
        if not sess or not sess:current_stack_frame() then return end
        local expr = (kind == "variable") and (data.evaluateName or data.name) or data.name
        sess:evaluate({ expression = expr, context = "hover" }, function(body, err)
            if err or not body then
                _float({ err or "not available" }, data.name)
                return
            end
            local lines = {}
            if body.type and body.type ~= "" then
                lines[#lines + 1] = body.type
                lines[#lines + 1] = ""
            end
            vim.list_extend(lines, vim.split(body.result or "", "\n", { plain = true }))
            _float(lines, data.name)
        end)
        return
    end

    if kind == "breakpoint" then
        local lines = {}
        if data.bp_kind == "source" then
            if data.bp_source and data.bp_source ~= "" then
                lines[#lines + 1] = vim.fn.fnamemodify(data.bp_source, ":~:.")
            end
            if data.bp_line then lines[#lines + 1] = "line " .. data.bp_line end
        elseif data.bp_kind == "function" then
            lines[#lines + 1] = "function: " .. (data.name or "?")
        elseif data.bp_kind == "exception_filter" then
            lines[#lines + 1] = "filter: " .. (data.bp_filter or data.name or "?")
        elseif data.bp_kind == "exception_type" then
            lines[#lines + 1] = "exception: " .. (data.bp_ex_name or data.name or "?")
            if data.break_mode then lines[#lines + 1] = "break mode: " .. data.break_mode end
            if data.unsupported then lines[#lines + 1] = "(not supported by adapter)" end
        elseif data.bp_kind == "data" then
            lines[#lines + 1] = "data: " .. (data.name or "?")
            if data.access_type then lines[#lines + 1] = "access: " .. data.access_type end
        end
        if data.condition and data.condition ~= "" then
            lines[#lines + 1] = "condition: " .. data.condition
        end
        if data.hit_condition and data.hit_condition ~= "" then
            lines[#lines + 1] = "hit: " .. data.hit_condition
        end
        if data.log_message and data.log_message ~= "" then
            lines[#lines + 1] = "log: " .. data.log_message
        end
        local st = data.bp_id and sess and sess:bp_status(data.bp_id)
        if st then
            if st.message and st.message ~= "" then
                lines[#lines + 1] = ""
                lines[#lines + 1] = st.message
            end
            if st.hits and st.hits > 0 then
                lines[#lines + 1] = "hit count: " .. st.hits
            end
        end
        if data.disabled then
            lines[#lines + 1] = "disabled"
        elseif data.verified == false then
            lines[#lines + 1] = "not verified"
        elseif data.verified then
            lines[#lines + 1] = "verified"
        end
        if #lines > 0 then _float(lines, "Breakpoint") end
        return
    end
end

-- ── Session rows ──────────────────────────────────────────────────────────

---@param id number
---@param info easydap.client.SessionInfo
function DebugView:_upsert_session_row(id, info)
    local item_id = _roots.sessions .. "/" .. id
    ---@type easydap.DebugView.ItemData
    local data = {
        kind         = "session",
        path         = item_id,
        name         = info.name,
        session_id   = id,
        session_info = info,
        is_current   = (self._active_id == id),
    }
    if self._tree:have_item(item_id) then
        self._tree:set_item_data(item_id, data)
    else
        self._tree:add_item(_roots.sessions, {
            id         = item_id,
            expandable = false,
            expanded   = false,
            data       = data,
        })
    end
end

---@param id number?
---@param sess easydap.dap.Session?
function DebugView:_set_active(id, sess)
    local old_id      = self._active_id
    self._active_id   = id
    self._active_sess = sess

    -- Re-bind data-breakpoint refresh to the new active session. Data breakpoints
    -- are session-scoped, so we listen directly; stale listeners self-disable via
    -- the generation guard (the session drops all listeners when it terminates).
    self._dbp_gen     = (self._dbp_gen or 0) + 1
    local dbp_gen     = self._dbp_gen
    if sess then
        sess:on("data_breakpoints_changed", function()
            if dbp_gen ~= self._dbp_gen then return end
            self:_load_breakpoints()
        end)
    end

    -- refresh is_current flag on old and new session rows
    if old_id then
        local item = self._tree:get_item(_roots.sessions .. "/" .. old_id)
        if item and item.data then
            item.data.is_current = false
            self._tree:set_item_data(_roots.sessions .. "/" .. old_id, item.data)
        end
    end
    if id then
        local item = self._tree:get_item(_roots.sessions .. "/" .. id)
        if item and item.data then
            item.data.is_current = true
            self._tree:set_item_data(_roots.sessions .. "/" .. id, item.data)
        end
    end

    self._query_ctx = self._query_ctx + 1

    self._greyout_timer = _cancel_timer(self._greyout_timer)

    if not id then
        -- session ended with no replacement: keep data visible but greyed out
        self:_greyout_items()
        return
    end

    local ctx = self._query_ctx
    self._greyout_timer = _start_timer(config.antiflicker_delay, function()
        self._greyout_timer = nil
        if ctx ~= self._query_ctx then return end
        self:_greyout_items()
    end)

    self:_load_stack(ctx)
    self:_load_vars(ctx)
    self:_load_expressions(ctx)
    self:_load_breakpoints()
end

-- ── Data loading ──────────────────────────────────────────────────────────

---@private
---@param ctx number
function DebugView:_load_stack(ctx)
    local sess = self._active_sess
    if not sess then
        self._tree:set_children(_roots.stack, {})
        return
    end
    local thread = sess:current_thread()
    if not thread then
        self._tree:set_children(_roots.stack, {})
        return
    end
    sess:fetch_stack_trace(thread, 50, function()
        if ctx ~= self._query_ctx then return end
        self._greyout_timer = _cancel_timer(self._greyout_timer)
        local frames = thread.stack_frames or {}
        local current_frame = sess:current_stack_frame()

        -- Crop the stack to `stack_trace_limit` frames, but never hide the current
        -- frame: if it sits deeper than the limit, extend the cutoff to include it.
        local limit = config.stack_trace_limit
        local cutoff = (limit and limit > 0) and limit or #frames
        for i, frame in ipairs(frames) do
            if current_frame and frame.id == current_frame.id then
                cutoff = math.max(cutoff, i); break
            end
        end
        -- A lone hidden frame would cost the same line as the "… more" marker, so
        -- just show it instead.
        if #frames - cutoff == 1 then cutoff = #frames end

        local items = {}
        for i = 1, math.min(cutoff, #frames) do
            local frame, path = frames[i], _roots.stack .. "/" .. i
            items[i] = {
                id = path, expandable = false, expanded = false,
                data = {
                    kind       = "stackframe",
                    path       = path,
                    name       = frame.name or "<frame>",
                    frame_id   = frame.id,
                    is_current = current_frame and frame.id == current_frame.id or false,
                    greyout    = false,
                },
            }
        end
        local hidden = #frames - cutoff
        if hidden > 0 then
            items[#items + 1] = {
                id = _roots.stack .. "/__more__", expandable = false, expanded = false,
                data = {
                    kind    = "stackframe",
                    path    = _roots.stack .. "/__more__",
                    name    = ("… %d more frames"):format(hidden),
                    greyout = true,
                },
            }
        end
        self._tree:set_children(_roots.stack, items)
    end)
end

---@param parent_id any
---@param new_children easydap.ui.TreeBuffer.ItemDef[]
function DebugView:_merge_children(parent_id, new_children)
    local existing = self._tree:get_children(parent_id)
    local existing_map = {}
    for _, child in ipairs(existing) do
        existing_map[child.id] = true
    end

    local new_ids = {}
    for _, item in ipairs(new_children) do
        new_ids[item.id] = true
        if existing_map[item.id] then
            self._tree:set_item_data(item.id, item.data)
            self._tree:set_item_expafndable(item.id, item.expandable or false)
        else
            self._tree:add_item(parent_id, item)
        end
    end

    for _, child in ipairs(existing) do
        if not new_ids[child.id] then
            self._tree:remove_item(child.id)
        end
    end
end

---@private
---@param ctx number
function DebugView:_load_vars(ctx)
    local sess = self._active_sess
    local root_item = self._tree:get_item(_roots.variables)
    if not sess or not root_item or not root_item.expanded then
        self._tree:set_children(_roots.variables, {})
        return
    end
    local frame = sess:current_stack_frame()
    if not frame then
        self._tree:set_children(_roots.variables, {})
        return
    end
    sess:fetch_scopes(frame, function()
        if ctx ~= self._query_ctx then return end
        self._greyout_timer = _cancel_timer(self._greyout_timer)
        local scopes = frame.scopes or {}
        local scope_items = {}
        for i, scope in ipairs(scopes) do
            local path = _roots.variables .. "/" .. (scope.name or i)
            local expanded = self._expanded[path]
            if expanded == nil then
                expanded = not (scope.expensive
                    or scope.presentationHint == "globals"
                    or scope.name == "Globals" or scope.name == "Global"
                    or scope.name == "Registers" or scope.name == "Static")
            end
            scope_items[#scope_items + 1] = {
                id         = path,
                expandable = true,
                expanded   = expanded,
                data       = {
                    kind               = "scope",
                    path               = path,
                    name               = (scope.expensive and "⏱ " or "") .. (scope.name or "scope"),
                    variablesReference = scope.variablesReference,
                    greyout            = false,
                },
            }
        end
        self:_merge_children(_roots.variables, scope_items)
        -- load variables for expanded scopes
        for _, si in ipairs(scope_items) do
            if si.expanded and si.data.variablesReference and si.data.variablesReference > 0 then
                self:_load_children(ctx, sess, si.data.variablesReference, si.id, si.data.path)
            end
        end
    end)
end

---@param ctx number
---@param sess easydap.dap.Session
---@param ref number
---@param parent_id any
---@param parent_path string
function DebugView:_load_children(ctx, sess, ref, parent_id, parent_path)
    local tmp = { variablesReference = ref }
    sess:fetch_variables(tmp, function()
        if ctx ~= self._query_ctx then return end
        local vars = tmp.variables or {}
        local children = {}
        for i, var in ipairs(vars) do
            local path              = parent_path .. "/" .. (var.name or i)
            local expandable        = var.variablesReference and var.variablesReference > 0
            local expanded          = expandable and (self._expanded[path] == true) or false
            local item_id           = parent_id .. "::" .. (var.name or i) .. "#" .. i
            children[#children + 1] = {
                id         = item_id,
                expandable = expandable,
                expanded   = expanded,
                data       = {
                    kind               = "variable",
                    path               = path,
                    name               = var.name or "?",
                    value              = var.value,
                    variablesReference = var.variablesReference,
                    evaluateName       = var.evaluateName,
                    greyout            = false,
                },
            }
        end
        self:_merge_children(parent_id, children)
        for _, child in ipairs(children) do
            if child.expanded and child.data.variablesReference and child.data.variablesReference > 0 then
                self:_load_children(ctx, sess, child.data.variablesReference, child.id, child.data.path)
            end
        end
    end)
end

---@private
---@param ctx number
function DebugView:_load_expressions(ctx)
    local root_item = self._tree:get_item(_roots.expressions)
    if not root_item or not root_item.expanded then return end

    local all = expressions.all()

    -- remove tree nodes for expressions that no longer exist
    local live = {}
    for _, e in ipairs(all) do live[_roots.expressions .. "/" .. e.internal_id] = true end
    for _, child in ipairs(self._tree:get_children(_roots.expressions)) do
        if not live[child.id] then self._tree:remove_item(child.id) end
    end

    -- ensure a tree node exists for every expression
    local existing = {}
    for _, child in ipairs(self._tree:get_children(_roots.expressions)) do
        existing[child.id] = true
    end
    for _, expr_obj in ipairs(all) do
        local item_id = _roots.expressions .. "/" .. expr_obj.internal_id
        if not existing[item_id] then
            self._tree:add_item(_roots.expressions, {
                id         = item_id,
                expandable = false,
                expanded   = false,
                data       = {
                    kind    = "expression",
                    path    = item_id,
                    name    = expr_obj.expr,
                    expr_id = expr_obj.internal_id,
                    is_na   = true,
                    value   = "not available",
                    greyout = false,
                },
            })
        else
            local item = self._tree:get_item(item_id)
            if item and item.data and item.data.name ~= expr_obj.expr then
                item.data.name = expr_obj.expr
                self._tree:set_item_data(item_id, item.data)
            end
        end
        self:_eval_expression(ctx, expr_obj)
    end
end

---@param ctx number
---@param expr_obj easydap.Expression
function DebugView:_eval_expression(ctx, expr_obj)
    local item_id = _roots.expressions .. "/" .. expr_obj.internal_id
    local sess = self._active_sess
    if not sess or not sess:current_stack_frame() then return end

    sess:evaluate({ expression = expr_obj.expr, context = "watch" }, function(body, err)
        if ctx ~= self._query_ctx then return end
        if not self._tree:have_item(item_id) then return end
        local item = self._tree:get_item(item_id)
        if not item then return end
        local data = item.data
        if err or not body then
            data.value              = "not available"
            data.is_na              = true
            data.error              = err
            data.greyout            = false
            data.variablesReference = nil
        else
            data.value              = body.result
            data.is_na              = false
            data.greyout            = false
            data.variablesReference = body.variablesReference
        end
        self._tree:set_item_data(item_id, data)
        local has_ref = data.variablesReference and data.variablesReference > 0
        self._tree:set_item_expandable(item_id, has_ref or false)
        if not has_ref then
            self._tree:remove_children(item_id)
        end
    end)
end

---@private
function DebugView:_load_breakpoints()
    local root_item = self._tree:get_item(_roots.breakpoints)
    if not root_item or not root_item.expanded then return end

    local items = {}

    for _, bp in ipairs(breakpoints.all()) do
        local short       = vim.fn.fnamemodify(bp.source, ":~:.")
        local path        = _roots.breakpoints .. "/src/" .. bp.internal_id
        local src_st      = manager.bp_status(bp.internal_id)
        items[#items + 1] = {
            id         = path,
            expandable = false,
            expanded   = false,
            data       = {
                kind          = "breakpoint",
                path          = path,
                name          = short .. ":" .. bp.line .. (bp.column and (":" .. bp.column) or ""),
                bp_kind       = "source",
                bp_id         = bp.internal_id,
                bp_source     = bp.source,
                bp_line       = bp.line,
                bp_column     = bp.column,
                disabled      = bp.disabled,
                verified      = src_st and src_st.verified,
                condition     = bp.condition,
                hit_condition = bp.hit_condition,
                log_message   = bp.log_message,
            },
        }
    end

    for _, bp in ipairs(breakpoints.function_breakpoints()) do
        local path        = _roots.breakpoints .. "/fn/" .. bp.internal_id
        local fn_st       = manager.bp_status(bp.internal_id)
        items[#items + 1] = {
            id         = path,
            expandable = false,
            expanded   = false,
            data       = {
                kind     = "breakpoint",
                path     = path,
                name     = bp.name,
                bp_kind  = "function",
                bp_id    = bp.internal_id,
                disabled = bp.disabled,
                verified = fn_st and fn_st.verified,
            },
        }
    end

    for _, bp in ipairs(breakpoints.exception_breakpoints()) do
        local path = _roots.breakpoints .. "/exc/" .. bp.filter
        items[#items + 1] = {
            id         = path,
            expandable = false,
            expanded   = false,
            data       = {
                kind      = "breakpoint",
                path      = path,
                name      = bp.label,
                bp_kind   = "exception_filter",
                bp_filter = bp.filter,
                disabled  = bp.disabled,
            },
        }
    end

    local active_sess = manager.session()
    local ex_opts_unsupported = active_sess ~= nil
        and not (active_sess.capabilities and active_sess.capabilities.supportsExceptionOptions)

    for _, bp in ipairs(breakpoints.exception_name_breakpoints()) do
        local path = _roots.breakpoints .. "/excn/" .. bp.internal_id
        items[#items + 1] = {
            id         = path,
            expandable = false,
            expanded   = false,
            data       = {
                kind        = "breakpoint",
                path        = path,
                name        = bp.name,
                bp_kind     = "exception_type",
                bp_id       = bp.internal_id,
                bp_ex_name  = bp.name,
                break_mode  = bp.break_mode,
                disabled    = bp.disabled,
                unsupported = ex_opts_unsupported,
            },
        }
    end

    if active_sess then
        for i, bp in ipairs(active_sess:data_breakpoints()) do
            local path        = _roots.breakpoints .. "/data/" .. i
            items[#items + 1] = {
                id         = path,
                expandable = false,
                expanded   = false,
                data       = {
                    kind        = "breakpoint",
                    path        = path,
                    name        = bp.name,
                    bp_kind     = "data",
                    bp_data_id  = bp.data_id,
                    access_type = bp.access_type,
                    disabled    = bp.disabled,
                    verified    = bp.verified,
                },
            }
        end
    end

    self._tree:set_children(_roots.breakpoints, items)
end

-- ── Public: window management ─────────────────────────────────────────────

---Create (or return existing) buffer for embedding in a window.
---@param on_deleted fun()  called when the buffer is wiped
---@return integer bufnr
function DebugView:get_bufnr(on_deleted)
    local bufnr, created = self._tree:create_buffer(on_deleted)
    if created then
        self:_setup_keymaps(bufnr)
        -- apply initial state for any already-running sessions
        for id, sess in pairs(manager.sessions()) do
            local info = {
                id                = id,
                name              = sess.config.name or sess.config.adapter or "debug",
                state             = sess.state,
                is_paused         = sess.state == "stopped",
                nb_paused_threads = 0,
            }
            self:_upsert_session_row(id, info)
        end
        local aid = manager.active_id()
        if aid then
            self:_set_active(aid, manager.get_session(aid))
        end
    end
    return bufnr
end

---Close the DebugView window if it is currently visible. The fixedwin on_delete
---(fired on WinClosed) records the final width ratio for the next open.
function DebugView:close()
    local winid = self._tree:get_winid()
    if winid > 0 then
        vim.api.nvim_win_close(winid, true)
    end
end

---@param focus boolean
function DebugView:_open(focus)
    local winid = self._tree:get_winid()
    if winid > 0 then
        if focus then vim.api.nvim_set_current_win(winid) end
        return
    end
    local bufnr = self:get_bufnr(function() end)
    -- fixedwin owns the split's creation, width pinning, resize/ratio tracking
    -- and re-pinning across layout changes; we only layer on the view-specific
    -- window options and swap in the tree buffer.
    local win = fixedwin.create_fixed_win("width", self._width_ratio or _DEFAULT_WIDTH_RATIO,
        function(ratio) self._width_ratio = ratio end,
        { enter = focus })
    vim.api.nvim_win_set_buf(win, bufnr)
    _setlocal(win, "winfixbuf", true)
    _setlocal(win, "signcolumn", "no")
    _setlocal(win, "number", false)
    _setlocal(win, "relativenumber", false)
end

---Open the DebugView in a vertical split (or focus if already visible).
function DebugView:open()
    self:_open(true)
end

---Open the DebugView without stealing focus. No-op if already visible.
function DebugView:show()
    self:_open(false)
end

-- ── Keymaps ────────────────────────────────────────────────────────────────

---Toggle a data breakpoint (watchpoint) on a variable tree node, resolving its
---dataId against the active session and prompting for an access type when the
---adapter offers several.
---@private
---@param cur easydap.ui.TreeBuffer.Item  a node whose data.kind == "variable"
function DebugView:_toggle_data_breakpoint(cur)
    local sess = self._active_sess
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN); return
    end
    if not sess:capable("supportsDataBreakpoints") then
        vim.notify("[dap] adapter does not support data breakpoints", vim.log.levels.WARN)
        return
    end
    local d          = cur.data
    local parent     = self._tree:get_parent_item(cur.id)
    local parent_ref = parent and parent.data and parent.data.variablesReference
    sess:data_breakpoint_info({ name = d.name, variablesReference = parent_ref }, function(body, err)
        if err or not body or not body.dataId then
            local why = err or (body and body.description) or "not available"
            vim.notify("[dap] cannot watch '" .. d.name .. "': " .. why, vim.log.levels.WARN)
            return
        end
        for _, bp in ipairs(sess:data_breakpoints()) do
            if bp.data_id == body.dataId then
                sess:remove_data_breakpoint(body.dataId)
                return
            end
        end
        local function add(access)
            sess:add_data_breakpoint({ data_id = body.dataId, name = d.name, access_type = access })
        end
        local types = body.accessTypes or {}
        if #types > 1 then
            select.open({ prompt = "Access type for `" .. d.name .. "`: ", items = types }, function(t)
                if t then add(t) end
            end)
        else
            add(types[1])
        end
    end)
end

---@private
---@param bufnr integer
function DebugView:_setup_keymaps(bufnr)
    ---@param key string
    ---@param desc string
    ---@param fn fun()
    local function map(key, desc, fn)
        vim.keymap.set("n", key, fn, { buffer = bufnr, desc = desc })
    end

    map("i", "Add watch expression / function breakpoint / toggle data breakpoint", function()
        local cur = self._tree:get_cursor_item()
        if not cur then return end
        local id = tostring(cur.id)
        local function under(root) return id == root or vim.startswith(id, root .. "/") end
        if under(_roots.expressions) then
            inputwin.open({ prompt = "Watch expression: " }, function(expr)
                if expr and expr ~= "" then expressions.add(expr) end
            end)
        elseif under(_roots.breakpoints) then
            inputwin.open({ prompt = "Function breakpoint: " }, function(name)
                if name and name ~= "" then breakpoints.add_function(name) end
            end)
        elseif cur.data and cur.data.kind == "variable" then
            self:_toggle_data_breakpoint(cur)
        end
    end)

    map("d", "Remove watch expression or breakpoint", function()
        local cur = self._tree:get_cursor_item()
        if not cur or not cur.data then return end
        if cur.data.kind == "expression" then
            for _, e in ipairs(expressions.all()) do
                if e.expr == cur.data.name then
                    expressions.remove(e.internal_id); break
                end
            end
        elseif cur.data.kind == "breakpoint" then
            local d = cur.data
            if d.bp_kind == "source" and d.bp_source and d.bp_line then
                breakpoints.remove(d.bp_source, d.bp_line, d.bp_column)
            elseif d.bp_kind == "function" then
                breakpoints.remove_function(d.name)
            elseif d.bp_kind == "exception_type" and d.bp_ex_name then
                breakpoints.remove_exception_name(d.bp_ex_name)
            elseif d.bp_kind == "data" and d.bp_data_id then
                local sess = manager.session()
                if sess then sess:remove_data_breakpoint(d.bp_data_id) end
            end
        end
    end)

    map("r", "Rename expression", function()
        local cur = self._tree:get_cursor_item()
        if not cur or not cur.data or cur.data.kind ~= "expression" then return end
        local d = cur.data
        if not d.expr_id then return end
        inputwin.open({ prompt = "Expression: ", default = d.name or "" }, function(input)
            if input and input ~= "" then expressions.update(d.expr_id, input) end
        end)
    end)

    map("x", "Toggle breakpoint enabled/disabled", function()
        local cur = self._tree:get_cursor_item()
        if not cur or not cur.data or cur.data.kind ~= "breakpoint" then return end
        local d = cur.data
        if d.bp_kind == "source" and d.bp_source and d.bp_line then
            breakpoints.patch(d.bp_source, d.bp_line, { disabled = not d.disabled })
        elseif d.bp_kind == "function" then
            breakpoints.add_function(d.name, { disabled = not d.disabled })
        elseif d.bp_kind == "exception_filter" and d.bp_filter then
            breakpoints.set_exception_enabled(d.bp_filter, d.disabled)
        elseif d.bp_kind == "exception_type" and d.bp_ex_name then
            breakpoints.set_exception_name_enabled(d.bp_ex_name, d.disabled)
        elseif d.bp_kind == "data" and d.bp_data_id then
            local sess = manager.session()
            if sess then sess:set_data_breakpoint_enabled(d.bp_data_id, d.disabled) end
        end
    end)

    map("c", "Change variable value, breakpoint condition/hit condition, or data breakpoint access type", function()
        local cur = self._tree:get_cursor_item()
        if not cur or not cur.data then return end
        local d = cur.data
        if d.kind == "breakpoint" and d.bp_kind == "data" and d.bp_data_id then
            local sess = manager.session()
            if not sess then
                vim.notify("[dap] no active session", vim.log.levels.WARN); return
            end
            local _types = { "read", "write", "readWrite" }
            local cur_at = d.access_type
            select.open({
                prompt = "Access type for " .. d.name .. ": ",
                items  = vim.tbl_map(function(t)
                    return { label = (t == cur_at and "● " or "  ") .. t, data = t }
                end, _types),
            }, function(at)
                if not at then return end
                sess:add_data_breakpoint({ data_id = d.bp_data_id, name = d.name, access_type = at })
            end)
        elseif d.kind == "breakpoint" and d.bp_kind == "source" and d.bp_source and d.bp_line then
            inputwin.open({ prompt = "Condition (empty to clear): ", default = d.condition or "" }, function(cond)
                if cond == nil then return end
                inputwin.open({ prompt = "Hit condition (empty to clear): ", default = d.hit_condition or "" },
                    function(hit)
                        if hit == nil then return end
                        breakpoints.patch(d.bp_source, d.bp_line, { condition = cond, hit_condition = hit })
                    end)
            end)
        elseif d.kind == "breakpoint" and d.bp_kind == "exception_type" and d.bp_ex_name then
            local _modes = { "always", "unhandled", "userUnhandled", "never" }
            local cur_mode = d.break_mode
            select.open({
                prompt = "Break mode for " .. d.bp_ex_name .. ": ",
                items  = vim.tbl_map(function(m)
                    return { label = (m == cur_mode and "● " or "  ") .. m, data = m }
                end, _modes),
            }, function(mode)
                if not mode then return end
                breakpoints.add_exception_name(d.bp_ex_name, mode)
            end)
        elseif d.kind == "variable" and self._active_sess then
            local parent = self._tree:get_parent_item(cur.id)
            local parent_ref = parent and parent.data and parent.data.variablesReference
            inputwin.open({ prompt = "New value: ", default = d.value or "" }, function(input)
                if input == nil then return end
                self._active_sess:set_variable(parent_ref,
                    {
                        name = d.name,
                        value = d.value,
                        variablesReference = d.variablesReference or 0,
                        evaluateName = d
                            .evaluateName
                    }, input,
                    function(_, err)
                        if err then return end
                        self:_load_vars(self._query_ctx)
                    end)
            end)
        end
    end)

    map("K", "Show details / full value", function()
        local cur = self._tree:get_cursor_item()
        if cur and cur.data then self:_show_hover(cur.data) end
    end)

    map("g?", "Show keymaps", function()
        floatwin.open(table.concat({
            "<CR>  Select session / switch frame / jump to breakpoint source",
            "K     Show full value / frame details / exception info / breakpoint details",
            "i     Add: watch expression (expressions) / function breakpoint (breakpoints) / data breakpoint (variable)",
            "d     Remove watch expression or breakpoint",
            "r     Rename expression",
            "x     Toggle breakpoint enabled/disabled",
            "c     Change variable value / breakpoint condition or hit condition / exception break mode / data access type",
        }, "\n"), { title = "Keymaps" })
    end)
end

return DebugView
