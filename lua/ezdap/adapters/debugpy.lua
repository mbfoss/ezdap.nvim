-- https://github.com/microsoft/debugpy/wiki/Debug-configuration-settings

local ui = require("ezdap.util.ui_util")
local shared = require("ezdap.shared")

---@return integer
local function _free_port()
    local tcp = assert(vim.uv.new_tcp(), "uv.new_tcp failed")
    tcp:bind("127.0.0.1", 0)
    local addr = assert(tcp:getsockname(), "getsockname failed")
    tcp:close()
    return addr.port
end


---Spawn the local debugpy adapter on a free port and point the connection at it.
---@param config   ezdap.dap.Config
---@param ctx      ezdap.AdapterSetupCtx
---@param callback fun(err?: string, state?: any)
local function _debugpy_setup(config, ctx, callback)
    local term = require("ezdap.tk.term")
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
            bufname = ui.unique_buf_name("ezdap://" .. (config.name or config.adapter or "debug") .. "_debugpy-adapter"),
            cwd     = config.cwd or vim.fn.getcwd(),
            on_exit = function() done("debugpy adapter exited unexpectedly") end,
        }
    )
    if not handle then return callback("failed to start debugpy adapter") end
    ctx.add_bufnr(handle.bufnr, { label = "debugpy", priority = -2 })
    config.port = port
    vim.defer_fn(function() done(nil, { handle = handle }) end, 500)
end

---Attributes debugpy accepts on both a launch and an attach. Declared once and
---merged into every profile, so a field is described in one place.
---@type table<string, ezdap.Input>
local _common_inputs = {
    just_my_code      = { type = "boolean", description = "debug only user-written code (default false)" },
    show_return_value = { type = "boolean", description = "show function return values while stepping (default true)" },
    redirect_output   = { type = "boolean", description = "route the debuggee's output to the debug console" },
    sub_process       = { type = "boolean", description = "debug child processes too" },
    path_mappings     = { type = "table", format = "map", description = "local=remote source path mappings" },
    django            = { type = "boolean", description = "enable Django template debugging" },
    jinja             = { type = "boolean", description = "enable Jinja2 template debugging" },
    pyramid           = { type = "boolean", description = "enable Pyramid application debugging" },
    gevent            = { type = "boolean", description = "support gevent monkey-patched code" },
    sudo              = { type = "boolean", description = "run the debuggee with elevated permissions" },
    log_to_file       = { type = "boolean", description = "log debugger events to a file" },
}

---A profile's own inputs on top of the common set.
---@param extra table<string, ezdap.Input>
---@return table<string, ezdap.Input>
local function _inputs(extra)
    return vim.tbl_extend("error", vim.deepcopy(_common_inputs), extra)
end

