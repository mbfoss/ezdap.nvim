---@brief The dock.nvim panel backend: one dock group (a tab) per run under the
---`ezdap` source, each of the run's buffers a page in it.
---
---It subscribes to `ezdap.runner` itself; `setup` starts it in place of
---`ezdap.ui.output_win` when dock.nvim is installed. dock owns the window, the
---tab bar and the focus rules; ezdap keeps owning its buffers, which is why a
---group is dropped rather than cleaned when the run's buffers are wiped.

local format = require("ezdap.ui.format")

local M      = {}

---Whether this backend was started. Everything below is inert until it is, so
---`:Debug output` reaches the backend that is in play — and nothing here
---requires `dock` before `setup` has established that it is there.
local _enabled = false

---@type dock.Source?
local _source

---@return dock.Source
local function _src()
    if not _source then _source = require("dock").source("ezdap") end
    return _source
end

---The dock group showing each run, keyed by run id.
---@type table<string, dock.Group>
local _groups = {}

---A run's state as a tab glyph, drawn from the same signs and highlights the
---views use, so a running run reads the same in the dock as in the DebugView.
---@param state? ezdap.runner.RunState
---@return dock.Badge?
local function _badge(state)
    if state == "running" then
        local icon, hl = format.session_sign({ state = "running" })
        return { icon = icon, hl = hl }
    elseif state == "done" then
        local icon, hl = format.session_sign({ state = "terminated" })
        return { icon = icon, hl = hl }
    elseif state == "failed" then
        return { icon = require("ezdap.config").signs.unsupported_breakpoint, hl = format.hl.exception }
    end
    return nil
end

---The group showing `run`, created on first sight of it. This is where a run
---becomes a tab; the runner never asks for one.
---@param run ezdap.runner.Run
---@return dock.Group
local function _group(run)
    local group = _groups[run.id]
    if group then return group end
    group = _src():group({
        id                = run.id,
        label             = run.name,
        badge             = _badge(run.state),
        busy              = run.state == "running",
        remove_when_empty = true,
        -- dock asking a tab to shed itself (`:Dock clean`) gets the same answer
        -- `runner.clean` gives: a finished run goes, a live one stays. Dropping
        -- the run brings its group down with it.
        on_clean          = function()
            if run.state ~= "running" then require("ezdap.runner").remove(run) end
        end,
    })
    _groups[run.id] = group
    return group
end

---@param run ezdap.runner.Run
---@param bufnr integer
---@param opts? ezdap.AddBufOpts
local function _page(run, bufnr, opts)
    opts = opts or {}
    _group(run):page({ buf = bufnr, label = opts.label, priority = opts.priority })
end

---Subscribe to the runner and adopt any run that started before now — the whole
---connection between the two. Called from `setup` when dock.nvim is installed;
---safe to call again.
function M.init()
    if _enabled then return end
    _enabled = true

    local runner = require("ezdap.runner")
    -- Groups are made on the run's own signal, not on its first buffer, so a run
    -- has its tab by the time anything lands in it.
    runner.on_run_started:subscribe(function(run) _group(run) end)
    runner.on_run_buffer:subscribe(_page)
    runner.on_run_state:subscribe(function(run, state)
        _group(run):set_busy(state == "running"):set_badge(_badge(state))
    end)
    runner.on_run_removed:subscribe(function(run)
        local group = _groups[run.id]
        _groups[run.id] = nil
        if group then group:remove() end
    end)

    -- A run that started before now carries everything needed to render it after
    -- the fact.
    for _, run in ipairs(runner.runs()) do
        _group(run)
        for _, buf in ipairs(run.buffers) do _page(run, buf.bufnr, buf.opts) end
    end
end

-- Panel-level operations. The dock is shared with other plugins, so these act on
-- the whole panel, not on ezdap's tabs alone.

---@param focus? boolean
function M.open(focus)
    if _enabled then require("dock").open({ enter = focus or false }) end
end

function M.close()
    if _enabled then require("dock").close() end
end

function M.toggle()
    if _enabled then require("dock").toggle({ enter = true }) end
end

---@return integer?
function M.winid()
    return _enabled and require("dock").panel():win() or nil
end

return M
