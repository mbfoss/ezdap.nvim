---@brief High-level DAP client.
---Manages session lifecycle: spawning adapters, TCP retry, session tracking,
---and exposes signals for session state changes.

local connection       = require("easydap.connection")
local session_mod      = require("easydap.session")
local configs          = require("easydap.configs")
local Signal           = require("easydap.util.Signal")
local async            = require("easydap.util.async")

local M                = {}

---@class easydap.SessionInfo
---@field id number
---@field name string
---@field state string
---@field is_paused boolean
---@field nb_paused_threads integer

---@class easydap.StartOpts
---@field on_event?    fun(event:string, ...)
---@field on_session?  fun(id:number, sess:easydap.Session)
---@field on_progress? fun(message: string)
---@field on_bufnr?    fun(bufnr: integer, label?: string, priority?: integer)
---@field on_fail?     fun()

-- ── Signals ────────────────────────────────────────────────────────────────

---Fires when a session is registered: (id, sess, info)
M.on_session_added     = Signal.new() ---@type easydap.util.Signal<fun(id:number, sess:easydap.Session, info:easydap.SessionInfo)>
---Fires when a session terminates: (id)
M.on_session_removed   = Signal.new() ---@type easydap.util.Signal<fun(id:number)>
---Fires when a session's state changes: (id, info)
M.on_session_updated   = Signal.new() ---@type easydap.util.Signal<fun(id:number, info:easydap.SessionInfo)>
---Fires when the active (stepping) session changes: (id?, sess?)
M.on_active_changed    = Signal.new() ---@type easydap.util.Signal<fun(id:number?, sess:easydap.Session?)>
---Fires once per stop, after threads and stack frames have been fetched: (id, info)
M.on_session_stopped   = Signal.new() ---@type easydap.util.Signal<fun(id:number, info:easydap.SessionInfo)>
---Fires for every raw DAP message: (id, direction, msg)
M.on_raw_message       = Signal.new() ---@type easydap.util.Signal<fun(id:number, direction:"in"|"out", msg:table)>
---Fires when thread or frame selection changes in the active session: (id, sess)
M.on_selection_changed = Signal.new() ---@type easydap.util.Signal<fun(id:number, sess:easydap.Session)>

-- ── Session registry ───────────────────────────────────────────────────────

---@type table<number, easydap.Session>
local _sessions        = {}
---@type number?
local _active_id       = nil
local _next_id         = 1
local _start_counter   = 0

---@param id number
---@param sess easydap.Session
---@return easydap.SessionInfo
local function _session_info(id, sess)
    local n = 0
    for _, t in ipairs(sess.threads) do
        if t.status == "stopped" then n = n + 1 end
    end
    return {
        id                = id,
        name              = sess.config.adapter or "debug",
        state             = sess.state,
        is_paused         = sess.state == "stopped",
        nb_paused_threads = n,
    }
end

---Set the active (stepping) session, emitting on_active_changed only on change.
---@param id number?
local function _set_active(id)
    if _active_id == id then return end
    _active_id = id
    M.on_active_changed:emit(id, id and _sessions[id] or nil)
end

---@return easydap.Session?
function M.session()
    return _active_id and _sessions[_active_id] or nil
end

---@return number?
function M.active_id()
    return _active_id
end

---@param id number
---@return easydap.Session?
function M.get_session(id)
    return _sessions[id]
end

---@return table<number, easydap.Session>
function M.sessions()
    return _sessions
end

-- ── Setup / teardown hooks ─────────────────────────────────────────────────

---Run config.setup via async.go (no-op if absent).
---setup(config, setup_ctx) may yield a waker-registration fn; whatever it returns is passed to teardown.
---cb(config, ctx) on success; cb(nil, nil) on error.
---@param config    easydap.Config
---@param setup_ctx easydap.SetupCtx
---@param cb        fun(config: easydap.Config?, ctx: any)
local function _run_setup(config, setup_ctx, cb)
    if not config.setup then return cb(config, nil) end
    setup_ctx.report("setup: starting")
    async.go(config.setup, function(ok, result)
        if not ok then
            vim.notify("[dap] setup failed: " .. tostring(result), vim.log.levels.ERROR)
            setup_ctx.report("setup failed: " .. tostring(result))
            cb(nil, nil)
        else
            setup_ctx.report("setup: ready")
            cb(config, result)
        end
    end, config, setup_ctx)
end

---@param config easydap.Config
---@param ctx    any  value returned by setup (nil if setup absent or returned nothing)
local function _run_teardown(config, ctx)
    if config.teardown then pcall(config.teardown, config, ctx) end
