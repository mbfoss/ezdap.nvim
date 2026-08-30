local M = {}

---@type ezdap.DebugView?
local _debug_view
---@type ezdap.DisassemblyView?
local _disassembly_view
-- Whether `setup()` has run. The public API relies on the config and autocmds
-- it installs; calling in before then would silently do the wrong thing, so
-- those entry points fail loudly instead.
local _setup_done = false

-- Whether the plugin proper is up: UI wiring, DAP subscriptions and the
-- restored project state. `setup()` deliberately stops short of this, so a
-- session that never debugs pays for nothing beyond the command and autocmds.
local _loaded = false
---Defined below, once `_init` is in scope.
---@type fun()
local _ensure_loaded

---Guard a public API entry point: raise a clear error — pointed at the caller —
---when `setup()` has not been called yet. Otherwise this *is* the demand that
---brings the plugin up, so every entry point below can assume a loaded plugin.
---@param fn string  the API name, for the message
local function _require_setup(fn)
    if not _setup_done then
        error(("[ezdap] require('ezdap').setup() must be called before %s()"):format(fn), 3)
    end
    _ensure_loaded()
end

---Whether the current project has a state file on disk. Deliberately goes to
---`project` rather than `store`: this runs while cold, and `store` would drag
---the read/write machinery in behind it. Nothing is decoded.
---@return boolean
local function _has_saved_state()
    local path = require("ezdap.project").data_path()
    return path ~= nil and vim.uv.fs_stat(path) ~= nil
end

-- Persistence seam: the engine deals in absolute source paths; on-disk state
-- uses project-relative paths for portability. The path conversion lives here,
-- never in the engine or the store.

---Collect breakpoints/expressions into a single on-disk payload, relativizing
---breakpoint source paths.
---@return table
local function _collect()
    local store       = require("ezdap.store")
    local bps         = require("ezdap.dap.breakpoints")
    local exprs       = require("ezdap.ui.expressions")
    local breakpoints = bps.get_data()
    for _, bp in ipairs(breakpoints.source) do bp.source = store.relativize(bp.source) end
    return { breakpoints = breakpoints, expressions = exprs.get_data() }
end

---Persist the current project's breakpoints/expressions. No-op when rootless.
local function _save()
    local store = require("ezdap.store")
    if not store.root() then return end
    store.write(_collect())
end

---Restore breakpoints/expressions for the current project, absolutizing
---breakpoint source paths. Clears them when the cwd is not in a project.
local function _load()
    local store       = require("ezdap.store")
    local bps         = require("ezdap.dap.breakpoints")
    local exprs       = require("ezdap.ui.expressions")
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

---Warn — once per rootless stretch — that the breakpoint/expression set changed
---but won't be persisted, because the cwd is not inside a project. No-op inside a
---project, or while nothing is set (so it never fires on an empty startup).
local function _warn_if_unpersisted()
    if _warned_rootless then return end
    if require("ezdap.store").root() then return end
    local bps   = require("ezdap.dap.breakpoints")
    local exprs = require("ezdap.ui.expressions")
    if #bps.all() == 0 and #bps.function_breakpoints() == 0
        and #bps.exception_name_breakpoints() == 0 and #exprs.all() == 0 then
        return
    end
    _warned_rootless = true
    vim.notify(
        "[ezdap] not in a project (no root marker); breakpoints and watch expressions won't be persisted",
        vim.log.levels.WARN)
end

-- The user-command surface. `setup()` registers the command — under whatever
-- name `config.command` gives — and routes it here through
-- `M.command`/`M.complete`.

---@type table?
local _command_mod

---@return table
local function _cmd()
    _command_mod = _command_mod or require("ezdap.command")
    return _command_mod
end

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
    local cmd = _cmd()
    local sub = args[1]
    if sub == nil or sub == "" or sub == "toggle" then
        if vim.b.ezdap_disasm and _disassembly_view then
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
            require("ezdap.dap.breakpoints").function_breakpoints())
    end
    if rest[1] == "exception_type" and #rest == 1 then
        return vim.tbl_map(function(bp) return bp.name end,
            require("ezdap.dap.breakpoints").exception_name_breakpoints())
    end
    if rest[1] == "exception_type" and #rest == 2 then
        return { "always", "unhandled", "userUnhandled", "never" }
    end
    return {}
end

