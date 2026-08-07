---@brief Where a run's buffers are shown — the seam between a run and whatever
---owns the window.
---
---`ezdap.runner` announces its runs, their buffers and their state through
---signals and knows nothing about windows; this module subscribes and decides
---how to show them. `dock.nvim` owns a shared, tabbed panel any plugin can draw
---into, so when it is installed each run becomes one dock group; otherwise runs
---share ezdap's own bottom split (`ezdap.ui.output_win`). Both backends answer
---the same channel API, so nothing above learns which one is in play.

local M = {}

---One run's slice of the panel: the buffers it spawned, plus how it is faring.
---A dock backend renders a channel as a tab; the fallback has a single window
---and ignores everything but the buffers.
---@class ezdap.ui.Channel
---@field add       fun(self: ezdap.ui.Channel, bufnr: integer, opts?: ezdap.AddBufOpts)
---@field show      fun(self: ezdap.ui.Channel, bufnr: integer, opts?: ezdap.AddBufOpts)  put `bufnr` on screen now, opening the panel
---@field set_state fun(self: ezdap.ui.Channel, state: ezdap.runner.RunState)
---@field remove    fun(self: ezdap.ui.Channel)  drop the channel; its buffers are the run's to wipe

---@class ezdap.ui.ChannelSpec
---@field id       string   stable per run, so re-creating one reuses its tab
---@field label    string
---@field state?   ezdap.runner.RunState
---@field on_clean fun()?   the backend asking the channel to shed itself (dock's `:Dock clean`)

---@class ezdap.ui.PanelBackend
---@field channel fun(spec: ezdap.ui.ChannelSpec): ezdap.ui.Channel
---@field open    fun(focus?: boolean)
---@field close   fun()
---@field toggle  fun()
---@field winid   fun(): integer?

---@type ezdap.ui.PanelBackend?
local _backend

---The channel showing each run, keyed by run id.
---@type table<string, ezdap.ui.Channel>
local _channels = {}

local _wired    = false

---The backend in use, resolved once: dock.nvim when it is on the runtimepath,
---ezdap's own bottom split otherwise.
---@return ezdap.ui.PanelBackend
local function _resolve()
    if not _backend then
        local has_dock = pcall(require, "dock")
        _backend = require(has_dock and "ezdap.ui.dock_panel" or "ezdap.ui.output_win")
    end
    return _backend
end

---The channel showing `run`, created on first sight of it. This is where a run
---becomes a piece of UI; the runner never asks for one.
---@param run ezdap.runner.Run
---@return ezdap.ui.Channel
local function _channel(run)
    local channel = _channels[run.id]
    if channel then return channel end
    channel = _resolve().channel({
        id       = run.id,
        label    = run.name,
        state    = run.state,
        -- A backend that can ask a channel to shed itself (dock's `:Dock clean`)
        -- gets the same answer `runner.clean` gives: a finished run goes, a live
        -- one stays. Dropping the run brings its channel down with it.
        on_clean = function()
            if run.state ~= "running" then require("ezdap.runner").remove(run) end
        end,
    })
    _channels[run.id] = channel
    return channel
end

---Put one of a run's buffers on screen now, parking an autoscrolling buffer on
---its last line so a log opens at its newest lines rather than its oldest.
---@param run ezdap.runner.Run
---@param bufnr integer
---@param opts? ezdap.AddBufOpts
local function _reveal(run, bufnr, opts)
    _channel(run):show(bufnr, opts)
    if not (opts and opts.autoscroll) then return end
    local win = M.winid()
    if win and vim.api.nvim_win_get_buf(win) == bufnr then
        vim.api.nvim_win_set_cursor(win, { vim.api.nvim_buf_line_count(bufnr), 0 })
    end
end

---Subscribe to the runner and adopt any run that started before now — the whole
---connection between the two. Called from `setup`; safe to call again.
function M.init()
    if _wired then return end
    _wired = true

    local runner = require("ezdap.runner")
    runner.on_run_started:subscribe(function(run) _channel(run) end)
    runner.on_run_buffer:subscribe(function(run, bufnr, opts) _channel(run):add(bufnr, opts) end)
    runner.on_run_state:subscribe(function(run, state) _channel(run):set_state(state) end)
    runner.on_run_reveal:subscribe(_reveal)
    runner.on_run_removed:subscribe(function(run)
        local channel = _channels[run.id]
        _channels[run.id] = nil
        if channel then channel:remove() end
    end)

    -- A run that started before `setup` (or before the panel was wired) carries
    -- everything needed to render it after the fact.
    for _, run in ipairs(runner.runs()) do
        local channel = _channel(run)
        for _, buf in ipairs(run.buffers) do channel:add(buf.bufnr, buf.opts) end
    end
end

---@param focus? boolean
function M.open(focus) _resolve().open(focus) end

function M.close() _resolve().close() end

function M.toggle() _resolve().toggle() end

---@return integer? winid  the panel window in this tabpage, when open
function M.winid() return _resolve().winid() end

return M
