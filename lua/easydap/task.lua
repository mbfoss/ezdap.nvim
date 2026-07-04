local OutputBuffer = require "easydap.ui.OutputBuffer"
local _config      = require "easydap.config"
---Presentation options for a buffer registered with the run host.
---@class easydap.AddBufOpts
---@field label?      string   tab label (defaults to the buffer name)
---@field priority?   integer  higher = surfaced preferentially when added (default 0)
---@field autoscroll? boolean  keep the buffer pinned to its last line while shown

---@class easydap.TaskCallback
---@field add_bufnr  fun(bufnr: integer, opts?: easydap.AddBufOpts)
---@field report     fun(message: string)
---@field on_done    fun(ok: boolean)

---@class easydap.BufEntry
---@field bufnr    integer
---@field label    string
---@field priority integer  higher = shown preferentially when added (default 0)

---@class easydap.TaskTypeDef
---@field start     fun(task: table, ctx: easydap.TaskCallback): fun()
---@field dispose   (fun(bufnrs: easydap.BufEntry[]))?  optional cleanup called when the run is disposed
---@field schema    table?

---@class easydap.TaskTypeDef
local M            = {}

local _run_counter = 0

---Return `base` if no buffer has that name, otherwise `base#1`, `base#2`, …
---@param base string
---@return string
local function _unique_buf_name(base)
    local name = base
    local n    = 0
    while vim.fn.bufnr(name) ~= -1 do
        n    = n + 1
        name = base .. "#" .. n
    end
    return name
end

---@param task    easydap.Task  native DAP task (`request_args` holds the raw body; generic fields, if any, are ignored)
---@param callbacks easydap.TaskCallback
---@return fun()
M.start = function(task, callbacks)
    local add_bufnr = callbacks.add_bufnr or function() end
    local report    = callbacks.report or function() end
    local on_done   = callbacks.on_done or function() end


    _run_counter   = _run_counter + 1
    local run_key  = (task.name or "debug") .. "#" .. _run_counter

    local manager  = require("easydap.manager")
    local adapters = require("easydap.adapters")

    -- The task is native DAP: `request_args` holds the adapter's raw launch/attach
    -- body. Translating a generic task (command/cwd/env/…) into `request_args` is
    -- the caller's job via the opt-in `easydap.derive` utility — this runner never
    -- interprets generic fields. An adapter with no `request_args` sends an empty body.
    local base     = adapters[task.adapter]
    if not base then
        report("unknown DAP adapter: " .. tostring(task.adapter))
        on_done(false)
        return function() end
    end

    local request = task.request or base.request or "launch"
    local config  = vim.tbl_extend("force", vim.deepcopy(base), { request = request })

    config.request_args = vim.tbl_deep_extend("force", config.request_args or {}, task.request_args or {})

    -- Adapters with setup manage config.host/port themselves (e.g. debugpy picks a
    -- free local port during setup). Only propagate task fields for adapters without setup.
    if base.setup == nil then
        if task.host ~= nil then config.host = task.host end
        if task.port ~= nil then config.port = task.port end
    end

    -- REPL buffer: interactive DAP expression evaluation.
    local repl = require("easydap.ui.ReplBuffer").new({
        name     = "easydap://" .. run_key .. "/repl",
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
    local out_buf = nil ---@type easydap.OutputBuffer?

    local function append_output(text)
        local lines = vim.split(text, "\n", { plain = true })
        if lines[#lines] == "" then table.remove(lines) end
        if #lines == 0 then return end
        if not out_buf then
            out_buf = OutputBuffer.new({
                name      = _unique_buf_name("easydap://" .. run_key .. "/output"),
                max_lines = _config.output_max_lines,
            })
            local buf = assert(out_buf:bufnr())
            add_bufnr(buf, { label = "Output", priority = 0, autoscroll = true })
        end
        out_buf:append(lines)
    end

    local _sessions     = {} ---@type table<integer, easydap.dap.Session>
    local _cancel_early = false
    local unsub_progress ---@type fun()

    ---@type easydap.AdapterSetupCtx
    local _setup_ctx    = { add_bufnr = add_bufnr, report = report }

    local function _run_setup(cb)
        if not config.setup then return cb(nil) end
        _setup_ctx.report("setup: starting")
        config.setup(config, _setup_ctx, function(err, state)
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

        local _teardown = config.teardown
        config.setup    = nil
        config.teardown = nil

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
                    local out ---@type easydap.OutputBuffer?
                    out = OutputBuffer.new({
                        name      = _unique_buf_name("easydap://" .. run_key .. "/dap-messages"),
                        max_lines = _config.output_max_lines,
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
