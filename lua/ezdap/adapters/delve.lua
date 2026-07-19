-- https://github.com/go-delve/delve/blob/master/Documentation/api/dap/README.md

local ui = require("ezdap.util.ui_util")
local shared = require("ezdap.shared")

-- Go — `dlv dap` is a TCP DAP server, not a stdio adapter: it prints
-- "DAP server listening at: <host>:<port>" and expects a TCP connection, so
-- `_setup` spawns it, parses that line and points the connection there.

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

-- Launch modes and their fields follow delve's DAP documentation. Every launch
-- mode accepts `dlvCwd`/`env`; `exec` adds the process fields, and `debug`/`test`
-- add the build and display fields on top of those.

---@type table<string, ezdap.Input>
local _any_mode_inputs = {
    dlv_cwd         = { type = "string", format = "dir", description = "working directory for the delve server itself" },
    env             = { type = "table", format = "map", description = "environment variables for the debuggee" },
    substitute_path = { type = "table", format = "map", description = "source path remappings, from=to" },
}

---Fields every mode that runs a process accepts (`exec`, and so `debug`/`test`).
---@type table<string, ezdap.Input>
local _process_inputs = {
    command  = { type = "string", required = true, description = "command line to debug (package or binary, plus args)" },
    cwd      = { type = "string", format = "cwd", description = "working directory for the debuggee" },
    backend  = { type = "string", description = "debugger backend: default|native|lldb|rr" },
    no_debug = { type = "boolean", description = "run the program without debugging it" },
}

---Build and display fields only the compiling modes (`debug`, `test`) accept.
---@type table<string, ezdap.Input>
local _build_inputs = {
    build_flags            = { type = "string", description = "flags passed to the Go compiler" },
    output                 = { type = "string", format = "file", description = "path for the compiled binary" },
    stop_on_entry          = { type = "boolean", description = "break at program entry" },
    stack_trace_depth      = { type = "integer", description = "maximum stack trace depth" },
    show_global_variables  = { type = "boolean", description = "show package-level variables among the scopes" },
    show_registers         = { type = "boolean", description = "show CPU registers among the scopes" },
    show_pprof_labels      = { type = "table", format = "list", description = "pprof labels to show in goroutine names" },
    show_raw_strings       = { type = "boolean", description = "show strings without quoting or escaping" },
    hide_system_goroutines = { type = "boolean", description = "hide runtime goroutines from the thread list" },
    goroutine_filters      = { type = "string", description = "filter expression limiting the goroutines listed" },
}

---A profile's inputs: the always-accepted set plus whichever groups apply.
---@param ... table<string, ezdap.Input>
---@return table<string, ezdap.Input>
local function _inputs(...)
    local out = vim.deepcopy(_any_mode_inputs)
    for _, group in ipairs({ ... }) do
        out = vim.tbl_extend("error", out, vim.deepcopy(group))
    end
    return out
end

---@param params table
---@param inputs table<string, any>
local function _any_mode_build(params, inputs)
    params.dlvCwd = inputs.dlv_cwd
    params.env    = inputs.env
    -- delve wants a list of {from, to} pairs, not a flat mapping.
    if inputs.substitute_path then
        local rules = {}
        for from, to in pairs(inputs.substitute_path) do
            rules[#rules + 1] = { from = from, to = to }
        end
        params.substitutePath = rules
    end
end

---@param params table
---@param inputs table<string, any>
local function _process_build(params, inputs)
    _any_mode_build(params, inputs)
    params.program, params.args = shared.split_command(inputs.command)
    params.cwd     = inputs.cwd
    params.backend = inputs.backend
    params.noDebug = inputs.no_debug
end

---@param params table
---@param inputs table<string, any>
local function _build_build(params, inputs)
    _process_build(params, inputs)
    params.buildFlags           = inputs.build_flags
    params.output               = inputs.output
    params.stopOnEntry          = inputs.stop_on_entry
    params.stackTraceDepth      = inputs.stack_trace_depth
    params.showGlobalVariables  = inputs.show_global_variables
    params.showRegisters        = inputs.show_registers
    params.showPprofLabels      = inputs.show_pprof_labels
    params.showRawStrings       = inputs.show_raw_strings
    params.hideSystemGoroutines = inputs.hide_system_goroutines
    params.goroutineFilters     = inputs.goroutine_filters
end

---@type ezdap.AdapterDef
return {
    command  = { "dlv", "dap" },
    setup    = _setup,
    teardown = function(_, ctx) if ctx and ctx.handle then ctx.handle.stop() end end,
    profiles       = {
        -- `build` splits the one `command` input into `program` and `args`.
        launch_program = {
            description = "build and debug a Go package/binary",
            request = "launch",
            inputs = _inputs(_process_inputs, _build_inputs),
            build = function(params, _, inputs)
                params.mode = "debug"
                _build_build(params, inputs)
            end,
        },
        launch_test = {
            description = "build and debug a Go test package",
            request = "launch",
            inputs = _inputs(_process_inputs, _build_inputs),
            build = function(params, _, inputs)
                params.mode = "test"
                _build_build(params, inputs)
            end,
        },
        launch_exec = {
            description = "debug a pre-built Go binary",
            request = "launch",
            inputs = _inputs(_process_inputs),
            build = function(params, _, inputs)
                params.mode = "exec"
                _process_build(params, inputs)
            end,
        },
        -- Replay and core are post-mortem: they read a recording rather than run a
        -- process, so they take neither args nor the process fields.
        replay = {
            description = "replay an rr trace recording",
            request = "launch",
            inputs = _inputs {
                program        = { type = "string", format = "file", required = true, description = "binary the trace was recorded from" },
                trace_dir_path = { type = "string", format = "dir", required = true, description = "rr trace directory to replay" },
            },
            build = function(params, _, inputs)
                params.mode         = "replay"
                _any_mode_build(params, inputs)
                params.program      = inputs.program
                params.traceDirPath = inputs.trace_dir_path
            end,
        },
        core = {
            description = "post-mortem debug from a core dump",
            request = "launch",
            inputs = _inputs {
                program       = { type = "string", format = "file", required = true, description = "binary that produced the core" },
                corefile_path = { type = "string", format = "file", required = true, description = "core dump to load" },
            },
            build = function(params, _, inputs)
                params.mode          = "core"
                _any_mode_build(params, inputs)
                params.program       = inputs.program
                params.corefilePath  = inputs.corefile_path
            end,
        },
        -- Only `dlv dap`-served attach mode is "local" (attach to a process the
        -- server can see); "remote" attach is served by `dlv --headless` and
        -- configured at the connection level, not through this launched-server body.
        attach_process = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = {
                pid     = { type = "integer", description = "process id to attach to" },
                backend = { type = "string", description = "debugger backend: default|native|lldb|rr" },
            },
            build = function(params, _, inputs)
                local pid, err = shared.resolve_pid(inputs.pid)
                if not pid then return err end
                params.mode      = "local"
                params.processId = pid
                params.backend   = inputs.backend
            end,
        },
    },
}