local _debug_subs = {
    "run", "run_file", "new_run_file", "rerun", "adapter_info",
    "breakpoint",
    "view", "output", "continue", "continue_all",
    "step_over", "next", "step_in", "step_out", "step_back",
    "step_into_targets", "reverse_continue",
    "jump_to_cursor", "restart_frame", "exception_info",
    "pause", "restart",
    "stop", "stop_all",
    "session", "thread", "terminate_thread", "frame",
    "inspect", "value", "disassemble",
    "project", "clean",
}

---Read `:Debug run <adapter> <mode> [input=value]…`: the adapter and mode are
---strictly the first two positionals, every later token an `input=value` assignment.
---@param args string[]  the command-line tokens from the adapter on
---@return string? adapter, string? mode, table<string, string>? inputs
local function _parse_run_args(args)
    local adapter, mode = args[1], args[2]
    if (adapter and adapter:find("=", 1, true)) or (mode and mode:find("=", 1, true)) then
        vim.notify(("[ezdap] run: usage: :%s run <adapter> <mode> [input=value]…")
            :format(require("ezdap.config").command), vim.log.levels.WARN)
        return
    end
    local inputs = {}
    for i = 3, #args do
        local tok = args[i]
        local eq = tok:find("=", 1, true)
        if not eq then
            vim.notify("[ezdap] run: expected input=value, got '" .. tok .. "'", vim.log.levels.WARN)
            return
        end
        inputs[tok:sub(1, eq - 1)] = tok:sub(eq + 1)
    end
    return adapter, mode, inputs
end

---@type ezdap.util.usercmd.run_fn
local function _debug_run(_, args, opts)
    local cmd = _cmd()
    local sub = args[1]
    if sub == "run_file" then
        M.run_file(args[2])
    elseif sub == "run" then
        local adapter, mode, inputs = _parse_run_args({ unpack(args, 2) })
        if inputs then M.run_mode(adapter or "", mode or "", inputs) end
    elseif sub == "new_run_file" then
        M.new_run_file({ unpack(args, 2) })
    elseif sub == "adapter_info" then
        M.adapter_info(args[2], args[3])
    elseif sub == "rerun" then
        M.rerun()
    elseif sub == "view" then
        cmd.view.toggle()
    elseif sub == "output" then
        cmd.view.output_toggle()
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
    elseif sub == "stop" then
        cmd.debug.stop()
    elseif sub == "stop_all" then
        cmd.debug.stop_all()
    elseif sub == "inspect" then
        -- A `'<,'>` range (e.g. `:'<,'>Debug inspect` from visual mode) sets
        -- opts.range > 0; inspect then reads the `'<`/`'>` marks.
        cmd.debug.inspect(args[2], opts.range and opts.range > 0)
    elseif sub == "value" then
        cmd.debug.value(args[2], opts.range and opts.range > 0)
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
    elseif sub == "clean" then
        M.clean()
    elseif sub == "breakpoint" then
        _bp_run({ unpack(args, 2) })
    else
        vim.notify("[ezdap] unknown command: " .. tostring(sub), vim.log.levels.WARN)
    end
end

