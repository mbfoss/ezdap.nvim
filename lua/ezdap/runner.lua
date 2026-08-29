---@brief Standalone task runner for ezdap.
---
---Runs a debug task by supplying run callbacks to `ezdap.task.start`, which
---stays provider-agnostic. Every run — `:Debug run`, a run file, or another
---plugin's task — goes through here, so resolving a mode, tracking the run and
---cancelling it are written once.
---
---A run announces itself through signals — it started, it spawned a buffer, its
---state changed, it is gone — and holds the buffers it spawned so a late
---subscriber can catch up. Whether and how any of it is shown is the panel
---backends' decision; nothing here knows about windows.
---
---A run given a `presenter` (`ezdap.runner.Presenter`) inverts that: the presenter
---takes the buffers, the progress and the outcome through its own callbacks, and
---the run is never announced — ezdap's panels do not show what another plugin is
---already showing.
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
---@field id       string
---@field name     string
---@field cancel   fun()
---@field buffers   ezdap.runner.RunBuffer[]  empty when presented elsewhere: the presenter holds its own
---@field sessions  integer[]  the sessions this run started, filled in as they start
---@field state     ezdap.runner.RunState
---@field presenter? ezdap.runner.Presenter  whoever shows this run, when it is not ezdap itself
---@field log?      ezdap.OutputBuffer  this run's own progress log, one of its `buffers` (a presented run reports to its presenter instead)
---@field settled?  boolean  whether the presenter has been told how the run ended

