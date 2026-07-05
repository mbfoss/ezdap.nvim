---@brief Generic DAP session registry and lifecycle manager.
---Manages session spawning, adapter connections, and session-level events.
---Active session selection is handled by manager.lua.

local connection  = require("easydap.dap.connection")
local session_mod = require("easydap.dap.session")
local Signal      = require("easydap.tk.Signal")
local str_util    = require("easydap.tk.strutil")

-- ── Config type ─────────────────────────────────────────────────────────────

---A resolved, per-run DAP config — the thing the dap layer (client → session →
---connection) actually consumes to spawn/connect and drive the protocol. The
---task runner builds one from an `easydap.AdapterDef` plus a task: it flattens
---the adapter's launch/attach fields and adds the run's `request`/`request_args`
---(and host/port). `setup`/`teardown` are the adapter def's concern and are
---resolved before this exists, so they are not part of it.
---@class easydap.dap.Config
---@field adapter?               string  adapter name (for adapterID / display)
---@field type?                  string  DAP adapterID override
---@field command?               string|string[]
---@field command_cwd?           string
---@field command_env?           table<string,string>
---@field command_insert_stderr? boolean
---@field host?                  string
---@field port?                  integer
---@field request?               string
---@field request_args?          table   raw DAP launch/attach body sent with the request
---@field defer_launch_attach?   boolean

-- ── Config evaluation ──────────────────────────────────────────────────────

local function _eval_val(v)
    if type(v) == "function" then
        local ok, val = pcall(v)
        return ok and val or v
    end
    return v
end

---@param config easydap.dap.Config
---@return easydap.dap.Config
local function _eval_config(config)
    local result = {}
    for k, v in pairs(config) do
        if type(v) == "table" then
            local out = {}
            for ak, av in pairs(v) do out[ak] = _eval_val(av) end
            result[k] = out
        else
            result[k] = _eval_val(v)
        end
    end
    return result
end

local M                 = {}

---@class easydap.client.SessionInfo
---@field id number
---@field name string
---@field state string
---@field is_paused boolean
---@field nb_paused_threads integer

---@class easydap.client.StartOpts
---@field on_event?    fun(event:string, ...)
---@field on_session?  fun(id:number, sess:easydap.dap.Session)
---@field on_progress? fun(message: string)
---@field on_fail?     fun()

-- ── Signals ────────────────────────────────────────────────────────────────

---Fires when a session is registered: (id, sess, info)
M.on_session_added      = Signal.new() ---@type easydap.tk.Signal<fun(id:number, sess:easydap.dap.Session, info:easydap.client.SessionInfo)>
---Fires when a session terminates: (id)
M.on_session_removed    = Signal.new() ---@type easydap.tk.Signal<fun(id:number)>
---Fires when a session's state changes: (id, info)
M.on_session_updated    = Signal.new() ---@type easydap.tk.Signal<fun(id:number, info:easydap.client.SessionInfo)>
---Fires once per stop, after threads and stack frames have been fetched: (id, info)
M.on_session_stopped    = Signal.new() ---@type easydap.tk.Signal<fun(id:number, info:easydap.client.SessionInfo)>
---Fires for every raw DAP message: (id, direction, msg)
M.on_raw_message        = Signal.new() ---@type easydap.tk.Signal<fun(id:number, direction:"in"|"out", msg:table)>
---Fires when thread or frame selection changes in any session: (id, sess)
M.on_selection_changed  = Signal.new() ---@type easydap.tk.Signal<fun(id:number, sess:easydap.dap.Session)>
---Fires after a variable value is successfully changed by the user: (id, sess)
M.on_variable_changed   = Signal.new() ---@type easydap.tk.Signal<fun(id:number, sess:easydap.dap.Session)>
---Fires when a breakpoint's adapter-verified status changes: (id, bp, status)
M.on_breakpoint_updated = Signal.new() ---@type easydap.tk.Signal<fun(id:number, bp:table, status:easydap.dap.BpStatus)>

-- ── Session registry ───────────────────────────────────────────────────────

---@type table<number, easydap.dap.Session>
local _sessions         = {}
local _next_id          = 1
local _start_counter    = 0

---@param id number
---@param sess easydap.dap.Session
---@return easydap.client.SessionInfo
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

---@param id number
---@return easydap.dap.Session?
function M.get_session(id)
    return _sessions[id]
end

---@return table<number, easydap.dap.Session>
function M.sessions()
    return _sessions
end

-- ── Config preparation ─────────────────────────────────────────────────────

---@param config easydap.dap.Config
---@return easydap.dap.Config?
local function _prepare_config(config)
    config = vim.deepcopy(config)
    config = _eval_config(config)
    return config
end

-- ── Session registration ───────────────────────────────────────────────────

