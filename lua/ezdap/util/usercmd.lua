local M = {}

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
--
---`raw` is the line as typed up to the token being completed: `rest` has been
---split and unescaped, this has not, so a subcommand that reads a value's own
---backslashes (a `:Ezdap run … input=value`) takes them from `raw`.
---@alias ezdap.util.usercmd.subcommand fun(cmd:string,rest:string[],arg_lead:string,raw:string):string[]

--- Completion for a command registered with `nargs = "*"`, to be called from
--- inside the `complete` callback so that this module -- and whatever
--- `subcommand` closes over -- is only required once completion is first
--- attempted.
---@param arg_lead string
---@param cmd_line string
---@param cursorpos integer  byte index in `cmd_line` of the cursor
---@param subcommand ezdap.util.usercmd.subcommand
---@return string[]
function M.complete(arg_lead, cmd_line, cursorpos, subcommand)
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

    return filter(subcommand(parsed.cmd, rest, arg_lead, raw))
end

-- Splitting a command's arguments

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

return M
