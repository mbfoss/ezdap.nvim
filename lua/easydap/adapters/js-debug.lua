local S = require("easydap.adapters._shared")

-- JavaScript / TypeScript — starts js-debug's TCP server, then connects to it.
---@type easydap.AdapterDef
return {
    setup = function(config, ctx, callback)
        local term = require("easydap.tk.term")
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
            bufname = S.unique_buf_name("easydap://" .. (config.name or config.adapter or "debug") .. "/js-debug-server"),
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

    -- Field set follows vscode-js-debug's `node` launch/attach options
    -- (https://github.com/microsoft/vscode-js-debug/blob/main/OPTIONS.md). js-debug
    -- picks the debuggee's console via `console`, not runInTerminal.
    launch_schema = {
        type                     = { default = "pwa-node", fixed = true },
        program                  = S.program,
        args                     = S.args,
        runtimeExecutable        = { type = "string", desc = "runtime to launch (e.g. node, npm)", default = "node" },
        runtimeArgs              = { type = "list", desc = "arguments passed to the runtime executable" },
        runtimeVersion           = { type = "string", desc = "node version to use (requires nvm/nvs)" },
        cwd                      = S.cwd,
        env                      = S.env,
        envFile                  = { type = "string", kind = "file", desc = "file with environment variable definitions" },
        console                  = {
            type = "string",
            kind = "enum",
            default = "internalConsole",
            enum = { "internalConsole", "integratedTerminal", "externalTerminal" },
            desc = "where to launch the target"
        },
        stopOnEntry              = { type = "boolean", desc = "stop at entry" },
        skipFiles                = { type = "list", desc = "glob patterns to skip while stepping" },
        sourceMaps               = { type = "boolean", desc = "use JavaScript source maps (default true)" },
        outFiles                 = { type = "list", desc = "glob patterns locating generated JS" },
        smartStep                = { type = "boolean", desc = "automatically step over un-source-mapped lines" },
        autoAttachChildProcesses = { type = "boolean", desc = "attach to child processes automatically" },
    },
    attach_schema = {
        type             = { default = "pwa-node", fixed = true },
        port             = { type = "integer", kind = "port", role = "port", desc = "inspector port", default = 9229 },
        address          = { type = "string", kind = "host", role = "host", desc = "inspector host", default = "localhost" },
        processId        = { type = "integer", role = "pid", desc = "process id to attach to" },
        continueOnAttach = { type = "boolean", desc = "continue the program if it is paused when attached" },
        restart          = { type = "boolean", desc = "reconnect if the connection is lost" },
        cwd              = S.cwd,
        localRoot        = { type = "string", kind = "dir", desc = "local directory containing the program" },
        remoteRoot       = { type = "string", desc = "remote directory containing the program" },
        skipFiles        = { type = "list", desc = "glob patterns to skip while stepping" },
        sourceMaps       = { type = "boolean", desc = "use JavaScript source maps (default true)" },
        outFiles         = { type = "list", desc = "glob patterns locating generated JS" },
        timeout          = { type = "integer", desc = "retry connecting for this many milliseconds" },
    },
}
