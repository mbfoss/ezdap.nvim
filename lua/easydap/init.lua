local M = {}

---@type easydap.DebugView?
local _debug_view
---@type easydap.DisassemblyView?
local _disassembly_view
local _initialized = false

local function _save()
    local store = require("easydap.store")
    if not store.in_project() then return end
    local bps   = require("easydap.dap.breakpoints")
    local exprs = require("easydap.ui.expressions")
    store.set("breakpoints", bps.get_data())
    store.set("expressions", exprs.get_data())
    store.flush()
end

local function _load()
    local store = require("easydap.store")
    local bps   = require("easydap.dap.breakpoints")
    local exprs = require("easydap.ui.expressions")
    bps.restore(store.get("breakpoints"))
    exprs.restore(store.get("expressions"))
end

local function _clear()
    local bps   = require("easydap.dap.breakpoints")
    local exprs = require("easydap.ui.expressions")
    bps.restore(nil)
    exprs.restore(nil)
end

local function _register_user_commands()
    local cmd      = require("easydap.manager")
    local usercmd  = require("easydap.util.usercmd")

    local _bp_subs = {
        "toggle", "add", "remove", "column",
        "clear_file", "clear_all", "clear_fn",
        "enable", "disable", "enable_all", "disable_all",
        "condition", "logpoint",
        "fn", "exception_filter", "exception_type",
        "data", "data_clear", "data_list",
        "list",
    }

    usercmd.register_subcommand("breakpoint", function(_, args, _)
        local sub = args[1]
        if sub == nil or sub == "" or sub == "toggle" then
            if vim.b.easydap_disasm and _disassembly_view then
                _disassembly_view:toggle_bp_at_cursor()
            else
                cmd.breakpoint.toggle()
            end
        elseif sub == "add" then
            cmd.breakpoint.add(args[2])
        elseif sub == "remove" then
            cmd.breakpoint.remove()
        elseif sub == "column" then
            cmd.breakpoint.column()
        elseif sub == "clear_file" then
            cmd.breakpoint.clear_file()
        elseif sub == "clear_all" then
            cmd.breakpoint.clear_all()
        elseif sub == "clear_fn" then
            cmd.breakpoint.clear_fn()
        elseif sub == "enable" then
            cmd.breakpoint.enable()
        elseif sub == "disable" then
            cmd.breakpoint.disable()
        elseif sub == "enable_all" then
            cmd.breakpoint.enable_all()
        elseif sub == "disable_all" then
            cmd.breakpoint.disable_all()
        elseif sub == "condition" then
            cmd.breakpoint.condition()
        elseif sub == "logpoint" then
            cmd.breakpoint.logpoint()
        elseif sub == "fn" then
            cmd.breakpoint.fn(args[2])
        elseif sub == "exception_filter" then
            cmd.breakpoint.exception_filter()
        elseif sub == "exception_type" then
            cmd.breakpoint.exception_type(args[2], args[3])
        elseif sub == "data" then
            cmd.breakpoint.data(args[2])
        elseif sub == "data_clear" then
            cmd.breakpoint.data_clear()
        elseif sub == "data_list" then
            cmd.breakpoint.data_list()
        elseif sub == "list" then
            cmd.breakpoint.list()
        else
            vim.notify("[dap] unknown subcommand: " .. tostring(sub), vim.log.levels.WARN)
        end
    end, {
        complete_fn = function(rest, _)
            if #rest == 0 then return _bp_subs end
            if rest[1] == "fn" and #rest == 1 then
                return vim.tbl_map(function(bp) return bp.name end,
                    require("easydap.dap.breakpoints").function_breakpoints())
            end
            if rest[1] == "exception_type" and #rest == 1 then
                return vim.tbl_map(function(bp) return bp.name end,
                    require("easydap.dap.breakpoints").exception_name_breakpoints())
            end
            if rest[1] == "exception_type" and #rest == 2 then
                return { "always", "unhandled", "userUnhandled", "never" }
            end
            return {}
        end,
    })

    local _debug_subs = {
        "run",
        "breakpoint",
        "view", "continue", "continue_all",
        "step_over", "next", "step_in", "step_out", "step_back",
        "step_into_targets", "reverse_continue",
        "jump_to_cursor", "restart_frame", "exception_info",
        "pause", "restart",
        "stop", "terminate", "terminate_all",
        "session", "thread", "terminate_thread", "frame",
        "inspect", "disassemble",
    }

    usercmd.register_user_cmd("Debug", function(_, args, _)
        local sub = args[1]
        if sub == "run" then
            M.run(args[2])
        elseif sub == "view" then
            cmd.panel.toggle()
        elseif sub == "continue" then
            cmd.debug.continue()
        elseif sub == "continue_all" then
            cmd.debug.continue_all()
        elseif sub == "step_over" or sub == "next" then
            cmd.debug.step_over()
        elseif sub == "step_in" then
            cmd.debug.step_in()
        elseif sub == "step_out" then
            cmd.debug.step_out()
        elseif sub == "step_back" then
            cmd.debug.step_back()
        elseif sub == "step_into_targets" then
            cmd.debug.step_into_targets()
        elseif sub == "reverse_continue" then
            cmd.debug.reverse_continue()
        elseif sub == "jump_to_cursor" then
            cmd.debug.jump_to_cursor()
        elseif sub == "restart_frame" then
            cmd.debug.restart_frame()
        elseif sub == "exception_info" then
            cmd.debug.exception_info()
        elseif sub == "pause" then
            cmd.debug.pause()
        elseif sub == "restart" then
            cmd.debug.restart()
        elseif sub == "stop" or sub == "terminate" then
            cmd.debug.stop()
        elseif sub == "terminate_all" then
            cmd.debug.terminate_all()
        elseif sub == "inspect" then
            cmd.debug.inspect()
        elseif sub == "disassemble" then
            cmd.debug.disassemble()
        elseif sub == "session" then
            cmd.debug.session()
        elseif sub == "thread" then
            cmd.debug.thread()
        elseif sub == "terminate_thread" then
            cmd.debug.terminate_thread()
        elseif sub == "frame" then
            cmd.debug.frame()
        elseif sub == "breakpoint" then
            local def = usercmd.get_subcommand("breakpoint")
            if def then def.run("breakpoint", { unpack(args, 2) }, {}) end
        else
            vim.notify("[easydap] unknown command: " .. tostring(sub), vim.log.levels.WARN)
        end
    end, {
        desc = "easydap commands",
        subcommand_fn = function(_, rest, arg_lead)
            if #rest == 0 then return _debug_subs end
            if rest[1] == "breakpoint" then
                local def = usercmd.get_subcommand("breakpoint")
                return def and def.complete({ unpack(rest, 2) }, arg_lead) or {}
            end
            if rest[1] == "run" and #rest == 1 then
                return vim.fn.getcompletion(arg_lead, "file")
            end
            return {}
        end,
    })
