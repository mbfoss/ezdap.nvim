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

---A live run: the task name, a cancel function, and the buffers the task
---spawned (REPL, Output, Terminal, DAP messages).
---@class easydap.runner.Run
---@field name   string
---@field cancel fun()
---@field bufnrs integer[]

---@type easydap.runner.Run?
local _active

---@param msg string
local function _warn(msg) vim.notify("[easydap] " .. msg, vim.log.levels.WARN) end

---@param msg string
local function _err(msg) vim.notify("[easydap] " .. msg, vim.log.levels.ERROR) end

---@param v any
---@return boolean
local function _is_task(v)
    return type(v) == "table" and type(v.adapter) == "string"
end

-- ── Report window ──────────────────────────────────────────────────────────
-- Adapter/run progress goes to a dedicated split rather than vim.notify, which
-- is spammy during setup. The buffer accumulates across runs (each prefixed
-- with a banner); lines autoscroll while the window is visible. Pre-flight
-- errors (bad path, etc.) stay on vim.notify — they happen before any run.

local _report_buf  ---@type integer?
local _report_win  ---@type integer?
local _panel_wins  = {} ---@type integer[]  -- run-panel windows, left-to-right insertion order

---Surviving panel windows, in insertion order (prunes ones the user closed).
---@return integer[]
local function _panel_valid()
    local out = {}
    for _, w in ipairs(_panel_wins) do
        if vim.api.nvim_win_is_valid(w) then out[#out + 1] = w end
    end
    _panel_wins = out
    return out
end

---Show `bufnr` in the run panel without stealing focus. The first panel buffer
---opens a horizontal split at the bottom; subsequent ones open a vertical split
---to the right of the last pane, tiling the bottom row in insertion order.
---`height` applies only to the initial horizontal split. Reuses any window
---already showing `bufnr`.
---@param bufnr integer
---@param height integer?
---@return integer win
local function _panel_show(bufnr, height)
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == bufnr then return w end
    end

    local cur   = vim.api.nvim_get_current_win()
    local valid = _panel_valid()
    local win
    if #valid > 0 then
        vim.api.nvim_set_current_win(valid[#valid]) -- split the last pane → new one on its right
        vim.cmd("rightbelow vsplit")
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, bufnr)
    else
        vim.cmd("botright " .. (height and (height .. "split") or "split"))
        win = vim.api.nvim_get_current_win()
        vim.api.nvim_win_set_buf(win, bufnr)
    end
    _panel_wins[#_panel_wins + 1] = win

    vim.wo[win].number         = false
    vim.wo[win].relativenumber = false
    vim.wo[win].winfixheight   = true
    if vim.api.nvim_win_is_valid(cur) then vim.api.nvim_set_current_win(cur) end
    return win
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

---@return boolean
local function _report_visible()
    return _report_win ~= nil
        and vim.api.nvim_win_is_valid(_report_win)
        and vim.api.nvim_win_get_buf(_report_win) == _report_buf
end

---Open the report window in a bottom split without stealing focus. Reuses an
---existing window already showing the buffer.
local function _report_open()
    if _report_visible() then return end
    _report_win            = _panel_show(_report_bufnr(), 8)
    vim.wo[_report_win].wrap = false
end

---Append timestamped lines to the report buffer; autoscroll if visible.
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

    if _report_visible() then
        pcall(vim.api.nvim_win_set_cursor, _report_win, { vim.api.nvim_buf_line_count(buf), 0 })
    end
end

---Surface a spawned run buffer. The DebugView and REPL open on their own (the
---DebugView on session start, the REPL is created up front), so only the
---Output and Terminal buffers need a window; tile them into the run panel
---(vertical splits beside the report window) without stealing focus.
---@param bufnr integer
---@param label string?
local function _present(bufnr, label)
    if label ~= "Output" and label ~= "Terminal" then return end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    _panel_show(bufnr)
end

---Run a single debug task. Cancels the previous active run first. The returned
---handle is also stored as the active run (see `M.active`). Returns nil when
---`task` is not a valid task table.
---@param task easydap.Task
---@return easydap.runner.Run?
function M.run(task)
    if not _is_task(task) then
        _err("run: expected a task table with an `adapter` field")
        return
    end
    if _active then _active.cancel() end

    task      = vim.deepcopy(task)
    task.name = task.name or "debug"

    _report_open()
    _report("▶ " .. task.name)

    ---@type easydap.runner.Run
    local run = { name = task.name, cancel = function() end, bufnrs = {} }

    local cancel = require("easydap.task").start(task, {
        add_bufnr = function(bufnr, label, _)
            run.bufnrs[#run.bufnrs + 1] = bufnr
            _present(bufnr, label)
        end,
        report    = _report,
        on_done   = function(ok)
            if _active == run then _active = nil end
            _report((ok and "✓ " or "✗ ") .. task.name .. (ok and " finished" or " failed"))
        end,
    })

    run.cancel = cancel
    _active    = run
    return run
end

---Load a Lua file and run the single task it returns (or that its returned
---function produces). Reports a clear error for every failure mode instead of
---throwing: missing/empty path, non-`.lua` path, file not found, load or
---runtime error, or a file that does not return a task.
---@param path string
function M.run_file(path)
    if type(path) ~= "string" or path == "" then
        _warn("run: no file path given (usage: run('path/to/task.lua'))")
        return
    end

    local resolved = vim.fn.fnamemodify(vim.fn.expand(path), ":p")
    if not resolved:match("%.lua$") then
        _warn("run: not a Lua file: " .. resolved)
        return
    end
    ---@diagnostic disable-next-line: undefined-field
    if not vim.uv.fs_stat(resolved) then
        _warn("run: file not found: " .. resolved)
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

---Cancel the active run, if any. Stops its sessions, or aborts a run still in
---adapter setup (before any session exists, where `:Debug stop` has nothing to
---act on yet).
function M.cancel()
    if _active then _active.cancel() end
end

---The currently active run, or nil.
---@return easydap.runner.Run?
function M.active()
    return _active
end

return M
