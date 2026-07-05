local M = {}

setmetatable(M, {
    __index = function(t, k)
        if k == "adapters" then
            local adapters = require("easydap.adapters")
            rawset(t, k, adapters)
            return adapters
        end
    end,
})

---@type easydap.DebugView?
local _debug_view
---@type easydap.DisassemblyView?
local _disassembly_view
local _initialized = false

-- Persistence seam: the engine deals in absolute source paths; on-disk state
-- uses project-relative paths for portability. The path conversion lives here,
-- never in the engine or the store.

---Collect breakpoints/expressions into a single on-disk payload, relativizing
---breakpoint source paths.
---@return table
local function _collect()
    local store       = require("easydap.store")
    local bps         = require("easydap.dap.breakpoints")
    local exprs       = require("easydap.ui.expressions")
    local breakpoints = bps.get_data()
    for _, bp in ipairs(breakpoints.source) do bp.source = store.relativize(bp.source) end
    return { breakpoints = breakpoints, expressions = exprs.get_data() }
end

---Persist the current project's breakpoints/expressions. No-op when rootless.
local function _save()
    local store = require("easydap.store")
    if not store.root() then return end
    store.write(_collect())
end

---Restore breakpoints/expressions for the current project, absolutizing
---breakpoint source paths. Clears them when the cwd is not in a project.
local function _load()
    local store       = require("easydap.store")
    local bps         = require("easydap.dap.breakpoints")
    local exprs       = require("easydap.ui.expressions")
    local data        = store.read() or {}
    local breakpoints = data.breakpoints
    if type(breakpoints) == "table" and type(breakpoints.source) == "table" then
        for _, bp in ipairs(breakpoints.source) do bp.source = store.absolutize(bp.source) end
    end
    bps.restore(breakpoints)
    exprs.restore(data.expressions)
end

-- Whether we've already warned, in the current rootless stretch, that project
-- state can't be persisted. Reset on every cwd change so a later rootless period
-- warns afresh.
local _warned_rootless = false

---Warn — once per rootless stretch — that the breakpoint/expression set just
---changed but won't be persisted, because the cwd is not inside a project. No-op
---inside a project, or while nothing is set (so it never fires on an empty
---startup/restore).
local function _warn_if_unpersisted()
    if _warned_rootless then return end
    if require("easydap.store").root() then return end
    local bps   = require("easydap.dap.breakpoints")
    local exprs = require("easydap.ui.expressions")
    if #bps.all() == 0 and #bps.function_breakpoints() == 0
        and #bps.exception_name_breakpoints() == 0 and #exprs.all() == 0 then
        return
    end
    _warned_rootless = true
    vim.notify(
        "[easydap] not in a project (no root marker); breakpoints and watch expressions won't be persisted",
        vim.log.levels.WARN)
end

local function _register_user_commands()
    local cmd      = require("easydap.manager")
    local usercmd  = require("easydap.tk.usercmd")

    local _bp_subs = {
        "toggle", "add", "remove", "column",
        "clear_file", "clear_all", "clear_fn",
        "enable", "disable", "enable_all", "disable_all",
        "condition", "logpoint",
        "fn", "exception_filter", "exception_type",
        "data", "data_clear", "data_list",
        "list",
    }

    ---Run the `breakpoint` subcommand. Also reachable via `:Debug breakpoint …`.
    ---@param args string[]
    local function _bp_run(args)
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
    end

    ---Completion for the `breakpoint` subcommand.
    ---@param rest string[]
    ---@return string[]
    local function _bp_complete(rest)
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
    end

    local _debug_subs = {
        "run_file", "run_target", "new_task", "rerun",
        "breakpoint",
        "view", "continue", "continue_all",
        "step_over", "next", "step_in", "step_out", "step_back",
        "step_into_targets", "reverse_continue",
        "jump_to_cursor", "restart_frame", "exception_info",
        "pause", "restart",
        "stop", "terminate", "terminate_all",
        "session", "thread", "terminate_thread", "frame",
        "inspect", "disassemble",
        "project", "panel",
    }

    ---@type easydap.tk.usercmd.run_fn
    local function _debug_run(_, args, opts)
        local sub = args[1]
        if sub == "run_file" then
            M.run_file(args[2])
        elseif sub == "run_target" then
            M.run_target(args[2], args[3], { unpack(args, 4) })
        elseif sub == "new_task" then
            M.new_task(args[2], args[3], args[4])
        elseif sub == "rerun" then
            M.rerun()
        elseif sub == "view" then
            cmd.view.toggle()
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
            -- A `'<,'>` range (e.g. `:'<,'>Debug inspect` from visual mode) sets
            -- opts.range > 0; inspect then reads the `'<`/`'>` marks.
            cmd.debug.inspect(nil, opts.range and opts.range > 0)
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
        elseif sub == "project" then
            M.project_info()
        elseif sub == "panel" then
            local runner = require("easydap.runner")
            local action = args[2]
            -- A count prefix selects a tab: `:2Debug panel` / `:2Debug panel jump`
            -- both jump to tab 2 (count is 0 when none is given).
            local count  = opts.count > 0 and opts.count or nil
            if action == "jump" then
                runner.panel_jump(count or tonumber(args[3]) or nil)
            elseif action == "next" then
                runner.panel_next()
            elseif action == "previous" or action == "prev" then
                runner.panel_prev()
            elseif action == nil or action == "" or action == "toggle" then
                if count then runner.panel_jump(count) else runner.panel_toggle() end
            else
                vim.notify("[easydap] unknown panel command: " .. tostring(action), vim.log.levels.WARN)
            end
        elseif sub == "breakpoint" then
            _bp_run({ unpack(args, 2) })
        else
            vim.notify("[easydap] unknown command: " .. tostring(sub), vim.log.levels.WARN)
        end
    end

    ---Completion for `:Debug …`.
    ---@type easydap.tk.usercmd.subcommand_fn
    local function _debug_complete_subs(_, rest, arg_lead)
        if #rest == 0 then return _debug_subs end
        if rest[1] == "breakpoint" then
            return _bp_complete({ unpack(rest, 2) })
        end
        if rest[1] == "run_file" and #rest == 1 then
            return vim.fn.getcompletion(arg_lead, "file")
        end
        if rest[1] == "run_target" then
            -- First arg: adapter name; program and its args complete as files.
            if #rest == 1 then return require("easydap.schema").target_adapters() end
            return vim.fn.getcompletion(arg_lead, "file")
        end
        if rest[1] == "new_task" then
            local schema = require("easydap.schema")
            -- <adapter> <request> [path]
            if #rest == 1 then return schema.adapter_names() end
            if #rest == 2 then return schema.requests(rest[2]) end
            if #rest == 3 then return vim.fn.getcompletion(arg_lead, "file") end
            return {}
        end
        if rest[1] == "panel" and #rest == 1 then
            return { "toggle", "jump", "next", "previous" }
        end
        if rest[1] == "panel" and rest[2] == "jump" and #rest == 2 then
            return require("easydap.runner").panel_tab_numbers()
        end
        return {}
    end

    -- `range = true` lets `:'<,'>Debug inspect` from visual mode be accepted
    -- instead of erroring with E16; a leading count (`:2Debug panel`) still
    -- arrives via `opts.count`.
    usercmd.register_user_cmd("Debug", _debug_run, {
        desc = "easydap commands",
        range = true,
        subcommand_fn = _debug_complete_subs,
    })
