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
---  "breakpoint_updated"(bp)                       — bp verified/message changed
---  "terminated"        (session)                  — session ended
---  "run_in_terminal"   (bufnr)                    — terminal buffer opened
---  "start_debugging"   (child_config, parent_sess)— adapter requests child session

local breakpoints = require("easydap.breakpoints")

---@class easydap.Thread
---@field id           integer
---@field name         string
---@field status       "running"|"stopped"|"exited"
---@field stack_frames table[]?
---@field total_frames integer?

---@class easydap.StackFrame
---@field id                        integer
---@field name                      string
---@field source                    table?
---@field line                      integer?
---@field column                    integer?
---@field scopes                    table[]?
---@field instructionPointerReference string?

---@class easydap.Session
---@field conn          easydap.Connection
---@field config        easydap.Config
---@field state         string
---@field state_reason  string?
---@field capabilities  table
---@field initialized   boolean
---@field threads       easydap.Thread[]
---@field thread_id     integer?
---@field stack_id      integer?
---@field exception_description string?
---@field modules       table[]
---@field sources       table[]
---@field source_buffers table<integer,integer>   sourceReference -> bufnr
---@field on            fun(self: easydap.Session, event: string, handler: fun(...))
---@field start         fun(self: easydap.Session)
---@field stop          fun(self: easydap.Session, cb: fun()?)
---@field disconnect    fun(self: easydap.Session, cb: fun()?)
---@field continue      fun(self: easydap.Session, thread_id: integer?)
---@field next          fun(self: easydap.Session, thread_id: integer?)
---@field step_in       fun(self: easydap.Session, thread_id: integer?)
---@field step_out      fun(self: easydap.Session, thread_id: integer?)
---@field pause         fun(self: easydap.Session, thread_id: integer?)
---@field step_back     fun(self: easydap.Session, thread_id: integer?)
---@field restart       fun(self: easydap.Session)
---@field evaluate      fun(self: easydap.Session, expr: string, context: string, cb: fun(body: table?, err: string?))
---@field request       fun(self: easydap.Session, command: string, args: table?, cb: fun(body: table?, err: string?)?)
---@field capable       fun(self: easydap.Session, name: string): boolean
---@field current_thread      fun(self: easydap.Session): easydap.Thread?
---@field current_stack_frame fun(self: easydap.Session): easydap.StackFrame?
---@field stopped_threads     fun(self: easydap.Session): easydap.Thread[]
---@field fetch_variables     fun(self: easydap.Session, object: table, cb: fun()?)
---@field fetch_stack_trace   fun(self: easydap.Session, thread: easydap.Thread, levels: integer, cb: fun()?)
---@field fetch_scopes        fun(self: easydap.Session, frame: easydap.StackFrame, cb: fun()?)
---@field set_variable        fun(self: easydap.Session, reference: integer?, variable: table, value: string, cb: fun(body: table?, err: string?)?)
---@field get_source_buffer   fun(self: easydap.Session, ref: integer, cb: fun(bufnr: integer?, err: string?))
---@field sync_breakpoints              fun(self: easydap.Session, source: integer|string|nil, cb: fun()?)
---@field sync_function_breakpoints    fun(self: easydap.Session, cb: fun()?)
---@field sync_exception_breakpoints   fun(self: easydap.Session, cb: fun()?)
---@field completions                  fun(self: easydap.Session, text: string, column: integer, frame_id: integer?, cb: fun(targets: table[]))
---@field select_thread                fun(self: easydap.Session, thread_id: integer)
---@field select_frame                 fun(self: easydap.Session, frame_id: integer)
---@field report                  fun(self: easydap.Session, msg: string)
---@field _emit                    fun(self: easydap.Session, event: string, ...)
---@field _handle_event            fun(self: easydap.Session, event: string, body: table)
---@field _handle_adapter_request  fun(self: easydap.Session, command: string, args: table, respond: easydap.RespondFn)
---@field _on_close                fun(self: easydap.Session)

local M = {}

local _Session = {}
_Session.__index = _Session

