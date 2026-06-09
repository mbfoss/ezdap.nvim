---@brief DAP connection layer.
---Manages a single adapter connection (stdio pipe or TCP socket).
---Handles Content-Length framing, request/response correlation, and
---dispatching events and adapter-initiated requests to the session.

local transport = require("easydap.transport")

local M = {}

---@alias easydap.ResponseCb fun(body: table?, err: string?)
---@alias easydap.RespondFn  fun(result: table?, err: string?)

---@class easydap.ConnOpts
---@field on_close? fun()

---@class easydap.StdioOpts : easydap.ConnOpts
---@field cwd? string
---@field env? table<string,string>

---@class easydap.TcpOpts : easydap.ConnOpts

---@class easydap.Connection
---@field _seq           integer                     monotonic request counter
---@field _pending       table<integer, easydap.ResponseCb>
---@field _write         fun(data: string)
---@field _close         fun()
---@field on_event       fun(event: string, body: table)
---@field on_request     fun(command: string, args: table, respond: easydap.RespondFn)
---@field on_close       fun()
---@field on_stderr      fun(line: string)
---@field on_raw_message fun(direction: "in"|"out", msg: easydap.Message)
---@field _next_seq      fun(self: easydap.Connection): integer
---@field _dispatch      fun(self: easydap.Connection, msg: easydap.Message)
---@field request        fun(self: easydap.Connection, command: string, args: table?, cb: easydap.ResponseCb?)
---@field close          fun(self: easydap.Connection)

local _Connection = {}
_Connection.__index = _Connection

function _Connection:_next_seq()
    self._seq = self._seq + 1
    return self._seq
end

---Dispatch a decoded message from the adapter.
---@param msg easydap.Message
function _Connection:_dispatch(msg)
    self.on_raw_message("in", msg)
    local t = msg.type
    if t == "response" then
        local seq = tonumber(msg.request_seq)
        local cb  = seq and self._pending[seq]
        if seq and cb then
            self._pending[seq] = nil
            local err
            if not msg.success then
                err = msg.message
                -- Some adapters embed the human-readable reason inside body.error.format
                if not err then
                    local body = msg.body
                    err = body and body.error and body.error.format or "request failed"
                end
            end
            cb(msg.body, err)
        end

    elseif t == "event" then
        pcall(self.on_event, msg.event or "", msg.body or {})

    elseif t == "request" then
        -- Adapter-initiated request (e.g. runInTerminal, startDebugging)
        local req_seq = tonumber(msg.seq)
        local command = msg.command or ""
        local function respond(result, err_msg)
            ---@type easydap.Message
            local response = {
                type        = "response",
                seq         = self:_next_seq(),
                request_seq = req_seq,
                command     = command,
                success     = (err_msg == nil),
            }
            if err_msg then
                response.message = err_msg
            elseif result then
                response.body = result
            end
            self.on_raw_message("out", response)
            self._write(transport.encode(response))
        end
        pcall(self.on_request, command, msg.arguments or {}, respond)
    end
end

---Send a DAP request.
---@param command string
---@param args    table?
---@param cb      easydap.ResponseCb?   called on response (or nil for fire-and-forget)
function _Connection:request(command, args, cb)
    local seq = self:_next_seq()
    local msg = { type = "request", seq = seq, command = command }
    if args and next(args) ~= nil then
        msg.arguments = args
    end
    if cb then
        self._pending[seq] = cb
    end
    self.on_raw_message("out", msg)
    self._write(transport.encode(msg))
end

---Tear down the underlying transport.
function _Connection:close()
    self._close()
end

-- ── Internal constructor ───────────────────────────────────────────────────

---@param opts easydap.ConnOpts?
---@return easydap.Connection
local function _new_conn(opts)
    ---@diagnostic disable-next-line: missing-fields
    return setmetatable({
        _seq     = 0,
        _pending = {},
        on_event       = function() end,
        on_request     = function(_, _, respond) respond(nil, "unsupported request") end,
        on_close       = (opts and opts.on_close) or function() end,
        on_stderr      = function(_) end,
        on_raw_message = function() end,
    }, _Connection)
end

-- ── stdio (pipe) connection ────────────────────────────────────────────────

---Start the adapter as a subprocess and communicate via stdin/stdout.
---@param cmd  string[]       executable + arguments
---@param opts easydap.StdioOpts?
---@return easydap.Connection
function M.stdio(cmd, opts)
    opts = opts or {}
    local conn   = _new_conn(opts)
    local parser = transport.new_parser()

    parser.on_message = function(msg)
        -- jobstart callbacks fire on the main loop; dispatch synchronously.
        conn:_dispatch(msg)
    end

    local job_id = vim.fn.jobstart(cmd, {
        cwd     = opts.cwd,
        env     = opts.env,
        -- Do NOT use stdout_buffered — we need streaming access.
        on_stdout = function(_, data)
            -- data is a list of strings split on \n.
            -- Joining with \n reconstructs the original bytes (including \r in \r\n sequences).
            local chunk = table.concat(data, "\n")
            if chunk ~= "" then
                parser:feed(chunk)
            end
        end,
        on_stderr = function(_, data)
            for _, line in ipairs(data) do
                if line ~= "" then
                    conn.on_stderr(line)
                end
            end
        end,
        on_exit = function()
            vim.schedule(function() conn.on_close() end)
        end,
    })

    if job_id <= 0 then
        error("[dap] failed to start adapter: " .. table.concat(cmd, " "))
    end

    conn._write = function(data) vim.fn.chansend(job_id, data) end
    conn._close = function() vim.fn.jobstop(job_id) end

    return conn
end

-- ── TCP connection ─────────────────────────────────────────────────────────

---Attempt a single TCP connection; calls cb(conn, err) asynchronously.
---@param host string
---@param port integer
---@param opts easydap.TcpOpts?
---@param cb   fun(conn: easydap.Connection?, err: string?)
function M.try_tcp(host, port, opts, cb)
    opts = opts or {}
    local tcp = vim.uv.new_tcp()
    if not tcp then
        vim.schedule(function() cb(nil, "failed to create TCP handle") end)
        return
    end
    local conn = _new_conn(opts)

    local parser = transport.new_parser()
    parser.on_message = function(msg)
        vim.schedule(function() conn:_dispatch(msg) end)
    end

    tcp:connect(host, port, function(err)
        if err then
            tcp:close()
            vim.schedule(function() cb(nil, err) end)
            return
        end

        tcp:read_start(function(read_err, chunk)
            if read_err or not chunk then
                vim.schedule(function() conn.on_close() end)
                return
            end
            parser:feed(chunk)
        end)

        conn._write = function(data) tcp:write(data) end
        conn._close = function()
            tcp:read_stop()
            if not tcp:is_closing() then tcp:close() end
        end
        conn.on_close = opts.on_close or function() end

        vim.schedule(function() cb(conn, nil) end)
    end)
end

return M
