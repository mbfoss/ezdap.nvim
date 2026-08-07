---@brief DAP adapter registry.
---
---The module is a plain table: each key is an adapter name, each value is an
---AdapterDef — native DAP process/connection config (command, host/port,
---setup/teardown, …) plus a `profiles` table of named `ezdap.Profile`
---launch/attach descriptions. Profiles are what `:Debug new_run_file`/`:Debug run`
---read (via `ezdap.schema`) to scaffold a run file / assemble a
---native request body; the DAP core never touches them.
---
---The plugin ships only the generic `remote` adapter. Every other adapter is
---user-supplied: drop one file per adapter under `lua/ezdap-adapters/` on the
---runtimepath (e.g. `~/.config/nvim/lua/ezdap-adapters/debugpy.lua`), each returning
---one AdapterDef; this module globs and assembles them into the `name -> AdapterDef`
---table, keyed by filename. Users can also add or override adapters directly:
---  local adapters = require("ezdap.adapters")
---  adapters.myAdapter = { command = "..." }

-- Type annotations

---Context passed to `config.setup()` so the adapter can report progress and
---register terminal buffers with the task runner.
---
---`profile` names the profile the run was resolved from, which the config itself
---does not record — it is how a `setup` gates one profile rather than the whole
---adapter (e.g. a feature only a newer binary supports). A raw task (a run file's
---`configuration`, or `runner.run` called directly) names no profile, so a `setup`
---must treat nil as "not one of mine" and let the run proceed.
---@class ezdap.AdapterSetupCtx
---@field add_bufnr fun(bufnr: integer, opts?: ezdap.AddBufOpts)
---@field report    fun(message: string)
---@field profile?  string

---What an input *is* — the Lua type of the value `build` receives.
---@alias ezdap.InputType
---| "string"   # the default
---| "boolean"
---| "integer"
---| "number"
---| "table"    # always needs a `format` to say how the string becomes one

---Which of the declared formats an input takes — the whole vocabulary lives in
---[inputs.lua](../inputs.lua), one row per name, and each row states every way that
---format is read: parsed from a command line, described as JSON Schema for a typed
---file, seeded into a scaffolded document, completed on a command line. Omit the
---format and the string form is read by `type` alone: verbatim for a string,
---`tonumber` for a number/integer, true/1/yes or false/0/no for a boolean.
---
---A format never changes the declared `type` — it only says how to get there, and
---which values are legal on the way. The arrows below are that trip: what you write
---→ what `build` receives.
---@alias ezdap.InputFormat
---| "file"        # → string: a path, expanded
---| "dir"         # → string: a path, expanded (a working directory too)
---| "command"     # → string: a command line, verbatim (each token completed as a path)
---| "port"        # → integer: range-checked (0-65535)
---| "map"         # → table: "A=1,B=2" → { A = "1", B = "2" }
---| "list"        # → table: "a,b" → { "a", "b" }

---One declared input of a profile — a `name=value` argument to `:Debug run`, a
---`parameters` key in an easytasks tasks file. `type` is what `build` receives;
---`format` says which authored forms reach it (and drives path-aware value
---completion). Omit both for an input taken verbatim as a string. An input with
---`required = true` must be supplied — leaving it unset is a resolve error; any
---other input simply arrives at `build` as nil, which a `build` is free to answer
---some other way than by omitting the field (an attach profile asks the user
---to pick a process for an unset `pid`, which is why no adapter marks that input
---`required`).
---`choices` are the values an input is normally written with, when the adapter
---names them itself — a `console`, a mode, a backend. They are offered by
---completion and by a typed file's schema (as `examples`), never enforced: a value
---outside them reaches `build` unhindered, in either authoring form.
---@class ezdap.Input
---@field type?        ezdap.InputType    default `string`
---@field format?      ezdap.InputFormat  default: read by `type` alone
---@field choices?     string[]  the values this input takes, when they're a fixed set
---@field required?    boolean  unset is an error (default false)
---@field description? string   a few words on what the input means

