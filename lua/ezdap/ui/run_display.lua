---@brief ezdap's own presenter: how a run ezdap shows itself reaches the panels.
---
---`ezdap.runner` hands every run a presenter and knows nothing else about
---display. This makes the one it hands the runs it owns: it creates the run's log
---buffer, holds the buffers the run spawned so they can be wiped when it is
---forgotten, and forwards all of it to the run panel it was built for.
---
---A caller running a task with a `runner.Presenter` of its own replaces this
---module wholesale, which is why nothing here is reached for a run shown
---elsewhere.

local OutputBuffer = require "ezdap.ui.OutputBuffer"
local ui_util      = require "ezdap.util.ui"
local _config      = require "ezdap.config"

local M            = {}

---Where a run is shown: a dock group per run (`ezdap.ui.dock_panel`), or the
---single bottom split (`ezdap.ui.output_win`). Only `add_buf` is required — a
---panel with one window for every run cannot show a run's identity or outcome.
---@class ezdap.ui.RunPanel
---@field open_run?  fun(run: ezdap.runner.Run)  a run beginning, before it has any buffer
---@field add_buf    fun(run: ezdap.runner.Run, bufnr: integer, opts: ezdap.AddBufOpts)
---@field set_done?  fun(run: ezdap.runner.Run, ok: boolean)  how the run ended; called once
---@field close_run? fun(run: ezdap.runner.Run)  the run being forgotten, its buffers still valid

---A run's progress is appended to a scratch log buffer of its own, alongside its
---Output and REPL and reachable by name (`:b ezdap://<run>:log`). Pre-flight
---errors stay on vim.notify, happening before the run exists.
---@param run ezdap.runner.Run
---@return ezdap.OutputBuffer
local function _make_log(run)
    return OutputBuffer.new({
        name       = ui_util.unique_buf_name("ezdap://" .. run.id .. ":log"),
        max_lines  = _config.output_max_lines,
        autoscroll = true,
    })
end

---The presenter for one run ezdap shows itself, on the run `panel`.
---@param panel ezdap.ui.RunPanel
---@param run ezdap.runner.Run
---@return ezdap.runner.Presenter
local function _presenter(panel, run)
    ---@type ezdap.runner.RunBuffer[]
    local buffers = {}
    local log ---@type ezdap.OutputBuffer

    local self    = {}

    ---Held so the buffer can be wiped when the run is forgotten, and passed on to
    ---the panel to be shown.
    ---@param bufnr integer
    ---@param opts? ezdap.AddBufOpts
    function self.add_bufnr(bufnr, opts)
        opts                  = opts or {}
        buffers[#buffers + 1] = { bufnr = bufnr, opts = opts }
        panel.add_buf(run, bufnr, opts)
    end

    ---@param msg string
    function self.report(msg)
        local stamp = os.date("%H:%M:%S")
        local lines = {}
        for _, l in ipairs(vim.split(msg, "\n", { plain = true })) do
            lines[#lines + 1] = ("[%s] %s"):format(stamp, l)
        end
        log:append(lines)
    end

    ---@param ok boolean
    function self.on_done(ok)
        if panel.set_done then panel.set_done(run, ok) end
        self.report(ok and "finished" or "failed")
    end

    ---The panel is told first, so it is off these buffers before they go.
    function self.on_removed()
        if panel.close_run then panel.close_run(run) end
        for _, b in ipairs(buffers) do
            if vim.api.nvim_buf_is_valid(b.bufnr) then
                pcall(vim.api.nvim_buf_delete, b.bufnr, { force = true })
            end
        end
    end

    -- The panel learns of the run before it has any buffer, so one that renders a
    -- run as a whole (a dock tab) has it by the time the first arrives.
    if panel.open_run then panel.open_run(run) end

    -- The log is this run's own buffer, so its lines need no task-name prefix. It
    -- ranks lowest of the run's buffers, so it never displaces its Output.
    log = _make_log(run)
    self.add_bufnr(assert(log:bufnr()), { label = "log", priority = -4, autoscroll = true })

    return self
end

---How runs shown on `panel` are presented: `setup` hands the result to
---`ezdap.runner`, which calls it once per run it owns.
---@param panel ezdap.ui.RunPanel
---@return ezdap.runner.PresenterFactory
function M.for_panel(panel)
    return function(run) return _presenter(panel, run) end
end

return M