end

local function _init()
    if _initialized then return end
    _initialized = true

    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = _save,
        desc     = "easydap: persist breakpoints and expressions",
    })

    local store = require("easydap.store")
    store.on_project_leave_pre:subscribe(function()
        local bps   = require("easydap.dap.breakpoints")
        local exprs = require("easydap.ui.expressions")
        store.set("breakpoints", bps.get_data())
        store.set("expressions", exprs.get_data())
    end)
    store.on_project_enter:subscribe(function() _load() end)
    store.on_project_leave:subscribe(function() _clear() end)

    require("easydap.ui.breakpoints_ui").init()
    require("easydap.ui.debugline_ui").init()
    require("easydap.ui.inlinevars").enable()

    local client = require("easydap.dap.client")
    client.on_session_added:subscribe(function()
        vim.schedule(function() M.debug_view():show() end)
    end)
end

---Return the singleton DebugView, creating it on first call.
---@return easydap.DebugView
function M.debug_view()
    if not _debug_view then
        _debug_view = require("easydap.ui.DebugView").new()
    end
    return _debug_view
end

---Open the DebugView in a vertical split (or focus if already visible).
function M.open_debug_view()
    M.debug_view():open()
end

---Return the singleton DisassemblyView, creating it on first call.
---@return easydap.DisassemblyView
function M.disassembly_view()
    if not _disassembly_view then
        _disassembly_view = require("easydap.ui.DisassemblyView").new()
    end
    return _disassembly_view
end

---Open the disassembly pane for the active session's current frame.
function M.open_disassembly_view()
    M.disassembly_view():open()
end

---Run a debug task standalone (without easytasks):
---  • string → path to a Lua file returning a single task
---  • table  → run a task directly
---@param arg string|easydap.Task
function M.run(arg)
    local runner = require("easydap.runner")

    if type(arg) == "string" then
        return runner.run_file(arg)
    end
    if type(arg) == "table" then
        return runner.run(arg)
    end

    vim.notify("[easydap] run: expected a path to a Lua file, e.g. :Debug run debug.lua",
        vim.log.levels.WARN)
end

---@param opts? easydap.Config
function M.setup(opts)
    local config = require("easydap.config")
    local tmp = vim.tbl_deep_extend("force", config or {}, opts or {})
    for k, v in pairs(tmp) do
        config[k] = v
    end

    _init()
    _load()
    _register_user_commands()
end

return M
