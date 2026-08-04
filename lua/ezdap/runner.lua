---@brief Standalone task runner for ezdap.
---
---Runs a debug task without easytasks by supplying ezdap's own run callbacks
---to `ezdap.task.start`. `ezdap.task` stays provider-agnostic: easytasks
---supplies its own callbacks via its backend; this module is the standalone
---equivalent (progress, run lifecycle).
---
---A run's buffers are shown in the shared bottom window (`ezdap.ui.output_win`),
---which holds whichever of them has the highest priority; they are tracked here
---as well so a finished run's buffers can be wiped.
---
---One task per file: a run file returns a single task (or a function
---returning one):
---  -- debug.lua
---  return { name = "debug app", adapter = "lldb", configuration = { request = "launch", program = "a.out" } }

local M        = {}

---A run: a unique id, the task name, a cancel function, the buffers it spawned
---(REPL, Output, Terminal, DAP messages), and whether it has finished. Runs are
---tracked together so tasks can run in parallel.
---@class ezdap.runner.Run
---@field id     string
---@field name   string
---@field cancel fun()
---@field bufnrs integer[]
---@field done   boolean

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

-- Run progress is appended to a scratch log buffer, reachable by name
-- (`:b ezdap://log`) or via `:Debug log`. Pre-flight errors stay on
-- vim.notify, happening before the run exists.

local _log_buf ---@type integer?

---Cap on the log buffer's line count; `_log` trims oldest lines past this.
local _MAX_LOG_LINES = 10000

---@return integer
local function _log_bufnr()
    if _log_buf and vim.api.nvim_buf_is_valid(_log_buf) then return _log_buf end
    _log_buf                    = vim.api.nvim_create_buf(false, true)
    vim.bo[_log_buf].buftype    = "nofile"
    vim.bo[_log_buf].swapfile   = false
    vim.bo[_log_buf].buflisted  = true
    vim.bo[_log_buf].bufhidden  = "hide"
    vim.bo[_log_buf].modifiable = false

    local bufname               = "ezdap://log"
    local oldbuf                = vim.fn.bufnr(bufname)
    if oldbuf > 0 then vim.api.nvim_buf_delete(oldbuf, {}) end
    vim.api.nvim_buf_set_name(_log_buf, bufname)
    return _log_buf
end

---A scratch buffer always holds at least one line, so emptiness is that single
---line being blank.
---@param buf integer
---@return boolean
local function _buf_empty(buf)
    return vim.api.nvim_buf_line_count(buf) == 1
        and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
end

---Append timestamped lines to the log buffer, which every run shares. Oldest
---lines are trimmed past `_MAX_LOG_LINES` so the buffer never grows unbounded
---across a long session.
---@param msg string
local function _log(msg)
    local stamp = os.date("%H:%M:%S")
    local lines = {}
    for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
        lines[#lines + 1] = ("[%s] %s"):format(stamp, l)
    end

    local buf              = _log_bufnr()
    local empty            = _buf_empty(buf)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, lines)
    local overflow = vim.api.nvim_buf_line_count(buf) - _MAX_LOG_LINES
    if overflow > 0 then
        vim.api.nvim_buf_set_lines(buf, 0, overflow, false, {})
    end
    vim.bo[buf].modifiable = false
end

---Wipe the buffers a run spawned.
---@param run ezdap.runner.Run
local function _remove_run(run)
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

---Show the shared run log in the window a run's own buffers use, parked on its
---last line. Opens nothing when no run has logged anything yet. Bound to
---`:Debug log`.
function M.log_open()
    if not _log_buf or not vim.api.nvim_buf_is_valid(_log_buf) or _buf_empty(_log_buf) then
        _warn("log: nothing logged yet")
        return
    end
    local buf        = _log_bufnr()
    local output_win = require("ezdap.ui.output_win")
    -- Ranked below every run buffer, so the window hands itself back to the run's
    -- own output the next time one registers; `show` overrides that for now.
    output_win.show(buf, { label = "Log", priority = -4 })
    local win = output_win.winid()
    if win then
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
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
    local run = {
        id     = task.name .. "-" .. _counter,
        name   = task.name,
        cancel = function() end,
        bufnrs = {},
        done   = false,
    }
    _runs[#_runs + 1] = run

    local cancel = require("ezdap.task").start(task, {
        -- Shown in the shared bottom window, and tracked so `clean` can wipe them.
        add_bufnr = function(bufnr, opts)
            run.bufnrs[#run.bufnrs + 1] = bufnr
            require("ezdap.ui.output_win").add(bufnr, opts)
        end,
        report    = function (msg)
            _log(task.name .. ": " .. msg)
        end,
        on_done   = function(ok)
            run.done = true
            _log(task.name .. (ok and " finished" or " failed"))
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