---A named profile for one adapter — what `resolve_task` turns into a runnable
---task, and what `new_run_file` scaffolds.
---
---`inputs` declares what the profile accepts (name → `ezdap.Input`), and
---`build` turns supplied values into a runnable request. Both `:Debug run` and a
---scaffolded run file resolve the same way — through `resolve_task`/`build` — so a
---profile is described in exactly one place: its `inputs`. `new_run_file`
---seeds a run file's `inputs` from those declarations (each input's `seed`, described
---by its `description`); a run file may still add a raw `parameters` overlay by hand
---for fields the inputs don't expose.
---
---`build(params, connect, inputs)` assembles everything a run needs, in place: the
---native request body in `params`, and — for adapters that connect over a
---task-level TCP endpoint (an `AdapterDef` `host`/`port`, e.g.
---`remote`/`java-debug-server`) — that endpoint in `connect`. Both start empty;
---leaving `connect` untouched keeps the adapter def's own host/port in force. An
---unset input is nil, and Lua drops nil-valued keys, so `params.cwd = inputs.cwd`
---omits `cwd` entirely when it wasn't supplied — assign unconditionally and optional
---fields take care of themselves. Identity fields the adapter pins (`type`/`name`)
---and fixed defaults are assigned here too, as plain literals. `inputs` arrives
---already read into each input's declared `type`, whichever form the caller authored
---it in.
---
---Omitting the field is only the *default* answer to an unset input; `build` is
---where a profile decides otherwise, because it alone knows what the request
---means. An attach body is nothing without a process, so every attach `build`
---resolves an unset `pid` by asking the user to pick one (`shared.resolve_pid`) —
---the schema layer just reads a pid as the integer it is. Such a `build` yields;
---`resolve_task` runs it on a coroutine for exactly that reason and delivers the task
---once it returns. A `build` that cannot go on returns an error string (a cancelled
---picker), which aborts the run.
---
---A `build` must always resume — return a value or an error string — so that a
---caller waiting on it hears back. A caller that gives up first cancels its resolve
---and stops listening, so a `build` parked forever on an unanswered picker strands
---nothing but itself.
---@class ezdap.Profile
---@field description  string
---@field request      "launch"|"attach"
---@field inputs?      table<string, ezdap.Input>  the profile's declared inputs
---@field build?       fun(params: table, connect: table, inputs: table<string, any>): string?  assemble body + connection in place; return an error string to abort

---A static adapter definition — the launch/attach description for one adapter.
---Entries of this module are values of this type. It is NOT the per-run config
---the DAP layer consumes: the task runner resolves an `AdapterDef` + a task into
---an `ezdap.dap.Config` (see [dap/client.lua](dap/client.lua)). No
---`request_args` here — that is a per-run value carried by the resolved config.
---`setup`/`teardown` receive that resolved config (setup may mutate host/port).
---`profiles` are consumed only by `ezdap.schema` (for
---new_run_file/run), never by the DAP core.
---@class ezdap.AdapterDef
---@field command?               string|string[]
---@field cwd?                   string
---@field env?                   table<string,string>
---@field host?                  string
---@field port?                  integer
---@field type?                  string   DAP adapterID override (defaults to the adapter name)
---@field defer_launch_attach?   boolean
---@field profiles?               table<string, ezdap.Profile>
---@field setup?                 fun(config: ezdap.dap.Config, ctx: ezdap.AdapterSetupCtx, callback: fun(err?: string, state?: any))
---@field teardown?              fun(config: ezdap.dap.Config, ctx: any)

-- The one shipped adapter: generic TCP attach — connect to a DAP server already
-- listening on host:port. host/port live at the task level (they set the connection),
-- so the attach body itself stays minimal.
---@type ezdap.AdapterDef
local remote = {
    host     = "127.0.0.1",
    port     = 0,
    profiles = {
        connect = {
            description = "attach to a DAP server listening on host:port",
            request     = "attach",
            inputs = {
                host = {
                    type = "string", description = "DAP server host",
                    -- Loopback in each family, then `::` for any interface.
                    choices = { "localhost", "127.0.0.1", "::1", "::" },
                },
                port = { type = "integer", format = "port", description = "DAP server port" },
            },
            build = function(_, connect, inputs)
                connect.host = inputs.host
                connect.port = inputs.port
            end,
        },
    },
}

-- The registry: the shipped `remote` adapter, plus every user adapter found under
-- `lua/ezdap-adapters/` on the runtimepath. Each user file returns one AdapterDef and
-- is keyed by its filename stem; a file named `remote.lua` overrides the shipped one.

---@type table<string, ezdap.AdapterDef>
local M = {
    remote = remote,
}

-- Load each `lua/ezdap-adapters/*.lua` on the runtimepath. `init.lua` is skipped —
-- it's a conventional module name, never a single adapter. A file that errors is
-- reported and skipped so one broken adapter never breaks the rest of the registry.
for _, path in ipairs(vim.api.nvim_get_runtime_file("lua/ezdap-adapters/*.lua", true)) do
    local name = vim.fn.fnamemodify(path, ":t:r")
    if name ~= "init" then
        local ok, def = pcall(require, "ezdap-adapters." .. name)
        if ok then
            M[name] = def
        else
            vim.notify(("[ezdap] failed to load adapter '%s': %s"):format(name, def), vim.log.levels.ERROR)
        end
    end
end

return M