---@param conn   easydap.Connection
---@param config easydap.Config
---@return easydap.Session
function M.new(conn, config)
    ---@type easydap.Session
    local self      = setmetatable({
        conn                  = conn,
        config                = config,
        state                 = "starting",
        state_reason          = nil,
        capabilities          = {},
        initialized           = false,
        threads               = {},
        thread_id             = nil,
        stack_id              = nil,
        exception_description = nil,
        modules               = {},
        sources               = {},
        source_buffers        = {},
        _listeners            = {},
        report                = function(_, msg) vim.notify(msg, vim.log.levels.WARN) end,
    }, _Session)

    conn.on_event   = function(event, body) self:_handle_event(event, body) end
    conn.on_request = function(cmd, args, respond) self:_handle_adapter_request(cmd, args, respond) end
    conn.on_close   = function() self:_on_close() end

    return self
end

-- ── Listener helpers ───────────────────────────────────────────────────────

function _Session:on(event, handler)
    self._listeners[event] = self._listeners[event] or {}
    table.insert(self._listeners[event], handler)
end

function _Session:_emit(event, ...)
    for _, h in ipairs(self._listeners[event] or {}) do
        pcall(h, ...)
    end
end

-- ── State helpers ──────────────────────────────────────────────────────────

---@param state  string
---@param reason string?
function _Session:_set_state(state, reason)
    self.state        = state
    self.state_reason = reason
    self:_emit("state_changed", self)
end

---@param name string  capability key e.g. "supportsRestartRequest"
---@return boolean
function _Session:capable(name)
    return self.capabilities[name] == true
end

-- ── Thread helpers ─────────────────────────────────────────────────────────

---@param id integer?
---@return easydap.Thread?
function _Session:_find_thread(id)
    for _, t in ipairs(self.threads) do
        if t.id == id then return t end
    end
end

---@param id     integer?
---@param status "running"|"stopped"|"exited"
function _Session:_upsert_thread(id, status)
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
---@param all_threads boolean
---@param status     "running"|"stopped"|"exited"
function _Session:_set_thread_status(thread_id, all_threads, status)
    if all_threads then
        for _, t in ipairs(self.threads) do t.status = status end
    else
        self:_upsert_thread(thread_id, status)
    end
end

---@param id    integer?
---@param force boolean?
function _Session:_select_thread(id, force)
    if id and (force or not self.thread_id) then
        self.thread_id = id
    end
end

