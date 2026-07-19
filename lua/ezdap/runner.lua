local ui_util  = require "ezdap.util.ui_util"
---@brief Standalone task runner for ezdap.
---
---Runs a debug task without easytasks by supplying ezdap's own run callbacks
---to `ezdap.task.start`. `ezdap.task` stays provider-agnostic: easytasks
---supplies its own callbacks via its backend; this module is the standalone
---equivalent (buffer presentation, progress, run lifecycle).
---
---One task per file: a run file returns a single task (or a function
---returning one):
---  -- debug.lua
---  return { name = "debug app", adapter = "lldb", configuration = { request = "launch", program = "a.out" } }

local M        = {}

---A run: a unique id (used as its panel group), the task name, a cancel
---function, the buffers it spawned (REPL, Output, Terminal, DAP messages), and
---whether it has finished. Runs are tracked together so tasks can run in parallel.
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

-- Run panel: a single bottom split (ezdap.ui.Panel) hosts every buffer a run
-- registers and pages between them via a winbar. Run progress goes to the report
-- page; pre-flight errors stay on vim.notify, happening before any panel exists.

local _report_buf ---@type integer?
local _panel ---@type ezdap.ui.Panel?

---Cap on the report buffer's line count; `_report` trims oldest lines past this.
local _MAX_REPORT_LINES = 10000

---@return ezdap.ui.Panel
local function _get_panel()
    if not _panel then _panel = require("ezdap.ui.Panel").new() end
    return _panel
end

---@return integer
local function _report_bufnr()
    if _report_buf and vim.api.nvim_buf_is_valid(_report_buf) then return _report_buf end
    _report_buf                    = vim.api.nvim_create_buf(false, true)
    vim.bo[_report_buf].buftype    = "nofile"
    vim.bo[_report_buf].swapfile   = false
    vim.bo[_report_buf].bufhidden  = "hide"
    vim.bo[_report_buf].modifiable = false

    local bufname                  = "ezdap://reports"
    local oldbuf                   = vim.fn.bufnr(bufname)
    if oldbuf > 0 then vim.api.nvim_buf_delete(oldbuf, {}) end
    vim.api.nvim_buf_set_name(_report_buf, bufname)
    return _report_buf
end

---Show the shared report page in the run panel. Group-less, so it renders before
---any run group. Priority -1 keeps it visible during setup while real program
---output (Output 0, Terminal 10) surfaces over it once it arrives.
local function _report_open()
    _get_panel():add(_report_bufnr(), { label = "Messages", priority = -1, autoscroll = true })
end

---Append timestamped lines to the report buffer. The panel autoscrolls the page
---while it is the active one. Oldest lines are trimmed past `_MAX_REPORT_LINES`
---so the buffer never grows unbounded across a long session.
---@param msg string
local function _report(msg)
    local stamp = os.date("%H:%M:%S")
    local lines = {}
    for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
        lines[#lines + 1] = ("[%s] %s"):format(stamp, l)
    end

    local buf              = _report_bufnr()
    local empty            = vim.api.nvim_buf_line_count(buf) == 1
        and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, lines)
    local overflow = vim.api.nvim_buf_line_count(buf) - _MAX_REPORT_LINES
    if overflow > 0 then
        vim.api.nvim_buf_set_lines(buf, 0, overflow, false, {})
    end
    vim.bo[buf].modifiable = false
end

---Remove a run's group from the panel and wipe the buffers it spawned.
---@param run ezdap.runner.Run
local function _remove_run(run)
    _get_panel():remove_group(run.id)
    for _, b in ipairs(run.bufnrs) do
        if vim.api.nvim_buf_is_valid(b) then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
end

---Drop any finished run of the same name from the panel and wipe its buffers, so
---re-running a task replaces its own previous run. Live runs and finished runs of
---other tasks are left untouched, so parallel runs accumulate as separate groups.
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

---Drop every finished run from the panel and wipe their buffers, leaving live
---runs untouched. Bound to `:Debug panel clean`.
function M.panel_clean()
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

