---@brief Reusable fragments shared across built-in adapter definitions.
---
---Holds small helpers (`unique_buf_name`, `free_port`) and the debugpy
---`setup` function used by the `debugpy` adapter file (local launch/attach and
---remote attach). Preset field sets are adapter-specific and stay local to
---each adapter's own file.

local S = {}

-- ── Utilities ──────────────────────────────────────────────────────────────

---@param basename string
---@return string
function S.unique_buf_name(basename)
    local name = basename
    local n    = 0
    while vim.fn.bufnr(name) ~= -1 do
        n    = n + 1
        name = basename .. "#" .. n
    end
    return name
end

---@return integer
function S.free_port()
    local tcp = assert(vim.uv.new_tcp(), "uv.new_tcp failed")
    tcp:bind("127.0.0.1", 0)
    local addr = assert(tcp:getsockname(), "getsockname failed")
    tcp:close()
    return addr.port
end

-- ── debugpy ──────────────────────────────────────────────────────────────

---Spawn the local debugpy adapter on a free port and point the connection at it.
---@param config   easydap.dap.Config
---@param ctx      easydap.AdapterSetupCtx
---@param callback fun(err?: string, state?: any)
function S.debugpy_setup(config, ctx, callback)
    local term = require("easydap.tk.term")
    local function resolve_python()
        local base = vim.fs.joinpath(vim.fn.stdpath("data"), "mason", "packages", "debugpy", "venv")
        local path = vim.fn.has("win32") == 1
            and vim.fs.joinpath(base, "Scripts", "python.exe")
            or vim.fs.joinpath(base, "bin", "python")
        if vim.fn.filereadable(path) == 1 then return path end
        local sys = vim.fn.exepath("python3")
        local fallback = type(config.command) == "table" and config.command[1] or config.command --[[@as string]]
        return sys ~= "" and sys or fallback
    end
    local python = resolve_python()
    if vim.fn.executable(python) == 0 then return callback(python .. " not found") end
    if vim.fn.system(python .. " -c 'import debugpy.adapter'"):match("^Error") then
        return callback("debugpy is not installed for " .. python)
    end
    local port   = S.free_port()
    local called = false
    local function done(err, state)
        if called then return end
        called = true
        callback(err, state)
    end
    local handle = term.spawn(
        { python, "-m", "debugpy.adapter", "--host", "127.0.0.1", "--port", tostring(port) },
        {
            bufname = S.unique_buf_name("easydap://" .. (config.name or config.adapter or "debug") .. "/debugpy-adapter"),
            cwd     = config.cwd or vim.fn.getcwd(),
            on_exit = function() done("debugpy adapter exited unexpectedly") end,
        }
    )
    if not handle then return callback("failed to start debugpy adapter") end
    ctx.add_bufnr(handle.bufnr, { label = "debugpy", priority = -2 })
    config.port = port
    vim.defer_fn(function() done(nil, { handle = handle }) end, 500)
end

return S
