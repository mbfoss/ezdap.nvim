---@brief Built-in DAP adapter definitions.
---
---The module is a plain table: each key is an adapter name, each value is an
---AdapterDef — native DAP process/connection config (command, host/port,
---setup/teardown, request, …) plus optional `launch_schema`/`attach_schema`
---describing that adapter's own launch/attach parameters. The schemas are what
---`:Debug new_run_file`/`run_target` read (via `easydap.schema`) to scaffold a run
---file / assemble a native request body; the DAP core never touches them.
---
---Each built-in adapter lives in its own file under `easydap/adapters/`, returning
---one AdapterDef; this module assembles them into the `name -> AdapterDef` table.
---Reusable fragments shared between adapter files live in `adapters/_shared.lua`.
---Users can add adapters or override existing ones directly:
---  local adapters = require("easydap.adapters")
---  adapters.myAdapter = { command = "...", request = "launch" }

-- ── Type annotations ──────────────────────────────────────────────────────

---Context passed to `config.setup()` so the adapter can report progress and
---register terminal buffers with the task runner.
---@class easydap.AdapterSetupCtx
---@field add_bufnr fun(bufnr: integer, opts?: easydap.AddBufOpts)
---@field report    fun(message: string)

---One parameter of an adapter's launch/attach schema. `type` is the value's pure
---Lua/JSON type. `kind` is an optional *data* refinement (file/dir/cwd/env/enum/
---host/port/list/shell_args) driving CLI-string coercion, completion and
---validation (a `kind` implies its `type`).
---
---A schema is a `table<string, easydap.ParamSpec>`. A value may instead be a nested
---group — a ParamSpec with `type = "schema"` holding its children under `fields`
---— which produces a nested body table (e.g. a `connect` group → body.connect).
---Group children are addressed by their dotted path (`connect.host`).
---@class easydap.ParamSpec
---@field type?     "string"|"boolean"|"integer"|"number"|"table"|"list"|"schema"
---@field kind?     "env"|"enum"|"host"|"port"|"file"|"dir"|"cwd"|"shell_args"   data refinement
---@field fields?   table<string, easydap.ParamSpec>  child specs when `type == "schema"`
---@field enum?     any[]              allowed values when `kind == "enum"`
---@field desc?     string
---@field default?  any|fun():any      value used when the caller omits the key
---@field required? boolean
---@field fixed?    boolean            identity field (e.g. `type`/`name`) the adapter pins itself; not user-editable, so `new_run_file` omits it from the scaffolded template

---A named `quick_run` preset for one adapter. `parameters` is a native request
---body (mirroring the shape of `launch_schema`/`attach_schema`'s output) whose
---leaf values may be the literal placeholder string `"{name}"`; `easydap.schema`
---fills those from `quick_run`'s `name=value` tokens, coercing each by the
---ParamSpec found at that field's native path in the adapter's `request` schema.
---`connect` is the same mechanism for adapters that connect over a task-level TCP
---endpoint (an `AdapterDef` `host`/`port`, e.g. `remote`/`java-debug-server`) —
---its `host`/`port` placeholders set the task's connection, not a body field.
---@class easydap.Template
---@field request     "launch"|"attach"
---@field parameters  table    native request body; leaves may be `"{placeholder}"`
---@field connect?    {host?: string, port?: string}   task-level connection placeholders

---A static adapter definition — the launch/attach template for one adapter.
---Entries of this module are values of this type. It is NOT the per-run config
---the DAP layer consumes: the task runner resolves an `AdapterDef` + a task into
---an `easydap.dap.Config` (see [dap/client.lua](dap/client.lua)). No
---`request_args` here — that is a per-run value carried by the resolved config.
---`setup`/`teardown` receive that resolved config (setup may mutate host/port).
---`launch_schema`/`attach_schema` describe the adapter's own DAP parameters and
---are consumed only by `easydap.schema` (for new_run_file/run_target/quick_run),
---never by the DAP core. `templates` names the `quick_run` presets built on top
---of those schemas.
---@class easydap.AdapterDef
---@field command?               string|string[]
---@field cwd?                   string
---@field env?                   table<string,string>
---@field host?                  string
---@field port?                  integer
---@field type?                  string   DAP adapterID override (defaults to the adapter name)
---@field defer_launch_attach?   boolean
---@field request?               string
---@field launch_schema?         table<string, easydap.ParamSpec>
---@field attach_schema?         table<string, easydap.ParamSpec>
---@field templates?             table<string, easydap.Template>
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
