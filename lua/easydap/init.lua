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
-- Whether `setup()` has run. The public API (session runners, views, project
-- state) relies on the autocmds, UI wiring and restored breakpoints that setup
-- installs; calling in before then would silently do the wrong thing (no
-- persistence, no auto-shown view, empty breakpoint set), so those entry points
-- fail loudly instead.
local _setup_done = false

---Guard a public API entry point: raise a clear error — pointed at the caller —
---when `setup()` has not been called yet.
---@param fn string  the API name, for the message
local function _require_setup(fn)
    if _setup_done then return end
    error(("[easydap] require('easydap').setup() must be called before %s()"):format(fn), 3)
end

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
        "enable", "disable", "toggle_enabled", "enable_all", "disable_all",
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
        elseif sub == "toggle_enabled" then
            cmd.breakpoint.toggle_enabled()
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
        "run_file", "quick_run", "new_run_file", "rerun",
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
        elseif sub == "quick_run" then
            M.quick_run({ unpack(args, 2) })
        elseif sub == "new_run_file" then
            M.new_run_file({ unpack(args, 2) })
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
            if action == "jump" then
                runner.panel_jump(tonumber(args[3]))
            elseif action == "next" then
                runner.panel_next()
            elseif action == "previous" or action == "prev" then
                runner.panel_prev()
            elseif action == "clean" then
                runner.panel_clean()
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

    ---Completion for `:Debug quick_run …` tokens: the adapter (1st bare
    ---positional), then the configuration name (2nd bare positional), then
    ---placeholder names (as `name=`) not yet supplied, or a value once `=` has
    ---been typed (file paths for a path-like placeholder).
    ---@param schema table
    ---@param used string[]     already-typed tokens preceding the one being completed
    ---@param arg_lead string   the token being completed
    ---@return string[]
    local function _quick_run_complete(schema, used, arg_lead)
        local adapter, configuration_name
        local supplied = {}
        for _, tok in ipairs(used) do
            local e = tok:find("=", 1, true)
            if e then
                supplied[tok:sub(1, e - 1)] = true
            elseif not adapter then
                adapter = tok
            elseif not configuration_name then
                configuration_name = tok
            end
        end

        local eq = arg_lead:find("=", 1, true)
        if eq then
            if not adapter or not configuration_name then return {} end
            local name = arg_lead:sub(1, eq - 1)
            local pfx  = arg_lead:sub(1, eq)
            local val  = arg_lead:sub(eq + 1)
            -- Completing a placeholder's value: offer paths for a path-typed
            -- placeholder, per the `type` its configuration declares; nothing
            -- for the rest.
            local ptype = schema.configuration_placeholder_types(adapter, configuration_name)[name]
            local comp_type = (ptype == "file" and "file")
                or ((ptype == "dir" or ptype == "cwd") and "dir")
                or nil
            if not comp_type then return {} end
            return vim.tbl_map(function(f) return pfx .. f end, vim.fn.getcompletion(val, comp_type))
        end

        -- No `=` yet: complete the adapter, then the configuration, then placeholder names.
        if not adapter then
            return schema.quick_run_adapters()
        elseif not configuration_name then
            return schema.configuration_names(adapter)
        end
        local out = {}
        for _, name in ipairs(schema.configuration_placeholders(adapter, configuration_name)) do
            if not supplied[name] then out[#out + 1] = name .. "=" end
        end
        return out
    end

    ---Completion for `:Debug …`.
    ---@type easydap.tk.usercmd.subcommand
    local function _debug_complete_subs(_, rest, arg_lead)
        if #rest == 0 then return _debug_subs end
        if rest[1] == "breakpoint" then
            return _bp_complete({ unpack(rest, 2) })
        end
        if rest[1] == "run_file" and #rest == 1 then
            return vim.fn.getcompletion(arg_lead, "file")
        end
        if rest[1] == "quick_run" then
            -- <adapter> <configuration> <placeholder>=<value>…
            local schema = require("easydap.schema")
            return _quick_run_complete(schema, { unpack(rest, 2) }, arg_lead)
        end
        if rest[1] == "new_run_file" then
            -- Positional: <adapter> [configuration] [path]. The path names a new file to
            -- create, so it has no completion.
            local schema = require("easydap.schema")
            local used   = { unpack(rest, 2) }
            local pos    = #used + 1 -- 1-based position of the token being completed
            if pos == 1 then
                return schema.quick_run_adapters()
            elseif pos == 2 then
                return schema.configuration_names(used[1])
            end
            return {}
        end
        if rest[1] == "panel" and #rest == 1 then
            return { "toggle", "jump", "next", "previous", "clean" }
        end
        if rest[1] == "panel" and rest[2] == "jump" and #rest == 2 then
            return require("easydap.runner").panel_tab_numbers()
        end
        return {}
    end

    usercmd.register_user_cmd("Debug", _debug_run, {
        desc = "easydap commands",
        range = true,
        subcommand = _debug_complete_subs,
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

    -- Gracefully stop active sessions on exit. An adapter (e.g. lldb-dap) that
    -- is killed without a completed `disconnect` orphans its launched debuggee —
    -- the process keeps running. Neovim SIGKILLs the adapter jobs as it exits, so
    -- we must finish the DAP disconnect handshake first. vim.wait pumps the event
    -- loop (letting the async disconnect responses land) while the timeout caps a
    -- hung adapter so quitting is never blocked; the per-session 3s force-close
    -- backstops within that window.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        callback = function()
            local client = require("easydap.dap.client")
            local done = false
            client.quit(function() done = true end)
            vim.wait(10000, function() return done end, 20)
        end,
        desc = "easydap: disconnect sessions so debuggees are terminated on exit",
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
    _require_setup("debug_view")
    if not _debug_view then
        _debug_view = require("easydap.ui.DebugView").new()
    end
    return _debug_view
end

---Open the DebugView in a vertical split (or focus if already visible).
function M.open_debug_view()
    _require_setup("open_debug_view")
    M.debug_view():open()
end

---Return the singleton DisassemblyView, creating it on first call.
---@return easydap.DisassemblyView
function M.disassembly_view()
    _require_setup("disassembly_view")
    if not _disassembly_view then
        _disassembly_view = require("easydap.ui.DisassemblyView").new()
    end
    return _disassembly_view
end

---Open the disassembly pane for the active session's current frame.
function M.open_disassembly_view()
    _require_setup("open_disassembly_view")
    M.disassembly_view():open()
end

---@param path string a Lua file returning a single task, or a folder to pick one from
function M.run_file(path)
    _require_setup("run_file")
    local runner = require("easydap.runner")
    return runner.run_file(path)
end

---Scaffold a run_file from one of an adapter's configurations (fixed/default fields +
---placeholders) and open it for editing. `assignments` is positional: the
---adapter, an optional configuration name (defaults to the adapter's sole configuration),
---and an optional destination path. E.g. `new_run_file({ "codelldb", "launch" })`
---writes `<root>/codelldb_launch.lua`.
---@param assignments string[]  positional adapter, configuration, path, e.g. { "codelldb", "launch", "./foo.lua" }
function M.new_run_file(assignments)
    _require_setup("new_run_file")
    return require("easydap.scaffold").new_run_file(assignments)
end

---Launch or attach under an adapter using one of its declared `configurations`,
---filling `{placeholder}` tokens from `placeholder=value` assignments — the
---command-surface entry point behind `:Debug quick_run`. `assignments` leads
---with the adapter and configuration name as bare positional tokens. E.g.
---`quick_run({ "codelldb", "launch", "command=./a.out --verbose" })` or
---`quick_run({ "debugpy", "attach", "pid=41234" })`.
---@param assignments string[]  adapter, configuration name, then "placeholder=value" tokens
function M.quick_run(assignments)
    _require_setup("quick_run")
    return require("easydap.runner").quick_run(assignments)
end

---@param task easydap.Task
function M.run(task)
    _require_setup("run")
    local runner = require("easydap.runner")
    return runner.run(task)
end

--- function intended to be called by custom plugins that manages their own task UI
---@param task easydap.Task
---@param callbacks easydap.TaskCallback
---@return fun() cancel function
function M.start_task(task, callbacks)
    _require_setup("start_task")
    return require("easydap.task").start(task, callbacks)
end

---Re-run the most recently run task from scratch. Warns when nothing has run yet.
function M.rerun()
    _require_setup("rerun")
    require("easydap.runner").rerun()
end

---Report whether the cwd is inside a project and, if so, the resolved root and
---data file (and whether that file exists on disk yet). Echoed to the command
---line rather than notified, so it reads as a status query.
function M.project_info()
    _require_setup("project_info")
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
    _setup_done = true
end

return M
