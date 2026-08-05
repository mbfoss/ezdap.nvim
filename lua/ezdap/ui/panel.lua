---@brief Where a run's buffers are shown — the seam between ezdap and whatever
---owns the window.
---
---`dock.nvim` owns a shared, tabbed panel any plugin can draw into; when it is
---installed ezdap uses it (one dock group per run), and otherwise falls back to
---its own single bottom split (`ezdap.ui.output_win`). Both backends answer the
---same channel API, so callers never learn which one is in play.

local M = {}

---One run's slice of the panel: the buffers it spawned, plus how it is faring.
---A dock backend renders a channel as a tab; the fallback has a single window
---and ignores everything but the buffers.
---@class ezdap.ui.Channel
---@field add       fun(self: ezdap.ui.Channel, bufnr: integer, opts?: ezdap.AddBufOpts)
---@field show      fun(self: ezdap.ui.Channel, bufnr: integer, opts?: ezdap.AddBufOpts)  put `bufnr` on screen now, opening the panel
---@field set_state fun(self: ezdap.ui.Channel, state: ezdap.ui.ChannelState)
---@field remove    fun(self: ezdap.ui.Channel)  drop the channel; its buffers are the caller's to wipe

---@alias ezdap.ui.ChannelState "running"|"done"|"failed"

---@class ezdap.ui.ChannelSpec
---@field id       string   stable per run, so re-creating one reuses its tab
---@field label    string
---@field state?   ezdap.ui.ChannelState
---@field on_clean fun()?   the backend asking the channel to shed itself (dock's `:Dock clean`)

---@class ezdap.ui.PanelBackend
---@field channel fun(spec: ezdap.ui.ChannelSpec): ezdap.ui.Channel
---@field open    fun(focus?: boolean)
---@field close   fun()
---@field toggle  fun()
---@field winid   fun(): integer?

---@type ezdap.ui.PanelBackend?
local _backend

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

---@param spec ezdap.ui.ChannelSpec
---@return ezdap.ui.Channel
function M.channel(spec)
    return _resolve().channel(spec)
end

---@param focus? boolean
function M.open(focus) _resolve().open(focus) end

function M.close() _resolve().close() end

function M.toggle() _resolve().toggle() end

---@return integer? winid  the panel window in this tabpage, when open
function M.winid() return _resolve().winid() end

return M
