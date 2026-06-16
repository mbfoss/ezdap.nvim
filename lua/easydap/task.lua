---@class easydap.TaskTemplate
---@field label string  shown in vim.ui.select
---@field task  table   the template data to encode and insert

---@class easydap.RunCtx
---@field tasks      table<string,table>
---@field add_bufnr  fun(bufnr: integer, label?: string, priority?: integer)
---@field report     fun(message: string)

---@class easydap.BufEntry
---@field bufnr    integer
---@field label    string
---@field priority integer  higher = shown preferentially when added (default 0)

---@class easydap.TaskTypeDef
---@field start     fun(task: table, ctx: easydap.RunCtx, on_done: fun(ok: boolean)): fun()
---@field dispose   (fun(bufnrs: easydap.BufEntry[]))?  optional cleanup called when the run is disposed
---@field schema    table?
---@field templates (easydap.TaskTemplate[]|(fun(): easydap.TaskTemplate[]))?

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

---@param task    table
---@param ctx     easydap.RunCtx
---@param on_done fun(ok: boolean)
---@return fun()
M.start     = function(task, ctx, on_done)
    _run_counter   = _run_counter + 1
    local run_key  = (task.name or "debug") .. "#" .. _run_counter

    local manager  = require("easydap.manager")
    local adapters = require("easydap.adapters")

    -- Resolve named adapter config and build request_args via one of two paths:
    --   1. task.request_args is set  → use verbatim as the DAP launch/attach arguments
    --   2. task.request_args absent  → call config.derive_request_args(config, task, request)
    --      to derive args from the generic task fields (command, args, cwd, env, …)
    -- Fallback when neither is available: use the adapter's base launch/attach args.
    local base     = adapters[task.adapter]
    if not base then
        ctx.report("unknown DAP adapter: " .. tostring(task.adapter))
        on_done(false)
        return function() end
    end

    local request             = task.request or base.request or "launch"
    local config              = vim.tbl_extend("force", vim.deepcopy(base), { request = request })
    config.derive_launch_args = nil
    config.derive_attach_args = nil

    if request == "launch" and base.derive_launch_args then
        local ok, result = pcall(base.derive_launch_args, task)
        if not ok then
            ctx.report("failed to build launch args, " .. tostring(result))
            on_done(false)
            return function() end
        end
        config.request_args = result
    elseif request == "attach" and base.derive_attach_args then
        local ok, result = pcall(base.derive_attach_args, task)
        if not ok then
            ctx.report("failed to build attach args, " .. tostring(result))
            on_done(false)
            return function() end
        end
        config.request_args = result
    end

    -- override  with user provided args
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
    ctx.add_bufnr(repl:bufnr(), "REPL", -1)

    -- Output buffer: created on first non-console output event.
    local out_buf = nil ---@type integer?

    local function append_output(text)
        local lines = vim.split(text, "\n", { plain = true })
        if lines[#lines] == "" then table.remove(lines) end
        if #lines == 0 then return end
        if not out_buf then
            out_buf                    = vim.api.nvim_create_buf(true, true)
            vim.bo[out_buf].buftype    = "nofile"
            vim.bo[out_buf].swapfile   = false
            vim.bo[out_buf].buflisted  = true
            vim.bo[out_buf].bufhidden  = "hide"
            vim.bo[out_buf].modifiable = false
            vim.api.nvim_buf_set_name(out_buf,
                _unique_buf_name("easydap://" .. run_key .. "/output"))

            vim.api.nvim_buf_set_var(out_buf, "easytasks_autoscroll", true)
            ctx.add_bufnr(out_buf, "Output")
        end
        if not vim.api.nvim_buf_is_valid(out_buf) then return end
        vim.bo[out_buf].modifiable = true
        vim.api.nvim_buf_set_lines(out_buf, -1, -1, false, lines)
        vim.bo[out_buf].modifiable = false
    end

    local _sessions     = {} ---@type table<integer, easydap.dap.Session>
    local _cancel_early = false
    local unsub_progress ---@type fun()

    ---@type easydap.AdapterSetupCtx
    local _setup_ctx    = { add_bufnr = ctx.add_bufnr, report = ctx.report }

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
                    ctx.add_bufnr(bufnr, "Terminal", 10)
                end)

                local unsub
                if task.raw_messages then
                    local buf              = vim.api.nvim_create_buf(true, true)
                    vim.bo[buf].buftype    = "nofile"
                    vim.bo[buf].swapfile   = false
                    vim.bo[buf].buflisted  = true
                    vim.bo[buf].bufhidden  = "hide"
                    vim.bo[buf].modifiable = false
                    vim.api.nvim_buf_set_name(buf,
                        _unique_buf_name("easydap://" .. run_key .. "/dap-messages"))
                    vim.api.nvim_buf_set_var(buf, "easytasks_autoscroll", true)
                    ctx.add_bufnr(buf, "DAP Messages", -3)

                    unsub = manager.on_raw_message:subscribe(function(sid, direction, msg)
                        if sid ~= id then return end
                        if not vim.api.nvim_buf_is_valid(buf) then return end
                        local arrow  = direction == "out" and "→" or "←"
                        local name   = msg.command or msg.event or ""
                        local header = ("%s [%s] %s"):format(arrow, msg.type or "?", name)
                        if msg.seq then header = header .. " #" .. msg.seq end
                        local ok, json = pcall(vim.json.encode, msg)
                        vim.bo[buf].modifiable = true
                        vim.api.nvim_buf_set_lines(buf, -1, -1, false,
                            { header, ok and json or tostring(msg), "" })
                        vim.bo[buf].modifiable = false
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
                ctx.report(message)
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

M.schema    = {
    description = "Definition of a `debug` task (runs via a DAP adapter)",
    ["x-order"] = {
        "name", "type", "if_running", "depends_on", "depends_order",
        "adapter", "request", "host", "port",
        "command", "args", "cwd", "env", "clear_env", "run_in_terminal", "stop_on_entry",
        "request_args", "raw_messages",
    },
    required    = { "adapter" },
    properties  = {
        adapter         = {
            type        = "string",
            minLength   = 1,
            description = "Name of the DAP adapter to use (e.g. codelldb, delve, debugpy)",
            enum        = function()
                local n = vim.tbl_keys(require("easydap.adapters"))
                table.sort(n)
                return n
            end,
        },
        host            = {
            type        = { "string", "null" },
            minLength   = 1,
            description =
            "Hostname or IP address of the DAP server to connect to (attach only; overrides the adapter default)",
        },
        port            = {
            type        = { "integer", "null" },
            minimum     = 1,
            maximum     = 65535,
            description = "TCP port of the DAP server to connect to (attach only; required for `remote` adapter)",
        },
        request         = {
            description = "Whether to launch a new process or attach to a running one",
            oneOf = {
                { type = "string", const = "launch", description = "Start the program under the debugger" },
                { type = "string", const = "attach", description = "Attach to an already-running process" },
            },
        },
        -- ── Generic fields (used by derive_request_args when request_args is absent) ──
        command         = {
            description =
            "Program to debug. A string is a plain path; an array is [program, arg1, …] shorthand (args are merged with `args` if also set)",
            oneOf = {
                { type = "string", minLength = 1,               description = "Path to the executable" },
                { type = "array",  items = { type = "string" }, minItems = 1,                          description = "Executable followed by arguments" },
            },
        },
        cwd             = {
            type        = { "string", "null" },
            minLength   = 1,
            description = "Working directory for the debugged program",
        },
        env             = {
            type                 = { "object", "null" },
            description          = "Environment variables for the debugged program",
            additionalProperties = { type = "string" },
        },
        clear_env       = {
            type        = { "boolean", "null" },
            description = "Pass `env` verbatim without merging with the current process environment",
        },
        run_in_terminal = {
            type        = { "boolean", "null" },
            description = "Ask the DAP client to spawn an integrated terminal for the program's stdio",
        },
        stop_on_entry   = {
            type        = { "boolean", "null" },
            description = "Pause execution at the program's entry point before running any user code",
        },
        -- ── Advanced override ──────────────────────────────────────────────
        request_args    = {
            type                 = { "object", "null" },
            description          =
            "Arguments sent verbatim in the DAP launch or attach request (takes precedence over all generic fields above)",
            additionalProperties = true,
        },
        raw_messages    = {
            type        = { "boolean", "null" },
            description = "Capture all raw DAP protocol messages in a dedicated buffer attached to the task",
        },
    },
}

M.templates = require("easydap.templates")

return M
