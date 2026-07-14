---@brief Built-in DAP adapter definitions.
---
---The module is a plain table: each key is an adapter name, each value is an
---AdapterDef — native DAP process/connection config (command, host/port,
---setup/teardown, request, …) plus a `presets` table of named `easydap.Preset`
---launch/attach templates. Presets are what `:Debug new_run_file`/`run_target`/
---`quick_run` read (via `easydap.schema`) to scaffold a run file / assemble a
---native request body; the DAP core never touches them.
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

---A named `quick_run`/`new_run_file` preset for one adapter. `parameters` is a
---native request body whose leaf values may be:
---  * a literal (string/boolean/number/table), for identity fields the
---    adapter pins itself (`type`/`name`) or fixed defaults it wants sent
---    regardless of user input;
---  * a zero-arg function, resolved at fill time (a computed default, e.g.
---    `function() return vim.fn.getcwd() end`);
---  * a placeholder string `"{name}"` (kept as a raw string) or `"{name:kind}"`
---    (coerced from a CLI string by `kind` — one of `boolean`/`integer`/
---    `number`/`file`/`dir`/`cwd`/`env`/`host`/`port`/`list`/`shell_args`;
---    `easydap.schema.coerce` does the coercion).
---`required` lists placeholder names that must be supplied (a missing one is a
---`quick_run` error; anything else left unset is simply omitted from the body).
---`connect` is the same placeholder mechanism for adapters that connect over a
---task-level TCP endpoint (an `AdapterDef` `host`/`port`, e.g. `remote`/
---`java-debug-server`) — its `host`/`port` placeholders set the task's
---connection, not a body field.
---@class easydap.Preset
---@field request     "launch"|"attach"
---@field parameters  table    native request body; leaves may be a literal, a zero-arg function, or `"{placeholder}"`/`"{placeholder:kind}"`
---@field required?   string[]                    placeholder names that must be supplied
---@field connect?    {host?: string, port?: string}   task-level connection placeholders

---A static adapter definition — the launch/attach template for one adapter.
---Entries of this module are values of this type. It is NOT the per-run config
---the DAP layer consumes: the task runner resolves an `AdapterDef` + a task into
---an `easydap.dap.Config` (see [dap/client.lua](dap/client.lua)). No
---`request_args` here — that is a per-run value carried by the resolved config.
---`setup`/`teardown` receive that resolved config (setup may mutate host/port).
---`presets` are consumed only by `easydap.schema` (for
---new_run_file/run_target/quick_run), never by the DAP core.
---@class easydap.AdapterDef
---@field command?               string|string[]
---@field cwd?                   string
---@field env?                   table<string,string>
---@field host?                  string
---@field port?                  integer
---@field type?                  string   DAP adapterID override (defaults to the adapter name)
---@field defer_launch_attach?   boolean
---@field request?               string
---@field presets?               table<string, easydap.Preset>
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
