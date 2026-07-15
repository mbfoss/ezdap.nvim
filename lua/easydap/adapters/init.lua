---@brief Built-in DAP adapter definitions.
---
---The module is a plain table: each key is an adapter name, each value is an
---AdapterDef — native DAP process/connection config (command, host/port,
---setup/teardown, request, …) plus a `configurations` table of named `easydap.Configuration`
---launch/attach templates. Configurations are what `:Debug new_run_file`/`quick_run`
---read (via `easydap.schema`) to scaffold a run file / assemble a
---native request body; the DAP core never touches them.
---
---Each built-in adapter lives in its own file under `easydap/adapters/`, returning
---one AdapterDef; this module assembles them into the `name -> AdapterDef` table.
---Users can add adapters or override existing ones directly:
---  local adapters = require("easydap.adapters")
---  adapters.myAdapter = { command = "...", request = "launch" }

-- ── Type annotations ──────────────────────────────────────────────────────

---Context passed to `config.setup()` so the adapter can report progress and
---register terminal buffers with the task runner.
---@class easydap.AdapterSetupCtx
---@field add_bufnr fun(bufnr: integer, opts?: easydap.AddBufOpts)
---@field report    fun(message: string)

---What an input *is* — the Lua type of the value `build` receives.
---@alias easydap.InputType
---| "string"   # the default
---| "boolean"
---| "integer"
---| "number"
---| "table"    # always needs a `format` to say how the string becomes one

---How an input's raw `quick_run` string is read into a value of its `type`
---(`easydap.schema.coerce` does the reading). Omit it and the string is read by
---`type` alone: verbatim for a string, `tonumber` for a number/integer, true/1/yes
---or false/0/no for a boolean. A format never changes the declared `type` — it only
---says how to get there, and which values are legal on the way.
---@alias easydap.InputFormat
---| "file"        # → string: a path, expanded
---| "dir"         # → string: a path, expanded
---| "cwd"         # → string: a path, expanded and made absolute
---| "host"        # → string: taken verbatim
---| "port"        # → integer: range-checked (0-65535)
---| "env"         # → table: "A=1,B=2" → { A = "1", B = "2" }
---| "list"        # → table: "a,b" → { "a", "b" }
---| "shell_args"  # → table: a shell-quoted command line → a list of arguments

---One declared input of a configuration — the `name=value` arguments `quick_run`
---accepts. `type` is what `build` receives; `format` says how the raw CLI string is
---read into it, and drives path-aware value completion. Omit both for an input taken
---verbatim as a string. An input with `required = true` must be supplied — leaving it
---unset is a `quick_run` error; any other input simply arrives at `build` as nil.
---@class easydap.Input
---@field type?        easydap.InputType    default `string`
---@field format?      easydap.InputFormat  default: read by `type` alone
---@field required?    boolean  unset is an error (default false)
---@field description? string   a few words on what the input means

---A named `quick_run`/`new_run_file` configuration for one adapter.
---
---`inputs` declares what the configuration accepts (name → `easydap.Input`); the
---two commands then read it along separate paths that never meet:
---
---  * `build(params, connect, inputs)` assembles everything `quick_run` needs, in
---    place: the native request body in `params`, and — for adapters that connect
---    over a task-level TCP endpoint (an `AdapterDef` `host`/`port`, e.g.
---    `remote`/`java-debug-server`) — that endpoint in `connect`. Both start empty;
---    leaving `connect` untouched keeps the adapter def's own host/port in force.
---    An unset input is nil, and Lua drops nil-valued keys, so
---    `params.cwd = inputs.cwd` omits `cwd` entirely when it wasn't supplied —
---    assign unconditionally and optional fields take care of themselves. Identity
---    fields the adapter pins (`type`/`name`) and fixed defaults are assigned here
---    too, as plain literals.
---  * `template` is what `new_run_file` scaffolds: Lua **source text** for the body
---    of the generated run file's `parameters` table, spliced in as written (only
---    re-indented). Because it is source rather than data it carries its own
---    comments, key order, and computed values as expressions the *run file*
---    evaluates when loaded (`cwd = vim.fn.getcwd()`), which keeps the generated
---    file portable instead of baking in one machine's paths. It never reaches an
---    adapter through `build` — a run file's `parameters` is sent verbatim — so
---    seed it with realistic values a reader can edit, not blanks.
---
---Keeping the field list in both is deliberate: they answer different questions
---(what to send vs. what to show someone starting a run file), and drift between
---them costs scaffold quality, never `quick_run` correctness. The template is
---unvalidated text — a typo in it surfaces only when the run file is scaffolded.
---@class easydap.Configuration
---@field description  string
---@field request      "launch"|"attach"
---@field inputs?      table<string, easydap.Input>  the configuration's declared inputs
---@field build?       fun(params: table, connect: table, inputs: table<string, any>)  assemble body + connection in place
---@field template?    string   Lua source for the scaffolded run file's `parameters` body

---A static adapter definition — the launch/attach template for one adapter.
---Entries of this module are values of this type. It is NOT the per-run config
---the DAP layer consumes: the task runner resolves an `AdapterDef` + a task into
---an `easydap.dap.Config` (see [dap/client.lua](dap/client.lua)). No
---`request_args` here — that is a per-run value carried by the resolved config.
---`setup`/`teardown` receive that resolved config (setup may mutate host/port).
---`configurations` are consumed only by `easydap.schema` (for
---new_run_file/quick_run), never by the DAP core.
---@class easydap.AdapterDef
---@field command?               string|string[]
---@field cwd?                   string
---@field env?                   table<string,string>
---@field host?                  string
---@field port?                  integer
---@field type?                  string   DAP adapterID override (defaults to the adapter name)
---@field defer_launch_attach?   boolean
---@field request?               string
---@field configurations?               table<string, easydap.Configuration>
---@field setup?                 fun(config: easydap.dap.Config, ctx: easydap.AdapterSetupCtx, callback: fun(err?: string, state?: any))
---@field teardown?              fun(config: easydap.dap.Config, ctx: any)

-- ── Built-in adapters ──────────────────────────────────────────────────────
-- One file per adapter; keys with hyphens are loaded from the matching filename.

---@type table<string, easydap.AdapterDef>
local M = {
    debugpy               = require("easydap.adapters.debugpy"),
    codelldb              = require("easydap.adapters.codelldb"),
    gdb                   = require("easydap.adapters.gdb"),
    netcoredbg            = require("easydap.adapters.netcoredbg"),
    remote                = require("easydap.adapters.remote"),
    ["java-debug-server"] = require("easydap.adapters.java-debug-server"),
    lldb                  = require("easydap.adapters.lldb"),
    delve                 = require("easydap.adapters.delve"),
    ["js-debug"]          = require("easydap.adapters.js-debug"),
    ["bash-debug-adapter"] = require("easydap.adapters.bash-debug-adapter"),
    ["php-debug-adapter"] = require("easydap.adapters.php-debug-adapter"),
    ["local-lua-debugger"] = require("easydap.adapters.local-lua-debugger"),
}

return M
