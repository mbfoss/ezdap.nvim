local M = {}

-- Quoting rules (shared with keystone.nvim's queryflags):
--
--   Arguments are whitespace-separated. Only " quotes, and only on a word
--   boundary: quoting is in play for an argument solely when its very first
--   character is a ". For such an argument, a " opens or closes a quoted span
--   -- whitespace inside a span does not split the argument, the delimiting
--   quotes are stripped, a literal double quote is written as \", and a
--   backslash before anything else is literal. Text following a closing quote
--   joins the same argument.
--
--   An argument that does not begin with a ", or one whose last span is left
--   unterminated, has no quoting at all: it runs to the next whitespace and is
--   taken literally, with no quote or backslash processing.
--
--     "a b c"      -> a b c            a"b"c  -> a"b"c
--     "a"c         -> ac               a\"c   -> a\"c
--     "text"suffix -> textsuffix       "a b   -> "a  and  b
--     "a\"c"       -> a"c
--
--   "" is an explicit empty argument and is kept as one.
--
--- Scan the quote-delimited argument starting at the opening quote at `start`.
--- Returns its unescaped text and the index just past it, or nil if a span was
--- left unterminated.
---@param str string
---@param start integer
---@return string? arg
---@return integer? next_i
local function scan_quoted(str, start)
    local len    = #str
    local chars  = {}
    local inside = false
    local i      = start

    while i <= len do
        local c = str:sub(i, i)
        if c == "\\" and str:sub(i + 1, i + 1) == '"' then
            table.insert(chars, '"')
            i = i + 2
        elseif c == '"' then
            inside = not inside
            i      = i + 1
        elseif c:match("%s") and not inside then
            break
        else
            table.insert(chars, c)
            i = i + 1
        end
    end

    if inside then return nil end -- unterminated
    return table.concat(chars), i
end

---@param str string
---@return string[]
function M.split_args(str)
    local args = {}
    local i    = 1
    local len  = #str

    while i <= len do
        while i <= len and str:sub(i, i):match("%s") do i = i + 1 end
        if i > len then break end

        local arg = nil
        if str:sub(i, i) == '"' then
            local content, next_i = scan_quoted(str, i)
            if content then
                arg = content
                i   = next_i --[[@as integer]]
            end
        end

        if not arg then
            -- Literal token: run to the next whitespace, verbatim.
            local from = i
            while i <= len and not str:sub(i, i):match("%s") do i = i + 1 end
            arg = str:sub(from, i - 1)
        end

        table.insert(args, arg)
    end

    return args
end

---@alias ezdap.util.usercmd.subcommand fun(cmd:string,rest:string[],arg_lead:string):string[]

---@alias ezdap.util.usercmd.run_fn
---| fun(cmd:string,args:string[],opts:vim.api.keyset.create_user_command.command_args)


---@param subcommand ezdap.util.usercmd.subcommand
local function _complete(subcommand, arg_lead, cmd_line)
    local function filter(strs)
        local out = {}
        for _, s in ipairs(strs or {}) do
            if vim.startswith(s, arg_lead) then
                table.insert(out, s)
            end
        end
        return out
    end

    local args = M.split_args(cmd_line)
    if cmd_line:match("%s+$") then
        table.insert(args, ' ')
    end

    local cmd = args[1]
    if #args == 1 then
        return filter(subcommand(cmd, {}, arg_lead))
    elseif #args >= 2 then
        local rest = { unpack(args, 2) }
        rest[#rest] = nil
        return filter(subcommand(cmd, rest, arg_lead))
    end
    return {}
end

---@param cmd string
---@param run_fn ezdap.util.usercmd.run_fn
---@param opts vim.api.keyset.create_user_command.command_args
local function _dispatch(cmd, run_fn, opts)
    local args = M.split_args(opts.args)
    local ok, err = pcall(run_fn, cmd, args, opts)
    if not ok then
        vim.notify(
            "[ezdap.util.nvim] " .. cmd .. " command error\n" .. tostring(err),
            vim.log.levels.ERROR
        )
    end
end

---@param cmd string
---@param run_fn ezdap.util.usercmd.run_fn
---@param opts {desc:string?,subcommand:ezdap.util.usercmd.subcommand?,count:boolean,range:boolean}?
function M.register_user_cmd(cmd, run_fn, opts)
    opts = opts or {}
    vim.api.nvim_create_user_command(cmd, function(cmd_opts)
            _dispatch(cmd, run_fn, cmd_opts)
        end,
        {
            nargs = "*",
            count = opts.count,
            range = opts.range,
            complete = opts.subcommand ~= nil and function(arg_lead, cmd_line, _)
                return _complete(opts.subcommand, arg_lead, cmd_line)
            end or function() return {} end,
            desc = opts.desc,
        })
end

return M