---Assign the common attributes, plus the `type` every debugpy body carries.
---`justMyCode`/`showReturnValue` keep ezdap's defaults when left unset.
---@param params table
---@param inputs table<string, any>
local function _common_build(params, inputs)
    params.type            = "python"
    params.justMyCode      = inputs.just_my_code == nil and false or inputs.just_my_code
    params.showReturnValue = inputs.show_return_value == nil and true or inputs.show_return_value
    params.redirectOutput  = inputs.redirect_output
    params.subProcess      = inputs.sub_process
    params.django          = inputs.django
    params.jinja           = inputs.jinja
    params.pyramid         = inputs.pyramid
    params.gevent          = inputs.gevent
    params.sudo            = inputs.sudo
    params.logToFile       = inputs.log_to_file
    if inputs.path_mappings then
        local mappings = {}
        for local_root, remote_root in pairs(inputs.path_mappings) do
            mappings[#mappings + 1] = { localRoot = local_root, remoteRoot = remote_root }
        end
        params.pathMappings = mappings
    end
end

---Launch-only attributes shared by the `program`, `module` and `code` profiles.
---@type table<string, ezdap.Input>
local _launch_inputs = {
    cwd           = { type = "string", format = "cwd", description = "working directory" },
    env           = { type = "table", format = "map", description = "environment variables" },
    python        = { type = "table", format = "list", description = "python executable and interpreter arguments" },
    console       = { type = "string", description = "where the debuggee's stdio goes: internalConsole|integratedTerminal|externalTerminal" },
    stop_on_entry = { type = "boolean", description = "break at the first line of user code" },
}

---@param params table
---@param inputs table<string, any>
local function _launch_build(params, inputs)
    _common_build(params, inputs)
    params.cwd         = inputs.cwd
    params.env         = inputs.env
    params.python      = inputs.python
    params.console     = inputs.console
    params.stopOnEntry = inputs.stop_on_entry
end

-- Attach to a remote Python process: the `connect`/`listen` groups target the
-- REMOTE process and go in the body, not the task-level connection (the local
-- adapter's port is chosen by `_debugpy_setup`, which also spawns it).
---@type ezdap.AdapterDef
return {
    command  = "python3",
    setup    = _debugpy_setup,
    teardown = function(_, ctx) if ctx then ctx.handle.stop() end end,
    profiles       = {
        -- One `command` input carries the whole command line; `build` splits it into
        -- `program` (the first word) and `args` (the rest).
        launch_program = {
            description = "debug a Python file",
            request = "launch",
            inputs = _inputs(vim.tbl_extend("error", vim.deepcopy(_launch_inputs), {
                command = { type = "string", required = true, description = "command line to debug" },
            })),
            build = function(params, _, inputs)
                _launch_build(params, inputs)
                params.program, params.args = shared.split_command(inputs.command)
            end,
        },
        launch_module = {
            description = "debug a module, as `python -m`",
            request = "launch",
            inputs = _inputs(vim.tbl_extend("error", vim.deepcopy(_launch_inputs), {
                module = { type = "string", required = true, description = "module name to debug" },
                args   = { type = "table", format = "list", description = "command line arguments passed to the module" },
            })),
            build = function(params, _, inputs)
                _launch_build(params, inputs)
                params.module = inputs.module
                params.args   = inputs.args
            end,
        },
        launch_code = {
            description = "debug a snippet of Python source, as `python -c`",
            request = "launch",
            inputs = _inputs(vim.tbl_extend("error", vim.deepcopy(_launch_inputs), {
                code = { type = "string", required = true, description = "Python code to debug" },
                args = { type = "table", format = "list", description = "command line arguments passed to the code" },
            })),
            build = function(params, _, inputs)
                _launch_build(params, inputs)
                params.code = inputs.code
                params.args = inputs.args
            end,
        },
        attach_process = {
            description = "attach to a running process by pid",
            request = "attach",
            inputs = _inputs {
                pid = { type = "integer", description = "process id to attach to" },
            },
            build = function(params, _, inputs)
                local pid, err = shared.resolve_pid(inputs.pid)
                if not pid then return err end
                _common_build(params, inputs)
                params.processId = pid
            end,
        },
        remote = {
            description = "attach to a remote debugpy process over host/port",
            request = "attach",
            inputs = _inputs {
                host = { type = "string", format = "host", required = true, description = "remote debugpy host" },
                port = { type = "integer", format = "port", required = true, description = "remote debugpy port" },
            },
            build = function(params, _, inputs)
                _common_build(params, inputs)
                params.connect = { host = inputs.host, port = inputs.port }
            end,
        },
        -- The inverse of `remote`: the adapter listens and the debuggee, started
        -- with `debugpy --connect`, dials in.
        listen = {
            description = "wait for a debugpy process to connect back on host/port",
            request = "attach",
            inputs = _inputs {
                host = { type = "string", format = "host", description = "host to listen on" },
                port = { type = "integer", format = "port", required = true, description = "port to listen on" },
            },
            build = function(params, _, inputs)
                _common_build(params, inputs)
                params.listen = { host = inputs.host or "127.0.0.1", port = inputs.port }
            end,
        },
    },
}
