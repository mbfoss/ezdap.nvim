-- shared functions - Public API

local M = {}

---The process id to attach to: the one already given, or one picked interactively.
---What an attach profile's `build` calls for its `pid` input, which is why
---no adapter marks that input `required` — there is nothing the user must type.
---
---Yields (see `select_process`) only when `pid` is nil.
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

---Pick a running process interactively, via `vim.ui.select`.
---
---This yields: it must be called from inside a coroutine, and it resumes that
---coroutine with the choice once the user picks (or cancels).
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
    -- left to do runs inside this resume, so a failure in it surfaces here or not at
    -- all — `coroutine.resume` reports an error by returning false instead of raising,
    -- and there is no one above us to catch it.
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