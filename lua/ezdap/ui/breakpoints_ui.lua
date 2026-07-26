---@brief Singleton that renders breakpoints in source buffers.
---Subscribes to breakpoints.on_change and keeps the marks in sync.
---
---Line breakpoints are gutter signs. Column breakpoints render an inline glyph
---right before their column instead. Both drive the fileextmarks module directly
---(the signs module only ever places marks in the gutter at column 0).

local fileextmarks = require("ezdap.ui.fileextmarks")
local breakpoints  = require("ezdap.dap.breakpoints")
local format       = require("ezdap.ui.format")
local manager      = require("ezdap.manager")

local M            = {}

---@type ezdap.ui.fileextmarks.GroupFunctions?
local _group
local _init_done

local _BP_HL      = "EzdapBreakpoint"
vim.api.nvim_set_hl(0, _BP_HL, { link = "Debug", default = true })

local _PRIORITY   = 10

local function _refresh()
    if not _group then return end
    _group.remove_extmarks()
    for _, bp in ipairs(breakpoints.all()) do
        if bp.source ~= "" then
            assert(bp.internal_id > 0, "breakpoint internal_id must be positive")
            -- While a session is live the adapter may bind the breakpoint to a
            -- different line; show the sign there. Falls back to the stored line
            -- when there is no session (st is nil) or it was not moved.
            local st    = manager.bp_status(bp.internal_id)
            local lnum  = (st and st.line) or bp.line
            -- Gutter/inline marks keep the single `EzdapBreakpoint` highlight; only
            -- the glyph comes from the shared resolver.
            local glyph, _, name = format.breakpoint_sign({
                kind          = "source",
                disabled      = bp.disabled,
                verified      = st and st.verified,
                condition     = bp.condition,
                hit_condition = bp.hit_condition,
                log_message   = bp.log_message,
            })
            ---@type vim.api.keyset.set_extmark
            local opts  = { priority = _PRIORITY }
            local col   = 0
            if bp.column then
                -- Column breakpoint: inline glyph just before the column only, no
                -- gutter sign.
                col                = math.max(0, bp.column - 1)
                opts.virt_text     = { { glyph, _BP_HL } }
                opts.virt_text_pos = "inline"
            else
                -- Line breakpoint: gutter sign.
                opts.sign_text     = glyph
                opts.sign_hl_group = _BP_HL
            end
            _group.set_file_extmark(bp.internal_id, bp.source, lnum, col, opts, { name = name })
        end
    end
end

function M.init()
    if _init_done then return end
    _init_done = true
    _group     = fileextmarks.define_group("breakpoints")

    breakpoints.on_change:subscribe(_refresh)
    -- Adapter-verified status is session-scoped; repaint signs when it changes.
    manager.on_breakpoint_updated:subscribe(function() _refresh() end)
    manager.on_active_changed:subscribe(function() _refresh() end)

    fileextmarks.on_synced:subscribe(function(file)
        local marks = _group.get_file_extmarks(file, false)
        if #marks == 0 then return end
        local positions = {}
        for _, mark in ipairs(marks) do
            positions[mark.id] = { lnum = mark.lnum, col = mark.col }
        end
        breakpoints.relocate_batch(positions)
    end)

    _refresh()
end

return M
