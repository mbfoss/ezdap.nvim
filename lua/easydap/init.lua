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

---Completion for `:Debug quick_run …`. `committed` is the already-typed
---`key=value` tokens; `arg_lead` is the partial token under the cursor. Returns
---full `key=value` candidates — the usercmd layer prefix-filters them by arg_lead.
---@param committed string[]
---@param arg_lead string
---@return string[]
local function _quick_run_complete(committed, arg_lead)
    local derive = require("easydap.derive")

    -- Scan committed tokens for the chosen adapter/request and the used keys.
    local adapter, request
    local used = {}
    for _, tok in ipairs(committed) do
        local key, val = tok:match("^([%w_]+)=(.*)$")
        if key then
            used[key] = true
            if key == "adapter" then adapter = val end
            if key == "request" then request = val end
        end
    end

    ---The request used for field lookup: explicit request=, else the adapter's
    ---default, else whichever it maps.
    local function eff_request()
        if request and request ~= "" then return request end
        if not adapter then return "launch" end
        local supported = derive.requests(adapter)
        local base      = require("easydap.adapters")[adapter]
        local r         = (base and base.request) or "launch"
        if vim.tbl_contains(supported, r) then return r end
        return supported[1] or "launch"
    end

    ---@param prefix string
    ---@param values string[]
    local function tag(prefix, values)
        return vim.tbl_map(function(v) return prefix .. v end, values)
    end

    -- Completing a value: arg_lead is `key=partial`.
    local vkey, vpartial = arg_lead:match("^([%w_]+)=(.*)$")
    if vkey then
        if vkey == "adapter" then
            return tag("adapter=", derive.adapter_names())
        elseif vkey == "request" then
            return tag("request=", adapter and derive.requests(adapter) or { "launch", "attach" })
        elseif vkey == "raw_messages" then
            return tag("raw_messages=", { "true", "false" })
        end
        local spec = derive.field_specs[vkey]
        if spec and spec.type == "boolean" then
            return tag(vkey .. "=", { "true", "false" })
        elseif spec and spec.type == "path" then
            return tag(vkey .. "=", vim.fn.getcompletion(vpartial, "file"))
        end
        return {}
    end

    -- Completing a key: offer `key=` candidates, minus already-used keys.
    local out = {}
    local function offer(key)
        if not used[key] then out[#out + 1] = key .. "=" end
    end
    offer("adapter")
    if adapter and derive.adapters[adapter] then
        offer("request")
        offer("name")
        offer("raw_messages")
        for _, f in ipairs(derive.fields(adapter, eff_request())) do offer(f) end
    end
    return out
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
        "run_file", "quick_run", "rerun",
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

    usercmd.register_user_cmd("Debug", function(_, args, opts)
        local sub = args[1]
        if sub == "run_file" then
            M.run_file(args[2])
        elseif sub == "quick_run" then
            M.quick_run({ unpack(args, 2) })
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
            local def = usercmd.get_subcommand("breakpoint")
            if def then def.run("breakpoint", { unpack(args, 2) }, {}) end
        else
            vim.notify("[easydap] unknown command: " .. tostring(sub), vim.log.levels.WARN)
        end
    end, {
        desc = "easydap commands",
        -- `range` (not `count`) so `:'<,'>Debug inspect` from visual mode is
        -- accepted instead of erroring with E16; a leading count (`:2Debug
        -- panel`) still arrives via opts.count.
        range = true,
        subcommand_fn = function(_, rest, arg_lead)
            if #rest == 0 then return _debug_subs end
            if rest[1] == "breakpoint" then
                local def = usercmd.get_subcommand("breakpoint")
                return def and def.complete({ unpack(rest, 2) }, arg_lead) or {}
            end
            if rest[1] == "run_file" and #rest == 1 then
                return vim.fn.getcompletion(arg_lead, "file")
            end
            if rest[1] == "quick_run" then
                return _quick_run_complete({ unpack(rest, 2) }, arg_lead)
            end
            if rest[1] == "panel" and #rest == 1 then
                return { "toggle", "jump", "next", "previous" }
            end
            if rest[1] == "panel" and rest[2] == "jump" and #rest == 2 then
                return require("easydap.runner").panel_tab_numbers()
            end
            return {}
        end,
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

---Assemble and run a debug task from `key=value` tokens (adapter-agnostic).
---E.g. `quick_run adapter=gdb command=./a.out stop_on_entry=true`.
---@param tokens string[] raw key=value tokens
function M.quick_run(tokens)
    local runner = require("easydap.runner")
    return runner.quick_run(tokens)
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