---Run a debug task. Tasks may run in parallel: each run gets its own panel group
---and does not cancel the others. Re-running a task replaces its own previous
---finished run. Returns nil when `task` is not a valid task table.
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
        id     = task.name .. "#" .. _counter,
        name   = task.name,
        cancel = function() end,
        bufnrs = {},
        done   = false,
    }
    _runs[#_runs + 1] = run

    _report_open()
    _report("▶ " .. task.name)

    local cancel = require("ezdap.task").start(task, {
        add_bufnr = function(bufnr, opts)
            opts = opts or {}
            run.bufnrs[#run.bufnrs + 1] = bufnr
            _get_panel():add(bufnr, {
                label       = opts.label,
                priority    = opts.priority,
                autoscroll  = opts.autoscroll,
                group       = run.id,
                group_label = run.name,
            })
        end,
        report    = _report,
        on_done   = function(ok)
            run.done = true
            _report((ok and "✓ " or "✗ ") .. task.name .. (ok and " finished" or " failed"))
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
    -- `parameters`; resolve it through the profile's `build`, as `quick_run` does.
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
            task.raw_messages = spec.raw_messages
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
            name         = spec.name,
            adapter      = spec.adapter,
            request      = request,
            parameters   = body,
            host         = spec.host,
            port         = spec.port,
            raw_messages = spec.raw_messages,
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
function M.quick_run(assignments)
    local schema = require("ezdap.schema")

    -- The adapter and profile name are strictly the first two positional
    -- arguments (`quick_run codelldb launch …`); every argument from the
    -- third on is an `input=value` assignment.
    local adapter, profile_name = assignments[1], assignments[2]
    if not adapter or adapter == "" or adapter:find("=", 1, true) then
        _warn("quick_run: usage: quick_run <adapter> <profile> [input=value]…")
        return
    end
    if not require("ezdap.adapters")[adapter] then
        _err("quick_run: unknown adapter: " .. adapter ..
            " (available: " .. table.concat(schema.profiled_adapters(), ", ") .. ")")
        return
    end
    if not profile_name or profile_name == "" or profile_name:find("=", 1, true) then
        _warn("quick_run: usage: quick_run " .. adapter .. " <profile> [input=value]…"
            .. " (profiles: " .. table.concat(schema.profile_names(adapter), ", ") .. ")")
        return
    end

    local values = {}
    for i = 3, #assignments do
        local tok = assignments[i]
        local eq = tok:find("=", 1, true)
        if not eq then
            _warn("quick_run: expected input=value, got '" .. tok .. "'")
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
            _err("quick_run: " .. tostring(err))
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

---The run panel, or nil (with a hint) before the first run when none exists yet.
---@return ezdap.ui.Panel?
local function _panel_or_warn()
    if not _panel then
        _warn("run panel: nothing to show yet (run a task first)")
        return nil
    end
    return _panel
end

---Show or hide the run panel. Hosted buffers persist while hidden, so toggling
---it back restores the same tabs.
function M.panel_toggle()
    local p = _panel_or_warn()
    if p then p:toggle() end
end

---Jump to the n-th panel tab (1-based, matching the numbers shown in the winbar).
---@param n integer?
function M.panel_jump(n)
    local p = _panel_or_warn()
    if not p then return end
    if type(n) ~= "number" then
        _warn("panel jump: expected a tab number, e.g. :Debug panel jump 2")
        return
    end
    p:show_index(n)
end

---Show the next panel tab, wrapping.
function M.panel_next()
    local p = _panel_or_warn()
    if p then p:next() end
end

---Show the previous panel tab, wrapping.
function M.panel_prev()
    local p = _panel_or_warn()
    if p then p:prev() end
end

---Tab numbers as strings, for `:Debug panel jump` completion. Empty when no panel.
---@return string[]
function M.panel_tab_numbers()
    if not _panel then return {} end
    local out = {}
    for i = 1, _panel:tab_count() do out[i] = tostring(i) end
    return out
end

return M
