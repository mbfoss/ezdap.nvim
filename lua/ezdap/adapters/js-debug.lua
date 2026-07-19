local ui = require("ezdap.util.ui_util")
local shared = require("ezdap.shared")

-- JavaScript / TypeScript — starts js-debug's TCP server, then connects to it.
-- Fields follow vscode-js-debug's options documentation
-- (https://github.com/microsoft/vscode-js-debug/blob/main/OPTIONS.md). js-debug
-- picks the debuggee's console via `console`, not runInTerminal.

---Source-resolution fields every profile accepts, node and browser alike.
---@type table<string, ezdap.Input>
local _source_inputs = {
    source_maps                  = { type = "boolean", description = "use source maps when they exist" },
    source_map_path_overrides    = { type = "table", format = "map", description = "rewrite sourcemap file locations, from=to" },
    resolve_source_map_locations = { type = "table", format = "list", description = "globs where sourcemaps may be resolved" },
    out_files                    = { type = "table", format = "list", description = "globs matching generated JavaScript" },
    skip_files                   = { type = "table", format = "list", description = "globs to skip when stepping" },
    smart_step                   = { type = "boolean", description = "step over generated code with no original source" },
}

---Fields both Node profiles accept on top of the source ones.
---@type table<string, ezdap.Input>
local _node_inputs = {
    cwd                         = { type = "string", format = "cwd", description = "working directory" },
    env                         = { type = "table", format = "map", description = "environment variables" },
    env_file                    = { type = "string", format = "file", description = "file of environment variable definitions" },
    restart                     = { type = "boolean", description = "try to reconnect when the connection is lost" },
    auto_attach_child_processes = { type = "boolean", description = "attach to child processes automatically" },
}

---A profile's inputs: the source-resolution set plus whichever groups apply.
---@param ... table<string, ezdap.Input>
---@return table<string, ezdap.Input>
local function _inputs(...)
    local out = vim.deepcopy(_source_inputs)
    for _, group in ipairs({ ... }) do
        out = vim.tbl_extend("error", out, vim.deepcopy(group))
    end
    return out
end

---@param params table
---@param inputs table<string, any>
local function _source_build(params, inputs)
    params.sourceMaps                = inputs.source_maps
    params.sourceMapPathOverrides    = inputs.source_map_path_overrides
    params.resolveSourceMapLocations = inputs.resolve_source_map_locations
    params.outFiles                  = inputs.out_files
    params.skipFiles                 = inputs.skip_files
    params.smartStep                 = inputs.smart_step
end

---@param params table
---@param inputs table<string, any>
local function _node_build(params, inputs)
    _source_build(params, inputs)
    params.type                     = "pwa-node"
    params.cwd                      = inputs.cwd
    params.env                      = inputs.env
    params.envFile                  = inputs.env_file
    params.restart                  = inputs.restart
    params.autoAttachChildProcesses = inputs.auto_attach_child_processes
end

---@type table<string, ezdap.Profile>
local _profiles = {
    -- One `command` input carries the whole command line; `build` splits it into
    -- `program` (the first word) and `args` (the rest). The runtime is not part of
    -- it — `command` starts at the script, and `runtime_executable` names the runtime.
    launch_program = {
        description = "debug a Node.js/JS/TS file",
        request = "launch",
        inputs = _inputs(_node_inputs, {
            command            = { type = "string", required = true, description = "script to debug, plus its arguments" },
            runtime_executable = { type = "string", description = "runtime to run the script with (default node)" },
            runtime_args       = { type = "table", format = "list", description = "arguments passed to the runtime, before the program" },
            stop_on_entry      = { type = "boolean", description = "break at program entry" },
            console            = { type = "string", description = "where to run the debuggee: internalConsole|integratedTerminal|externalTerminal" },
        }),
        build = function(params, _, inputs)
            _node_build(params, inputs)
            params.program, params.args = shared.split_command(inputs.command)
            params.runtimeExecutable = inputs.runtime_executable
            params.runtimeArgs       = inputs.runtime_args
            params.stopOnEntry       = inputs.stop_on_entry
            params.console           = inputs.console
        end,
    },
    -- Both attach profiles are the same DAP request; they differ only in whether
    -- the debuggee is named by pid or by address/port.
    attach_process = {
        description = "attach to a running process by pid",
        request = "attach",
        inputs = _inputs(_node_inputs, {
            pid                      = { type = "integer", description = "process id to attach to" },
            attach_existing_children = { type = "boolean", description = "also attach to already-spawned child processes" },
            continue_on_attach       = { type = "boolean", description = "resume a program waiting on --inspect-brk" },
        }),
        build = function(params, _, inputs)
            local pid, err = shared.resolve_pid(inputs.pid)
            if not pid then return err end
            _node_build(params, inputs)
            params.processId              = pid
            params.attachExistingChildren = inputs.attach_existing_children
            params.continueOnAttach       = inputs.continue_on_attach
        end,
    },
    -- `local_root`/`remote_root` map the remote machine's paths onto this one.
    remote = {
        description = "attach to a remote Node.js process over host/port",
        request = "attach",
        inputs = _inputs(_node_inputs, {
            host                     = { type = "string", format = "host", description = "remote Node.js host" },
            port                     = { type = "integer", format = "port", description = "remote Node.js debug port (default 9229)" },
            local_root               = { type = "string", format = "dir", description = "local directory containing the program" },
            remote_root              = { type = "string", description = "remote directory containing the program" },
            attach_existing_children = { type = "boolean", description = "also attach to already-spawned child processes" },
            continue_on_attach       = { type = "boolean", description = "resume a program waiting on --inspect-brk" },
        }),
        build = function(params, _, inputs)
            _node_build(params, inputs)
            params.address                = inputs.host
            params.port                   = inputs.port
            params.localRoot              = inputs.local_root
            params.remoteRoot             = inputs.remote_root
            params.attachExistingChildren = inputs.attach_existing_children
            params.continueOnAttach       = inputs.continue_on_attach
        end,
    },
    -- The browser target: js-debug serves pwa-chrome from the same server, and
    -- resolves sources through `web_root`/`path_mapping` rather than a cwd.
    launch_browser = {
        description = "launch a Chromium browser and debug a page",
        request = "launch",
        inputs = _inputs {
            url                = { type = "string", required = true, description = "url to open and attach to" },
            web_root           = { type = "string", format = "dir", description = "absolute path to the webserver root" },
            path_mapping       = { type = "table", format = "map", description = "url-to-local-folder mappings, from=to" },
            user_data_dir      = { type = "string", format = "dir", description = "browser profile directory (default: a temp profile)" },
            runtime_executable = { type = "string", description = "'stable', 'canary', or a path to the browser executable" },
            runtime_args       = { type = "table", format = "list", description = "arguments passed to the browser" },
        },
        build = function(params, _, inputs)
            _source_build(params, inputs)
            params.type              = "pwa-chrome"
            params.url               = inputs.url
            params.webRoot           = inputs.web_root
            params.pathMapping       = inputs.path_mapping
            params.userDataDir       = inputs.user_data_dir
            params.runtimeExecutable = inputs.runtime_executable
            params.runtimeArgs       = inputs.runtime_args
        end,
    },
}

---@type ezdap.AdapterDef
return {
    setup = function(config, ctx, callback)
        local term = require("ezdap.tk.term")
        local server_js = vim.fs.joinpath(
            vim.fn.stdpath("data"), "mason", "packages",
            "js-debug-adapter", "js-debug", "src", "dapDebugServer.js"
        )
        if vim.fn.filereadable(server_js) == 0 then
            return callback("js-debug-adapter not found at " .. server_js)
        end
        local resolved_host = nil
        local resolved_port = nil
        local called        = false
        local function done(err, state)
            if called then return end
            called = true
            callback(err, state)
        end
        local handle
        handle = term.spawn({ "node", server_js }, {
            bufname = ui.unique_buf_name("ezdap://" .. (config.name or config.adapter or "debug") .. "_js-debug-server"),
            on_stdout = function(_, data)
                if resolved_port then return end
                for _, line in ipairs(data) do
                    -- format: "Debug server listening at <host>:<port>"
                    -- (.+) is greedy so it captures up to the last colon,
                    -- correctly handling IPv6 addresses like ::1
                    local h, p = line:match("Debug server listening at (.+):(%d+)")
                    if h and p then
                        resolved_host = h
                        resolved_port = tonumber(p)
                        config.host   = resolved_host
                        config.port   = resolved_port
                        done(nil, { handle = handle })
                        return
                    end
                end
            end,
            on_exit = function()
                if not resolved_port then
                    done("js-debug server exited before reporting a port")
                end
            end,
        })
        if not handle then return callback("failed to start js-debug server") end
        ctx.add_bufnr(handle.bufnr, { label = "js-debug server", priority = -2 })
        ctx.report("js-debug: waiting for server port")
        vim.defer_fn(function()
            if not resolved_port then
                done("js-debug server did not start within 5 s")
            end
        end, 5000)
    end,

    teardown = function(_, ctx)
        if ctx then ctx.handle.stop() end
    end,

    profiles       = _profiles,
}
