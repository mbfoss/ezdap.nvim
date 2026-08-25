---@brief Standalone task runner for ezdap.
---
---Runs a debug task without easytasks by supplying ezdap's own run callbacks
---to `ezdap.task.start`. `ezdap.task` stays provider-agnostic: easytasks
---supplies its own callbacks via its backend; this module is the standalone
---equivalent (progress, run lifecycle).
---
---A run announces itself through signals — it started, it spawned a buffer, its
---state changed, it is gone — and holds the buffers it spawned so a late
---subscriber can catch up. Whether and how any of it is shown is the panel
---backends' decision; nothing here knows about windows.
---
---One task per file: a run file returns a single task (or a function
---returning one):
---  -- debug.lua
---  return { name = "debug app", adapter = "lldb", mode = "binary", parameters = { command = "a.out" } }

local OutputBuffer = require "ezdap.ui.OutputBuffer"
local ui_util      = require "ezdap.util.ui"
local Signal       = require "ezdap.util.Signal"
local _config      = require "ezdap.config"

local M            = {}

---@alias ezdap.runner.RunState "running"|"done"|"failed"

---One buffer a run spawned, together with how it asked to be presented.
---@class ezdap.runner.RunBuffer
---@field bufnr integer
---@field opts  ezdap.AddBufOpts

---A run: a unique id, the task name, a cancel function, the buffers it spawned
---(REPL, Output, Terminal, DAP messages) and how it is faring. Runs are tracked
---together so tasks can run in parallel.
---@class ezdap.runner.Run
---@field id      string
---@field name    string
---@field cancel  fun()
---@field buffers ezdap.runner.RunBuffer[]
---@field state   ezdap.runner.RunState
---@field log     ezdap.OutputBuffer  this run's own progress log; its buffer is one of `buffers`

-- Signals. A run's whole life is announced here and nowhere else: a view
-- subscribes to decide how runs are shown, and the runner stays out of it.

M.on_run_started = Signal.new() ---@type ezdap.util.Signal<fun(run: ezdap.runner.Run)>

M.on_run_buffer  = Signal.new() ---@type ezdap.util.Signal<fun(run: ezdap.runner.Run, bufnr: integer, opts: ezdap.AddBufOpts)>

M.on_run_state   = Signal.new() ---@type ezdap.util.Signal<fun(run: ezdap.runner.Run, state: ezdap.runner.RunState)>

---A run being forgotten, emitted while its buffers are still valid.
M.on_run_removed = Signal.new() ---@type ezdap.util.Signal<fun(run: ezdap.runner.Run)>

---@type ezdap.runner.Run[]
local _runs      = {}
local _counter   = 0

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

