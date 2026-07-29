---@brief The exception hover: the exception that stopped the session — id,
---description, type and adapter stack trace — in a float. View-independent, so
---`:Debug exception_info` and the automatic hover on an exception stop share it.

local DetailBlock = require("ezdap.ui.DetailBlock")
local manager     = require("ezdap.manager")

local M           = {}

local _FOCUS_ID   = "ezdap_exception"

---@param body ezdap.dap.proto.ExceptionInfoResponseBody
local function _render(body)
    local block = DetailBlock.new({ focus_id = _FOCUS_ID })
    block:line(body.exceptionId or "Exception")
    if body.description and body.description ~= "" then
        block:blank():text(body.description)
    end
    local d = body.details
    if d then
        if d.typeName and d.typeName ~= "" then
            block:blank():kv("Type", d.typeName)
        end
        if d.message and d.message ~= "" and d.message ~= body.description then
            block:text(d.message)
        end
        if d.stackTrace and d.stackTrace ~= "" then
            block:blank():line("Stack trace:"):text(d.stackTrace)
        end
    end
    block:show("Exception")
end

---One line naming the exception: its type or id, plus the first line of its
---description. Empty when the body says nothing.
---@param body ezdap.dap.proto.ExceptionInfoResponseBody
---@return string?
local function _oneline(body)
    local d = body.details or {}
    local name = (d.typeName ~= "" and d.typeName) or body.exceptionId
    local text = (d.message ~= "" and d.message) or body.description
    local first = text and vim.split(text, "\n", { plain = true })[1] or nil
    first = first and vim.trim(first)
    if name and first and first ~= "" and first ~= name then return name .. ": " .. first end
    local out = (first ~= "" and first) or name
    return (out and out ~= "") and out or nil
end

---Resolve a one-line summary of what `sess` stopped on: the adapter's
---exceptionInfo when it offers one, else the text the stopped event carried.
---`cb` gets nil when neither says anything.
---@param sess ezdap.dap.Session
---@param cb   fun(text: string?)
function M.oneline(sess, cb)
    local carried = sess.exception_description
    carried = carried and vim.trim(vim.split(carried, "\n", { plain = true })[1])
    local fallback = (carried ~= "") and carried or nil
    if not sess:capable("supportsExceptionInfoRequest") then
        cb(fallback); return
    end
    manager.exception_info(function(body)
        cb((body and _oneline(body)) or fallback)
    end)
end

---Show the active session's exception info. `silent` suppresses the "no active
---session"/"not supported"/"nothing to show" notifications, for callers that
---offer the hover rather than being asked for it.
---@param opts? { silent?: boolean }
function M.show(opts)
    local silent = opts and opts.silent
    ---@param msg string
    local function warn(msg)
        if not silent then vim.notify("[dap] " .. msg, vim.log.levels.WARN) end
    end

    local sess = manager.session()
    if not sess then
        warn("no active session"); return
    end
    if not sess:capable("supportsExceptionInfoRequest") then
        warn("adapter does not support exception info"); return
    end
    manager.exception_info(function(body, err)
        if not body then
            warn(err or "no exception info available"); return
        end
        _render(body)
    end)
end

return M
