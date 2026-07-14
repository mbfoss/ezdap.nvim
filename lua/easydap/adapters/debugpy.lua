local ui = require("easydap.util.ui_util")

---@return integer
local function _free_port()
    local tcp = assert(vim.uv.new_tcp(), "uv.new_tcp failed")
    tcp:bind("127.0.0.1", 0)
    local addr = assert(tcp:getsockname(), "getsockname failed")
    tcp:close()
    return addr.port
end


---Spawn the local debugpy adapter on a free port and point the connection at it.
---@param config   easydap.dap.Config
---@param ctx      easydap.AdapterSetupCtx
---@param callback fun(err?: string, state?: any)
local function _debugpy_setup(config, ctx, callback)
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
    local port   = _free_port()
    local called = false
    local function done(err, state)
        if called then return end
        called = true
        callback(err, state)
    end
    local handle = term.spawn(
        { python, "-m", "debugpy.adapter", "--host", "127.0.0.1", "--port", tostring(port) },
        {
            bufname = ui.unique_buf_name("easydap://" .. (config.name or config.adapter or "debug") .. "/debugpy-adapter"),
            cwd     = config.cwd or vim.fn.getcwd(),
            on_exit = function() done("debugpy adapter exited unexpectedly") end,
        }
    )
    if not handle then return callback("failed to start debugpy adapter") end
    ctx.add_bufnr(handle.bufnr, { label = "debugpy", priority = -2 })
    config.port = port
    vim.defer_fn(function() done(nil, { handle = handle }) end, 500)
end

-- Attach to a remote Python process running debugpy via `connect.*`.
-- task.host / task.port point to the REMOTE process; the local debugpy adapter
-- is spawned by S.debugpy_setup and connects to it via the `connect` args.
-- The `connect` group targets the REMOTE process and goes in the body's
-- `connect`, not the task-level connection (the local adapter port is chosen
-- by S.debugpy_setup). `justMyCode`/`showReturnValue` keep easydap's existing
-- behaviour (debug all code, show return values); debugpy applies its own
-- documented defaults for everything else, per its wiki
-- (https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings).
---@type easydap.AdapterDef
return {
    command  = "python3",
    setup    = _debugpy_setup,
    teardown = function(_, ctx) if ctx then ctx.handle.stop() end end,
    configurations = {
        launch = {
            request = "launch",
            parameters = {
                type            = "python",
                program         = "{target:file}",
                args            = "{args:shell_args}",
                cwd             = "{cwd:cwd}",
                env             = "{env:env}",
                justMyCode      = false,
                showReturnValue = true,
            },
        },
        attach = {
            request = "attach",
            parameters = {
                type            = "python",
                processId       = "{pid:integer}",
                justMyCode      = false,
                showReturnValue = true,
            },
        },
        -- The `connect.*` body group targets the remote process — not the
        -- configuration-level `connect` block (that's reserved for a task-level TCP
        -- endpoint, which this adapter's def doesn't declare).
        remote = {
            request = "attach",
            parameters = {
                type = "python",
                connect = {
                    host = "{host:host}",
                    port = "{port:port}",
                },
                justMyCode      = false,
                showReturnValue = true,
            },
        },
    },
}
