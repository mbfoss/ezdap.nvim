local ui = require("ezdap.util.ui_util")
local shared = require("ezdap.shared")

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
---@param config   ezdap.dap.Config
---@param ctx      ezdap.AdapterSetupCtx
---@param callback fun(err?: string, state?: any)
local function _setup(config, ctx, callback)
    local term = require("ezdap.tk.term")
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
        bufname   = ui.unique_buf_name("ezdap://" .. (config.name or config.adapter or "debug") .. "_dlv-dap"),
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

---@type ezdap.AdapterDef
return {
    command  = { "dlv", "dap" },
    setup    = _setup,
    teardown = function(_, ctx) if ctx and ctx.handle then ctx.handle.stop() end end,
    profiles       = {
        -- Launch mode defaults to "debug" (LaunchConfig, service/dap/config.go);
        -- `dlvCwd`/per-mode fields (buildFlags, corefilePath, …) aren't set by
        -- this configuration — add them to the run file directly if needed.
        -- One `command` input carries the whole command line; `build` splits it into
        -- `program` (the first word) and `args` (the rest).
        launch_program = {
            description = "debug a Go package/binary",
            request = "launch",
            inputs = {
                command = { type = "table", format = "shell_args", description = "command line to debug" },
                cwd     = { type = "string", format = "cwd", description = "working directory" },
                env     = { type = "table", format = "env", description = "environment variables" },
            },
            build = function(params, _, inputs)
                params.mode = "debug"
                if inputs.command then
                    params.program = vim.fn.expand(inputs.command[1] or "")
                    params.args    = { unpack(inputs.command, 2) }
                end
                params.cwd = inputs.cwd
                params.env = inputs.env
            end,
        },
        -- Only `dlv dap`-served attach mode is "local" (attach to a process the
        -- server can see); "remote" attach is served by `dlv --headless` and
        -- configured at the connection level, not through this launched-server body.
        attach_process = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = {
                pid = { type = "integer", description = "process id to attach to" },
            },
            build = function(params, _, inputs)
                local pid, err = shared.resolve_pid(inputs.pid)
                if not pid then return err end
                params.mode      = "local"
                params.processId = pid
            end,
        },
    },
}
