---@brief Optional, standalone convenience for building a task's `parameters`.
---
---easydap does NOT use this module — nothing in the runtime requires it. It is a
---self-contained helper you can call yourself to turn a portable task
---description (target/cwd/env/process_id/…) into an adapter-native launch or
---attach body, then hand that to easydap as the task's `parameters` field. The
---DAP core, `easydap.adapters`, and `easydap.dap.Config` stay pure native DAP.
---
---The registry is declarative: each adapter maps `launch`/`attach` to a spec that
---pairs the native-body `build` function with the `fields` it reads. Exposing the
---accepted fields lets callers (e.g. the `:Debug quick_run` completion) enumerate
---an adapter's options without running the builder.
---
---Usage — fill `parameters` from portable fields when defining a task:
---  local derive = require("easydap.derive")
---  return {
---    name       = "debug app",
---    adapter    = "codelldb",
---    request    = "launch",
---    parameters = derive.args("codelldb", "launch", { target = "./a.out", cwd = "/tmp" }),
---  }
---
---Override or add adapters directly on the registry, keyed by adapter name:
---  derive.adapters.codelldb.launch.build = function(task) … end
---  derive.adapters.myAdapter = {
---    launch = { fields = { "target", "cwd" }, build = function(task) … end },
---  }

local str_util = require("easydap.util.str_util")

local M = {}

-- ── Portable task contract ─────────────────────────────────────────────────

