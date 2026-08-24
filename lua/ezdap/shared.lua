-- shared functions - Public API

local str_util = require("ezdap.util.strutil")

local M = {}

-- Re-exported so registry adapters (under `lua/ezdap-adapters/`) depend only on
-- `ezdap.shared`, not on the plugin's internal module layout.

---Spawn a command in a terminal buffer — see `ezdap.util.term.spawn`.
---@type fun(cmd: string|string[], opts: ezdap.util.SpawnOpts, bufnr?: integer): ezdap.util.TermHandle?, string?
M.spawn = require("ezdap.util.term").spawn

---A buffer name unique against currently-loaded buffers — see
---`ezdap.util.ui.unique_buf_name`.
---@type fun(basename: string): string
M.unique_buf_name = require("ezdap.util.ui").unique_buf_name

---Split a `command` input into the `program`/`args` pair a launch body wants. The
---first word is expanded (`~`, `$VAR`) as the program, the rest are its arguments
---verbatim; a list is accepted as-is. An unset command yields an empty program.
---@param command string|string[]|nil  a command line, or an argument list
---@return string program, string[] args
function M.split_command(command)
    local argv = str_util.cmd_to_string_array(command or "")
    return vim.fn.expand(argv[1] or ""), { unpack(argv, 2) }
end

---Expand one candidate path from a lookup list: a leading `$VAR` becomes the
---environment variable's value (nil when unset, so the caller skips the entry),
---`~` becomes the home directory, and a relative entry is taken against `cwd` when
---one is given. Pass no `cwd` for a list of programs, where a bare name is meant
---to be looked up on $PATH rather than resolved against a directory.
---@param path string
---@param cwd? string  base for relative entries; without it they are left as-is
---@return string?
function M.expand_path(path, cwd)
    local var, rest = path:match("^%$([%w_]+)(.*)$")
    if var then
        local value = vim.env[var]
        if not value or value == "" then return nil end
        path = value .. rest
    end
    if cwd and not path:match("^~") and vim.fn.isabsolutepath(path) == 0 then
        path = vim.fs.joinpath(cwd, path)
    end
    return vim.fs.normalize(path)
end

---Walk a list of candidate locations and return the first one `accept` approves,
---alongside every candidate actually tried (for an error message naming them).
---Entries are expanded by `expand_path`, mapped through `opts.transform` when one
---is given, and de-duplicated. Entries are literal paths — no globbing.
---@param candidates string[]  lookup list, in preference order
---@param accept fun(path: string): boolean  the test a usable candidate passes
---@param opts? { cwd?: string, transform?: fun(path: string): string }
---@return string? found, string[] tried
function M.resolve_path(candidates, accept, opts)
    opts = opts or {}
    local tried, seen = {}, {}
    for _, cand in ipairs(candidates) do
        local path = M.expand_path(cand, opts.cwd)
        if path and opts.transform then path = opts.transform(path) end
        if path and not seen[path] then
            seen[path] = true
            tried[#tried + 1] = path
            if accept(path) then return path, tried end
        end
    end
    return nil, tried
end

---`accept` for `resolve_path` when the candidate must be a runnable program.
---@param path string
---@return boolean
function M.is_executable(path) return vim.fn.executable(path) == 1 end

---`accept` for `resolve_path` when the candidate must be an existing directory.
---@param path string
---@return boolean
function M.is_directory(path) return vim.fn.isdirectory(path) == 1 end

---The process id to attach to: the one already given, or one picked interactively.
---What an attach mode's `build` calls for its `pid` input, which is why no adapter
---marks it `required`. Yields (see `select_process`) only when `pid` is nil.
---@param pid integer?  the pid supplied as an input, if any
---@param prompt? string  select prompt
---@return integer? pid, string? err
function M.resolve_pid(pid, prompt)
    -- Not `pid or select_process(…)`: `or` would truncate the call to one value
    -- and drop the error, leaving a cancelled pick indistinguishable from a
    -- successful one.
    if pid then return pid end
    return M.select_process(prompt or "Select process to attach to")
end

---Pick a running process interactively, via `vim.ui.select`. This yields: it must be
---called from inside a coroutine, and resumes it with the choice once the user picks.
---@param prompt? string  select prompt (default "Select process")
---@return integer? pid, string? err
function M.select_process(prompt)
    local co = coroutine.running()
    if not co then
        return nil, "select_process must be called from a coroutine"
    end

    local lines = vim.fn.systemlist("ps -eo pid,user,comm 2>/dev/null")
    if not lines or #lines == 0 then
        return nil, "No processes found"
    end

    ---@type {label:string, pid:string}[]
    local choices = {}
    for i, line in ipairs(lines) do
        if i > 1 then -- skip header
            local pid, user, name = line:match("^%s*(%d+)%s+(%S+)%s+(.-)%s*$")
            if pid then
                choices[#choices + 1] = {
                    label = ("%8s | %s - %s"):format(pid, user, name),
                    pid   = pid,
                }
            end
        end
    end
    if #choices == 0 then return nil, "No processes found" end

    -- Hands the answer back to the yielded caller. Everything that caller still has
    -- to do runs inside this resume, so a failure in it surfaces here or not at all —
    -- `coroutine.resume` returns false instead of raising, and no one is above us.
    local function answer(pid)
        local ok, err = coroutine.resume(co, pid)
        if not ok then
            vim.notify("ezdap: " .. tostring(err), vim.log.levels.ERROR)
        end
    end

    vim.schedule(function()
        local labels = vim.tbl_map(function(c) return c.label end, choices)
        vim.ui.select(labels, { prompt = type(prompt) == "string" and prompt or "Select process" }, function(selected)
            if not selected then
                answer(nil)
                return
            end
            for _, c in ipairs(choices) do
                if c.label == selected then
                    answer(c.pid)
                    return
                end
            end
            answer(nil)
        end)
    end)

    local pid = coroutine.yield()
    if not pid then return nil, "Process selection cancelled" end
    return tonumber(pid)
end

return M