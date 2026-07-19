---@brief DAP connection layer.
---Manages a single adapter connection (stdio pipe or TCP socket).
---Handles Content-Length framing, request/response correlation, and
---dispatching events and adapter-initiated requests to the session.

local transport = require("ezdap.dap.transport")

local M = {}

---@alias ezdap.dap.ResponseCb fun(body: table?, err: string?)
---@alias ezdap.dap.RespondFn  fun(result: table?, err: string?)

---@class ezdap.dap.ConnOpts
---@field on_close? fun()

---@class ezdap.dap.StdioOpts : ezdap.dap.ConnOpts
---@field cwd? string
---@field env? table<string,string>

---@class ezdap.dap.TcpOpts : ezdap.dap.ConnOpts

---@class ezdap.dap.Connection
---@field _seq           integer                     monotonic request counter
---@field _pending       table<integer, ezdap.dap.ResponseCb>
---@field _closed        boolean
---@field _write         fun(data: string)
---@field _close         fun()
---@field on_event       fun(event: string, body: table)
---@field on_request     fun(command: string, args: table, respond: ezdap.dap.RespondFn)
---@field on_close       fun()
---@field on_stderr      fun(line: string)
---@field on_raw_message fun(direction: "in"|"out", msg: ezdap.dap.Message)
---@field _next_seq      fun(self: ezdap.dap.Connection): integer
---@field _dispatch      fun(self: ezdap.dap.Connection, msg: ezdap.dap.Message)
---@field request        fun(self: ezdap.dap.Connection, command: string, args: table?, cb: ezdap.dap.ResponseCb?)
---@field close          fun(self: ezdap.dap.Connection)

local Connection = {}
Connection.__index = Connection

function Connection:_next_seq()
    self._seq = self._seq + 1
    return self._seq
end

---Dispatch a decoded message from the adapter.
---@param msg ezdap.dap.Message
function Connection:_dispatch(msg)
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
            ---@type ezdap.dap.Message
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
---@param cb      ezdap.dap.ResponseCb?   called on response (or nil for fire-and-forget)
function Connection:request(command, args, cb)
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

---Tear down the underlying transport. Idempotent: safe from both the explicit
---stop path and the transport's remote-close path. Pending callbacks drain with
---an error so they never hang; on_close is always scheduled exactly once.
function Connection:close()
    if self._closed then return end
    self._closed = true
    local pending = self._pending
    self._pending = {}
    self._close()
    for _, cb in pairs(pending) do
        cb(nil, "connection closed")
    end
    vim.schedule(function() self.on_close() end)
end

-- Internal constructor

---@param opts ezdap.dap.ConnOpts?
---@return ezdap.dap.Connection
local function _new_conn(opts)
    ---@diagnostic disable-next-line: missing-fields
    return setmetatable({
        _seq           = 0,
        _pending       = {},
        _closed        = false,
        on_event       = function() end,
        on_request     = function(_, _, respond) respond(nil, "unsupported request") end,
        on_close       = (opts and opts.on_close) or function() end,
        on_stderr      = function(_) end,
        on_raw_message = function() end,
    }, Connection)
end

-- stdio (pipe) connection

---Start the adapter as a subprocess and communicate via stdin/stdout.
---@param cmd  string[]       executable + arguments
---@param opts ezdap.dap.StdioOpts?
---@return ezdap.dap.Connection
function M.stdio(cmd, opts)
    opts              = opts or {}
    local conn        = _new_conn(opts)
    local parser      = transport.new_parser()

    parser.on_message = function(msg)
        -- jobstart callbacks fire on the main loop; dispatch synchronously.
        conn:_dispatch(msg)
    end

    local env         = nil
    if opts.env and next(opts.env) then env = opts.env end
    if opts.cwd and not vim.fn.has("win32") == 1 then
        env = env and vim.deepcopy(env) or {}
        env.PWD = opts.cwd
    end

    local job_id = vim.fn.jobstart(cmd, {
        cwd       = opts.cwd,
        env       = env,
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
        on_exit   = function()
            vim.schedule(function() conn:close() end)
        end,
    })

    if job_id <= 0 then
        error("[dap] failed to start adapter: " .. table.concat(cmd, " "))
    end

    conn._write = function(data) vim.fn.chansend(job_id, data) end
    conn._close = function() vim.fn.jobstop(job_id) end

    return conn
end

-- TCP connection

---Attempt a single TCP connection; calls cb(conn, err) asynchronously.
---@param host string
---@param port integer
---@param opts ezdap.dap.TcpOpts?
---@param cb   fun(conn: ezdap.dap.Connection?, err: string?)
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
                vim.schedule(function() conn:close() end)
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
