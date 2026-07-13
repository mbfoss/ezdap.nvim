local S = require("easydap.adapters._shared")

-- Go — `dlv dap` is a TCP DAP server, NOT a stdio adapter: it prints
-- "DAP server listening at: <host>:<port>" and expects the client to connect over
-- TCP (writing DAP messages to its stdin is ignored). `_setup` spawns it, parses
-- that line, and points the connection at the reported host/port. `program`
-- defaults to the current directory (debug the package at cwd). Field set follows
-- vscode-go's launch.json attributes for dlv-dap mode
-- (https://github.com/golang/vscode-go/blob/master/docs/debugging.md); the delve
-- source-remapping settings below are shared by launch and attach.

---Start `dlv dap`, wait for its "DAP server listening at: host:port" line, and
---point the connection at that endpoint (delve speaks DAP over TCP, not stdio).
---@param config   easydap.dap.Config
---@param ctx      easydap.AdapterSetupCtx
---@param callback fun(err?: string, state?: any)
local function _setup(config, ctx, callback)
    local term = require("easydap.tk.term")
    local cmd  = type(config.command) == "table" and config.command or { config.command or "dlv", "dap" }
    if vim.fn.executable(cmd[1]) == 0 then
        return callback(cmd[1] .. " not found (install delve, e.g. via mason)")
    end
    local resolved = false
    local called   = false
    local handle
    local function done(err, state)
        if called then return end
        called = true
        callback(err, state)
    end
    handle = term.spawn(cmd, {
        bufname   = S.unique_buf_name("easydap://" .. (config.name or config.adapter or "debug") .. "/dlv-dap"),
        cwd       = config.cwd or vim.fn.getcwd(),
        env       = config.env,
        on_stdout = function(_, data)
            if resolved then return end
            for _, line in ipairs(data) do
                -- "DAP server listening at: 127.0.0.1:53742"
                -- (.+) is greedy so it captures up to the last colon (IPv6-safe).
                local h, p = line:match("DAP server listening at:%s*(.+):(%d+)")
                if h and p then
                    resolved    = true
                    config.host = h
                    config.port = tonumber(p)
                    done(nil, { handle = handle })
                    return
                end
            end
        end,
        on_exit   = function()
            if not resolved then done("dlv dap exited before reporting a listening port") end
        end,
    })
    if not handle then return callback("failed to start dlv dap") end
    ctx.add_bufnr(handle.bufnr, { label = "dlv dap", priority = -2 })
    ctx.report("delve: waiting for DAP server port")
    vim.defer_fn(function()
        if not resolved then done("dlv dap did not report a listening port within 5 s") end
    end, 5000)
end

-- Delve's `LaunchAttachCommonConfig` — the fields shared by every launch and
-- attach mode (service/dap/config.go). These are DAP request-body fields the
-- `dlv dap` server itself reads; client-only options like vscode-go's `showLog`
-- / `dlvFlags` are NOT part of it and are deliberately omitted.
---@type table<string, easydap.ParamSpec>
local _common = {
    stopOnEntry          = { type = "boolean", desc = "stop at the program entry point" },
    backend              = {
        type = "string",
        kind = "enum",
        enum = { "default", "native", "lldb", "rr" },
        desc = "backend used by delve (dlv --backend)"
    },
    stackTraceDepth      = { type = "integer", desc = "max stack trace depth collected from delve" },
    showGlobalVariables  = { type = "boolean", desc = "show global package variables" },
    showRegisters        = { type = "boolean", desc = "show register contents while debugging" },
    hideSystemGoroutines = { type = "boolean", desc = "hide system/runtime goroutines from the goroutine list" },
    showPprofLabels      = { type = "list", desc = "pprof label keys to show for each goroutine" },
    goroutineFilters     = { type = "string", desc = "goroutine filters (dlv `goroutines -with/-without`)" },
    substitutePath       = { type = "table", desc = "local<->remote path maps: array of {from, to}" },
}

---@type easydap.AdapterDef
return {
    command       = { "dlv", "dap" },
    setup         = _setup,
    teardown      = function(_, ctx) if ctx and ctx.handle then ctx.handle.stop() end end,
    -- Launch modes and their per-mode fields (LaunchConfig, service/dap/config.go):
    --   debug/test : program (+ buildFlags, output, noDebug)
    --   exec       : program (+ noDebug)   — program is a pre-built binary
    --   core       : program + corefilePath
    --   replay     : traceDirPath
    -- `dlvCwd`/`env` apply to every mode. Per-mode "required" fields can't be
    -- gated here, so all target-ish fields stay optional (the mode dictates which
    -- the server actually needs).
    launch_schema = vim.tbl_extend("error", {
        mode         = {
            type = "string",
            kind = "enum",
            default = "debug",
            enum = { "debug", "test", "exec", "replay", "core" },
            desc = "dlv launch mode"
        },
        program      = {
            type = "string",
            role = "target",
            desc = "package or binary to debug (defaults to cwd; debug/test/exec/core)",
            default = function() return vim.fn.getcwd() end
        },
        args         = S.args,
        cwd          = S.cwd,
        env          = S.env,
        dlvCwd       = { type = "string", kind = "dir", desc = "working directory for the dlv process itself" },
        buildFlags   = { type = "string", desc = "build flags passed to the Go compiler (single string; debug/test)" },
        output       = { type = "string", kind = "file", desc = "output path for the compiled debug binary (debug/test)" },
        noDebug      = { type = "boolean", desc = "run the program without debugging (debug/test/exec)" },
        corefilePath = { type = "string", kind = "file", desc = "core dump to open (core mode)" },
        traceDirPath = { type = "string", kind = "dir", desc = "trace directory to replay (replay mode)" },
    }, _common),
    -- Only `dlv dap`-served attach mode is "local" (attach to a process the server
    -- can see); "remote" attach is served by `dlv --headless` and configured at the
    -- connection level, not through this launched-server body.
    attach_schema = vim.tbl_extend("error", {
        mode      = { type = "string", kind = "enum", enum = { "local", "remote" }, default = "local", desc = "dlv attach mode" },
        processId = { type = "integer", role = "pid", desc = "PID to attach to (local mode)" },
    }, _common),
}
