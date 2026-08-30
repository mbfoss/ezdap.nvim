---@brief The dock.nvim run panel: one dock group (a tab) per run under the
---`ezdap` source, each of the run's buffers a page in it.
---
---An `ezdap.ui.RunPanel`, driven from `ezdap.ui.run_display`; `setup` puts it
---in play in place of `ezdap.ui.output_win` when dock.nvim is installed. dock owns
---the window, the tab bar and the focus rules; ezdap keeps owning its buffers,
---which is why a group is dropped rather than cleaned when the run's buffers are
---wiped.

local format = require("ezdap.ui.format")

local M      = {}

---Whether this panel was started. The dock operations below are inert until it
---is, so `:Debug output` reaches the panel in play — and nothing here requires
---`dock` before `setup` has established that it is there.
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
        return { icon = "▶", hl = format.hl.session_running }
    elseif state == "done" then
        return { icon = "✓", hl = format.hl.session_running }
    elseif state == "failed" then
        return { icon = "✗", hl = format.hl.exception }
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

-- The RunPanel interface. A run's group is made on the run itself rather than
-- on its first buffer, so it has its tab by the time anything lands in it.

---@param run ezdap.runner.Run
function M.open_run(run) _group(run) end

---@param run ezdap.runner.Run
---@param bufnr integer
---@param opts ezdap.AddBufOpts
function M.add_buf(run, bufnr, opts)
    _group(run):page({ buf = bufnr, label = opts.label, priority = opts.priority })
end

---@param run ezdap.runner.Run
---@param ok boolean
function M.set_done(run, ok)
    _group(run):set_busy(false):set_badge(_badge(ok and "done" or "failed"))
end

---@param run ezdap.runner.Run
function M.close_run(run)
    local group = _groups[run.id]
    _groups[run.id] = nil
    if group then group:remove() end
end

---Mark this panel the one in play, so the dock operations below act rather than
---defer to the bottom split. Called from `setup`, which also hands it the runs.
function M.init() _enabled = true end

-- Dock-level operations. The dock is shared with other plugins, so these act on
-- its whole panel, not on ezdap's tabs alone.

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
