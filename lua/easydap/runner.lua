---@brief Standalone task runner for easydap.
---
---Runs a debug task without easytasks by supplying easydap's own run callbacks
---to `easydap.task.start`. `easydap.task` stays provider-agnostic: easytasks
---supplies its own callbacks via its backend; this module is the standalone
---equivalent (buffer presentation, progress, run lifecycle).
---
---One task per file: a config file returns a single task (or a function
---returning one):
---  -- debug.lua
---  return { name = "debug app", adapter = "lldb", request = "launch", request_args = { program = "a.out" } }

local M = {}

---A debug task: the generic fields consumed by `easydap.task` and the adapters.
---Mirrors what easytasks sends as `debug.Params`; `name` defaults to "debug".
---@class easydap.Task
---@field name?            string
---@field adapter          string                  name of an entry in `easydap.adapters`
---@field request?         "launch"|"attach"
---@field host?            string                  attach only
---@field port?            integer                 attach only (required for the `remote` adapter)
---@field command?         string|string[]         program to debug ([program, arg1, …] shorthand allowed)
---@field cwd?             string
---@field env?             table<string,string>
---@field clear_env?       boolean                 pass `env` verbatim without merging the process environment
---@field run_in_terminal? boolean
---@field stop_on_entry?   boolean
---@field request_args?    table                   sent verbatim in the launch/attach request (overrides the generic fields)
---@field raw_messages?    boolean                 capture raw DAP protocol messages in a dedicated buffer

---A run: a unique id (used as its panel group), the task name, a cancel
---function, the buffers it spawned (REPL, Output, Terminal, DAP messages), and
---whether it has finished. Runs are tracked together so tasks can run in parallel.
---@class easydap.runner.Run
---@field id     string
---@field name   string
---@field cancel fun()
---@field bufnrs integer[]
---@field done   boolean

---@type easydap.runner.Run[]
local _runs    = {}
local _counter = 0

---The most recently run task, kept so `rerun()` can re-launch it from scratch.
---@type easydap.Task?
local _last_task

---@param msg string
local function _warn(msg) vim.notify("[easydap] " .. msg, vim.log.levels.WARN) end

---@param msg string
local function _err(msg) vim.notify("[easydap] " .. msg, vim.log.levels.ERROR) end

---@param v any
---@return boolean
local function _is_task(v)
    return type(v) == "table" and type(v.adapter) == "string"
end

-- ── Run panel ──────────────────────────────────────────────────────────────
-- A single bottom split (easydap.ui.Panel) hosts every buffer a run registers —
-- the report, REPL, output, terminal and DAP-message buffers — and pages between
-- them via a winbar. Adapter/run progress goes to the report page rather than
-- vim.notify, which is spammy during setup. Pre-flight errors (bad path, etc.)
-- stay on vim.notify — they happen before any run, hence before any panel.

local _report_buf  ---@type integer?
local _panel       ---@type easydap.ui.Panel?

---@return easydap.ui.Panel
local function _get_panel()
    if not _panel then _panel = require("easydap.ui.Panel").new() end
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
    pcall(vim.api.nvim_buf_set_name, _report_buf, "easydap://reports")
    return _report_buf
end

---Show the shared report page in the run panel. Group-less, so it renders before
---any run group. Priority -1 keeps it visible during setup (REPL/adapter-log
---pages do not outrank it) while real program output (Output 0, Terminal 10)
---surfaces over it once it arrives.
local function _report_open()
    _get_panel():add(_report_bufnr(), { label = "Report", priority = -1, autoscroll = true })
end

---Append timestamped lines to the report buffer. The panel autoscrolls the page
---while it is the active one.
---@param msg string
local function _report(msg)
    local stamp = os.date("%H:%M:%S")
    local lines = {}
    for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
        lines[#lines + 1] = ("[%s] %s"):format(stamp, l)
    end

    local buf   = _report_bufnr()
    local empty = vim.api.nvim_buf_line_count(buf) == 1
        and vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] == ""
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, empty and 0 or -1, -1, false, lines)
    vim.bo[buf].modifiable = false
end

---Drop any finished run of the same name from the panel and wipe its buffers, so
---re-running a task replaces its own previous run. Live runs and finished runs of
---other tasks are left untouched, so parallel runs accumulate as separate groups.
---@param name string
local function _clear_finished(name)
    local kept = {}
    for _, r in ipairs(_runs) do
        if r.done and r.name == name then
            _get_panel():remove_group(r.id)
            for _, b in ipairs(r.bufnrs) do
                if vim.api.nvim_buf_is_valid(b) then
                    pcall(vim.api.nvim_buf_delete, b, { force = true })
                end
            end
        else
            kept[#kept + 1] = r
        end
    end
    _runs = kept
end

---Run a debug task. Tasks may run in parallel: each run gets its own panel group
---and is tracked alongside the others (it does not cancel them). Re-running a
---task replaces its own previous finished run. Returns nil when `task` is not a
---valid task table.
---@param task easydap.Task
---@return easydap.runner.Run?
function M.run(task)
    if not _is_task(task) then
        _err("run: expected a task table with an `adapter` field")
        return
    end

    task      = vim.deepcopy(task)
    task.name = task.name or "debug"
    _last_task = task

    _clear_finished(task.name)

    _counter = _counter + 1
    ---@type easydap.runner.Run
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

    local cancel = require("easydap.task").start(task, {
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

---Re-launch the most recently run task from scratch. Unlike `:Debug restart`
---(a DAP restart request on the live session), this works after the session has
---ended and for adapters without restart support, and re-reads nothing from disk.
---Warns when no task has been run yet.
---@return easydap.runner.Run?
function M.rerun()
    if not _last_task then
        _warn("rerun: nothing to re-run yet (run a task first)")
        return
    end
    return M.run(_last_task)
end

---Prompt to pick one of the Lua files directly in `dir`, then run it, using
---easydap's own fuzzy picker with a preview of each file. Runs the sole file
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
    require("easydap.util.select").open({
        prompt         = "Debug task",
        items          = items,
        enable_preview = true,
    }, function(data)
        if data and data.filepath then M.run_file(data.filepath) end
    end)
end

---Run a task from a path. A directory opens a picker of the Lua files in it (see
---`_run_from_dir`); a Lua file is loaded and the single task it returns (or that
---its returned function produces) is run. Reports a clear error for every failure
---mode instead of throwing: missing/empty path, path not found, non-`.lua` file,
---load or runtime error, or a file that does not return a task.
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

    local ok, task = pcall(chunk)
    if ok and type(task) == "function" then
        ok, task = pcall(task)
    end
    if not ok then
        _err("run: error in " .. resolved .. ": " .. tostring(task))
        return
    end

    if not _is_task(task) then
        _err("run: " .. vim.fn.fnamemodify(resolved, ":t") ..
            " must return a task table with an `adapter` field")
        return
    end

    M.run(task)
end

---Cancel every live run. Stops their sessions, or aborts a run still in adapter
---setup (before any session exists, where `:Debug stop` has nothing to act on yet).
function M.cancel()
    for _, r in ipairs(_runs) do
        if not r.done then r.cancel() end
    end
end

---The most recently started live run, or nil.
---@return easydap.runner.Run?
function M.active()
    for i = #_runs, 1, -1 do
        if not _runs[i].done then return _runs[i] end
    end
    return nil
end

---The run panel, or nil (with a hint) before the first run when none exists yet.
---@return easydap.ui.Panel?
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