---@param sess     easydap.dap.Session
---@param opts     easydap.client.StartOpts
---@param progress fun(msg: string)
local function _register_session(sess, opts, progress)
    local id                 = _next_id
    _next_id                 = _next_id + 1
    _sessions[id]            = sess

    local on_event           = opts.on_event
    local on_session         = opts.on_session

    sess.conn.on_raw_message = function(direction, msg)
        M.on_raw_message:emit(id, direction, msg)
    end

    local ALL_EVENTS         = {
        "state_changed", "output", "stopped", "continued",
        "thread_updated", "terminated", "breakpoint_updated",
        "run_in_terminal", "start_debugging",
        "memory_changed", "progress",
    }
    if on_event then
        for _, ev in ipairs(ALL_EVENTS) do
            local name = ev
            sess:on(name, function(...) on_event(name, ...) end)
        end
    end

    sess:on("state_changed", function()
        M.on_session_updated:emit(id, _session_info(id, sess))
    end)

    sess:on("stopped", function()
        local info = _session_info(id, sess)
        M.on_session_updated:emit(id, info)
        M.on_session_stopped:emit(id, info)
    end)
    sess:on("continued", function()
        M.on_session_updated:emit(id, _session_info(id, sess))
    end)
    sess:on("selection_changed", function()
        M.on_selection_changed:emit(id, sess)
    end)
    sess:on("variable_changed", function()
        M.on_variable_changed:emit(id, sess)
    end)
    sess:on("breakpoint_updated", function(bp, status)
        M.on_breakpoint_updated:emit(id, bp, status)
    end)

    sess:on("start_debugging", function(child_config)
        local child_opts = { on_event = on_event, on_fail = opts.on_fail }
        if sess.config.port then
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
        _sessions[id] = nil
        M.on_session_removed:emit(id)
    end)

    sess.report = function(_, msg) progress(msg) end
    sess.conn.on_stderr = function(line) progress("[dap stderr] " .. line) end

    progress("session started (id " .. id .. ")")
    M.on_session_added:emit(id, sess, _session_info(id, sess))
    if on_session then on_session(id, sess) end
end

-- ── Session startup ────────────────────────────────────────────────────────

---@param config easydap.dap.Config
---@param opts? easydap.client.StartOpts
function M.start(config, opts)
    opts = opts or {}
    assert(type(config) == "table")
    assert(type(opts) == "table")

    _start_counter = _start_counter + 1
    local start_id = _start_counter
    local function progress(msg)
        if opts.on_progress then opts.on_progress(msg) end
    end

    local cfg = _prepare_config(config)
    if not cfg then
        if opts.on_fail then opts.on_fail() end
        return start_id
    end

    progress("config resolved: " .. vim.inspect(cfg))

    if cfg.port then
        M._start_tcp(cfg, opts, progress)
    else
        M._start_stdio(cfg, opts, progress)
    end

    return start_id
end

---@param config   easydap.dap.Config
---@param opts     easydap.client.StartOpts
---@param progress fun(msg: string)
function M._start_stdio(config, opts, progress)
    if not config.command then
        progress("[dap] no command in config")
        if opts.on_fail then opts.on_fail() end
        return
    end

    -- A string command may carry args (e.g. "python3 -m debugpy"); split it on
    -- shell whitespace so the first token is the executable and the rest are args.
    local cmd = type(config.command) == "table"
        and config.command --[[@as string[] ]]
        or str_util.split_shell_args(config.command --[[@as string]])

    -- Pre-flight: the most common first-run failure is a missing adapter binary.
    -- Catch it here with a friendly message instead of letting connection.stdio
    -- throw a raw Lua error (and leaving the run uncleaned because on_fail never
    -- fires).
    if vim.fn.executable(cmd[1]) == 0 then
        local msg = ("adapter executable not found: %s"
            .. "or override its `command` in require('easydap.adapters')"):format(cmd[1])
        vim.notify("[dap] " .. msg, vim.log.levels.ERROR)
        progress("[dap] " .. msg)
        if opts.on_fail then opts.on_fail() end
        return
    end

    progress("starting adapter: " .. cmd[1])
    local ok, conn = pcall(connection.stdio, cmd, {
        cwd = config.command_cwd or vim.fn.getcwd(),
        env = config.command_env,
    })
    if not ok or not conn then
        local msg = "failed to start adapter: " .. table.concat(cmd, " ")
        vim.notify("[dap] " .. msg, vim.log.levels.ERROR)
        progress("[dap] " .. msg)
        if opts.on_fail then opts.on_fail() end
        return
    end

    local sess = session_mod.new(conn, config)
    _register_session(sess, opts, progress)
    sess:start()
end