end

local function _init()
    if _initialized then return end
    _initialized = true

    local store = require("easydap.store")

    -- Persist before leaving the current project (cwd change) and on exit.
    vim.api.nvim_create_autocmd({ "DirChangedPre", "VimLeavePre" }, {
        callback = _save,
        desc     = "easydap: persist breakpoints and expressions",
    })

    -- After a cwd change, re-resolve the project root and restore its state
    -- (or clear it, when the new cwd is not inside a project).
    vim.api.nvim_create_autocmd("DirChanged", {
        callback = function()
            store.invalidate()
            _warned_rootless = false
            _load()
        end,
        desc = "easydap: restore project state after cwd change",
    })

    require("easydap.dap.breakpoints").on_change:subscribe(_warn_if_unpersisted)
    require("easydap.ui.expressions").on_change:subscribe(_warn_if_unpersisted)

    require("easydap.ui.breakpoints_ui").init()
    require("easydap.ui.debugline_ui").init()
    require("easydap.ui.inlinevars").enable()

    local client = require("easydap.dap.client")
    client.on_session_added:subscribe(function()
        vim.schedule(function() M.debug_view():show() end)
    end)
end

-- adapters table is Lazily loaded on first access
---@type table<string, easydap.AdapterDef>
M.adapters = nil

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

---@param path string a Lua file returning a single task, or a folder to pick one from
function M.run_file(path)
    local runner = require("easydap.runner")
    return runner.run_file(path)
end

---Scaffold a run_file for `adapter` + `request` from its schema (defaults +
---placeholders + descriptions) and open it for editing. E.g.
---`new_task("codelldb", "launch")` writes `<root>/codelldb_launch.lua`.
---@param adapter string
---@param request string?
---@param path string?
function M.new_task(adapter, request, path)
    return require("easydap.scaffold").new_task(adapter, request, path)
end

---Launch `program` (with optional `args`) under the named debugger — a convenience
---that maps the program and its arguments onto the adapter's native launch fields.
---E.g. `run_target("codelldb", "./a.out", { "--verbose" })`.
---@param adapter string
---@param program string?
---@param program_args string[]?
function M.run_target(adapter, program, program_args)
    local runner = require("easydap.runner")
    return runner.run_target(adapter, program, program_args)
end

---@param task easydap.Task
function M.run(task)
    local runner = require("easydap.runner")
    return runner.run(task)
end

---Re-run the most recently run task from scratch. Warns when nothing has run yet.
function M.rerun()
    require("easydap.runner").rerun()
end

---Report whether the cwd is inside a project and, if so, the resolved root and
---data file (and whether that file exists on disk yet). Echoed to the command
---line rather than notified, so it reads as a status query.
function M.project_info()
    local store = require("easydap.store")
    local root  = store.root()
    if not root then
        vim.api.nvim_echo({
            { "[easydap] ",                        "Title" },
            { "not in a project (no root marker)", "WarningMsg" },
        }, false, {})
        return
    end
    local chunks = {
        { "[easydap] project: ", "Title" },
        { root,                  "Directory" },
    }
    vim.api.nvim_echo(chunks, false, {})
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
