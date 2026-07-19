local OutputBuffer = require "ezdap.ui.OutputBuffer"
local _config      = require "ezdap.config"
local ui_util      = require "ezdap.util.ui_util"

---A debug task — native DAP, sent as-is. `parameters` is the adapter's raw
---launch/attach body. This is the resolved shape `run`/`start_task` consume, which
---run files and `:Debug quick_run` both produce via `ezdap.schema`'s `resolve_task`.
---@class ezdap.Task
---@field name?         string                     run/panel group name (defaults to "debug")
---@field adapter       string                     name of an entry in `ezdap.adapters`
---@field request?      "launch"|"attach"          defaults to the adapter's default
---@field parameters?   table                      native DAP launch/attach body (the adapter's own keys), sent verbatim
---@field host?         string                     attach/TCP connection target
---@field port?         integer                    attach/TCP connection target (required for the `remote` adapter)
---@field raw_messages? boolean                    capture raw DAP protocol messages in a dedicated buffer

---Presentation options for a buffer registered with the run host.
---@class ezdap.AddBufOpts
---@field label?      string   tab label (defaults to the buffer name)
---@field priority?   integer  higher = surfaced preferentially when added (default 0)
---@field autoscroll? boolean  keep the buffer pinned to its last line while shown

---@class ezdap.TaskCallback
---@field add_bufnr  fun(bufnr: integer, opts?: ezdap.AddBufOpts)
---@field report     fun(message: string)
---@field on_done    fun(ok: boolean)

---@class ezdap.BufEntry
---@field bufnr    integer
---@field label    string
---@field priority integer  higher = shown preferentially when added (default 0)

---@class ezdap.TaskTypeDef
local M            = {}

local _run_counter = 0

---@param task ezdap.Task  native DAP task (name + adapter + request + parameters, plus optional host/port/raw_messages)
---@param callbacks ezdap.TaskCallback
---@return fun() -- cancel function
M.start            = function(task, callbacks)
    local add_bufnr = callbacks.add_bufnr or function() end
    local report    = callbacks.report or function() end
    local on_done   = callbacks.on_done or function() end


    _run_counter   = _run_counter + 1
    local run_key  = (task.name or "debug") .. "#" .. _run_counter

    local manager  = require("ezdap.manager")
    local adapters = require("ezdap.adapters")

    -- The task is native DAP: `parameters` is the adapter's raw launch/attach body,
    -- sent verbatim and never inspected or translated here. Scaffolding it from an
    -- adapter schema is new_run_file's job. No `parameters` sends an empty body.
    local base     = adapters[task.adapter]
    if not base then
        report("unknown DAP adapter: " .. tostring(task.adapter))
        on_done(false)
        return function() end
    end

    local request = task.request or base.request or "launch"

    -- Resolve the adapter definition + this task into the per-run dap config.
    -- setup/teardown stay on the adapter def (`base`); the runtime config carries
    -- only what the dap layer consumes.
    ---@type ezdap.dap.Config
    local config = {
        name                = task.name,
        adapter             = task.adapter,
        type                = base.type,
        command             = base.command,
        cwd                 = base.cwd,
        env                 = base.env,
        defer_launch_attach = base.defer_launch_attach,
        host                = base.host,
        port                = base.port,
        request             = request,
        request_args        = vim.deepcopy(task.parameters or {}),
    }

    -- Adapters with setup manage config.host/port themselves (e.g. debugpy picks a
    -- free local port during setup). Only take the task's host/port otherwise.
    if base.setup == nil then
        if task.host ~= nil then config.host = task.host end
        if task.port ~= nil then config.port = task.port end
    end

    -- REPL buffer: interactive DAP expression evaluation.
    local repl = require("ezdap.ui.ReplBuffer").new({
        name     = ui_util.unique_buf_name("ezdap://" .. run_key .. "_repl"),
        evaluate = function(expr, cb)
            manager.evaluate(expr, "repl", function(body, err)
                cb(body and body.result, err)
            end)
        end,
        complete = function(text, col, cb)
            manager.complete(text, col, cb)
        end,
    })
    add_bufnr(repl:bufnr(), { label = "REPL", priority = -1 })

    -- Output buffer: created on first non-console output event.
    local out_buf = nil ---@type ezdap.OutputBuffer?

    local function append_output(text)
        local lines = vim.split(text, "\n", { plain = true })
        if lines[#lines] == "" then table.remove(lines) end
        if #lines == 0 then return end
        if not out_buf then
            out_buf = OutputBuffer.new({
                name        = ui_util.unique_buf_name("ezdap://" .. run_key .. "_output"),
                max_lines   = _config.output_max_lines,
                ansi_colors = true,
                autoscroll  = true,
            })
            local buf = assert(out_buf:bufnr())
            add_bufnr(buf, { label = "Output", priority = 0, autoscroll = true })
        end
        out_buf:append(lines)
    end

    local _sessions     = {} ---@type table<integer, ezdap.dap.Session>
    local _cancel_early = false
    local unsub_progress ---@type fun()

    ---@type ezdap.AdapterSetupCtx
    local _setup_ctx    = { add_bufnr = add_bufnr, report = report }

    local function _run_setup(cb)
        if not base.setup then return cb(nil) end
        _setup_ctx.report("setup: starting")
        base.setup(config, _setup_ctx, function(err, state)
            if err then
                vim.notify("[dap] setup failed: " .. tostring(err), vim.log.levels.ERROR)
                _setup_ctx.report("setup failed: " .. tostring(err))
                cb(nil, true)
            else
                _setup_ctx.report("setup: ready")
                cb(state)
            end
        end)
    end

    _run_setup(function(setup_result, failed)
        if failed then
            if unsub_progress then unsub_progress() end
            on_done(false)
            return
        end

        local _teardown = base.teardown

        manager.start(config, {
            on_session = function(id, sess)
                _sessions[id] = sess
                if _cancel_early then
                    sess:stop()
                    return
                end

                -- When the adapter spawns a terminal, register it as a task buffer.
                -- The terminal buffer already has a term:// name; just make it listed.
                sess:on("run_in_terminal", function(bufnr)
                    vim.bo[bufnr].buflisted = true
                    add_bufnr(bufnr, { label = "Terminal", priority = 10 })
                end)

                local unsub
                if task.raw_messages then
                    local out ---@type ezdap.OutputBuffer?
                    out = OutputBuffer.new({
                        name        = ui_util.unique_buf_name("ezdap://" .. run_key .. "_dap-messages"),
                        max_lines   = _config.output_max_lines,
                        ansi_colors = true,
                        autoscroll  = true,
                    })
                    local buf = assert(out:bufnr())
                    add_bufnr(buf, { label = "DAP Messages", priority = -3, autoscroll = true })
                    unsub = manager.on_raw_message:subscribe(function(sid, direction, msg)
                        if sid ~= id or not out:is_valid() then
                            unsub()
                            return
                        end
                        local arrow  = direction == "out" and "→" or "←"
                        local name   = msg.command or msg.event or ""
                        local header = ("%s [%s] %s"):format(arrow, msg.type or "?", name)
                        if msg.seq then header = header .. " #" .. msg.seq end
                        local ok, json = pcall(vim.json.encode, msg)
                        out:append({ header, ok and json or tostring(msg), "" })
                    end)
                end

                sess:on("terminated", function()
                    _sessions[id] = nil
                    if unsub then unsub() end
                    if unsub_progress then unsub_progress() end
                    if _teardown then pcall(_teardown, config, setup_result) end
                    on_done(true)
                end)
            end,
            on_fail = function()
                if unsub_progress then unsub_progress() end
                if _teardown then pcall(_teardown, config, setup_result) end
                on_done(false)
            end,
            on_event = function(event, ...)
                if event == "output" then
                    local category, text = ...
                    if category == "console" then
                        repl:write(text)
                    else
                        append_output(text)
                    end
                end
            end,
            on_progress = function(message)
                report(message)
            end,
        })
    end)

    return function()
        if next(_sessions) then
            for _, sess in pairs(_sessions) do
                sess:stop()
            end
        else
            _cancel_early = true
        end
    end
end

return M
