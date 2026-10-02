---@brief The `:Ezdap` command line: parse a typed invocation, route it to the
---`commands` tables (or `init`'s public API for the run/project operations), and
---complete its arguments. `init` requires this lazily from the `:Ezdap`
---callback, so none of it loads until the command is first used.

local commands = require("ezdap.commands")
local ezdap    = require("ezdap")

local M        = {}

---Warn about an unrecognised subcommand, pointing at the nearest known names.
---`prefix` names the level it was typed at (e.g. "breakpoint"), so the message
---says which list the suggestions come from.
---@param sub string|nil
---@param subs string[]
---@param prefix string?
local function _warn_unknown(sub, subs, prefix)
    local where = prefix and (prefix .. ": ") or ""
    local msg = ("[ezdap] %sunknown subcommand '%s'"):format(where, tostring(sub))
    local near = vim.fn.matchfuzzy(subs, tostring(sub))
    if #near > 0 then
        msg = msg .. "; did you mean " .. table.concat({ unpack(near, 1, 3) }, ", ") .. "?"
    else
        msg = msg .. "; :help ezdap-commands for the full list"
    end
    vim.notify(msg, vim.log.levels.WARN)
end

local _bp_subs = {
    "toggle", "set", "column", "remove",
    "clear_file", "clear_all", "clear_fn",
    "enable", "disable", "toggle_enabled", "enable_all", "disable_all",
    "condition", "logpoint",
    "fn", "exception_filter", "exception_type",
    "data", "data_clear", "data_list",
    "list",
}

---`set` argument keys, mapped to the fields `commands.breakpoint.set` takes.
local _BP_SET_KEYS = {
    col = "column", cond = "condition", hit = "hit_condition", log = "log_message",
}

---Read `:Ezdap breakpoint set [col=N] [cond=…] [hit=…] [log=…]`. Values are
---split by Vim's rules, so escape any space (`cond=x\ >\ 3`); an empty value clears
---the field. `col=` takes a column number — the word under the cursor and the
---adapter-offered columns are `:Ezdap breakpoint column`. No arguments at all sets
---a plain line breakpoint at the cursor.
---@param args string[]
---@return ezdap.commands.BpSetOpts?
local function _parse_bp_set_args(args)
    local opts = {}
    for _, tok in ipairs(args) do
        local key, value = tok:match("^([%w_]+)=(.*)$")
        local field = key and _BP_SET_KEYS[key]
        if not field then
            vim.notify("[ezdap] breakpoint set: expected col=/cond=/hit=/log=, got '" .. tok .. "'",
                vim.log.levels.WARN)
            return
        end
        if field == "column" and not tonumber(value) then
            vim.notify("[ezdap] breakpoint set: col= takes a column number; "
                .. "use :Ezdap breakpoint column [pick] for the word under the cursor "
                .. "or an adapter-offered column", vim.log.levels.WARN)
            return
        end
        opts[field] = value
    end
    return opts
end

---Run the `breakpoint` subcommand. Also reachable via `:Ezdap breakpoint …`.
---@param args string[]
local function _bp_run(args)
    local sub = args[1]
    -- In a disassembly buffer the toggle acts on the instruction under the
    -- cursor, which only the (already-open) view can resolve.
    local disasm = ezdap.disassembly_view_if_open()
    if sub == nil or sub == "" or sub == "toggle" then
        if vim.b.ezdap_disasm and disasm then
            disasm:toggle_bp_at_cursor()
        else
            commands.breakpoint.toggle()
        end
    elseif sub == "set" then
        local set_opts = _parse_bp_set_args({ unpack(args, 2) })
        if set_opts then commands.breakpoint.set(set_opts) end
    elseif sub == "column" then
        commands.breakpoint.column(args[2])
    elseif sub == "remove" then
        commands.breakpoint.remove()
    elseif sub == "clear_file" then
        commands.breakpoint.clear_file()
    elseif sub == "clear_all" then
        commands.breakpoint.clear_all()
    elseif sub == "clear_fn" then
        commands.breakpoint.clear_fn()
    elseif sub == "enable" then
        commands.breakpoint.enable()
    elseif sub == "disable" then
        commands.breakpoint.disable()
    elseif sub == "toggle_enabled" then
        commands.breakpoint.toggle_enabled()
    elseif sub == "enable_all" then
        commands.breakpoint.enable_all()
    elseif sub == "disable_all" then
        commands.breakpoint.disable_all()
    elseif sub == "condition" then
        commands.breakpoint.condition()
    elseif sub == "logpoint" then
        commands.breakpoint.logpoint()
    elseif sub == "fn" then
        commands.breakpoint.fn(args[2])
    elseif sub == "exception_filter" then
        commands.breakpoint.exception_filter()
    elseif sub == "exception_type" then
        commands.breakpoint.exception_type(args[2], args[3])
    elseif sub == "data" then
        commands.breakpoint.data(args[2])
    elseif sub == "data_clear" then
        commands.breakpoint.data_clear()
    elseif sub == "data_list" then
        commands.breakpoint.data_list()
    elseif sub == "list" then
        commands.breakpoint.list()
    else
        _warn_unknown(sub, _bp_subs, "breakpoint")
    end
end

---Completion for the `breakpoint` subcommand.
---@param rest string[]
---@return string[]
local function _bp_complete(rest)
    if #rest == 0 then return _bp_subs end
    if rest[1] == "set" then
        return { "cond=", "hit=", "log=", "col=" }
    end
    if rest[1] == "column" and #rest == 1 then
        return { "pick" }
    end
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

local _view_subs = { "toggle", "hide" }

---Run the `view` subcommand: bare `:Ezdap view` opens (or focuses) the debug
---view, so it never closes a view the user asked for; `toggle` and `hide` are
---the explicit ways to close it.
---@param args string[]
local function _view_cmd(args)
    local sub = args[1]
    if sub == nil or sub == "" then
        commands.view.open()
    elseif sub == "toggle" then
        commands.view.toggle()
    elseif sub == "hide" then
        commands.view.hide()
    else
        _warn_unknown(sub, _view_subs, "view")
    end
end

local _debug_subs = {
    "run", "run_file", "new_run_file", "rerun", "adapter_info",
    "breakpoint",
    "view", "panel", "continue", "continue_all",
    "step_over", "next", "step_in", "step_out", "step_back",
    "step_into_targets", "reverse_continue",
    "jump_to_cursor", "restart_frame", "exception_info",
    "pause", "restart",
    "stop", "stop_all",
    "session", "thread", "terminate_thread", "frame",
    "inspect", "value", "disassemble",
    "project", "clean",
}

---The tokens of the run line from the adapter on: everything after the `run`
---subcommand itself. Split by `split_args`'s rules, not Neovim's, so a value's
---own backslashes reach the input parser intact.
---@param raw string  the run line as typed, `run` and all
---@return string[]
local function _run_tokens(raw)
    local toks = M.split_args(raw)
    for i, tok in ipairs(toks) do
        if tok == "run" then return { unpack(toks, i + 1) } end
    end
    return toks
end

---Read `:Ezdap run <adapter> <mode> [input=value]…` from the run line as typed: the
---adapter and mode are strictly the first two positionals, every later token an
---`input=value` assignment naming one of the mode's declared inputs. The names are
---checked where the inputs are read (`schema.resolve_task`), so a typo is refused
---the same way here, from a run file and through the API.
---@param raw string  the run line as typed, `run` and all
---@return string? adapter, string? mode, table<string, string>? inputs
local function _parse_run_args(raw)
    local args = _run_tokens(raw)
    local adapter, mode = args[1], args[2]
    if (adapter and adapter:find("=", 1, true)) or (mode and mode:find("=", 1, true)) then
        vim.notify("[ezdap] run: usage: :Ezdap run <adapter> <mode> [input=value]…",
            vim.log.levels.WARN)
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

local function _debug_run(_, args, opts)
    local sub = args[1]
    -- Bare `:Ezdap` opens the debug view: the one thing that is useful at any
    -- point, session or not, and the way in for everything the view offers.
    if sub == nil or sub == "" then
        commands.view.open()
    elseif sub == "run_file" then
        ezdap.run_file(args[2])
    elseif sub == "run" then
        local adapter, mode, inputs = _parse_run_args(opts.args or "")
        if inputs then ezdap.run_mode(adapter or "", mode or "", inputs) end
    elseif sub == "new_run_file" then
        ezdap.new_run_file({ unpack(args, 2) })
    elseif sub == "adapter_info" then
        ezdap.adapter_info(args[2], args[3])
    elseif sub == "rerun" then
        ezdap.rerun()
    elseif sub == "view" then
        _view_cmd({ unpack(args, 2) })
    elseif sub == "panel" then
        commands.panel.toggle()
    elseif sub == "continue" then
        commands.debug.continue()
    elseif sub == "continue_all" then
        commands.debug.continue_all()
    elseif sub == "step_over" or sub == "next" then
        commands.debug.step_over()
    elseif sub == "step_in" then
        commands.debug.step_in()
    elseif sub == "step_out" then
        commands.debug.step_out()
    elseif sub == "step_back" then
        commands.debug.step_back()
    elseif sub == "step_into_targets" then
        commands.debug.step_into_targets()
    elseif sub == "reverse_continue" then
        commands.debug.reverse_continue()
    elseif sub == "jump_to_cursor" then
        commands.debug.jump_to_cursor()
    elseif sub == "restart_frame" then
        commands.debug.restart_frame()
    elseif sub == "exception_info" then
        commands.debug.exception_info()
    elseif sub == "pause" then
        commands.debug.pause()
    elseif sub == "restart" then
        commands.debug.restart()
    elseif sub == "stop" then
        commands.debug.stop()
    elseif sub == "stop_all" then
        commands.debug.stop_all()
    elseif sub == "inspect" then
        -- A `'<,'>` range (e.g. `:'<,'>Debug inspect` from visual mode) sets
        -- opts.range > 0; inspect then reads the `'<`/`'>` marks.
        commands.debug.inspect(args[2], opts.range and opts.range > 0)
    elseif sub == "value" then
        commands.debug.value(args[2], opts.range and opts.range > 0)
    elseif sub == "disassemble" then
        commands.debug.disassemble()
    elseif sub == "session" then
        commands.debug.session()
    elseif sub == "thread" then
        commands.debug.thread()
    elseif sub == "terminate_thread" then
        commands.debug.terminate_thread()
    elseif sub == "frame" then
        commands.debug.frame()
    elseif sub == "project" then
        ezdap.project_info()
    elseif sub == "clean" then
        ezdap.clean()
    elseif sub == "breakpoint" then
        _bp_run({ unpack(args, 2) })
    else
        _warn_unknown(sub, _debug_subs, nil)
    end
end

---Completion for `:Ezdap run …` tokens: the adapter (1st bare positional),
---then the mode name (2nd), then input names not yet supplied (as `name=`),
---or a value once `=` has been typed (file paths for a path-like input).
---@param schema table
---@param raw string        the run line as typed, up to the token being completed
---@param arg_lead string   the token being completed
---@return string[]
local function _run_complete(schema, raw, arg_lead)
    local adapter, mode_name
    local supplied = {}
    for _, tok in ipairs(_run_tokens(raw)) do
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
        -- Completing an input's value: whatever the input itself can offer,
        -- paths, true/false, a fixed set of values, nothing for the rest.
        local input  = schema.mode_inputs(adapter, mode_name)[name]
        local values = require("ezdap.inputs").completion(input, val)
        return vim.tbl_map(function(v) return pfx .. v end, values)
    end

    -- No `=` yet: complete the adapter, then the mode, then input names.
    if not adapter then
        return ezdap.available_adapters()
    elseif not mode_name then
        return schema.mode_names(adapter)
    end
    local out = {}
    for _, name in ipairs(schema.mode_input_names(adapter, mode_name)) do
        if not supplied[name] then out[#out + 1] = name .. "=" end
    end
    return out
end

---Completion for `:Ezdap …`. `raw` is the line as typed up to the token being
---completed, for the subcommands that split their arguments themselves.
---@param raw string
---@type ezdap.usercmd.subcommand
local function _complete_subs(_, rest, arg_lead, raw)
    if #rest == 0 then return _debug_subs end
    if rest[1] == "breakpoint" then
        return _bp_complete({ unpack(rest, 2) })
    end
    if rest[1] == "view" then
        return #rest == 1 and _view_subs or {}
    end
    if rest[1] == "run_file" and #rest == 1 then
        return vim.fn.getcompletion(arg_lead, "file")
    end
    if rest[1] == "run" then
        -- <adapter> <mode> <input>=<value>…, split from the raw line so a value
        -- keeps the backslashes its own parser reads.
        local schema = require("ezdap.schema")
        return _run_complete(schema, raw, arg_lead)
    end
    if rest[1] == "adapter_info" then
        -- Positional: [adapter] [mode]; no argument lists every adapter name.
        local schema = require("ezdap.schema")
        if #rest == 1 then return ezdap.available_adapters() end
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
            return ezdap.available_adapters()
        elseif pos == 2 then
            return schema.mode_names(used[1])
        end
        return {}
    end
    return {}
end

-- Completion leaves the split to Neovim: the raw line goes back through
-- nvim_parse_cmd, so `rest` follows the native <f-args> rules below. Running a
-- command instead uses `split_args`, which splits the raw line itself and leaves
-- each escape to exactly one layer.
--
-- Neovim's rules (:h <f-args>): arguments are separated by unescaped whitespace.
-- A backslash escapes the character after it: \<space> (or \<tab>) is that
-- literal whitespace and does not split the argument, \\ is a single backslash,
-- and a backslash before anything else -- including a trailing backslash at end
-- of line -- is kept verbatim along with what follows it. Quotes are not special.
--
--     a\ b c   -> a b  and  c        a\\b     -> a\b
--     a\\\ b   -> a\ b               a\nb     -> a\nb
--     \ a      -> " a"               a\       -> a\
--     "a b"    -> "a  and  b"        --p=x\ y -> --p=x y
--
-- `split_args` escapes only whitespace -- a backslash before a space or tab is
-- that literal character -- and keeps every other backslash for the caller's own
-- parser to read.

---`raw` is the line as typed up to the token being completed: `rest` has been
---split and unescaped, this has not, so a subcommand that reads a value's own
---backslashes (a `:Ezdap run … input=value`) takes them from `raw`.
---@alias ezdap.usercmd.subcommand fun(cmd:string,rest:string[],arg_lead:string,raw:string):string[]

---The `complete` callback for `:Ezdap`, in the shape `nvim_create_user_command`
---calls: re-split the raw line the way <f-args> would, then hand the pieces to
---`_complete_subs`.
---@param arg_lead string
---@param cmd_line string
---@param cursorpos integer  byte index in `cmd_line` of the cursor
---@return string[]
function M.complete(arg_lead, cmd_line, cursorpos)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    -- nvim_parse_cmd splits exactly as <f-args> does, and strips any range or
    -- command modifiers. It throws on a command line it cannot parse.
    local ok, parsed = pcall(vim.api.nvim_parse_cmd, cmd_line, {})
    if not ok then return {} end

    -- Trailing whitespace means a new, still-empty argument has begun; without
    -- it the last argument is the one being completed, not context for it.
    local rest = parsed.args or {}
    if not cmd_line:match("%s$") then
        rest[#rest] = nil
    end

    -- The line up to the token being completed, as typed: `rest` is split and
    -- unescaped, this is not, so a subcommand reads a value's backslashes here.
    local raw = cmd_line:sub(1, cursorpos - #arg_lead)

    return filter(_complete_subs(parsed.cmd, rest, arg_lead, raw))
end

---Split a raw argument string into its arguments, by the execution-side rules
---(module doc): whitespace separates, and a backslash escapes only a following
---space or tab, so a value keeps the backslashes its own parser reads.
---@param raw string
---@return string[]
function M.split_args(raw)
    local args, arg, i = {}, {}, 1
    local function flush()
        if #arg > 0 then args[#args + 1] = table.concat(arg) end
        arg = {}
    end
    while i <= #raw do
        local c, next_c = raw:sub(i, i), raw:sub(i + 1, i + 1)
        if c == "\\" and (next_c == " " or next_c == "\t") then
            arg[#arg + 1] = next_c
            i = i + 2
        elseif c:match("%s") then
            flush()
            i = i + 1
        else
            arg[#arg + 1] = c
            i = i + 1
        end
    end
    flush()
    return args
end

---Run a `:Ezdap …` invocation, exactly as the `:Ezdap` callback hands it over.
---The `setup()` guard has already run by the time init calls this.
---@param cmd  string
---@param args string[]
---@param opts table   the user-command opts (`opts.args`, `opts.range`)
function M.run(cmd, args, opts)
    _debug_run(cmd, args, opts)
end

return M