---The portable fields the built-in translations understand. A caller supplies
---whichever apply; each `build` fn reads the ones it needs and emits a native DAP
---body (the value you assign to a task's `parameters`).
---@class easydap.derive.Task
---@field target?          string|string[]         program to debug ([program, arg1, …] shorthand allowed)
---@field cwd?             string
---@field env?             table<string,string>
---@field clear_env?       boolean                 pass `env` verbatim without merging the process environment
---@field process_id?      integer                 attach only — target process id (PID) to attach to
---@field host?            string                  attach only — remote host
---@field port?            integer                 attach only — remote port
---@field run_in_terminal? boolean
---@field stop_on_entry?   boolean

---A native-body builder paired with the portable fields it reads.
---@class easydap.derive.Spec
---@field fields string[]                          portable field keys this request accepts
---@field build  fun(task: easydap.derive.Task): table

---A per-adapter pair of translations.
---@class easydap.derive.Entry
---@field launch? easydap.derive.Spec
---@field attach? easydap.derive.Spec

---Metadata for one portable field: how to coerce a CLI string into it and a
---one-line description (used for parsing and completion).
---@class easydap.derive.FieldSpec
---@field type "string"|"path"|"boolean"|"integer"|"table"
---@field desc string

---@type table<string, easydap.derive.FieldSpec>
M.field_specs = {
    target          = { type = "path",    desc = "program to debug (+ args)" },
    cwd             = { type = "path",    desc = "working directory" },
    env             = { type = "table",   desc = "env vars: VAR=VAL,VAR2=VAL2" },
    clear_env       = { type = "boolean", desc = "pass env verbatim (no merge)" },
    process_id      = { type = "integer", desc = "PID to attach to" },
    host            = { type = "string",  desc = "remote host" },
    port            = { type = "integer", desc = "remote port" },
    run_in_terminal = { type = "boolean", desc = "run in integrated terminal" },
    stop_on_entry   = { type = "boolean", desc = "stop at entry" },
}

-- ── Shared helpers ─────────────────────────────────────────────────────────

---Split task.target (string or string[]) into the program path and any extra args.
---@param task easydap.derive.Task
---@return string?  program
---@return string[]? args
local function _split_target(task)
    if not task.target then return end
    local parts = type(task.target) == "table"
        and task.target
        or str_util.split_shell_args(task.target --[[@as string]])
    local args = {}
    for i = 2, #parts do args[#args + 1] = parts[i] end
    return parts[1], args
end

---Resolve task.env, merging with the process environment unless task.clear_env is set.
---Returns nil when neither task.env nor task.clear_env was provided, so adapters
---don't stamp the full process environment into request_args unprompted.
---@param task easydap.derive.Task
---@return table<string,string>|nil
local function _resolve_env(task)
    if task.clear_env then return task.env end
    if task.env == nil then return nil end
    return vim.tbl_extend("force", vim.fn.environ(), task.env)
end

-- Common field sets, reused across the process-launching adapters.
local _LAUNCH_FIELDS = { "target", "cwd", "env", "clear_env", "run_in_terminal", "stop_on_entry" }
local _ATTACH_FIELDS = { "process_id", "cwd", "stop_on_entry" }

-- ── Declarative adapter registry ───────────────────────────────────────────

---@type table<string, easydap.derive.Entry>
M.adapters = {}

M.adapters.debugpy = {
    launch = {
        fields = _LAUNCH_FIELDS,
        build  = function(task)
            local program, extra_args = _split_target(task)
            local args = {
                type            = "python",
                program         = program,
                args            = extra_args,
                justMyCode      = false,
                console         = "integratedTerminal",
                stopOnEntry     = false,
                showReturnValue = true,
            }
            if task.cwd ~= nil then args.cwd = task.cwd end
            local env = _resolve_env(task)
            if env then args.env = env end
            if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    attach = {
        fields = _ATTACH_FIELDS,
        build  = function(task)
            local args = { processId = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },
}

-- task.target maps to `module` (the Python module name, not a file path)
M.adapters["debugpy-module"] = {
    launch = {
        fields = _LAUNCH_FIELDS,
        build  = function(task)
            local module_name, extra_args = _split_target(task)
            local args = {
                type        = "python",
                module      = module_name,
                args        = extra_args,
                justMyCode  = false,
                console     = "integratedTerminal",
                stopOnEntry = false,
            }
            if task.cwd ~= nil then args.cwd = task.cwd end
            local env = _resolve_env(task)
            if env then args.env = env end
            if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    attach = {
        fields = _ATTACH_FIELDS,
        build  = function(task)
            local args = { processId = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },
}

-- Attach to a remote Python process running debugpy.
-- task.host / task.port point to the REMOTE process; the local debugpy adapter
-- is spawned by the adapter's setup and connects to it via the `connect` args.
M.adapters["debugpy-remote"] = {
    attach = {
        fields = { "host", "port" },
        build  = function(task)
            return {
                type       = "python",
                connect    = {
                    host = task.host or "127.0.0.1",
                    port = task.port or 5678,
                },
                justMyCode = false,
            }
        end,
    },
}

M.adapters.codelldb = {
    launch = {
        fields = _LAUNCH_FIELDS,
        build  = function(task)
            local program, extra_args = _split_target(task)
            local args = {
                type        = "lldb",
                program     = program,
                args        = extra_args,
                stopOnEntry = false,
            }
            if task.cwd ~= nil then args.cwd = task.cwd end
            local env = _resolve_env(task)
            if env then args.env = env end
            if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    attach = {
        fields = _ATTACH_FIELDS,
        build  = function(task)
            local args = { type = "lldb", pid = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },
}

M.adapters.gdb = {
    launch = {
        fields = _LAUNCH_FIELDS,
        build  = function(task)
            local program, extra_args = _split_target(task)
            local args = {
                request = "launch",
                program = program,
                args    = extra_args,
            }
            if task.cwd ~= nil then args.cwd = task.cwd end
            local env = _resolve_env(task)
            if env then args.env = env end
            if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    attach = {
        fields = _ATTACH_FIELDS,
        build  = function(task)
            local args = { pid = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },
}

-- netcoredbg uses stopAtEntry instead of the standard stopOnEntry
M.adapters.netcoredbg = {
    launch = {
        fields = _LAUNCH_FIELDS,
        build  = function(task)
            local program, extra_args = _split_target(task)
            local args = {
                program     = program,
                args        = extra_args,
                stopAtEntry = false,
            }
            if task.cwd ~= nil then args.cwd = task.cwd end
            local env = _resolve_env(task)
            if env then args.env = env end
            if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
            if task.stop_on_entry ~= nil then args.stopAtEntry = task.stop_on_entry end
            return args
        end,
    },

    attach = {
        fields = _ATTACH_FIELDS,
        build  = function(task)
            local args = { processId = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopAtEntry = task.stop_on_entry end
            return args
        end,
    },
}

-- Generic TCP attach — connect to a DAP server already listening on host:port.
-- host/port target the connection (carried as the task's host/port); the attach
-- body stays minimal. Adapter-specific extras (e.g. delve's mode="remote") go in a
-- task file's request_args or by overriding this build.
M.adapters.remote = {
    attach = {
        fields = { "host", "port", "stop_on_entry" },
        build  = function(task)
            local args = {}
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },
}

-- Java — expects an external debug server (e.g. started by nvim-jdtls).
M.adapters["java-debug-server"] = {
    attach = {
        fields = { "host", "port" },
        build  = function(task)
            local args = {}
            if task.host ~= nil then args.host = task.host end
            if task.port ~= nil then args.port = task.port end
            return args
        end,
    },
}

M.adapters.lldb = {
    launch = {
        fields = _LAUNCH_FIELDS,
        build  = function(task)
            local program, extra_args = _split_target(task)
            local args = {
                type          = "lldb",
                program       = program,
                args          = extra_args,
                stopOnEntry   = false,
                runInTerminal = true,
            }
            if task.cwd ~= nil then args.cwd = task.cwd end
            local env = _resolve_env(task)
            if env then args.env = env end
            if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    attach = {
        fields = _ATTACH_FIELDS,
        build  = function(task)
            local args = { type = "lldb", pid = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },
}

-- Go — dlv dap communicates over stdio; no TCP setup required.
-- program defaults to the current directory (debug the package at cwd).
M.adapters.delve = {
    launch = {
        fields = _LAUNCH_FIELDS,
        build  = function(task)
            local program, extra_args
            if task.target ~= nil then
                program, extra_args = _split_target(task)
            else
                program    = vim.fn.getcwd()
                extra_args = {}
            end
            local args = {
                mode    = "debug",
                program = program,
                args    = extra_args,
            }
            if task.cwd ~= nil then args.cwd = task.cwd end
            local env = _resolve_env(task)
            if env then args.env = env end
            if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    attach = {
        fields = _ATTACH_FIELDS,
        build  = function(task)
            local args = { mode = "local", processId = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },
}

M.adapters["js-debug"] = {
    launch = {
        fields = _LAUNCH_FIELDS,
        build  = function(task)
            local program, extra_args = _split_target(task)
            local args = {
                type              = "pwa-node",
                program           = program,
                args              = extra_args,
                runtimeExecutable = "node",
            }
            if task.cwd ~= nil then args.cwd = task.cwd end
            local env = _resolve_env(task)
            if env then args.env = env end
            if task.run_in_terminal ~= nil then args.runInTerminal = task.run_in_terminal end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    attach = {
        fields = { "cwd", "stop_on_entry" },
        build  = function(task)
            local args = { type = "pwa-node", port = 9229 }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },
}

-- bash-debug-adapter has adapter-specific path fields; run_in_terminal is excluded
-- because the adapter manages its own terminal kind via terminalKind.
M.adapters["bash-debug-adapter"] = {
    launch = {
        fields = { "target", "cwd", "env", "clear_env", "stop_on_entry" },
        build  = function(task)
            local program, extra_args = _split_target(task)
            local data_dir            = vim.fn.stdpath("data")
            local bashdb_path         = vim.fs.joinpath(data_dir, "mason", "packages", "bash-debug-adapter", "bashdb")
            local args                = {
                type          = "bashdb",
                name          = "Launch Bash Script",
                program       = program,
                args          = extra_args,
                pathBash      = "bash",
                pathBashdb    = vim.fn.filereadable(bashdb_path) == 1 and bashdb_path or "bashdb",
                pathBashdbLib = vim.fs.joinpath(data_dir, "mason", "packages", "bash-debug-adapter"),
                pathCat       = "cat",
                pathMkfifo    = "mkfifo",
                pathPkill     = "pkill",
                terminalKind  = "integrated",
            }
            if task.cwd ~= nil then args.cwd = task.cwd end
            local env = _resolve_env(task)
            if env then args.env = env end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },
}

-- PHP — listens for an Xdebug connection; task fields do not apply.
M.adapters["php-debug-adapter"] = {
    launch = {
        fields = {},
        build  = function(_)
            return { type = "php", name = "Listen for Xdebug", cwd = vim.fn.getcwd(), port = 9003 }
        end,
    },
}

-- Lua — task.target maps to program.file (first token); remaining args are not
-- forwarded because the js-based adapter embeds them inside the program table.
M.adapters["local-lua-debugger"] = {
    launch = {
        fields = { "target" },
        build  = function(task)
            local file = _split_target(task)
            return {
                type    = "lua-local",
                name    = "Debug",
                program = {
                    lua           = vim.fn.exepath("lua"),
                    file          = file,
                    communication = "stdio",
                },
            }
        end,
    },
}

-- ── Public API ─────────────────────────────────────────────────────────────

---Adapter names present in the registry (i.e. those `args` can build a body for),
---sorted.
---@return string[]
function M.adapter_names()
    local names = vim.tbl_keys(M.adapters)
    table.sort(names)
    return names
end

---Which requests (`"launch"`/`"attach"`) the adapter defines a translation for.
---@param adapter string
---@return string[]
function M.requests(adapter)
    local entry = M.adapters[adapter]
    if not entry then return {} end
    local out = {}
    if entry.launch then out[#out + 1] = "launch" end
    if entry.attach then out[#out + 1] = "attach" end
    return out
end

---The portable field keys an adapter's request accepts (for completion). Empty
---when the adapter or the request is unknown.
---@param adapter string
---@param request string  "launch"|"attach"
---@return string[]
function M.fields(adapter, request)
    local entry = M.adapters[adapter]
    local spec  = entry and entry[request]
    return spec and spec.fields or {}
end

---Build an adapter-native launch/attach body from a portable task description.
---@param adapter string
---@param request string  "launch"|"attach"
---@param task    easydap.derive.Task
---@return table? args   native DAP body, or nil on error
---@return string? err
function M.args(adapter, request, task)
    local entry = M.adapters[adapter]
    if not entry then
        return nil, "no derive mapping for adapter: " .. tostring(adapter)
    end
    local spec = entry[request]
    if not spec then
        return nil, ("adapter %s has no %s mapping"):format(adapter, tostring(request))
    end
    return spec.build(task)
end

---Coerce a raw CLI string into the value type declared for `field`.
---@param field string
---@param raw   string
---@return any? value   nil on error
---@return string? err
function M.coerce(field, raw)
    local spec = M.field_specs[field]
    if not spec then
        return nil, "unknown field: " .. tostring(field)
    end
    if spec.type == "boolean" then
        local low = raw:lower()
        if low == "true" or low == "1" or low == "yes" then return true end
        if low == "false" or low == "0" or low == "no" then return false end
        return nil, ("%s expects a boolean (true/false), got %q"):format(field, raw)
    elseif spec.type == "integer" then
        local n = tonumber(raw)
        if not n or n ~= math.floor(n) then
            return nil, ("%s expects an integer, got %q"):format(field, raw)
        end
        return math.floor(n)
    elseif spec.type == "path" then
        return vim.fn.expand(raw)
    elseif spec.type == "table" then
        -- env-style: VAR=VAL,VAR2=VAL2
        local out = {}
        for _, pair in ipairs(vim.split(raw, ",", { plain = true, trimempty = true })) do
            local eq = pair:find("=", 1, true)
            if not eq then
                return nil, ("%s expects VAR=VAL pairs, got %q"):format(field, pair)
            end
            out[pair:sub(1, eq - 1)] = pair:sub(eq + 1)
        end
        return out
    end
    return raw
end

return M