---Record a buffer on `run` and announce it. The run keeps it so it can be wiped
---when the run is forgotten, and so a view attaching later sees it.
---@param run ezdap.runner.Run
---@param bufnr integer
---@param opts? ezdap.AddBufOpts
local function _add_buf(run, bufnr, opts)
    opts                          = opts or {}
    run.buffers[#run.buffers + 1] = { bufnr = bufnr, opts = opts }
    M.on_run_buffer:emit(run, bufnr, opts)
end

-- A run's progress is appended to a scratch log buffer of its own, alongside the
-- Output and REPL, reachable by name (`:b ezdap://<run>-log`). Pre-flight errors
-- stay on vim.notify, happening before the run exists.

---Create a run's log — an `OutputBuffer` like the run's Output, so the line cap
---and autoscroll are the same ones — and register it as the lowest-ranked of the
---run's buffers, so it never displaces that Output.
---@param run ezdap.runner.Run
---@return ezdap.OutputBuffer
local function _make_log(run)
    local log = OutputBuffer.new({
        name       = ui_util.unique_buf_name("ezdap://" .. run.id .. ":log"),
        max_lines  = _config.output_max_lines,
        autoscroll = true,
    })

    _add_buf(run, assert(log:bufnr()), { label = "log", priority = -4, autoscroll = true })
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

---Announce a run's removal and wipe the buffers it spawned. The signal goes
---first, so subscribers are off those buffers before they are deleted.
---@param run ezdap.runner.Run
local function _remove_run(run)
    M.on_run_removed:emit(run)
    for _, b in ipairs(run.buffers) do
        if vim.api.nvim_buf_is_valid(b.bufnr) then
            pcall(vim.api.nvim_buf_delete, b.bufnr, { force = true })
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
        if r.state ~= "running" and r.name == name then
            _remove_run(r)
        else
            kept[#kept + 1] = r
        end
    end
    _runs = kept
end

---Forget a single run, announcing it and wiping its buffers. A live run is not
---stopped first — cancel it before removing it.
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
        if r.state ~= "running" then
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
    ---@diagnostic disable-next-line: missing-fields -- log is set right below, once `run` exists to hang it on
    local run = {
        id      = task.name .. "-" .. _counter,
        name    = task.name,
        cancel  = function() end,
        buffers = {},
        state   = "running",
    }
    _runs[#_runs + 1] = run

    -- Announced before it has any buffer, so a subscriber that renders a run as a
    -- whole (a tab, a status line) exists by the time the first one arrives.
    M.on_run_started:emit(run)
    -- The log is this run's own buffer, so its lines need no task-name prefix.
    run.log      = _make_log(run)

    local cancel = require("ezdap.task").start(task, {
        -- Announced for display, and tracked so `clean` can wipe them.
        add_bufnr = function(bufnr, opts)
            _add_buf(run, bufnr, opts)
        end,
        report    = function (msg)
            _log(run, msg)
        end,
        on_done   = function(ok)
            run.state = ok and "done" or "failed"
            M.on_run_state:emit(run, run.state)
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
---loaded and the value it returns is run — a mode-based task (`adapter`/`mode`/
---`parameters`), resolved through the mode's `build`.
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

    -- A mode-based run file names a mode and answers its inputs under
    -- `parameters`; resolve it through the mode's `build`, as `:Debug run` does.
    -- It may open a picker, so the run starts from the callback.
    if type(spec.mode) == "string" then
        local name = vim.fn.fnamemodify(resolved, ":t")
        require("ezdap.schema").resolve_task({
            adapter = spec.adapter,
            mode = spec.mode,
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

    _err("run: " .. vim.fn.fnamemodify(resolved, ":t") .. " must set `mode` (a named mode)")
end

---Launch or attach under an adapter's named mode, resolving `inputs` — the
---answers to the mode's declared inputs, in either authoring form — through
---`schema.resolve_task`.
---Returns nil when `build` stops to ask the user something — the run starts on answer.
---@param adapter string  adapter name, e.g. "codelldb"
---@param mode_name string  mode name, e.g. "binary"
---@param inputs? table<string, string>  input name -> value, e.g. { command = "./a.out" }
---@return ezdap.runner.Run?
function M.run_mode(adapter, mode_name, inputs)
    local schema = require("ezdap.schema")

    if not adapter or adapter == "" then
        _warn(("run: usage: :%s run <adapter> <mode> [input=value]…")
            :format(require("ezdap.config").command))
        return
    end
    if not require("ezdap.adapters")[adapter] then
        _err("run: unknown adapter: " .. adapter ..
            " (available: " .. table.concat(schema.adapters_with_modes(), ", ") .. ")")
        return
    end
    if not mode_name or mode_name == "" then
        _warn("run: usage: :" .. require("ezdap.config").command
            .. " run " .. adapter .. " <mode> [input=value]…"
            .. " (modes: " .. table.concat(schema.mode_names(adapter), ", ") .. ")")
        return
    end

    local values = inputs or {}

    -- A mode whose `build` asks the user something (an attach resolving an unset
    -- `pid`) resolves only once they answer, so the run starts from the callback.
    -- Every other mode resolves synchronously, assigning `run` before we return.
    local run
    schema.resolve_task({
        adapter = adapter,
        mode = mode_name,
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
        if r.state == "running" then r.cancel() end
    end
end

---The most recently started live run, or nil.
---@return ezdap.runner.Run?
function M.active()
    for i = #_runs, 1, -1 do
        if _runs[i].state == "running" then return _runs[i] end
    end
    return nil
end

---Every tracked run, live and finished, in start order — how a subscriber
---attaching after the fact catches up with the runs it missed.
---@return ezdap.runner.Run[]
function M.runs()
    return vim.list_slice(_runs)
end

return M
