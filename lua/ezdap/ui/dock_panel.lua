---@brief The dock.nvim backend behind `ezdap.ui.panel`.
---
---Each run becomes one dock group (a tab) under the `ezdap` source, each of its
---buffers a page in it. dock owns the window, the tab bar and the focus rules;
---ezdap keeps owning its buffers, which is why a group is dropped rather than
---cleaned when the run's buffers are wiped.

local format = require("ezdap.ui.format")

local M      = {}

---@type dock.Source?
local _source

---@return dock.Source
local function _src()
    if not _source then _source = require("dock").source("ezdap") end
    return _source
end

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

---@class ezdap.ui.DockChannel : ezdap.ui.Channel
---@field _group dock.Group
local Channel   = {}
Channel.__index = Channel

---@param spec ezdap.ui.ChannelSpec
---@return ezdap.ui.Channel
function M.channel(spec)
    local group = _src():group({
        id                = spec.id,
        label             = spec.label,
        badge             = _badge(spec.state),
        busy              = spec.state == "running",
        remove_when_empty = true,
        on_clean          = spec.on_clean and function() spec.on_clean() end or nil,
    })
    return setmetatable({ _group = group }, Channel)
end

---@param bufnr integer
---@param opts? ezdap.AddBufOpts
function Channel:add(bufnr, opts)
    opts = opts or {}
    self._group:page({ buf = bufnr, label = opts.label, priority = opts.priority })
end

---@param bufnr integer
---@param opts? ezdap.AddBufOpts
function Channel:show(bufnr, opts)
    self:add(bufnr, opts)
    self._group:activate({ buf = bufnr, enter = true })
end

---@param state ezdap.runner.RunState
function Channel:set_state(state)
    self._group:set_busy(state == "running"):set_badge(_badge(state))
end

function Channel:remove()
    self._group:remove()
end

-- Panel-level operations. The dock is shared with other plugins, so these act on
-- the whole panel, not on ezdap's tabs alone.

---@param focus? boolean
function M.open(focus) require("dock").open({ enter = focus or false }) end

function M.close() require("dock").close() end

function M.toggle() require("dock").toggle({ enter = true }) end

---@return integer?
function M.winid() return require("dock").panel():win() end

return M
