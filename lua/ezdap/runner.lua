---@brief Standalone task runner for ezdap.
---
---Runs a debug task without easytasks by supplying ezdap's own run callbacks
---to `ezdap.task.start`. `ezdap.task` stays provider-agnostic: easytasks
---supplies its own callbacks via its backend; this module is the standalone
---equivalent (progress, run lifecycle).
---
---A run's buffers are shown through `ezdap.ui.panel`, which gives each run a
---channel — a dock.nvim tab, or the shared bottom window when dock is not
---installed. They are tracked here as well so a finished run's buffers can be wiped.
---
---One task per file: a run file returns a single task (or a function
---returning one):
---  -- debug.lua
---  return { name = "debug app", adapter = "lldb", configuration = { request = "launch", program = "a.out" } }

local OutputBuffer = require "ezdap.ui.OutputBuffer"
local ui_util      = require "ezdap.util.ui"
local _config      = require "ezdap.config"

local M            = {}

---A run: a unique id, the task name, a cancel function, the buffers it spawned
---(REPL, Output, Terminal, DAP messages), the panel channel showing them, and
---whether it has finished. Runs are tracked together so tasks can run in parallel.
---@class ezdap.runner.Run
---@field id      string
---@field name    string
---@field cancel  fun()
---@field bufnrs  integer[]
---@field done    boolean
---@field channel ezdap.ui.Channel
---@field log     ezdap.OutputBuffer  this run's own progress log; its buffer is one of `bufnrs`

---@type ezdap.runner.Run[]
local _runs    = {}
local _counter = 0

---The most recently run task, kept so `rerun()` can re-launch it from scratch.
---@type ezdap.Task?
local _last_task

---@param msg string
local function _warn(msg) vim.notify("[ezdap] " .. msg, vim.log.levels.WARN) end

---@param msg string
local function _err(msg) vim.notify("[ezdap] " .. msg, vim.log.levels.ERROR) end

---@param v any
---@return boolean
local function _is_task(v)
    return type(v) == "table" and type(v.adapter) == "string"
end

-- A run's progress is appended to a scratch log buffer of its own, one page of
-- its channel alongside the Output and REPL, reachable by name (`:b
-- ezdap://<run>-log`) or via `:Debug log`. Pre-flight errors stay on vim.notify,
-- happening before the run exists.