---@param config   easydap.dap.Config
---@param opts     easydap.client.StartOpts
---@param progress fun(msg: string)
function M._start_tcp(config, opts, progress)
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
                _register_session(sess, opts, progress)
                sess:start()
            elseif attempts > 0 then
                vim.defer_fn(try_connect, 100)
            else
                local msg = ("[dap] could not connect to %s:%d — %s"):format(host, port, err or "timeout")
                progress(msg)
                progress("connection failed: " .. (err or "timeout"))
                if opts.on_fail then opts.on_fail() end
            end
        end)
    end

    vim.defer_fn(try_connect, 100)
end

-- ── Session control ────────────────────────────────────────────────────────

---@param id number
---@param cb fun()?
function M.stop(id, cb)
    local sess = _sessions[id]
    if sess then sess:stop(cb) end
end

---@param id number
---@param cb fun()?
function M.disconnect(id, cb)
    local sess = _sessions[id]
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

---@param id number
function M.continue(id)
    local s = _sessions[id]; if s then s:continue() end
end

---@param id number
---@param granularity easydap.dap.proto.SteppingGranularity?
function M.next(id, granularity)
    local s = _sessions[id]; if s then s:next({ granularity = granularity }) end
end

---@param id number
---@param granularity easydap.dap.proto.SteppingGranularity?
---@param target_id integer?  a StepInTarget id from step_in_targets
function M.step_in(id, granularity, target_id)
    local s = _sessions[id]; if s then s:step_in({ granularity = granularity, targetId = target_id }) end
end

---@param id number
---@param granularity easydap.dap.proto.SteppingGranularity?
function M.step_out(id, granularity)
    local s = _sessions[id]; if s then s:step_out({ granularity = granularity }) end
end

---@param id number
---@param granularity easydap.dap.proto.SteppingGranularity?
function M.step_back(id, granularity)
    local s = _sessions[id]; if s then s:step_back({ granularity = granularity }) end
end

---@param id number
function M.reverse_continue(id)
    local s = _sessions[id]; if s then s:reverse_continue() end
end

---@param id       number
---@param frame_id integer
---@param cb       fun(targets: easydap.dap.proto.StepInTarget[]?, err: string?)
function M.step_in_targets(id, frame_id, cb)
    local s = _sessions[id]
    if s then s:step_in_targets({ frameId = frame_id }, cb) else cb(nil, "no session") end
end

---@param id     number
---@param source easydap.dap.proto.Source
---@param line   integer
---@param cb     fun(targets: easydap.dap.proto.GotoTarget[]?, err: string?)
function M.goto_targets(id, source, line, cb)
    local s = _sessions[id]
    if s then s:goto_targets({ source = source, line = line }, cb) else cb(nil, "no session") end
end

---@param id        number
---@param target_id integer
function M.set_next_statement(id, target_id)
    local s = _sessions[id]; if s then s:set_next_statement({ targetId = target_id }) end
end

---@param id       number
---@param frame_id integer
function M.restart_frame(id, frame_id)
    local s = _sessions[id]; if s then s:restart_frame({ frameId = frame_id }) end
end

---@param id number
---@param cb fun(body: easydap.dap.proto.ExceptionInfoResponseBody?, err: string?)
function M.exception_info(id, cb)
    local s = _sessions[id]
    if s then s:exception_info(nil, cb) else cb(nil, "no session") end
end

---@param id number
function M.pause(id)
    local s = _sessions[id]; if s then s:pause() end
end

---@param id         number
---@param thread_ids integer[]
---@param cb         fun(err: string?)?
function M.terminate_threads(id, thread_ids, cb)
    local s = _sessions[id]
    if s then s:terminate_threads({ threadIds = thread_ids }, cb) elseif cb then cb("no session") end
end

---@param id number
function M.restart(id)
    local s = _sessions[id]; if s then s:restart() end
end

---Continue all stopped sessions.
function M.continue_all()
    for _, sess in pairs(_sessions) do
        if sess.state == "stopped" then sess:continue() end
    end
end

---@param id        number
---@param thread_id integer
function M.select_thread(id, thread_id)
    local s = _sessions[id]; if s then s:select_thread(thread_id) end
end

---@param id       number
---@param frame_id integer
function M.select_frame(id, frame_id)
    local s = _sessions[id]; if s then s:select_frame(frame_id) end
end

-- ── Evaluate ──────────────────────────────────────────────────────────────

---@param id     number
---@param text   string
---@param column integer
---@param cb     fun(targets: table[])
function M.complete(id, text, column, cb)
    local sess = _sessions[id]
    if not sess then
        cb({}); return
    end
    local frame = sess:current_stack_frame()
    sess:completions({ text = text, column = column, frameId = frame and frame.id }, cb)
end

---@param id      number
---@param expr    string
---@param context string
---@param cb      fun(body: table?, err: string?)
function M.evaluate(id, expr, context, cb)
    local sess = _sessions[id]
    if sess then
        sess:evaluate({ expression = expr, context = context }, cb)
    else
        cb(nil, "no session")
    end
end

return M