---Completion for `:Debug run …` tokens: the adapter (1st bare positional),
---then the mode name (2nd), then input names not yet supplied (as `name=`),
---or a value once `=` has been typed (file paths for a path-like input).
---@param schema table
---@param used string[]     already-typed tokens preceding the one being completed
---@param arg_lead string   the token being completed
---@return string[]
local function _run_complete(schema, used, arg_lead)
    local adapter, mode_name
    local supplied = {}
    for _, tok in ipairs(used) do
        local e = tok:find("=", 1, true)
        if e then
            supplied[tok:sub(1, e - 1)] = true
        elseif not adapter then
            adapter = tok
        elseif not mode_name then
            mode_name = tok
        end
    end

    local eq = arg_lead:find("=", 1, true)
    if eq then
        if not adapter or not mode_name then return {} end
        local name   = arg_lead:sub(1, eq - 1)
        local pfx    = arg_lead:sub(1, eq)
        local val    = arg_lead:sub(eq + 1)
        -- Completing an input's value: whatever the input itself can offer —
        -- paths, true/false, a fixed set of values, nothing for the rest.
        local input  = schema.mode_inputs(adapter, mode_name)[name]
        local values = require("ezdap.inputs").completion(input, val)
        return vim.tbl_map(function(v) return pfx .. v end, values)
    end

    -- No `=` yet: complete the adapter, then the mode, then input names.
    if not adapter then
        return schema.adapters_with_modes()
    elseif not mode_name then
        return schema.mode_names(adapter)
    end
    local out = {}
    for _, name in ipairs(schema.mode_input_names(adapter, mode_name)) do
        if not supplied[name] then out[#out + 1] = name .. "=" end
    end
    return out
end

---Completion for `:Debug …`.
---@type ezdap.util.usercmd.subcommand
local function _debug_complete_subs(_, rest, arg_lead)
    if #rest == 0 then return _debug_subs end
    if rest[1] == "breakpoint" then
        return _bp_complete({ unpack(rest, 2) })
    end
    if rest[1] == "run_file" and #rest == 1 then
        return vim.fn.getcompletion(arg_lead, "file")
    end
    if rest[1] == "run" then
        -- <adapter> <mode> <input>=<value>…
        local schema = require("ezdap.schema")
        return _run_complete(schema, { unpack(rest, 2) }, arg_lead)
    end
    if rest[1] == "adapter_info" then
        -- Positional: [adapter] [mode]; no argument lists every adapter name.
        local schema = require("ezdap.schema")
        if #rest == 1 then return schema.adapter_names() end
        if #rest == 2 then return schema.mode_names(rest[2]) end
        return {}
    end
    if rest[1] == "new_run_file" then
        -- Positional: <adapter> [mode] [path]. The path names a new file to
        -- create, so it has no completion.
        local schema = require("ezdap.schema")
        local used   = { unpack(rest, 2) }
        local pos    = #used + 1 -- 1-based position of the token being completed
        if pos == 1 then
            return schema.adapters_with_modes()
        elseif pos == 2 then
            return schema.mode_names(used[1])
        end
        return {}
    end
    return {}
end

---Run a `:Debug …` invocation. Only reachable once `setup()` has registered the
---command.
---@type ezdap.util.usercmd.run_fn
function M.command(cmd, args, opts)
    _require_setup("command")
    _debug_run(cmd, args, opts)
end

---Completion for `:Debug …`.
---@type ezdap.util.usercmd.subcommand
function M.complete(cmd, rest, arg_lead)
    return _debug_complete_subs(cmd, rest, arg_lead)
end

-- Autocmd handlers. `setup()` creates the autocmds, so these fire from startup
-- on — including in a session that never brought the plugin up. Each one is a
-- no-op while cold: there are no breakpoints, expressions or sessions yet.

---Persist the current project's breakpoints and expressions.
function M.save_state()
    if not _loaded then return end
    _save()
end

---Re-resolve the project root after a cwd change and restore that project's
---state (or clear it, when the new cwd is not inside a project).
function M.reload_state()
    require("ezdap.project").invalidate()
    _warned_rootless = false

    -- Still cold: the new project's state file is the trigger, exactly as at
    -- `setup()`. Without one there is nothing to restore and nothing to clear.
    if not _loaded then
        if _has_saved_state() then _ensure_loaded() end
        return
    end

    _load()
    -- The reloaded state belongs to another project; undoing into it would
    -- resurrect the old one's breakpoints.
    if _debug_view then _debug_view:clear_undo() end
end

---Disconnect every live session on exit: an adapter killed without a completed
---`disconnect` orphans its debuggee, and nvim SIGKILLs adapter jobs as it exits.
---vim.wait pumps the loop for the responses; the timeout caps a hung adapter.
function M.shutdown()
    if not _loaded then return end
    local client = require("ezdap.dap.client")
    local done = false
    client.quit(function() done = true end)
    vim.wait(10000, function() return done end, 20)
end

---Wire up the UI and DAP subscriptions. Called once, via `_ensure_loaded`.
local function _init()
    require("ezdap.dap.breakpoints").on_change:subscribe(_warn_if_unpersisted)
    require("ezdap.ui.expressions").on_change:subscribe(_warn_if_unpersisted)

    require("ezdap.ui.breakpoints_ui").init()
    require("ezdap.ui.debugline_ui").init()
    require("ezdap.ui.inlinevars").enable()
    require("ezdap.ui.popup_menu").init()
    -- The one place picking a run panel: dock.nvim gives each run a tab of its
    -- own, so it takes the runs when installed and ezdap's bottom split stays out
    -- of the way.
    local panel
    if pcall(require, "dock") then
        panel = require("ezdap.ui.dock_panel")
    else
        panel = require("ezdap.ui.output_win")
    end
    panel.init()

    -- Every run ezdap owns is shown through `run_display`, onto that panel.
    require("ezdap.runner").set_presenter(
        require("ezdap.ui.run_display").for_panel(panel))

    local client = require("ezdap.dap.client")
    client.on_session_added:subscribe(function()
        vim.schedule(function() M.debug_view():show() end)
    end)
end

---Bring the plugin proper up, once. The two demands that reach here are a
---`:Debug` invocation (or any public API call) and a project state file found
---by `setup()` or a cwd change.
function _ensure_loaded()
    if _loaded then return end
    _loaded = true
    _init()
    _load()
end

---Return the singleton DebugView, creating it on first call.
---@return ezdap.DebugView
function M.debug_view()
    _require_setup("debug_view")
    if not _debug_view then
        _debug_view = require("ezdap.ui.DebugView").new()
    end
    return _debug_view
end

---Open the DebugView in a vertical split (or focus if already visible).
function M.open_debug_view()
    _require_setup("open_debug_view")
    M.debug_view():open()
end

---Close the DebugView if it is visible, otherwise open and focus it.
function M.toggle_debug_view()
    _require_setup("toggle_debug_view")
    M.debug_view():toggle()
end

---Return the singleton DisassemblyView, creating it on first call.
---@return ezdap.DisassemblyView
function M.disassembly_view()
    _require_setup("disassembly_view")
    if not _disassembly_view then
        _disassembly_view = require("ezdap.ui.DisassemblyView").new()
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
    M.clean()
    local runner = require("ezdap.runner")
    return runner.run_file(path)
end

---Scaffold a run_file for one of an adapter's modes — `adapter`/`mode`/
---`parameters`, seeded and commented — and open it for editing. `assignments` is
---positional: adapter, optional mode (defaults to the sole one), optional path.
---@param assignments string[]  positional adapter, mode, path, e.g. { "codelldb", "binary", "./foo.lua" }
function M.new_run_file(assignments)
    _require_setup("new_run_file")
    return require("ezdap.scaffold").new_run_file(assignments)
end

---Load an adapter's definition, check it, and show what it accepts: anything
---wrong with the definition or its tooling, then its modes and the inputs each
---declares. With no adapter, lists every registered name without loading one.
---The entry point behind `:Debug adapter_info`.
---@param adapter? string  adapter name, e.g. "debugpy"
---@param mode? string  a single mode to show, e.g. "script"
function M.adapter_info(adapter, mode)
    _require_setup("adapter_info")
    return require("ezdap.adapter_info").show(adapter, mode)
end

---Launch or attach under an adapter using one of its declared `modes`, assembling
---the request body from `inputs` — the answers to the mode's declared inputs, in
---either authoring form. The entry point behind `:Debug run`.
---
---Pass a `presenter` to show the run in a UI of your own: the run's buffers,
---progress and outcome go to those callbacks, ezdap's own panels never see it, and
---the run is yours to `remove_run` when you are done with it.
---@param adapter string  adapter name, e.g. "debugpy"
---@param mode string  mode name, e.g. "binary"
---@param inputs? table<string, string>  input name -> value, e.g. { command = "./main.py" }
---@param presenter? ezdap.runner.Presenter  a caller showing the run itself
---@return ezdap.runner.Run?
function M.run_mode(adapter, mode, inputs, presenter)
    _require_setup("run_mode")
    -- Cleaning is ezdap tidying its own runs before adding another; a run shown
    -- elsewhere is not one of them, and its presenter decides when to drop it.
    if not presenter then M.clean() end
    return require("ezdap.runner").run_mode(adapter, mode, inputs, presenter)
end

---Forget a run: its presenter is told to dispose of what it made (ezdap's own
---wipes the run's buffers; a caller's does whatever it does), and the finished
---rows of the sessions it produced are dropped from the debug view. Cancel a live
---run before removing it. The view is only cleaned when it exists; disposing of a
---run is no reason to build one.
---@param run ezdap.runner.Run
function M.remove_run(run)
    _require_setup("remove_run")
    require("ezdap.runner").remove(run)
    if _debug_view then _debug_view:clear_sessions(run.sessions) end
end

---Re-run the most recently run task from scratch. Warns when nothing has run yet.
function M.rerun()
    _require_setup("rerun")
    M.clean()
    require("ezdap.runner").rerun()
end

---Drop every finished run — wiping its buffers — and the rows of the sessions
---they produced, leaving live runs and sessions untouched. The debug view is
---only cleaned when it exists; cleaning is no reason to create one.
function M.clean()
    _require_setup("clean")
    require("ezdap.runner").clean()
    if _debug_view then _debug_view:clear_finished_sessions() end
end

---Report whether the cwd is inside a project and, if so, the resolved root and
---data file (and whether that file exists on disk yet). Echoed to the command
---line rather than notified, so it reads as a status query.
function M.project_info()
    _require_setup("project_info")
    local store = require("ezdap.store")
    local root  = store.root()
    if not root then
        vim.api.nvim_echo({
            { "[ezdap] ",                          "Title" },
            { "not in a project (no root marker)", "WarningMsg" },
        }, false, {})
        return
    end
    local chunks = {
        { "[ezdap] project: ", "Title" },
        { root,                "Directory" },
    }
    vim.api.nvim_echo(chunks, false, {})
end

---Register the `:Debug` command under `name`.
---@param name string
local function _register_command(name)
    vim.api.nvim_create_user_command(name, function(opts)
        require("ezdap.util.usercmd").handle(opts, function(cmd, args, cmd_opts)
            return M.command(cmd, args, cmd_opts)
        end)
    end, {
        nargs = "*",
        range = true,
        desc = "ezdap commands",
        complete = function(arg_lead, cmd_line, _)
            return require("ezdap.util.usercmd").complete(arg_lead, cmd_line,
                function(cmd, rest, lead)
                    return M.complete(cmd, rest, lead)
                end)
        end,
    })
end

---Install the project-state autocmds.
local function _create_autocmds()
    local group = vim.api.nvim_create_augroup("ezdap", { clear = true })

    -- Persist before leaving the current project (cwd change) and on exit.
    vim.api.nvim_create_autocmd({ "DirChangedPre", "VimLeavePre" }, {
        group    = group,
        callback = function() M.save_state() end,
        desc     = "ezdap: persist breakpoints and expressions",
    })

    -- Gracefully stop active sessions on exit: an adapter killed without a
    -- completed `disconnect` orphans its debuggee, and nvim SIGKILLs adapter
    -- jobs as it exits.
    vim.api.nvim_create_autocmd("VimLeavePre", {
        group    = group,
        callback = function() M.shutdown() end,
        desc     = "ezdap: disconnect sessions so debuggees are terminated on exit",
    })

    -- After a cwd change, re-resolve the project root and restore its state
    -- (or clear it, when the new cwd is not inside a project).
    vim.api.nvim_create_autocmd("DirChanged", {
        group    = group,
        callback = function() M.reload_state() end,
        desc     = "ezdap: restore project state after cwd change",
    })
end

---Whether `setup()` has run.
---@return boolean
function M.is_setup()
    return _setup_done
end

---Initialise the plugin. Nothing exists before this runs, so options deciding
---what gets read off disk (`root_markers`, `data_filename`) or what the command
---is called (`command`) are in place by the time they are first used.
---
---Only the command and the autocmds are installed here. The plugin proper waits
---for demand — a `:Debug` invocation or an API call — or for a project that has
---saved breakpoints to restore.
---
---Calling it a second time is a no-op: the later `opts` are dropped rather
---than half-applied over a plugin that is already wired up.
---@param opts? ezdap.Config
function M.setup(opts)
    if _setup_done then
        vim.notify("[ezdap] setup() already called; ignoring this call", vim.log.levels.ERROR)
        return
    end

    if vim.fn.has("nvim-0.10") ~= 1 then
        error("[ezdap] ezdap.nvim requires Neovim >= 0.10")
    end

    -- `signs` was renamed `symbols` (it names the panel glyphs too, not just
    -- the gutter). Honoured rather than dropped, so an old config does not
    -- silently lose its glyphs. Delete once nobody is on the old name.
    if opts and opts.signs then
        vim.notify("[ezdap] the `signs` option is now `symbols`", vim.log.levels.WARN)
        opts = vim.deepcopy(opts)
        opts.symbols = vim.tbl_deep_extend("force", opts.signs, opts.symbols or {})
        opts.signs = nil
    end

    local config = require("ezdap.config")
    local tmp = vim.tbl_deep_extend("force", config or {}, opts or {})
    for k, v in pairs(tmp) do
        config[k] = v
    end

    -- Set first: the wiring below reaches guarded entry points (a session added
    -- during `_init` opens the debug view).
    _setup_done = true
    _register_command(config.command)
    _create_autocmds()

    -- Everything past this point is deferred to the first `:Debug` or API call
    -- — except when the project has saved breakpoints, which have to show up as
    -- signs without being asked for.
    if _has_saved_state() then _ensure_loaded() end
end

return M
