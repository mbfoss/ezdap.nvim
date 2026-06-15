---@brief DAP session.
---Owns one Connection, holds all runtime state (threads, frames, scopes,
---variables, modules, sources), and drives the full DAP protocol handshake.
---
---Emitted events (register with session:on(event, fn)):
---  "state_changed"     (session)                  — state / reason updated
---  "output"            (category, text)            — adapter output event
---  "stopped"           (session)                  — execution stopped
---  "continued"         (session)                  — execution resumed
---  "thread_updated"    (session)                  — thread list changed
---  "breakpoint_updated"(bp, status)               — bp verified/message changed; status is { verified, message, hits }
---  "terminated"        (session)                  — session ended
---  "run_in_terminal"   (bufnr)                    — terminal buffer opened
---  "start_debugging"   (child_config, parent_sess)— adapter requests child session

local breakpoints = require("easydap.dap.breakpoints")

---@class easydap.dap.Thread
---@field id           integer
---@field name         string
---@field status       "running"|"stopped"|"exited"
---@field stack_frames easydap.dap.StackFrame[]?
---@field total_frames integer?

---@class easydap.dap.StackFrame : easydap.dap.proto.StackFrame
---@field scopes easydap.dap.Scope[]?

---Scope augmented with a Lua-side variable cache populated by fetch_variables.
---@class easydap.dap.Scope : easydap.dap.proto.Scope
---@field variables? easydap.dap.Variable[]

---Variable augmented with a Lua-side child cache populated by fetch_variables.
---@class easydap.dap.Variable : easydap.dap.proto.Variable
---@field variables? easydap.dap.Variable[]

---Adapter-verified status for a single breakpoint tracked by the session.
---@class easydap.dap.BpStatus
---@field verified boolean?
---@field message  string?
---@field hits     integer

---A data breakpoint (watchpoint) tracked by the session.
---Session-scoped: dataIds are obtained per-session via dataBreakpointInfo and
---are not persisted to the project store.
---@class easydap.dap.DataBreakpoint
---@field data_id       string
---@field name          string                                   human label (variable/expression watched)
---@field access_type   easydap.dap.proto.DataBreakpointAccessType?
---@field condition     string?
---@field hit_condition string?
---@field disabled      boolean?                                 kept in the list but excluded from the synced set
---@field verified      boolean?
---@field message       string?

---@class easydap.dap.Session
---@field conn          easydap.dap.Connection
---@field config        easydap.dap.Config
---@field state         string
---@field state_reason  string?
---@field capabilities  easydap.dap.proto.Capabilities
---@field _initialized  boolean
---@field threads       easydap.dap.Thread[]
---@field _thread_id    integer?
---@field _stack_id     integer?
---@field exception_description string?
---@field _modules      easydap.dap.proto.Module[]
---@field _sources      easydap.dap.proto.Source[]
---@field _source_buffers table<integer,integer>   sourceReference -> bufnr
---@field on            fun(self: easydap.dap.Session, event: string, handler: fun(...))
---@field start         fun(self: easydap.dap.Session)
---@field stop          fun(self: easydap.dap.Session, cb: fun()?)
---@field terminate     fun(self: easydap.dap.Session, cb: fun(err: string?)?)
---@field disconnect    fun(self: easydap.dap.Session, cb: fun()?)
---@field continue      fun(self: easydap.dap.Session, thread_id: integer?)
---@field next          fun(self: easydap.dap.Session, thread_id: integer?, granularity: easydap.dap.proto.SteppingGranularity?)
---@field step_in       fun(self: easydap.dap.Session, thread_id: integer?, granularity: easydap.dap.proto.SteppingGranularity?)
---@field step_out      fun(self: easydap.dap.Session, thread_id: integer?, granularity: easydap.dap.proto.SteppingGranularity?)
---@field pause         fun(self: easydap.dap.Session, thread_id: integer?)
---@field step_back     fun(self: easydap.dap.Session, thread_id: integer?, granularity: easydap.dap.proto.SteppingGranularity?)
---@field restart       fun(self: easydap.dap.Session)
---@field evaluate      fun(self: easydap.dap.Session, expr: string, context: string, cb: fun(body: easydap.dap.proto.EvaluateResponseBody?, err: string?))
---@field disassemble   fun(self: easydap.dap.Session, ref: string, count: integer, offset: integer?, cb: fun(instructions: easydap.dap.proto.DisassembledInstruction[]?, err: string?))
---@field instruction_breakpoints        fun(self: easydap.dap.Session): table<string, easydap.dap.BpStatus>
---@field toggle_instruction_breakpoint  fun(self: easydap.dap.Session, ref: string, cb: fun(err: string?)?)
---@field _instr_bps                     table<string, easydap.dap.BpStatus>
---@field data_breakpoints               fun(self: easydap.dap.Session): easydap.dap.DataBreakpoint[]
---@field data_breakpoint_info           fun(self: easydap.dap.Session, name: string, variables_reference: integer?, cb: fun(body: easydap.dap.proto.DataBreakpointInfoResponseBody?, err: string?))
---@field add_data_breakpoint            fun(self: easydap.dap.Session, entry: { data_id: string, name: string, access_type?: easydap.dap.proto.DataBreakpointAccessType, condition?: string, hit_condition?: string }, cb: fun(err: string?)?)
---@field remove_data_breakpoint         fun(self: easydap.dap.Session, data_id: string, cb: fun(err: string?)?)
---@field set_data_breakpoint_enabled    fun(self: easydap.dap.Session, data_id: string, enabled: boolean, cb: fun(err: string?)?)
---@field clear_data_breakpoints         fun(self: easydap.dap.Session, cb: fun(err: string?)?)
---@field _data_bps                      easydap.dap.DataBreakpoint[]
---@field request       fun(self: easydap.dap.Session, command: string, args: table?, cb: fun(body: table?, err: string?)?)
---@field capable       fun(self: easydap.dap.Session, name: string): boolean
---@field current_thread      fun(self: easydap.dap.Session): easydap.dap.Thread?
---@field current_stack_frame fun(self: easydap.dap.Session): easydap.dap.StackFrame?
---@field stopped_threads     fun(self: easydap.dap.Session): easydap.dap.Thread[]
---@field fetch_variables     fun(self: easydap.dap.Session, object: easydap.dap.Scope|easydap.dap.Variable, cb: fun()?)
---@field fetch_stack_trace   fun(self: easydap.dap.Session, thread: easydap.dap.Thread, levels: integer, cb: fun()?)
---@field fetch_scopes        fun(self: easydap.dap.Session, frame: easydap.dap.StackFrame, cb: fun()?)
---@field set_variable        fun(self: easydap.dap.Session, reference: integer?, variable: easydap.dap.Variable, value: string, cb: fun(body: table?, err: string?)?)
---@field get_source_buffer   fun(self: easydap.dap.Session, ref: integer, cb: fun(bufnr: integer?, err: string?))
---@field _bp_status      table<integer, easydap.dap.BpStatus>
---@field _adapter_id_map table<integer, integer>
---@field sync_breakpoints              fun(self: easydap.dap.Session, source: string|nil, cb: fun()?)
---@field sync_function_breakpoints    fun(self: easydap.dap.Session, cb: fun()?)
---@field sync_exception_breakpoints   fun(self: easydap.dap.Session, cb: fun()?)
---@field bp_status                    fun(self: easydap.dap.Session, bp_id: integer): easydap.dap.BpStatus?
---@field completions                  fun(self: easydap.dap.Session, text: string, column: integer, frame_id: integer?, cb: fun(targets: easydap.dap.proto.CompletionItem[]))
---@field select_thread                fun(self: easydap.dap.Session, thread_id: integer)
---@field select_frame                 fun(self: easydap.dap.Session, frame_id: integer)
---@field report                  fun(self: easydap.dap.Session, msg: string)
---@field _emit                    fun(self: easydap.dap.Session, event: string, ...)
---@field _handle_event            fun(self: easydap.dap.Session, event: string, body: table)
---@field _handle_adapter_request  fun(self: easydap.dap.Session, command: string, args: table, respond: easydap.dap.RespondFn)
---@field _on_continued            fun(self: easydap.dap.Session, body: easydap.dap.proto.ContinuedEventBody)
---@field _on_close                fun(self: easydap.dap.Session)

