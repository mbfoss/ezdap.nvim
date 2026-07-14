local ui = require("easydap.util.ui_util")

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
            bufname = ui.unique_buf_name("easydap://" .. (config.name or config.adapter or "debug") .. "/js-debug-server"),
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
    configurations = {
        launch = {
            request = "launch",
            parameters = {
                type    = "pwa-node",
                program = "{target:file}",
                args    = "{args:shell_args}",
                cwd     = "{cwd:cwd}",
                env     = "{env:env}",
            },
        },
        attach = {
            request = "attach",
            parameters = {
                type      = "pwa-node",
                processId = "{pid:integer}",
            },
        },
        remote = {
            request = "attach",
            parameters = {
                type    = "pwa-node",
                address = "{host:host}",
                port    = "{port:port}",
            },
        },
    },
}
