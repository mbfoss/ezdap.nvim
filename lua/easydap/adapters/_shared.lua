---@brief Reusable fragments shared across built-in adapter definitions.
---
---Holds the generic `program`/`args`/`cwd`/`env` ParamSpecs, small helpers
---(`lldb_cmds`, `unique_buf_name`, `free_port`), and the debugpy `setup`/`common`
---fields used by the `debugpy` adapter file (local launch/attach and remote attach).
---Adapter-specific field sets that live in a single file (lldb, codelldb, delve, …)
---stay local to that file instead of here.

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

-- ── Common param specs ──────────────────────────────────────────────────────
-- Read-only ParamSpec fragments reused across the process-launching adapters.
-- Adapters whose defaults differ (e.g. delve's program, which defaults to cwd)
-- spell those entries out inline instead of sharing these.
--
-- Adapters that want these reachable from a `target`/`args`-driven `run_target`
-- or `quick_run` template point their template's `program`/`args` placeholders
-- at whichever of these keys they use (see e.g. `codelldb.lua`'s `templates`).
---@type easydap.ParamSpec
S.program = { type = "string", kind = "file", desc = "program to debug" }
---@type easydap.ParamSpec
S.args = { type = "list", kind = "shell_args", desc = "program arguments" }
---@type easydap.ParamSpec
S.cwd = { type = "string", kind = "cwd", desc = "working directory" }
---@type easydap.ParamSpec
S.env = { type = "table", kind = "env", desc = "environment: VAR=VAL,VAR2=VAL2" }

---A comma-separated list of verbatim LLDB command lines (each kept whole).
---@param desc string
---@return easydap.ParamSpec
function S.lldb_cmds(desc)
    return { type = "list", desc = desc }
end

-- ── debugpy ──────────────────────────────────────────────────────────────

-- debugpy's "Debugger Settings" — the toggles shared by launch and attach per the
-- debugpy wiki (https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings).
-- `justMyCode`/`showReturnValue` keep easydap's existing defaults (debug all code,
-- show return values); the rest are omitted unless set, so debugpy applies its own
-- documented defaults.
---@type table<string, easydap.ParamSpec>
S.debugpy_common = {
    justMyCode      = { type = "boolean", desc = "debug only user-written code", default = false },
    showReturnValue = { type = "boolean", desc = "show function return values when stepping", default = true },
    django          = { type = "boolean", desc = "enable Django template debugging" },
    jinja           = { type = "boolean", desc = "enable Jinja2 template debugging (e.g. Flask)" },
    gevent          = { type = "boolean", desc = "debug gevent monkey-patched code" },
    pyramid         = { type = "boolean", desc = "debug Pyramid applications" },
    subProcess      = { type = "boolean", desc = "debug child processes (debugpy default true)" },
    redirectOutput  = { type = "boolean", desc = "redirect program output to the debug console" },
    logToFile       = { type = "boolean", desc = "log debugger events to a file" },
    sudo            = { type = "boolean", desc = "run the program with elevated privileges (Unix)" },
    pathMappings    = { type = "table", desc = "local<->remote path maps: array of {localRoot, remoteRoot}" },
}

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