local M = {}

local Session = {}
Session.__index = Session

---@param conn   easydap.dap.Connection
---@param config easydap.dap.Config
---@return easydap.dap.Session
function M.new(conn, config)
    ---@type easydap.dap.Session
    local self      = setmetatable({
        conn                  = conn,
        config                = config,
        state                 = "starting",
        state_reason          = nil,
        capabilities          = {},
        _initialized          = false,
        threads               = {},
        _thread_id            = nil,
        _stack_id             = nil,
        exception_description = nil,
        _modules              = {},
        _sources              = {},
        _source_buffers       = {},
        _bp_status            = {},
        _adapter_id_map       = {},
        _instr_bps            = {},
        _data_bps             = {},
        _listeners            = {},
        _stop_cb              = nil,
        _stopping             = false,
        report                = function(_, msg) vim.notify(msg, vim.log.levels.WARN) end,
    }, Session)

    conn.on_event   = function(event, body) self:_handle_event(event, body) end
    conn.on_request = function(cmd, args, respond) self:_handle_adapter_request(cmd, args, respond) end
    conn.on_close   = function() self:_on_close() end

    return self
end

-- ── Listener helpers ───────────────────────────────────────────────────────

---@alias easydap.dap.SessionEvent
---| "state_changed"
---| "selection_changed"
---| "thread_updated"
---| "breakpoint_updated"
---| "instruction_breakpoints_changed"
---| "data_breakpoints_changed"
---| "variable_changed"
---| "stopped"
---| "continued"
---| "terminated"
---| "output"
---| "start_debugging"
---| "run_in_terminal"
---| "terminal_exit"

---@param event   easydap.dap.SessionEvent
---@param handler fun(...)
function Session:on(event, handler)
    self._listeners[event] = self._listeners[event] or {}
    table.insert(self._listeners[event], handler)
end

---@param event easydap.dap.SessionEvent
---@param ... any
function Session:_emit(event, ...)
    local snapshot = vim.list_slice(self._listeners[event] or {})

    for _, fn in ipairs(snapshot) do
        local ok, err = xpcall(fn, debug.traceback, ...)
        if not ok then
            vim.api.nvim_echo(
                { { tostring(err), "ErrorMsg" } },
                true,
                { err = true }
            )
        end
    end
end

-- ── State helpers ──────────────────────────────────────────────────────────

---@param state  string
---@param reason string?
function Session:_set_state(state, reason)
    self.state        = state
    self.state_reason = reason
    self:_emit("state_changed", self)
end

---@param name string  capability key e.g. "supportsRestartRequest"
---@return boolean
function Session:capable(name)
    return self.capabilities[name] == true
end

-- ── Thread helpers ─────────────────────────────────────────────────────────

---@param id integer?
---@return easydap.dap.Thread?
function Session:_find_thread(id)
    for _, t in ipairs(self.threads) do
        if t.id == id then return t end
    end
end

---@param id     integer?
---@param status "running"|"stopped"|"exited"
function Session:_upsert_thread(id, status)
    local t = self:_find_thread(id)
    if t then
        t.status = status
    elseif id then
        table.insert(self.threads, {
            id = id, name = "thread-" .. id, status = status,
        })
    end
end

---@param thread_id  integer?
---@param all_threads boolean?
---@param status     "running"|"stopped"|"exited"
function Session:_set_thread_status(thread_id, all_threads, status)
    if all_threads then
        for _, t in ipairs(self.threads) do t.status = status end
    else
        self:_upsert_thread(thread_id, status)
    end
end

---@param id    integer?
---@param force boolean?
function Session:_select_thread(id, force)
    if id and (force or not self._thread_id) then
        self._thread_id = id
    end
end