---Create a run's log — an `OutputBuffer` like the run's Output, so the line cap
---and autoscroll are the same ones — and register it as the lowest-ranked page
---of its channel, so it never displaces that Output.
---@param run ezdap.runner.Run
---@return ezdap.OutputBuffer
local function _make_log(run)
    local log = OutputBuffer.new({
        name       = ui_util.unique_buf_name("ezdap://" .. run.id .. "-log"),
        max_lines  = _config.output_max_lines,
        autoscroll = true,
    })

    local buf                   = assert(log:bufnr())
    run.bufnrs[#run.bufnrs + 1] = buf
    run.channel:add(buf, { label = "log", priority = -4 })
    return log
end

---Append timestamped lines to a run's log.
---@param run ezdap.runner.Run
---@param msg string
local function _log(run, msg)
    local stamp = os.date("%H:%M:%S")
    local lines = {}
    for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
        lines[#lines + 1] = ("[%s] %s"):format(stamp, l)
    end
    run.log:append(lines)
end

---Drop a run's channel and wipe the buffers it spawned. The channel goes first,
---so the panel is off those buffers before they are deleted.
---@param run ezdap.runner.Run
local function _remove_run(run)
    run.channel:remove()
    for _, b in ipairs(run.bufnrs) do
        if vim.api.nvim_buf_is_valid(b) then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
end

---Drop any finished run of the same name and wipe its buffers, so re-running a
---task replaces its own previous run. Live runs and finished runs of other tasks
---are left untouched, so parallel runs accumulate independently.
---@param name string
local function _clear_finished(name)
    local kept = {}
    for _, r in ipairs(_runs) do
        if r.done and r.name == name then
            _remove_run(r)
        else
            kept[#kept + 1] = r
        end
    end
    _runs = kept
end

---Show a run's log in the panel, parked on its last line — the newest live run's
---by default, else the most recent one's. Warns when no run has logged anything
---yet. Bound to `:Debug log`.
---@param run? ezdap.runner.Run  defaults to the newest live run, else the latest
function M.log_open(run)
    run = run or M.active() or _runs[#_runs]
    if not run or not run.log:is_valid() then
        _warn("log: nothing logged yet")
        return
    end
    local buf = assert(run.log:bufnr())
    run.channel:show(buf, { label = "log", priority = -4 })
    local win = require("ezdap.ui.panel").winid()
    if win then
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
end

---Forget a single run, wiping its buffers and dropping its channel. A live run
---is not stopped first — cancel it before removing it.
---@param run ezdap.runner.Run
function M.remove(run)
    for i, r in ipairs(_runs) do
        if r == run then
            table.remove(_runs, i)
            break
        end
    end
    _remove_run(run)
end

---Drop every finished run and wipe their buffers, leaving live runs untouched.
---Bound to `:Debug clean`.
function M.clean()
    local kept, finished = {}, {}
    for _, r in ipairs(_runs) do
        if r.done then
            finished[#finished + 1] = r
        else
            kept[#kept + 1] = r
        end
    end
    _runs = kept
    for _, r in ipairs(finished) do
        _remove_run(r)
    end
end

---Run a debug task. Tasks may run in parallel: starting one does not cancel the
---others. Re-running a task replaces its own previous finished run. Returns nil
---when `task` is not a valid task table.
---@param task ezdap.Task
---@return ezdap.runner.Run?
function M.run(task)
    if not _is_task(task) then
        _err("run: expected a task table with an `adapter` field")
        return
    end

    task       = vim.deepcopy(task)
    task.name  = task.name or "debug"
    _last_task = task

    _clear_finished(task.name)

    _counter = _counter + 1
    ---@type ezdap.runner.Run
    ---@diagnostic disable-next-line: missing-fields -- channel and log_buf are set right below, once `run` exists for the clean callback
    local run = {
        id      = task.name .. "-" .. _counter,
        name    = task.name,
        cancel  = function() end,
        bufnrs  = {},
        done    = false,
    }
    _runs[#_runs + 1] = run

    -- One channel per run. A backend that can ask a channel to shed itself (dock's
    -- `:Dock clean`) gets the same answer `M.clean` gives: a finished run goes,
    -- a live one stays.
    run.channel  = require("ezdap.ui.panel").channel({
        id       = run.id,
        label    = run.name,
        state    = "running",
        on_clean = function()
            if run.done then M.remove(run) end
        end,
    })
    -- The log is this run's own buffer, so its lines need no task-name prefix.
    run.log      = _make_log(run)

    local cancel = require("ezdap.task").start(task, {
        -- Shown in the run's panel channel, and tracked so `clean` can wipe them.
        add_bufnr = function(bufnr, opts)
            run.bufnrs[#run.bufnrs + 1] = bufnr
            run.channel:add(bufnr, opts)
        end,
        report    = function (msg)
            _log(run, msg)
        end,
        on_done   = function(ok)
            run.done = true
            run.channel:set_state(ok and "done" or "failed")
            _log(run, ok and "finished" or "failed")
        end,
    })

    run.cancel = cancel
    return run
end

---Re-launch the most recently run task from scratch. Unlike `:Debug restart` (a DAP
---request on the live session) this works after the session has ended and for
---adapters without restart support. Warns when no task has been run yet.
---@return ezdap.runner.Run?
function M.rerun()
    if not _last_task then
        _warn("rerun: nothing to re-run yet (run a task first)")
        return
    end
    return M.run(_last_task)
end

---Prompt to pick one of the Lua files directly in `dir`, then run it, using
---ezdap's own fuzzy picker with a preview of each file. Runs the sole file
---outright when there is only one, and warns when there are none.
---@param dir string  absolute directory path
local function _run_from_dir(dir)
    local files = vim.fn.globpath(dir, "*.lua", true, true) ---@type string[]
    if #files == 0 then
        _warn("run: no Lua files in " .. dir)
        return
    end
    local items = {}
    for _, f in ipairs(files) do
        items[#items + 1] = { label = vim.fn.fnamemodify(f, ":t"), data = { filepath = f } }
    end
    require("ezdap.util.select").open({
        prompt         = "Debug task",
        items          = items,
        enable_preview = true,
    }, function(data)
        if data and data.filepath then M.run_file(data.filepath) end
    end)
end

---Run a task from a path: a directory opens a picker of its Lua files, a Lua file is
---loaded and the value it returns is run — either profile-based (`adapter`/`profile`/
---`parameters`, resolved via `build`) or raw (`adapter`/`configuration`, sent verbatim).
---@param path string
function M.run_file(path)
    if type(path) ~= "string" or path == "" then
        _warn("run: no path given (usage: run('path/to/task.lua' or a folder))")
        return
    end

    local resolved = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
    ---@diagnostic disable-next-line: undefined-field
    local stat     = vim.uv.fs_stat(resolved)
    if not stat then
        _warn("run: path not found: " .. resolved)
        return
    end
    if stat.type == "directory" then
        return _run_from_dir(resolved)
    end
    if not resolved:match("%.lua$") then
        _warn("run: not a Lua file: " .. resolved)
        return
    end

    local chunk, load_err = loadfile(resolved)
    if not chunk then
        _err("run: cannot load " .. resolved .. ": " .. tostring(load_err))
        return
    end

    local ok, spec = pcall(chunk)
    if ok and type(spec) == "function" then
        ok, spec = pcall(spec)
    end
    if not ok then
        _err("run: error in " .. resolved .. ": " .. tostring(spec))
        return
    end

    if not _is_task(spec) then
        _err("run: " .. vim.fn.fnamemodify(resolved, ":t") ..
            " must return a task table with an `adapter` field")
        return
    end

    -- A profile-based run file names a profile and answers its inputs under
    -- `parameters`; resolve it through the profile's `build`, as `:Debug run` does.
    -- It may open a picker, so the run starts from the callback.
    if type(spec.profile) == "string" then
        local name = vim.fn.fnamemodify(resolved, ":t")
        require("ezdap.schema").resolve_task({
            adapter = spec.adapter,
            profile = spec.profile,
            name    = spec.name,
            values  = spec.parameters,
        }, function(task, err)
            if not task then
                _err("run: " .. name .. ": " .. tostring(err))
                return
            end
            M.run(task)
        end)
        return
    end

    -- A raw run file carries an nvim-dap-like `configuration` table of raw DAP
    -- parameters that includes `request`; lift `request` out and forward the rest
    -- as the DAP body, an `ezdap.Task` sent to the adapter verbatim.
    if type(spec.configuration) == "table" then
        local body = vim.deepcopy(spec.configuration)
        local request = body.request
        body.request = nil
        M.run({
            name       = spec.name,
            adapter    = spec.adapter,
            request    = request,
            parameters = body,
            host       = spec.host,
            port       = spec.port,
        })
        return
    end

    _err("run: " .. vim.fn.fnamemodify(resolved, ":t") ..
        " must set either `profile` (a named profile) or `configuration` (a raw DAP table)")
end

---Launch or attach under an adapter's named profile. `assignments[1]`/`[2]` are the
---adapter and profile; each later `input=value` is resolved by `schema.resolve_task`.
---Returns nil when `build` stops to ask the user something — the run starts on answer.
---@param assignments string[]  adapter, profile name, then "input=value" tokens, e.g. { "codelldb", "launch", "command=./a.out" }
---@return ezdap.runner.Run?
function M.run_profile(assignments)
    local schema = require("ezdap.schema")

    -- The adapter and profile name are strictly the first two positional
    -- arguments (`:Debug run codelldb launch …`); every argument from the
    -- third on is an `input=value` assignment.
    local adapter, profile_name = assignments[1], assignments[2]
    if not adapter or adapter == "" or adapter:find("=", 1, true) then
        _warn("run: usage: :Debug run <adapter> <profile> [input=value]…")
        return
    end
    if not require("ezdap.adapters")[adapter] then
        _err("run: unknown adapter: " .. adapter ..
            " (available: " .. table.concat(schema.profiled_adapters(), ", ") .. ")")
        return
    end
    if not profile_name or profile_name == "" or profile_name:find("=", 1, true) then
        _warn("run: usage: :Debug run " .. adapter .. " <profile> [input=value]…"
            .. " (profiles: " .. table.concat(schema.profile_names(adapter), ", ") .. ")")
        return
    end

    local values = {}
    for i = 3, #assignments do
        local tok = assignments[i]
        local eq = tok:find("=", 1, true)
        if not eq then
            _warn("run: expected input=value, got '" .. tok .. "'")
            return
        end
        values[tok:sub(1, eq - 1)] = tok:sub(eq + 1)
    end

    -- A profile whose `build` asks the user something (an attach resolving an unset
    -- `pid`) resolves only once they answer, so the run starts from the callback.
    -- Every other profile resolves synchronously, assigning `run` before we return.
    local run
    schema.resolve_task({
        adapter = adapter,
        profile = profile_name,
        name    = adapter,
        values  = values,
    }, function(task, err)
        if not task then
            _err("run: " .. tostring(err))
            return
        end
        run = M.run(task)
    end)
    return run
end

---Cancel every live run. Stops their sessions, or aborts a run still in adapter
---setup (before any session exists, where `:Debug stop` has nothing to act on yet).
function M.cancel()
    for _, r in ipairs(_runs) do
        if not r.done then r.cancel() end
    end
end

---The most recently started live run, or nil.
---@return ezdap.runner.Run?
function M.active()
    for i = #_runs, 1, -1 do
        if not _runs[i].done then return _runs[i] end
    end
    return nil
end

return M
