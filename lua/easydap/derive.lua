---@brief Optional convenience: translate a generic "task" table into native DAP request_args.
---
---This module is NOT part of the DAP core. `easydap.adapters` and
---`easydap.dap.Config` stay pure native DAP — they know only the wire protocol.
---`derive` is the higher-level, opt-in layer that turns a portable task
---description (command/cwd/env/process_id/…) into an adapter-native launch or
---attach body. Callers that already speak native DAP (`request_args`) never
---touch this module.
---
---Usage:
---  local derive = require("easydap.derive")
---  -- one adapter, one request:
---  local args = derive.args("codelldb", "launch", { command = "./a.out", cwd = "/tmp" })
---  -- or resolve a whole generic task into a native one (request_args populated):
---  local native = derive.resolve(task)
---
---Override or add translations directly on the registry, keyed by adapter name:
---  derive.adapters.codelldb.launch = function(task) … end
---  derive.adapters.myAdapter = { launch = function(task) … end }

local str_util = require("easydap.util.str_util")

local M = {}

-- ── Generic task contract ──────────────────────────────────────────────────

---The portable fields the built-in translations understand. A caller supplies
---whichever apply; each `launch`/`attach` fn reads the ones it needs and emits a
---native DAP body. `request_args` (native keys) is merged on top by `resolve`.
---@class easydap.derive.Task
---@field adapter          string                  name of an entry in `easydap.adapters`
---@field request?         "launch"|"attach"
---@field command?         string|string[]         program to debug ([program, arg1, …] shorthand allowed)
---@field cwd?             string
---@field env?             table<string,string>
---@field clear_env?       boolean                 pass `env` verbatim without merging the process environment
---@field process_id?      integer                 attach only — target process id (PID) to attach to
---@field host?            string                  attach only
---@field port?            integer                 attach only (required for the `remote` adapter)
---@field run_in_terminal? boolean
---@field stop_on_entry?   boolean
---@field request_args?    table                   raw DAP launch/attach body; deep-merged over the derived args and wins on conflicts. Uses the adapter's NATIVE DAP keys (e.g. `stopAtEntry` for netcoredbg, `pid` vs `processId`), which may not line up with the generic fields above — a mismatched key is added, not a substitute for the generic one.

---A per-adapter pair of translations.
---@class easydap.derive.Entry
---@field launch? fun(task: easydap.derive.Task): table
---@field attach? fun(task: easydap.derive.Task): table

-- ── Shared helpers ─────────────────────────────────────────────────────────

---Split task.command (string or string[]) into the program path and any extra args.
---@param task easydap.derive.Task
---@return string?  program
---@return string[]? args
local function _split_command(task)
    if not task.command then return end
    local parts = type(task.command) == "table"
        and task.command
        or str_util.split_shell_args(task.command)
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

-- ── Built-in translations, keyed by adapter name ────────────────────────────

---@type table<string, easydap.derive.Entry>
M.adapters = {
    debugpy = {
        launch = function(task)
            local program, extra_args = _split_command(task)
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

        attach = function(task)
            local args = { processId = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    -- task.command maps to `module` (the Python module name, not a file path)
    ["debugpy-module"] = {
        launch = function(task)
            local module_name, extra_args = _split_command(task)
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

        attach = function(task)
            local args = { processId = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    -- Attach to a remote Python process running debugpy.
    -- task.host / task.port point to the REMOTE process; the local debugpy adapter
    -- is spawned by the adapter's setup and connects to it via the `connect` args.
    ["debugpy-remote"] = {
        attach = function(task)
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

    codelldb = {
        launch = function(task)
            local program, extra_args = _split_command(task)
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

        attach = function(task)
            local args = { type = "lldb", pid = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    gdb = {
        launch = function(task)
            local program, extra_args = _split_command(task)
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

        attach = function(task)
            local args = { pid = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    -- netcoredbg uses stopAtEntry instead of the standard stopOnEntry
    netcoredbg = {
        launch = function(task)
            local program, extra_args = _split_command(task)
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

        attach = function(task)
            local args = { processId = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopAtEntry = task.stop_on_entry end
            return args
        end,
    },

    -- Java — expects an external debug server (e.g. started by nvim-jdtls).
    ["java-debug-server"] = {
        attach = function(task)
            local args = {}
            if task.host ~= nil then args.host = task.host end
            if task.port ~= nil then args.port = task.port end
            return args
        end,
    },

    lldb = {
        launch = function(task)
            local program, extra_args = _split_command(task)
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

        attach = function(task)
            local args = { type = "lldb", pid = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    -- Go — dlv dap communicates over stdio; no TCP setup required.
    -- program defaults to the current directory (debug the package at cwd).
    delve = {
        launch = function(task)
            local program, extra_args
            if task.command ~= nil then
                program, extra_args = _split_command(task)
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

        attach = function(task)
            local args = { mode = "local", processId = task.process_id }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    ["js-debug"] = {
        launch = function(task)
            local program, extra_args = _split_command(task)
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

        attach = function(task)
            local args = { type = "pwa-node", port = 9229 }
            if task.cwd ~= nil then args.cwd = task.cwd end
            if task.stop_on_entry ~= nil then args.stopOnEntry = task.stop_on_entry end
            return args
        end,
    },

    -- bash-debug-adapter has adapter-specific path fields; run_in_terminal is excluded
    -- because the adapter manages its own terminal kind via terminalKind.
    ["bash-debug-adapter"] = {
        launch = function(task)
            local program, extra_args = _split_command(task)
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

    -- PHP — listens for an Xdebug connection; task fields do not apply.
    ["php-debug-adapter"] = {
        launch = function(_)
            return { type = "php", name = "Listen for Xdebug", cwd = vim.fn.getcwd(), port = 9003 }
        end,
    },

    -- Lua — task.command maps to program.file (first token); remaining args are not
    -- forwarded because the js-based adapter embeds them inside the program table.
    ["local-lua-debugger"] = {
        launch = function(task)
            local file = _split_command(task)
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

---Build a native DAP request body for a single adapter/request from a generic task.
---Returns nil when the adapter has no translation for that request (the caller
---should fall back to `task.request_args` alone).
---@param adapter string
---@param request "launch"|"attach"
---@param task easydap.derive.Task
---@return table? request_args
---@return string? err
function M.args(adapter, request, task)
    local entry = M.adapters[adapter]
    local fn    = entry and entry[request]
    if not fn then return nil end
    local ok, result = pcall(fn, task)
    if not ok then return nil, tostring(result) end
    return result
end

---Resolve a generic task into a native one, in place: derive a base body from
---the generic fields, then deep-merge the task's own `request_args` on top
---(native keys win). Populates `request` and `request_args` on `task` and
---returns it (or `nil, err` if a translation raised, leaving `task` untouched).
---The result is native DAP, ready for `easydap.task.start`; other fields (host,
---port, name, …) are left as-is. Pass a copy first if you need the original
---generic task preserved.
---@param task easydap.derive.Task
---@return easydap.derive.Task? native  the same table, now native (nil on error)
---@return string? err
function M.resolve(task)
    local adapters = require("easydap.adapters")
    local base     = adapters[task.adapter]
    local request  = task.request or (base and base.request) or "launch"

    local derived, err = M.args(task.adapter, request, task)
    if err then return nil, err end

    task.request      = request
    task.request_args = vim.tbl_deep_extend("force", derived or {}, task.request_args or {})
    return task
end

return M