---@return easydap.dap.Thread[]
function Session:stopped_threads()
    local r = {}
    for _, t in ipairs(self.threads) do
        if t.status == "stopped" then r[#r + 1] = t end
    end
    return r
end

---@return easydap.dap.Thread?
function Session:current_thread()
    return self:_find_thread(self._thread_id)
end

---@return easydap.dap.StackFrame?
function Session:current_stack_frame()
    local thread = self:current_thread()
    if not thread or not thread.stack_frames then return end
    if self._stack_id then
        for _, f in ipairs(thread.stack_frames) do
            if f.id == self._stack_id then return f end
        end
    end
    return thread.stack_frames[1]
end

-- ── Outgoing requests ──────────────────────────────────────────────────────

---Low-level request, forwarded to the connection.
---Dropped (cb called with error) when the session is terminating or terminated
---so in-flight init chains (setBreakpoints, configurationDone, …) drain fast.
---"terminate" and "disconnect" are always forwarded so stop()/disconnect() work.
---@param command string
---@param args    table?
---@param cb      fun(body: table?, err: string?)?
function Session:request(command, args, cb)
    if (self.state == "terminated" or self._stopping)
        and command ~= "disconnect"
    then
        if cb then cb(nil, "session " .. (self.state == "terminated" and "terminated" or "closing")) end
        return
    end
    self.conn:request(command, args, cb)
end

---@return nil
function Session:_do_initialize()
    self:request("initialize", {
        clientID                            = "easydap",
        adapterID                           = self.config.type or self.config.adapter or "",
        pathFormat                          = "path",
        linesStartAt1                       = true,
        columnsStartAt1                     = true,
        supportsRunInTerminalRequest        = true,
        supportsArgsCanBeInterpretedByShell = true,
        supportsProgressReporting           = true,
        supportsStartDebuggingRequest       = true,
    }, function(body, err)
        if err then
            self:report("[dap] initialize failed: " .. err)
            self:_shutdown()
            return
        end
        self.capabilities = body or {}
        -- Per spec: send launch/attach after initialize unless the adapter uses
        -- configurationDone as the trigger (defer_launch_attach = true).
        if not self.config.defer_launch_attach then
            self:_do_launch_or_attach()
        end
    end)
end

---@param cb fun()?  called on successful response
function Session:_do_launch_or_attach(cb)
    local req_type = self.config.request or "launch"
    self:request(req_type, self:_protocol_args(), function(_, err)
        if err then
            self:report(("[dap] %s failed: %s"):format(req_type, err))
            self:_shutdown()
        elseif cb then
            cb()
        end
    end)
end

---@return table
function Session:_protocol_args()
    return self.config.request_args or {}
end

-- Breakpoint sync chain ──────────

---@return easydap.dap.proto.SetExceptionBreakpointsArguments
function Session:_exception_bp_params()
    local filters = {}
    for _, bp in ipairs(breakpoints.exception_breakpoints()) do
        if not bp.disabled then filters[#filters + 1] = bp.filter end
    end
    local params = { filters = filters }
    if self.capabilities.supportsExceptionOptions then
        local opts = {}
        for _, bp in ipairs(breakpoints.exception_name_breakpoints()) do
            if not bp.disabled then
                opts[#opts + 1] = { path = { { names = { bp.name } } }, breakMode = bp.break_mode }
            end
        end
        if #opts > 0 then params.exceptionOptions = opts end
    end
    return params
end

---@param cb fun()
function Session:_configure_exceptions(cb)
    local filter_defs = self.capabilities.exceptionBreakpointFilters or {}
    breakpoints.set_exception_filters(filter_defs)
    local params = self:_exception_bp_params()
    if #params.filters == 0 and not params.exceptionOptions then return cb() end
    self:request("setExceptionBreakpoints", params, function(_, err)
        if err then
            self:report("[dap] setExceptionBreakpoints failed: " .. err)
        end
        cb()
    end)
end

---@param cb fun()
function Session:_sync_source_breakpoints(cb)
    local sources = breakpoints.all_sources()
    if #sources == 0 then return cb() end
    local done = 0
    for _, source in ipairs(sources) do
        self:_sync_one_source(source, function()
            done = done + 1
            if done == #sources then cb() end
        end)
    end
end

---@param source string
---@param cb     fun()
function Session:_sync_one_source(source, cb)
    if source == "" then return cb() end
    local source_obj  = { path = source }
    local active_bps  = {}
    local active_req  = {}
    for _, bp in ipairs(breakpoints.for_source(source)) do
        if not bp.disabled then
            local entry = { line = bp.line }
            if bp.condition     then entry.condition   = bp.condition end
            if bp.hit_condition then entry.hitCondition = bp.hit_condition end
            if bp.log_message   then entry.logMessage   = bp.log_message end
            active_bps[#active_bps + 1] = bp
            active_req[#active_req + 1] = entry
        end
    end

    self:request("setBreakpoints", {
        source      = source_obj,
        breakpoints = active_req,
        lines       = vim.tbl_map(function(e) return e.line end, active_req),
    }, function(body, err)
        if err then
            self:report("[dap] setBreakpoints failed: " .. err)
        elseif body and body.breakpoints then
            local changed = false
            for i, upd in ipairs(body.breakpoints) do
                local bp = active_bps[i]
                if bp then
                    local prev = self._bp_status[bp.internal_id]
                    local st   = { verified = upd.verified, message = upd.message, hits = prev and prev.hits or 0 }
                    self._bp_status[bp.internal_id] = st
                    if upd.id then self._adapter_id_map[upd.id] = bp.internal_id end
                    changed = true
                    self:_emit("breakpoint_updated", bp, st)
                end
            end
            if changed then breakpoints.notify_change("source") end
        end
        cb()
    end)
end

---@param cb fun()
function Session:_sync_function_breakpoints(cb)
    self:sync_function_breakpoints(cb)
end

---@param cb fun()
function Session:_configuration_done(cb)
    if self:capable("supportsConfigurationDoneRequest") then
        self:request("configurationDone", {}, function(_, err)
            if err then
                self:report("[dap] configurationDone failed: " .. err)
            end
            cb()
        end)
    else
        cb()
    end
end

-- Full "initialized" sequence ──────

---@return nil
function Session:_on_initialized()
    self._initialized = true
    self:_set_state("initialized")
    self:_configure_exceptions(function()
        self:_sync_source_breakpoints(function()
            self:_sync_function_breakpoints(function()
                self:_configuration_done(function()
                    if self.config.defer_launch_attach then
                        self:_do_launch_or_attach(function()
                            self:_set_state("running")
                        end)
                    else
                        self:_set_state("running")
                    end
                end)
            end)
        end)
    end)
end

-- Thread / stack refresh ───────────────────────────────────────────────────

---@param cb fun()?
function Session:_update_threads(cb)
    self:request("threads", {}, function(body, err)
        if not err and body and body.threads then
            local updated = {}
            for _, nt in ipairs(body.threads) do
                local existing = self:_find_thread(nt.id)
                if existing then
                    existing.name = nt.name
                    updated[#updated + 1] = existing
                else
                    updated[#updated + 1] = { id = nt.id, name = nt.name, status = "running" }
                end
            end
            self.threads = updated
            if not self._thread_id and #self.threads > 0 then
                self._thread_id = self.threads[1].id
            end
        end
        self:_emit("thread_updated", self)
        if cb then cb() end
    end)
end

---@param thread easydap.dap.Thread?
---@param levels integer
---@param cb     fun()?
function Session:_fetch_stack_trace(thread, levels, cb)
    if not thread or thread.status ~= "stopped" then return cb and cb() end
    local current = thread.stack_frames and #thread.stack_frames or 0
    local total   = thread.total_frames
    if total and current >= total then return cb and cb() end

    local args = { threadId = thread.id }
    if self:capable("supportsDelayedStackTraceLoading") and current > 0 then
        args.startFrame = current
        args.levels     = levels - current
    end

    self:request("stackTrace", args, function(body, err)
        if not err and body and body.stackFrames then
            local frames = body.stackFrames
            if self:capable("supportsDelayedStackTraceLoading") and current > 0 then
                thread.stack_frames = vim.list_extend(thread.stack_frames or {}, frames)
            else
                thread.stack_frames = frames
            end
            if type(body.totalFrames) == "number" then
                thread.total_frames = body.totalFrames
            end
        end
        if cb then cb() end
    end)
end

---@param frame easydap.dap.StackFrame?
---@param cb    fun()?
function Session:_fetch_scopes(frame, cb)
    if not frame or frame.scopes then return cb and cb() end
    self:request("scopes", { frameId = frame.id }, function(body, err)
        if not err and body and body.scopes then
            frame.scopes = body.scopes
        end
        if cb then cb() end
    end)
end

-- Invalidate + re-fetch current thread's stack → scopes, then notify.
---@param invalidate "stack_frames"|"variables"|nil
---@param cb         fun()?
function Session:_update(invalidate, cb)
    if invalidate == "stack_frames" then
        for _, t in ipairs(self.threads) do
            t.stack_frames = nil
            t.total_frames = nil
        end
    elseif invalidate == "variables" then
        for _, t in ipairs(self.threads) do
            for _, f in ipairs(t.stack_frames or {}) do
                f.scopes = nil
            end
        end
    end
    local thread = self:current_thread()
    self:_fetch_stack_trace(thread, 1, function()
        local frame = self:current_stack_frame()
        self:_fetch_scopes(frame, function()
            self:_emit("state_changed", self)
            if cb then cb() end
        end)
    end)
end

-- ── Incoming events ────────────────────────────────────────────────────────

---@param event string
---@param body  table
function Session:_handle_event(event, body)
    if event == "initialized" then
        self:_on_initialized()
    elseif event == "stopped" then
        self:_on_stopped(body)
    elseif event == "continued" then
        self:_on_continued(body)
    elseif event == "output" then
        self:_on_output(body)
    elseif event == "thread" then
        self:_on_thread(body)
    elseif event == "module" then
        self:_on_module(body)
    elseif event == "loadedSource" then
        self:_on_loaded_source(body)
    elseif event == "breakpoint" then
        self:_on_breakpoint_event(body)
    elseif event == "process" then
        self:_on_process(body)
    elseif event == "exited" then
        self:_on_exited(body)
    elseif event == "terminated" then
        self:_on_terminated()
    elseif event == "capabilities" then
        if body and body.capabilities then
            self.capabilities = vim.tbl_extend("force", self.capabilities, body.capabilities)
            self:_configure_exceptions(function() end)
        end
    end
end

---@param body easydap.dap.proto.StoppedEventBody
function Session:_on_stopped(body)
    local tid         = body.threadId
    local reason      = body.reason
    local all_stopped = body.allThreadsStopped

    self:_set_state("stopped", reason)
    self:_select_thread(tid, true)
    self._stack_id              = nil
    self.exception_description = nil

    if reason == "exception" then
        local parts = {}
        if body.text then parts[#parts + 1] = body.text end
        if body.description then parts[#parts + 1] = body.description end
        local msg = table.concat(parts, ":\n\t") .. "\n"
        self.exception_description = msg
        self:_emit("output", "stderr", msg)
    end

    if body.hitBreakpointIds then
        for _, adapter_id in ipairs(body.hitBreakpointIds) do
            local bp_id = self._adapter_id_map[adapter_id]
            if bp_id then
                local st = self._bp_status[bp_id]
                if st then st.hits = st.hits + 1 end
            end
        end
    end

    self:_set_thread_status(tid, all_stopped, "stopped")
    self:_update_threads(function()
        self:_set_thread_status(tid, all_stopped, "stopped")
        self:_update("stack_frames", function()
            self:_emit("stopped", self)
        end)
    end)
end

---@param body easydap.dap.proto.ContinuedEventBody
function Session:_on_continued(body)
    local tid           = body.threadId
    local all_continued = body.allThreadsContinued
    if all_continued == nil then all_continued = true end
    self:_set_state("running")
    self:_select_thread(tid)
    self:_set_thread_status(tid, all_continued, "running")
    self:_emit("continued", self)
end

---@param body easydap.dap.proto.OutputEventBody
function Session:_on_output(body)
    local out = body.output
    if not out then return end
    local cat = body.category or "console"
    self:_emit("output", cat, out)
end

---@param body easydap.dap.proto.ThreadEventBody
function Session:_on_thread(body)
    local tid    = body.threadId
    local reason = body.reason
    self:_select_thread(tid)
    if reason == "started" then
        self:_set_state("running")
        self:_set_thread_status(tid, false, "running")
    elseif reason == "exited" then
        self:_set_thread_status(tid, false, "exited")
    end
    self:_update_threads(function()
        self:_emit("thread_updated", self)
    end)
end

---@param body easydap.dap.proto.ModuleEventBody
function Session:_on_module(body)
    local reason = body.reason
    local mod    = body.module
    if not mod then return end
    if reason == "new" then
        self._modules[#self._modules + 1] = mod
    elseif reason == "changed" then
        for i, m in ipairs(self._modules) do
            if m.id == mod.id then
                self._modules[i] = vim.tbl_extend("force", m, mod); break
            end
        end
    elseif reason == "removed" then
        for i, m in ipairs(self._modules) do
            if m.id == mod.id then
                table.remove(self._modules, i); break
            end
        end
    end
end

---@param body easydap.dap.proto.LoadedSourceEventBody
function Session:_on_loaded_source(body)
    local reason = body.reason
    local src    = body.source
    if not src then return end
    if reason == "new" then
        self._sources[#self._sources + 1] = src
    elseif reason == "changed" then
        for i, s in ipairs(self._sources) do
            if s.id == src.id then
                self._sources[i] = vim.tbl_extend("force", s, src); break
            end
        end
    elseif reason == "removed" then
        for i, s in ipairs(self._sources) do
            if s.id == src.id then
                table.remove(self._sources, i); break
            end
        end
    end
end

---@param body easydap.dap.proto.BreakpointEventBody
function Session:_on_breakpoint_event(body)
    local upd = body.breakpoint
    if not upd or not upd.id then return end
    local bp_id = self._adapter_id_map[upd.id]
    if not bp_id then return end
    local prev = self._bp_status[bp_id] or { hits = 0 }
    local st   = { verified = upd.verified, message = upd.message, hits = prev.hits }
    self._bp_status[bp_id] = st
    local bp = breakpoints.find_by_internal_id(bp_id)
    if bp then
        breakpoints.notify_change(bp.source and "source" or "function")
        self:_emit("breakpoint_updated", bp, st)
    end
end

---@param body easydap.dap.proto.ProcessEventBody
function Session:_on_process(body)
    local method = ((body.startMethod or "start") .. "ed"):gsub("^%l", string.upper)
    self:_set_state(body.startMethod or "started")
    self:_emit("output", "console", method .. " " .. (body.name or "") .. "\n")
end

---@param body easydap.dap.proto.ExitedEventBody
function Session:_on_exited(body)
    self:_set_state("exited")
    self:_emit("output", "console", "Exit code " .. tostring(body.exitCode) .. "\n")
end

---@return nil
function Session:_on_terminated()
    self:_set_state("terminated")
    self:_emit("terminated", self)
    self:_shutdown()
end

---@return nil
function Session:_on_close()
    local cb = self._stop_cb
    self._stop_cb = nil
    if self.state ~= "terminated" then
        self:_set_state("terminated")
        self:_emit("terminated", self)
    end
    if cb then cb() end
end

-- ── Adapter-initiated requests ─────────────────────────────────────────────

---@param command string
---@param args    table
---@param respond easydap.dap.RespondFn
function Session:_handle_adapter_request(command, args, respond)
    if command == "runInTerminal" then
        self:_run_in_terminal(args, respond)
    elseif command == "startDebugging" then
        local child_config = args.configuration
        if args.request then child_config.request = args.request end
        self:_emit("start_debugging", child_config, self)
        respond({})
    else
        respond(nil, "unsupported request: " .. command)
    end
end

---@param args    easydap.dap.proto.RunInTerminalRequestArguments
---@param respond easydap.dap.RespondFn
function Session:_run_in_terminal(args, respond)
    local term = require("easydap.util.term")
    local cmd  = args.args or {}
    if args.argsCanBeInterpretedByShell then
        cmd = { vim.o.shell, "-c", table.concat(cmd, " ") }
    end
    local handle
    local ok, err = pcall(function()
        handle = term.spawn(cmd, {
            cwd     = args.cwd,
            env     = args.env,
            on_exit = function() if handle then self:_emit("terminal_exit", handle.bufnr) end end,
        })
    end)
    if not ok or not handle then
        respond(nil, "failed to spawn terminal" .. (not ok and (": " .. tostring(err)) or ""))
        return
    end
    self:_emit("run_in_terminal", handle.bufnr)
    respond({ processId = handle.pid })
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────

---Start the DAP handshake (send initialize).
---@return nil
function Session:start()
    self:_set_state("starting")
    self:_do_initialize()
end

---@return nil
function Session:_shutdown()
    self.conn:close()
end

---Gracefully terminate the debug session.
---`cb` is always called exactly once, even if the adapter closes the
---connection before responding (via the _on_close path).
---A 3-second timeout forces _shutdown() for adapters that accept disconnect
---but never reply
---@param cb fun()?
function Session:stop(cb)
    if self.state == "terminated" or self._stopping then
        if cb then cb() end
        return
    end
    self._stopping = true
    -- Store cb so _on_close delivers it regardless of how termination happens.
    self._stop_cb = cb
    -- Not yet initialized — skip protocol, just kill the transport.
    if self.state == "starting" then
        self:_shutdown()
        return
    end
    local terminate_debuggee = (self.config.request or "launch") ~= "attach"
    -- Fallback: force-close if the adapter ignores the protocol request.
    local timer = vim.defer_fn(function()
        if self.state ~= "terminated" then self:_shutdown() end
    end, 3000)
    local function done()
        if not timer:is_closing() then timer:close() end
        self:_shutdown()
    end
    self:request("disconnect", { restart = false, terminateDebuggee = terminate_debuggee }, function()
        done()
    end)
end

---Ask the adapter to terminate the debuggee (requires supportsTerminateRequest).
---@param cb fun(err: string?)?
function Session:terminate_debuggee(cb)
    if not self:capable("supportsTerminateRequest") then
        if cb then cb("adapter does not support terminate") end
        return
    end
    self:request("terminate", {}, function(_, err)
        if cb then cb(err) end
    end)
end

---Disconnect without terminating the debuggee.
---@param cb fun()?
function Session:disconnect(cb)
    self:request("disconnect", { restart = false, terminateDebuggee = false }, function()
        self:_shutdown()
        if cb then cb() end
    end)
end

-- ── Control flow ───────────────────────────────────────────────────────────

---@param self        easydap.dap.Session
---@param command     string
---@param thread_id   integer?
---@param granularity easydap.dap.proto.SteppingGranularity?  defaults to "line"
local function _step_like(self, command, thread_id, granularity)
    thread_id = thread_id or self._thread_id
    local args = { threadId = thread_id }
    if self:capable("supportsSteppingGranularity") then
        args.granularity = granularity or "line"
    end
    self:request(command, args, function(_, err)
        if err then
            self:report(("[dap] %s failed: %s"):format(command, err))
            return
        end
        self:_on_continued({ threadId = thread_id --[[@as integer]], allThreadsContinued = false })
    end)
end

---@param thread_id integer?
function Session:continue(thread_id)
    thread_id = thread_id or self._thread_id
    self:request("continue", { threadId = thread_id }, function(body, err)
        if err then
            self:report("[dap] continue failed: " .. err)
            return
        end
        local all = (body and body.allThreadsContinued)
        if all == nil then all = true end
        self:_on_continued({ threadId = thread_id, allThreadsContinued = all })
    end)
end

---@param thread_id integer?
---@param granularity easydap.dap.proto.SteppingGranularity?
function Session:next(thread_id, granularity) _step_like(self, "next", thread_id, granularity) end

---@param thread_id integer?
---@param granularity easydap.dap.proto.SteppingGranularity?
function Session:step_in(thread_id, granularity) _step_like(self, "stepIn", thread_id, granularity) end

---@param thread_id integer?
---@param granularity easydap.dap.proto.SteppingGranularity?
function Session:step_out(thread_id, granularity) _step_like(self, "stepOut", thread_id, granularity) end

---@param thread_id integer?
---@param granularity easydap.dap.proto.SteppingGranularity?
function Session:step_back(thread_id, granularity)
    if not self:capable("supportsStepBack") then
        self:report("[dap] adapter does not support step back")
        return
    end
    _step_like(self, "stepBack", thread_id, granularity)
end

---@param thread_id integer?
function Session:pause(thread_id)
    thread_id = thread_id or self._thread_id or 0
    self:request("pause", { threadId = thread_id }, function(_, err)
        if err then self:report("[dap] pause failed: " .. err) end
    end)
end

---@return nil
function Session:restart()
    if not self:capable("supportsRestartRequest") then return end
    self.threads          = {}
    self._thread_id        = nil
    self._modules          = {}
    self._sources          = {}
    self._bp_status       = {}
    self._adapter_id_map  = {}
    self._instr_bps       = {}
    self._data_bps        = {}
    self:request("restart", { arguments = self:_protocol_args() }, function(_, err)
        if err then self:report("[dap] restart failed: " .. err) end
    end)
end

---Disassemble instructions around a memory reference.
---Stateless: disassembly is a query, not cached session state.
---@param ref    string   memoryReference (e.g. frame.instructionPointerReference)
---@param count  integer  instructionCount
---@param offset integer? instructionOffset (may be negative to fetch before ref)
---@param cb     fun(instructions: easydap.dap.proto.DisassembledInstruction[]?, err: string?)
function Session:disassemble(ref, count, offset, cb)
    if not self:capable("supportsDisassembleRequest") then
        return cb(nil, "adapter does not support disassemble")
    end
    self:request("disassemble", {
        memoryReference   = ref,
        instructionCount  = count,
        instructionOffset = offset,
        resolveSymbols    = true,
    }, function(body, err)
        cb(body and body.instructions, err)
    end)
end

---Instruction breakpoints currently set on this session, keyed by reference.
---Session-scoped: instruction references are only valid within a live session,
---so these are never persisted to the project store.
---@return table<string, easydap.dap.BpStatus> address -> verified status
function Session:instruction_breakpoints()
    return self._instr_bps
end

---Push the current instruction-breakpoint set to the adapter.
---DAP requires the full list on every call.
---@private
---@param cb fun(err: string?)?
function Session:_sync_instruction_breakpoints(cb)
    if not self:capable("supportsInstructionBreakpoints") then
        if cb then cb("adapter does not support instruction breakpoints") end
        return
    end
    local refs = vim.tbl_keys(self._instr_bps) ---@type string[]
    local args = vim.tbl_map(function(ref) return { instructionReference = ref } end, refs)
    self:request("setInstructionBreakpoints", { breakpoints = args }, function(body, err)
        if err then
            if cb then cb(err) end
            return
        end
        local results = body and body.breakpoints or {}
        for i, ref in ipairs(refs) do
            local bp = results[i]
            self._instr_bps[ref] = {
                verified = bp and bp.verified or false,
                message  = bp and bp.message,
                hits     = 0,
            }
        end
        self:_emit("instruction_breakpoints_changed", self)
        if cb then cb(nil) end
    end)
end

---Toggle an instruction breakpoint at the given reference (address).
---@param ref string  instructionReference (an instruction address)
---@param cb  fun(err: string?)?
function Session:toggle_instruction_breakpoint(ref, cb)
    if not self:capable("supportsInstructionBreakpoints") then
        self:report("[dap] adapter does not support instruction breakpoints")
        if cb then cb("unsupported") end
        return
    end
    if self._instr_bps[ref] then
        self._instr_bps[ref] = nil
    else
        self._instr_bps[ref] = { verified = false, hits = 0 }
    end
    self:_sync_instruction_breakpoints(cb)
end

-- ── Data breakpoints (watchpoints) ─────────────────────────────────────────

---Data breakpoints currently set on this session, in display order.
---Session-scoped: dataIds are only valid within a live session, so these are
---never persisted to the project store.
---@return easydap.dap.DataBreakpoint[]
function Session:data_breakpoints()
    return self._data_bps
end

---Resolve the dataId and supported access types for a data breakpoint on a
---variable or expression. Must be called while stopped (it scopes to the
---current frame when no container reference is given).
---@param name string                       variable name, or an expression
---@param variables_reference integer?       parent container reference (nil = expression in current frame)
---@param cb fun(body: easydap.dap.proto.DataBreakpointInfoResponseBody?, err: string?)
function Session:data_breakpoint_info(name, variables_reference, cb)
    if not self:capable("supportsDataBreakpoints") then
        return cb(nil, "adapter does not support data breakpoints")
    end
    local args = { name = name }
    if variables_reference and variables_reference > 0 then
        args.variablesReference = variables_reference
    else
        local frame = self:current_stack_frame()
        if frame then args.frameId = frame.id end
    end
    self:request("dataBreakpointInfo", args, cb)
end

---Add (or update) a data breakpoint with an already-resolved dataId, then push
---the full set to the adapter. Resolve `data_id` first via data_breakpoint_info.
---@param entry { data_id: string, name: string, access_type?: easydap.dap.proto.DataBreakpointAccessType, condition?: string, hit_condition?: string }
---@param cb fun(err: string?)?
function Session:add_data_breakpoint(entry, cb)
    if not self:capable("supportsDataBreakpoints") then
        self:report("[dap] adapter does not support data breakpoints")
        if cb then cb("unsupported") end
        return
    end
    for _, bp in ipairs(self._data_bps) do
        if bp.data_id == entry.data_id then
            bp.name          = entry.name
            bp.access_type   = entry.access_type
            bp.condition     = entry.condition
            bp.hit_condition = entry.hit_condition
            return self:_sync_data_breakpoints(cb)
        end
    end
    self._data_bps[#self._data_bps + 1] = {
        data_id       = entry.data_id,
        name          = entry.name,
        access_type   = entry.access_type,
        condition     = entry.condition,
        hit_condition = entry.hit_condition,
    }
    self:_sync_data_breakpoints(cb)
end

---Remove the data breakpoint with the given dataId and re-sync.
---@param data_id string
---@param cb fun(err: string?)?
function Session:remove_data_breakpoint(data_id, cb)
    for i, bp in ipairs(self._data_bps) do
        if bp.data_id == data_id then
            table.remove(self._data_bps, i)
            return self:_sync_data_breakpoints(cb)
        end
    end
    if cb then cb() end
end

---Enable/disable the data breakpoint with the given dataId and re-sync.
---Disabled breakpoints stay in the list but are dropped from the synced set.
---@param data_id string
---@param enabled boolean
---@param cb fun(err: string?)?
function Session:set_data_breakpoint_enabled(data_id, enabled, cb)
    for _, bp in ipairs(self._data_bps) do
        if bp.data_id == data_id then
            bp.disabled = not enabled
            return self:_sync_data_breakpoints(cb)
        end
    end
    if cb then cb() end
end

---Remove all data breakpoints and re-sync.
---@param cb fun(err: string?)?
function Session:clear_data_breakpoints(cb)
    if #self._data_bps == 0 then
        if cb then cb() end
        return
    end
    self._data_bps = {}
    self:_sync_data_breakpoints(cb)
end

---Push the current data-breakpoint set to the adapter.
---DAP requires the full list on every call; breakpoints not in the list are cleared.
---@private
---@param cb fun(err: string?)?
function Session:_sync_data_breakpoints(cb)
    if not self:capable("supportsDataBreakpoints") then
        if cb then cb("adapter does not support data breakpoints") end
        return
    end
    local active, list = {}, {}
    for _, bp in ipairs(self._data_bps) do
        if not bp.disabled then
            local entry = { dataId = bp.data_id }
            if bp.access_type   then entry.accessType   = bp.access_type end
            if bp.condition     then entry.condition    = bp.condition end
            if bp.hit_condition then entry.hitCondition = bp.hit_condition end
            active[#active + 1] = bp
            list[#list + 1]     = entry
        end
    end
    self:request("setDataBreakpoints", { breakpoints = list }, function(body, err)
        if err then
            self:report("[dap] setDataBreakpoints failed: " .. err)
        elseif body and body.breakpoints then
            for i, upd in ipairs(body.breakpoints) do
                local bp = active[i]
                if bp then
                    bp.verified = upd.verified
                    bp.message  = upd.message
                end
            end
        end
        self:_emit("data_breakpoints_changed", self)
        if cb then cb(err) end
    end)
end

-- ── Data fetching ──────────────────────────────────────────────────────────

---Evaluate an expression in the current frame.
---@param expr    string
---@param context easydap.dap.proto.EvaluateContext
---@param cb      fun(body: easydap.dap.proto.EvaluateResponseBody?, err: string?)
function Session:evaluate(expr, context, cb)
    local frame = self:current_stack_frame()
    local args  = { expression = expr, context = context }
    if frame and #self:stopped_threads() > 0 then
        args.frameId = frame.id
    end
    self:request("evaluate", args, cb)
end

---Fetch variables for a scope or variable object (populates .variables).
---@param object easydap.dap.Scope|easydap.dap.Variable
---@param cb     fun()?
function Session:fetch_variables(object, cb)
    local ref = object and object.variablesReference
    if not ref or ref == 0 or object.variables then
        return cb and cb()
    end
    self:request("variables", { variablesReference = ref }, function(body, _)
        if body and body.variables then object.variables = body.variables end
        if cb then cb() end
    end)
end

---Fetch more stack frames for a thread.
---@param thread easydap.dap.Thread
---@param levels integer
---@param cb     fun()?
function Session:fetch_stack_trace(thread, levels, cb)
    self:_fetch_stack_trace(thread, levels, cb)
end

---Fetch scopes for a frame.
---@param frame easydap.dap.StackFrame
---@param cb    fun()?
function Session:fetch_scopes(frame, cb)
    self:_fetch_scopes(frame, cb)
end

---Switch the active thread and refresh its stack trace + scopes.
---@param thread_id integer
function Session:select_thread(thread_id)
    self._thread_id = thread_id
    self._stack_id  = nil
    local t        = self:current_thread()
    if t then
        t.stack_frames = nil
        t.total_frames = nil
    end
    self:_update(nil, function()
        self:_emit("selection_changed", self)
    end)
end

---Switch the active stack frame and refresh its scopes.
---@param frame_id integer
function Session:select_frame(frame_id)
    self._stack_id = frame_id
    local frame = self:current_stack_frame()
    self:_fetch_scopes(frame, function()
        self:_emit("state_changed", self)
        self:_emit("selection_changed", self)
    end)
end

---@return nil
function Session:_invalidate_variable_cache()
    local frame = self:current_stack_frame()
    if frame and frame.scopes then
        for _, scope in ipairs(frame.scopes) do
            scope.variables = nil
        end
    end
end

---Set a variable's value.
---@param reference integer|nil  parent variablesReference (nil for expression-based)
---@param variable  easydap.dap.Variable
---@param value     string
---@param cb        fun(body: table?, err: string?)?
function Session:set_variable(reference, variable, value, cb)
    if self:capable("supportsSetVariable") and type(reference) == "number" then
        self:request("setVariable", {
            variablesReference = reference,
            name               = variable.name,
            value              = value,
        }, function(body, err)
            if err then
                self:report("[dap] setVariable failed: " .. err)
            else
                variable.variables = nil
                if body then for k, v in pairs(body) do variable[k] = v end end
                self:_invalidate_variable_cache()
                self:_emit("variable_changed")
            end
            if cb then cb(body, err) end
        end)
    elseif self:capable("supportsSetExpression") and (variable.evaluateName or variable.name) then
        local frame = self:current_stack_frame()
        self:request("setExpression", {
            frameId    = frame and frame.id,
            expression = variable.evaluateName or variable.name,
            value      = value,
        }, function(body, err)
            if err then
                self:report("[dap] setExpression failed: " .. err)
            else
                self:_invalidate_variable_cache()
                self:_emit("variable_changed")
            end
            if cb then cb(body, err) end
        end)
    else
        self:report("[dap] unable to set variable: adapter lacks capability")
    end
end

---Retrieve a virtual source by reference, returning a buffer number.
---The buffer is created once and cached.
---@param ref integer  sourceReference
---@param cb  fun(bufnr: integer?, err: string?)
function Session:get_source_buffer(ref, cb)
    local existing = self._source_buffers[ref]
    if existing and vim.api.nvim_buf_is_valid(existing) then
        return cb(existing)
    end
    self:request("source", {
        source          = { sourceReference = ref },
        sourceReference = ref,
    }, function(body, err)
        if err or not body then return cb(nil, err) end
        local buf   = vim.api.nvim_create_buf(false, true)
        local lines = vim.split(body.content or "", "\n", { plain = true })
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        vim.api.nvim_set_option_value("modifiable", false, { buf = buf })
        local mime_ft = { ["text/javascript"] = "javascript", ["text/x-lldb.disassembly"] = "asm" }
        local ft = mime_ft[body.mimeType or ""]
        if ft then vim.api.nvim_set_option_value("filetype", ft, { buf = buf }) end
        self._source_buffers[ref] = buf
        cb(buf)
    end)
end

---Request REPL completions from the adapter for the given text.
---@param text     string
---@param column   integer   1-based cursor column
---@param frame_id integer?
---@param cb       fun(targets: easydap.dap.proto.CompletionItem[])
function Session:completions(text, column, frame_id, cb)
    if not self:capable("supportsCompletionsRequest") then
        cb({})
        return
    end
    local args = { text = text, column = column }
    if frame_id then args.frameId = frame_id end
    self:request("completions", args, function(body, err)
        cb(not err and body and body.targets or {})
    end)
end

---Re-sync breakpoints for a specific source (or all sources) to the adapter.
---@param source string|nil  filepath, or nil for all
---@param cb     fun()?
function Session:sync_breakpoints(source, cb)
    if source then
        self:_sync_one_source(source, cb or function() end)
    else
        self:_sync_source_breakpoints(cb or function() end)
    end
end

---Re-sync function breakpoints to the adapter.
---@param cb fun()?
function Session:sync_function_breakpoints(cb)
    if not self:capable("supportsFunctionBreakpoints") then
        if cb then cb() end
        return
    end
    local active = {}
    for _, bp in ipairs(breakpoints.function_breakpoints()) do
        if not bp.disabled then active[#active + 1] = bp end
    end
    local list = {}
    for _, bp in ipairs(active) do list[#list + 1] = { name = bp.name } end
    self:request("setFunctionBreakpoints", { breakpoints = list }, function(body, err)
        if err then
            self:report("[dap] setFunctionBreakpoints failed: " .. err)
        elseif body and body.breakpoints then
            local changed = false
            for i, upd in ipairs(body.breakpoints) do
                local bp = active[i]
                if bp then
                    local prev = self._bp_status[bp.internal_id]
                    local st   = { verified = upd.verified, message = upd.message, hits = prev and prev.hits or 0 }
                    self._bp_status[bp.internal_id] = st
                    if upd.id then self._adapter_id_map[upd.id] = bp.internal_id end
                    changed = true
                    self:_emit("breakpoint_updated", bp, st)
                end
            end
            if changed then breakpoints.notify_change("function") end
        end
        if cb then cb() end
    end)
end

---Return this session's adapter-verified status for a breakpoint.
---@param bp_id integer  internal stable id (bp.internal_id)
---@return easydap.dap.BpStatus?
function Session:bp_status(bp_id)
    return self._bp_status[bp_id]
end

---Re-sync exception breakpoints to the adapter.
---@param cb fun()?
function Session:sync_exception_breakpoints(cb)
    local params = self:_exception_bp_params()
    self:request("setExceptionBreakpoints", params, function(_, err)
        if err then
            self:report("[dap] setExceptionBreakpoints failed: " .. err)
        end
        if cb then cb() end
    end)
end

return M