end

-- ── Config preparation ─────────────────────────────────────────────────────

---@param config easydap.Config
---@return easydap.Config?
local function _prepare_config(config)
    config = vim.deepcopy(config)
    config = configs.eval(config)
    return config
end

-- ── Session registration ───────────────────────────────────────────────────

---@param sess     easydap.Session
---@param ctx      any  value returned by setup, forwarded to teardown
---@param opts     easydap.StartOpts
---@param progress fun(msg: string)
local function _register_session(sess, ctx, opts, progress)
    local id                 = _next_id
    _next_id                 = _next_id + 1
    _sessions[id]            = sess

    local on_event           = opts.on_event
    local on_session         = opts.on_session

    -- forward raw messages to the global signal
    sess.conn.on_raw_message = function(direction, msg)
        M.on_raw_message:emit(id, direction, msg)
    end

    -- wire all events to on_event callback
    local ALL_EVENTS         = {
        "state_changed", "output", "stopped", "continued",
        "thread_updated", "terminated", "breakpoint_updated",
        "run_in_terminal", "start_debugging",
    }
    if on_event then
        for _, ev in ipairs(ALL_EVENTS) do
            local name = ev
            sess:on(name, function(...) on_event(name, ...) end)
        end
    end

    -- emit updated info on any state change
    sess:on("state_changed", function()
        M.on_session_updated:emit(id, _session_info(id, sess))
    end)

    -- auto-promote to active on stop; update info on continue
    sess:on("stopped", function()
        _set_active(id)
        local info = _session_info(id, sess)
        M.on_session_updated:emit(id, info)
        M.on_session_stopped:emit(id, info)
    end)
    sess:on("continued", function()
        M.on_session_updated:emit(id, _session_info(id, sess))
    end)
    sess:on("selection_changed", function()
        if id == _active_id then
            M.on_selection_changed:emit(id, sess)
        end
    end)

    -- propagate child sessions, forwarding on_event but not on_session
    sess:on("start_debugging", function(child_config, _parent)
        local child_opts = { on_event = on_event, on_fail = opts.on_fail }
        if sess.config.port then
            -- TCP adapter (e.g. js-debug): child connects to the same server instance
            M.start({
                host         = sess.config.host,
                port         = sess.config.port,
                request      = child_config.request or "attach",
                request_args = child_config,
            }, child_opts)
        else
            M.start(child_config, child_opts)
        end
    end)

    sess:on("terminated", function()
        _run_teardown(sess.config, ctx)
        _sessions[id] = nil
        if _active_id == id then
            local new_id
            for k in pairs(_sessions) do
                new_id = k; break
            end
            _set_active(new_id)
        end
        M.on_session_removed:emit(id)
    end)

    sess.report = function(_, msg) progress(msg) end
    sess.conn.on_stderr = function(line) progress("[dap stderr] " .. line) end

    progress("session started (id " .. id .. ")")
    M.on_session_added:emit(id, sess, _session_info(id, sess))
    _set_active(id)
    if on_session then on_session(id, sess) end
end

-- ── Session startup ────────────────────────────────────────────────────────

---Start a debug session.
---
---`config` may be a named string (looked up via configs.get) or a config table.
---`opts.on_event(event_name, ...)` receives all session events.
---`opts.on_session(id, sess)` fires once the session object is available.
---`opts.on_fail()` fires if the adapter connection cannot be established.
---
---@param config string|table
---@param opts? easydap.StartOpts
function M.start(config, opts)
    opts = opts or {}

    _start_counter = _start_counter + 1
    local start_id = _start_counter
    local function progress(msg)
        if opts.on_progress then opts.on_progress(msg) end
    end

    if type(config) == "string" then
        local named = configs.get(config)
        if not named then
            progress("[dap] unknown adapter config: " .. config)
            progress("unknown adapter config: " .. config)
            if opts.on_fail then opts.on_fail() end
            return start_id
        end
        config = named
    end

    local cfg = _prepare_config(config --[[@as table]])
    if not cfg then
        if opts.on_fail then opts.on_fail() end
        return start_id
    end

    progress("config resolved: " .. vim.inspect(cfg))

    local setup_ctx = {
        report    = progress,
        add_bufnr = function(bufnr, label, priority)
            if opts.on_bufnr then opts.on_bufnr(bufnr, label, priority) end
        end,
    }
    _run_setup(cfg, setup_ctx, function(resolved, ctx)
        if not resolved then
            if opts.on_fail then opts.on_fail() end
            return
        end
        if resolved.port then
            M._start_tcp(resolved, ctx, opts, progress)
        else
            M._start_stdio(resolved, ctx, opts, progress)
        end
    end)

    return start_id