---A caller showing a run in a UI of its own: it takes the run's buffers,
---progress and outcome through these callbacks — the same ones `ezdap.task`
---speaks — instead of ezdap's own log buffer and run signals.
---@class ezdap.runner.Presenter : ezdap.TaskCallback
---@field name? string  run group name (defaults to the adapter's)

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
    opts = opts or {}
    -- A presented run's buffers are the presenter's: it is handed them and does its
    -- own bookkeeping, so nothing is tracked or announced here.
    if run.presenter then return run.presenter.add_bufnr(bufnr, opts) end
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
    if run.presenter then return run.presenter.report(msg) end
    local stamp = os.date("%H:%M:%S")
    local lines = {}
    for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
        lines[#lines + 1] = ("[%s] %s"):format(stamp, l)
    end
    run.log:append(lines)
end

---Announce a run's removal and wipe the buffers it spawned. The signal goes
---first, so subscribers are off those buffers before they are deleted. A
---presented run has neither: its presenter disposes of it.
---@param run ezdap.runner.Run
local function _remove_run(run)
    -- A presented run was never announced and holds no buffers of ours: dropping it
    -- from the tracking above is all there is to do.
    if run.presenter then return end
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
        if r.state ~= "running" and r.name == name and not r.presenter then
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

---Drop every finished run and wipe their buffers, leaving live runs — and every
---run presented elsewhere, which is its presenter's to dispose of — untouched.
---Bound to `:Debug clean`.
function M.clean()
    local kept, finished = {}, {}
    for _, r in ipairs(_runs) do
        if r.state ~= "running" and not r.presenter then
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

---Create, track and announce a run, and give it the log it reports into. A
---presented run is neither announced nor given a log: it reports to its
---presenter, which is showing it, so ezdap's own panels must never see it.
---@param name string  run group name
---@param presenter? ezdap.runner.Presenter
---@return ezdap.runner.Run
local function _new_run(name, presenter)
    _clear_finished(name)

    _counter = _counter + 1
    ---@type ezdap.runner.Run
    local run = {
        id        = name .. "-" .. _counter,
        name      = name,
        cancel    = function() end,
        buffers   = {},
        sessions  = {},
        state     = "running",
        presenter = presenter,
    }
    _runs[#_runs + 1] = run

    if not presenter then
        -- Announced before it has any buffer, so a subscriber that renders a run as a
        -- whole (a tab, a status line) exists by the time the first one arrives.
        M.on_run_started:emit(run)
        -- The log is this run's own buffer, so its lines need no task-name prefix.
        run.log = _make_log(run)
    end
    return run
end

---Record how a run is faring and tell whoever is watching it.
---@param run ezdap.runner.Run
---@param state ezdap.runner.RunState
local function _set_state(run, state)
    run.state = state
    if run.presenter then
        -- `on_done` is a one-shot contract, and says how the run ended by itself:
        -- whatever ends after it — a second session, a late cancel — is no longer
        -- the presenter's business, and the log line would only repeat it.
        if not run.settled then
            run.settled = true
            run.presenter.on_done(state == "done")
        end
        return
    end
    M.on_run_state:emit(run, state)
    _log(run, state == "done" and "finished" or state)
end

---Start a resolved task into a run that already exists, wiring up the callbacks
---it reports through and taking over its `cancel`.
---@param run ezdap.runner.Run
---@param task ezdap.Task
local function _start(run, task)
    -- `rerun` re-launches into ezdap's own UI; a presented run is its presenter's
    -- to repeat.
    if not run.presenter then _last_task = task end

    local cancel, sessions = require("ezdap.task").start(task, {
        -- Announced for display, and tracked so `clean` can wipe them.
        add_bufnr = function(bufnr, opts) _add_buf(run, bufnr, opts) end,
        report    = function(msg) _log(run, msg) end,
        on_done   = function(ok) _set_state(run, ok and "done" or "failed") end,
    })

    run.cancel   = cancel
    -- Held by reference: the sessions land in it as they start.
    run.sessions = sessions
end

---Resolve one of an adapter's named modes through its `build` and run it. The run
---exists before `build` is asked anything, so a mode that stops to ask the user
---something still has a run to report into and a `cancel` that calls the question
---off — where a resolve that never answers would otherwise leave nothing to stop.
---@param spec ezdap.ResolveSpec  `name` is the run group name, defaulting to the adapter's
---@param presenter? ezdap.runner.Presenter
---@return ezdap.runner.Run
local function _run_spec(spec, presenter)
    local run = _new_run(spec.name or spec.adapter, presenter)

    -- Cancelling while the mode is still resolving calls the question off and fails
    -- the run. It goes on before resolving, not after: a mode that asks nothing
    -- resolves and starts inside the call below, and `_start` must have the last
    -- word on `cancel` — that one has a session to stop.
    local cancel_resolve
    run.cancel = function()
        if cancel_resolve then cancel_resolve() end
        if run.state == "running" then _set_state(run, "failed") end
    end

    cancel_resolve = require("ezdap.schema").resolve_task(spec, function(task, err)
        -- Cancelled while resolving: the run is already settled and nothing starts.
        if run.state ~= "running" then return end
        if not task then
            local msg = ("run: %s: %s"):format(run.name, tostring(err))
            _log(run, msg)
            -- A presented run shows its own log; only ezdap's own runs need the notify.
            if not presenter then _err(msg) end
            return _set_state(run, "failed")
        end
        _start(run, task)
    end)

    return run
end

---Re-launch the most recently run task from scratch, skipping the resolve it
---already went through. Unlike `:Debug restart` (a DAP request on the live
---session) this works after the session has ended and for adapters without
---restart support. Runs alongside the others: it replaces its own previous
---finished run, not theirs. Warns when no task has been run yet.
---@return ezdap.runner.Run?
function M.rerun()
    if not _last_task then
        _warn("rerun: nothing to re-run yet (run a task first)")
        return
    end
    -- Copied because `_start` records it as the task to rerun next time, and the
    -- one held here must not be the one a run is mutating.
    local task = vim.deepcopy(_last_task)
    local run  = _new_run(task.name or "debug")
    _start(run, task)
    return run
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
---@return ezdap.runner.Run?  nil when the path yields no task to run
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
    if type(spec.mode) == "string" then
        return _run_spec({
            adapter = spec.adapter,
            mode    = spec.mode,
            name    = spec.name or vim.fn.fnamemodify(resolved, ":t"),
            values  = spec.parameters,
        })
    end

    _err("run: " .. vim.fn.fnamemodify(resolved, ":t") .. " must set `mode` (a named mode)")
end

---Launch or attach under an adapter's named mode, resolving `inputs` — the
---answers to the mode's declared inputs, in either authoring form — through
---`schema.resolve_task`. The run is returned right away, even when `build` stops
---to ask the user something: it starts, or fails, once they answer.
---@param adapter string  adapter name, e.g. "codelldb"
---@param mode_name string  mode name, e.g. "binary"
---@param inputs? table<string, string>  input name -> value, e.g. { command = "./a.out" }
---@param presenter? ezdap.runner.Presenter  a caller showing the run in a UI of its own
---@return ezdap.runner.Run?
function M.run_mode(adapter, mode_name, inputs, presenter)
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

    return _run_spec({
        adapter = adapter,
        mode    = mode_name,
        name    = (presenter and presenter.name) or adapter,
        values  = inputs or {},
    }, presenter)
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

---Every run ezdap shows, live and finished, in start order — how a subscriber
---attaching after the fact catches up with the runs it missed. Runs presented
---elsewhere are absent: they were never announced, so no subscriber may see them.
---@return ezdap.runner.Run[]
function M.runs()
    local out = {}
    for _, r in ipairs(_runs) do
        if not r.presenter then out[#out + 1] = r end
    end
    return out
end

return M