---@return easydap.Thread[]
function _Session:stopped_threads()
    local r = {}
    for _, t in ipairs(self.threads) do
        if t.status == "stopped" then r[#r + 1] = t end
    end
    return r
end

---@return easydap.Thread?
function _Session:current_thread()
    return self:_find_thread(self.thread_id)
end

---@return easydap.StackFrame?
function _Session:current_stack_frame()
    local thread = self:current_thread()
    if not thread or not thread.stack_frames then return end
    if self.stack_id then
        for _, f in ipairs(thread.stack_frames) do
            if f.id == self.stack_id then return f end
        end
    end
    return thread.stack_frames[1]
end

-- ── Outgoing requests ──────────────────────────────────────────────────────

---Low-level request, forwarded to the connection.
---@param command string
---@param args    table?
---@param cb      fun(body: table?, err: string?)?
function _Session:request(command, args, cb)
    self.conn:request(command, args, cb)
end

function _Session:_do_initialize()
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

function _Session:_do_launch_or_attach()
    local req_type = self.config.request or "launch"
    self:request(req_type, self:_protocol_args(), function(_, err)
        if err then
            self:report(("[dap] %s failed: %s"):format(req_type, err))
            self:_shutdown()
        end
    end)
end

---@return table
function _Session:_protocol_args()
    local args = {}
    for k, v in pairs(self.config.request_args or {}) do
        args[k] = (v == false) and vim.NIL or v
    end
    return args
end

-- Breakpoint sync chain ────────────────────────────────────────────────────

---@return table  params for setExceptionBreakpoints
function _Session:_exception_bp_params()
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

function _Session:_configure_exceptions(cb)
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

function _Session:_sync_source_breakpoints(cb)
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

function _Session:_sync_one_source(source, cb)
    if source == "" then return cb() end
    local bps = breakpoints.for_source(source)
    local source_obj = { path = source }

    local active = {}
    for _, bp in ipairs(bps) do
        if not bp.disabled then
            local entry = { line = bp.line }
            if bp.condition then entry.condition = bp.condition end
            if bp.hit_condition then entry.hitCondition = bp.hit_condition end
            if bp.log_message then entry.logMessage = bp.log_message end
            active[#active + 1] = entry
        end
    end

    self:request("setBreakpoints", {
        source      = source_obj,
        breakpoints = active,
        lines       = vim.tbl_map(function(e) return e.line end, active),
    }, function(body, err)
        if err then
            self:report("[dap] setBreakpoints failed: " .. err)
        elseif body and body.breakpoints then
            local changed = false
            for i, upd in ipairs(body.breakpoints) do
                local bp = bps[i]
                if bp then
                    bp.verified = upd.verified
                    bp.id       = upd.id
                    bp.message  = upd.message
                    changed     = true
                    self:_emit("breakpoint_updated", bp)
                end
            end
            if changed then breakpoints.notify_change("source") end
        end
        cb()
    end)
end

function _Session:_sync_function_breakpoints(cb)
    self:sync_function_breakpoints(cb)
end

function _Session:_configuration_done(cb)
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

-- Full "initialized" sequence ──────────────────────────────────────────────

function _Session:_on_initialized()
    self.initialized = true
    self:_set_state("initialized")
    self:_configure_exceptions(function()
        self:_sync_source_breakpoints(function()
            self:_sync_function_breakpoints(function()
                self:_configuration_done(function()
                    if self.config.defer_launch_attach then
                        self:_do_launch_or_attach()
                    end
                end)
            end)
        end)
    end)
end

-- Thread / stack refresh ───────────────────────────────────────────────────

function _Session:_update_threads(cb)
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
            if not self.thread_id and #self.threads > 0 then
                self.thread_id = self.threads[1].id
            end
        end
        self:_emit("thread_updated", self)
        if cb then cb() end
    end)
end

function _Session:_fetch_stack_trace(thread, levels, cb)
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

function _Session:_fetch_scopes(frame, cb)
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
function _Session:_update(invalidate, cb)
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

function _Session:_handle_event(event, body)
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

function _Session:_on_stopped(body)
    local tid         = body.threadId
    local reason      = body.reason
    local all_stopped = body.allThreadsStopped

    self:_set_state("stopped", reason)
    self:_select_thread(tid, true)
    self.stack_id              = nil
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
        for _, id in ipairs(body.hitBreakpointIds) do
            local bp = breakpoints.find_by_id(id)
            if bp then bp.hits = (bp.hits or 0) + 1 end
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

function _Session:_on_continued(body)
    local tid           = body.threadId
    local all_continued = body.allThreadsContinued
    if all_continued == nil then all_continued = true end
    self:_set_state("running")
    self:_select_thread(tid)
    self:_set_thread_status(tid, all_continued, "running")
    self:_emit("continued", self)
end

function _Session:_on_output(body)
    local out = body.output
    if not out then return end
    local cat = body.category or "console"
    self:_emit("output", cat, out)
end

function _Session:_on_thread(body)
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

function _Session:_on_module(body)
    local reason = body.reason
    local mod    = body.module
    if not mod then return end
    if reason == "new" then
        self.modules[#self.modules + 1] = mod
    elseif reason == "changed" then
        for i, m in ipairs(self.modules) do
            if m.id == mod.id then
                self.modules[i] = vim.tbl_extend("force", m, mod); break
            end
        end
    elseif reason == "removed" then
        for i, m in ipairs(self.modules) do
            if m.id == mod.id then
                table.remove(self.modules, i); break
            end
        end
    end
end

function _Session:_on_loaded_source(body)
    local reason = body.reason
    local src    = body.source
    if not src then return end
    if reason == "new" then
        self.sources[#self.sources + 1] = src
    elseif reason == "changed" then
        for i, s in ipairs(self.sources) do
            if s.id == src.id then
                self.sources[i] = vim.tbl_extend("force", s, src); break
            end
        end
    elseif reason == "removed" then
        for i, s in ipairs(self.sources) do
            if s.id == src.id then
                table.remove(self.sources, i); break
            end
        end
    end
end

function _Session:_on_breakpoint_event(body)
    local upd = body.breakpoint
    if not upd or not upd.id then return end
    local bp = breakpoints.find_by_id(upd.id)
    if bp then
        bp.verified = upd.verified
        bp.message  = upd.message
        breakpoints.notify_change(bp.source and "source" or "function")
        self:_emit("breakpoint_updated", bp)
    end
end

function _Session:_on_process(body)
    local method = ((body.startMethod or "start") .. "ed"):gsub("^%l", string.upper)
    self:_set_state(body.startMethod or "started")
    self:_emit("output", "console", method .. " " .. (body.name or "") .. "\n")
end

function _Session:_on_exited(body)
    self:_set_state("exited")
    self:_emit("output", "console", "Exit code " .. tostring(body.exitCode) .. "\n")
end

function _Session:_on_terminated()
    self:_set_state("terminated")
    self:_emit("terminated", self)
    self:_shutdown()
end

function _Session:_on_close()
    if self.state ~= "terminated" then
        self:_set_state("terminated")
        self:_emit("terminated", self)
    end
end

-- ── Adapter-initiated requests ─────────────────────────────────────────────

function _Session:_handle_adapter_request(command, args, respond)
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

function _Session:_run_in_terminal(args, respond)
    local cmd = args.args or {}
    local cwd = args.cwd
    local env_list = {}
    if args.env then
        for k, v in pairs(args.env) do
            env_list[#env_list + 1] = k .. "=" .. v
        end
    end

    local buf = vim.api.nvim_create_buf(false, true)
    local pid
    vim.api.nvim_buf_call(buf, function()
        local run_cmd = cmd
        if args.argsCanBeInterpretedByShell then
            run_cmd = { vim.o.shell, "-c", table.concat(cmd, " ") }
        end
        local job = vim.fn.jobstart(run_cmd, {
            term    = true,
            cwd     = cwd,
            env     = #env_list > 0 and env_list or nil,
            on_exit = function() self:_emit("terminal_exit", buf) end,
        })
        if job and job > 0 then pid = vim.fn.jobpid(job) end
    end)
    self:_emit("run_in_terminal", buf)
    respond({ processId = pid })
end

-- ── Lifecycle ──────────────────────────────────────────────────────────────

---Start the DAP handshake (send initialize).
function _Session:start()
    self:_set_state("starting")
    self:_do_initialize()
end

function _Session:_shutdown()
    self.conn:close()
end

---Gracefully terminate the debug session.
---@param cb fun()?
function _Session:stop(cb)
    if self:capable("supportsTerminateRequest") then
        self:request("terminate", {}, function(_, err)
            if err then
                self:request("disconnect", { restart = false, terminateDebuggee = true }, function()
                    self:_shutdown()
                    if cb then cb() end
                end)
            else
                self:_shutdown()
                if cb then cb() end
            end
        end)
    else
        self:request("disconnect", { restart = false, terminateDebuggee = true }, function()
            self:_shutdown()
            if cb then cb() end
        end)
    end
end

---Disconnect without terminating the debuggee.
---@param cb fun()?
function _Session:disconnect(cb)
    self:request("disconnect", { restart = false, terminateDebuggee = false }, function()
        self:_shutdown()
        if cb then cb() end
    end)
end

-- ── Control flow ───────────────────────────────────────────────────────────

local function _step_like(self, command, thread_id)
    thread_id = thread_id or self.thread_id
    local args = { threadId = thread_id }
    if self:capable("supportsSteppingGranularity") then
        args.granularity = "line"
    end
    self:request(command, args, function(_, err)
        if err then
            self:report(("[dap] %s failed: %s"):format(command, err))
            return
        end
        self:_on_continued({ threadId = thread_id, allThreadsContinued = false })
    end)
end

function _Session:continue(thread_id)
    thread_id = thread_id or self.thread_id
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

function _Session:next(thread_id) _step_like(self, "next", thread_id) end

function _Session:step_in(thread_id) _step_like(self, "stepIn", thread_id) end

function _Session:step_out(thread_id) _step_like(self, "stepOut", thread_id) end

function _Session:step_back(thread_id)
    if not self:capable("supportsStepBack") then
        self:report("[dap] adapter does not support step back")
        return
    end
    _step_like(self, "stepBack", thread_id)
end

function _Session:pause(thread_id)
    thread_id = thread_id or self.thread_id or 0
    self:request("pause", { threadId = thread_id }, function(_, err)
        if err then self:report("[dap] pause failed: " .. err) end
    end)
end

function _Session:restart()
    if not self:capable("supportsRestartRequest") then return end
    self.threads   = {}
    self.thread_id = nil
    self.modules   = {}
    self.sources   = {}
    self:request("restart", { arguments = self:_protocol_args() }, function(_, err)
        if err then self:report("[dap] restart failed: " .. err) end
    end)
end

-- ── Data fetching ──────────────────────────────────────────────────────────

---Evaluate an expression in the current frame.
---@param expr    string
---@param context string  "watch"|"repl"|"hover"|"clipboard"
---@param cb      fun(body: table?, err: string?)
function _Session:evaluate(expr, context, cb)
    local frame = self:current_stack_frame()
    local args  = { expression = expr, context = context }
    if frame and #self:stopped_threads() > 0 then
        args.frameId = frame.id
    end
    self:request("evaluate", args, cb)
end

---Fetch variables for a scope or variable object (populates .variables).
---@param object table  must have .variablesReference
---@param cb     fun()?
function _Session:fetch_variables(object, cb)
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
---@param thread easydap.Thread
---@param levels integer
---@param cb     fun()?
function _Session:fetch_stack_trace(thread, levels, cb)
    self:_fetch_stack_trace(thread, levels, cb)
end

---Fetch scopes for a frame.
---@param frame easydap.StackFrame
---@param cb    fun()?
function _Session:fetch_scopes(frame, cb)
    self:_fetch_scopes(frame, cb)
end

---Switch the active thread and refresh its stack trace + scopes.
---@param thread_id integer
function _Session:select_thread(thread_id)
    self.thread_id = thread_id
    self.stack_id  = nil
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
function _Session:select_frame(frame_id)
    self.stack_id = frame_id
    local frame = self:current_stack_frame()
    self:_fetch_scopes(frame, function()
        self:_emit("state_changed", self)
        self:_emit("selection_changed", self)
    end)
end

---Set a variable's value.
---@param reference integer|nil  parent variablesReference (nil for expression-based)
---@param variable  table
---@param value     string
---@param cb        fun(body: table?, err: string?)?
function _Session:set_variable(reference, variable, value, cb)
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
            if err then self:report("[dap] setExpression failed: " .. err) end
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
function _Session:get_source_buffer(ref, cb)
    local existing = self.source_buffers[ref]
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
        self.source_buffers[ref] = buf
        cb(buf)
    end)
end

---Request REPL completions from the adapter for the given text.
---@param text     string
---@param column   integer   1-based cursor column
---@param frame_id integer?
---@param cb       fun(targets: table[])
function _Session:completions(text, column, frame_id, cb)
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
---@param source integer|string|nil  bufnr, filepath, or nil for all
---@param cb     fun()?
function _Session:sync_breakpoints(source, cb)
    if source then
        self:_sync_one_source(source, cb or function() end)
    else
        self:_sync_source_breakpoints(cb or function() end)
    end
end

---Re-sync function breakpoints to the adapter.
---@param cb fun()?
function _Session:sync_function_breakpoints(cb)
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
                    bp.verified = upd.verified
                    bp.id       = upd.id
                    bp.message  = upd.message
                    changed     = true
                    self:_emit("breakpoint_updated", bp)
                end
            end
            if changed then breakpoints.notify_change("function") end
        end
        if cb then cb() end
    end)
end

---Re-sync exception breakpoints to the adapter.
---@param cb fun()?
function _Session:sync_exception_breakpoints(cb)
    local params = self:_exception_bp_params()
    self:request("setExceptionBreakpoints", params, function(_, err)
        if err then
            self:report("[dap] setExceptionBreakpoints failed: " .. err)
        end
        if cb then cb() end
    end)
end

return M