end

---@param config   easydap.Config
---@param ctx      any
---@param opts     easydap.StartOpts
---@param progress fun(msg: string)
function M._start_stdio(config, ctx, opts, progress)
    if not config.command then
        progress("[dap] no command in config")
        if opts.on_fail then opts.on_fail() end
        return
    end

    local cmd = { config.command }
    if config.command_args then
        vim.list_extend(cmd, config.command_args --[[@as string[] ]])
    end

    progress("starting adapter: " .. config.command)
    local conn = connection.stdio(cmd, {
        cwd = config.command_cwd or vim.fn.getcwd(),
        env = config.command_env,
    })

    local sess = session_mod.new(conn, config)
    _register_session(sess, ctx, opts, progress)
    sess:start()
end

---@param config   easydap.Config
---@param ctx      any
---@param opts     easydap.StartOpts
---@param progress fun(msg: string)
function M._start_tcp(config, ctx, opts, progress)
    local host = config.host or "127.0.0.1"
    local port = config.port
    assert(type(port) == "number", "invalid port number")
    local max_attempts = 30
    local attempts     = max_attempts
    progress(("connecting to %s:%d"):format(host, port))
    local function try_connect()
        attempts = attempts - 1
        connection.try_tcp(host, port, {}, function(conn, err)
            if conn then
                local sess = session_mod.new(conn, config)
                _register_session(sess, ctx, opts, progress)
                sess:start()
            elseif attempts > 0 then
                vim.defer_fn(try_connect, 100)
            else
                local msg = ("[dap] could not connect to %s:%d — %s"):format(host, port, err or "timeout")
                progress(msg)
                progress("connection failed: " .. (err or "timeout"))
                _run_teardown(config, ctx)
                if opts.on_fail then opts.on_fail() end
            end
        end)
    end

    vim.defer_fn(try_connect, 100)
end

-- ── Session control ────────────────────────────────────────────────────────

---@param cb fun()?
function M.stop(cb)
    local sess = M.session()
    if sess then sess:stop(cb) end
end

---@param cb fun()?
function M.disconnect(cb)
    local sess = M.session()
    if sess then sess:disconnect(cb) end
end

---Stop all sessions.
---@param cb fun()?
function M.quit(cb)
    local list = vim.tbl_values(_sessions)
    local remaining = #list
    if remaining == 0 then return cb and cb() end
    for _, sess in ipairs(list) do
        sess:stop(function()
            remaining = remaining - 1
            if remaining == 0 and cb then cb() end
        end)
    end
end

-- ── Stepping ──────────────────────────────────────────────────────────────

function M.continue()
    local s = M.session(); if s then s:continue() end
end

function M.next()
    local s = M.session(); if s then s:next() end
end

function M.step_in()
    local s = M.session(); if s then s:step_in() end
end

function M.step_out()
    local s = M.session(); if s then s:step_out() end
end

function M.step_back()
    local s = M.session(); if s then s:step_back() end
end

function M.pause()
    local s = M.session(); if s then s:pause() end
end

function M.restart()
    local s = M.session(); if s then s:restart() end
end

---Continue all stopped sessions.
function M.continue_all()
    for _, sess in pairs(_sessions) do
        if sess.state == "stopped" then sess:continue() end
    end
end

---Terminate all active sessions.
function M.terminate_all()
    M.quit()
end

---@param thread_id integer
function M.select_thread(thread_id)
    local s = M.session(); if s then s:select_thread(thread_id) end
end

---@param frame_id integer
function M.select_frame(frame_id)
    local s = M.session(); if s then s:select_frame(frame_id) end
end

-- ── Evaluate ──────────────────────────────────────────────────────────────

---Request REPL completions using the active session's current frame for context.
---@param text   string   text left of cursor
---@param column integer  1-based cursor column
---@param cb     fun(targets: table[])
function M.complete(text, column, cb)
    local sess = M.session()
    if not sess then
        cb({}); return
    end
    local frame = sess:current_stack_frame()
    sess:completions(text, column, frame and frame.id, cb)
end

---@param expr    string
---@param context string
---@param cb      fun(body: table?, err: string?)
function M.evaluate(expr, context, cb)
    local sess = M.session()
    if sess then
        sess:evaluate(expr, context, cb)
    else
        cb(nil, "no active session")
    end
end

-- ── Session selection ──────────────────────────────────────────────────────

---Manually promote a session to the active (stepping) slot.
---@param id number
function M.select_session(id)
    if _sessions[id] then
        _set_active(id)
    end
end

return M
