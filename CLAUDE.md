# CLAUDE.md

## Overview

easydap.nvim is a Neovim Debug Adapter Protocol (DAP) client. It speaks the DAP
wire protocol directly (no `nvim-dap` dependency), manages adapter processes,
tracks debug sessions/breakpoints, and renders a tree-based debug UI. Requires
Neovim >= 0.10 (guarded in [plugin/easydap.lua](plugin/easydap.lua)).

Entry point is [lua/easydap/init.lua](lua/easydap/init.lua): `setup(opts)` merges
config, wires autocmds/signals, and registers the `:Debug` user command (with a
`breakpoint` subcommand surface).

## Architecture

The code is layered; higher layers depend on lower ones, not the reverse.

**Public API** — [init.lua](lua/easydap/init.lua)
- `setup`, `run` (task entry point), `debug_view`/`open_debug_view`, user commands.

**Command surface / active session** — [manager.lua](lua/easydap/manager.lua)
- Owns the "which session is active" concept that keymaps and UI subscribe to.
- Wraps the session-id-explicit `dap/client` with active-session helpers and
  exposes user-facing command tables: `M.debug.*`, `M.breakpoint.*`, `M.view.*`.
- Re-exports client signals so consumers depend only on `manager`, never `client`.

**DAP core** — [lua/easydap/dap/](lua/easydap/dap/)
- `client.lua` — session registry & lifecycle; session spawning and session-level events.
- `session.lua` — one DAP session: owns a Connection, holds all runtime state
  (threads, frames, scopes, variables, modules, sources), drives the protocol
  handshake. Emits events via `session:on(event, fn)`.
- `connection.lua` — a single adapter connection (stdio pipe or TCP socket);
  Content-Length framing, request/response correlation, event/request dispatch.
- `transport.lua` — streaming Content-Length parser.
- `breakpoints.lua` — global, session-independent breakpoint registry (source,
  function, exception-filter, exception-name breakpoints).
- `proto.lua` — `---@meta` file of DAP spec types; never `require()` it.

**Adapters & tasks**
- [adapters.lua](lua/easydap/adapters.lua) — built-in adapter definitions as a
  plain `name -> easydap.AdapterDef` table: native DAP process/connection config
  plus optional `launch_schema`/`attach_schema` (a `native_key -> ParamSpec` map)
  describing the adapter's own launch/attach parameters. Users add/override keys
  directly. The DAP core never reads the schemas — only `easydap.schema` does.
- [task.lua](lua/easydap/task.lua) — task runner (`easydap.TaskTypeDef`); the
  `run` backend for external task runners. Consumes a native task
  (`name`/`adapter`/`request`/`parameters` + optional `host`/`port`/
  `raw_messages`) and sends `parameters` as the DAP request body verbatim.
- [schema.lua](lua/easydap/schema.lua) — the engine behind `:Debug quick_run` and
  the schema reader for `new_task`. Reads the adapters' `launch_schema`/
  `attach_schema` (each `ParamSpec` has a Lua `type`, an optional data `kind` and
  value-meaning `role`; a schema entry may be a nested group — a `type = "schema"`
  spec holding children under `fields`) to assemble a native request body (`build`)
  and locate role-tagged fields by `role` (`key_of_role`/`quick_roles`, for
  `quick_run`). Exposes `is_group`/`group_fields`/`resolve_default` for schema
  traversal. Native keys throughout — no portable/generic field vocabulary.
- [scaffold.lua](lua/easydap/scaffold.lua) — task-file creation behind `:Debug
  new_task`: renders an adapter's schema (via `easydap.schema`) into a runnable Lua
  run_file, seeded with defaults/placeholders, then opens it.

**Persistence** — [store.lua](lua/easydap/store.lua)
- A thin path + read/write helper. The project root is the nearest ancestor of
  the cwd (cwd included) holding a `root_markers` entry (default `.git`); all
  project state lives in a single JSON file at that root (`.easydap.json` by
  default). `root()` (cached, `invalidate()` after a cwd change), `relativize`/
  `absolutize` (portable project-relative paths), and `read`/`write` (write
  removes the file when the payload is empty). The store knows nothing about
  *what* is stored.
- The lifecycle lives in [init.lua](lua/easydap/init.lua): it owns the autocmds
  (`DirChangedPre`/`VimLeavePre` save, `DirChanged` re-resolves the root and
  reloads/clears) and the breakpoint/expression payloads, converting source
  paths at the persistence seam.

**UI** — [lua/easydap/ui/](lua/easydap/ui/)
- `DebugView.lua` — the main debug panel (tree of sessions/frames/scopes/
  variables/expressions/breakpoints), built on `TreeBuffer`.
- `signs.lua`, `breakpoints_ui.lua`, `debugline_ui.lua`, `inlinevars.lua`,
  `extmarks.lua`, `expressions.lua`, `ReplBuffer.lua` — gutter signs, inline
  values, REPL, etc.

**Utilities** — [lua/easydap/util/](lua/easydap/util/)
- `Signal.lua` — the pub/sub primitive used throughout: `Signal.new()`,
  `:subscribe(fn)` (returns an unsubscribe fn), `:emit(...)`. This is the main
  decoupling mechanism between layers.
- `Tree.lua`, `select.lua`, `inputwin.lua`, `usercmd.lua` (subcommand
  registration/completion), plus `fsutil`, `str_util`, `table_util`, `term`,
  `throttle`, `timer`, `ui_util`.

### Conventions to keep in mind
- Layers communicate through `Signal`s, not direct back-references. Lower layers
  emit; higher layers subscribe.
- `manager` is the single dependency surface for UI/commands — prefer it over
  importing `dap/client` directly.

## Styling

Add Lua annotations (`---@param`, `---@return`, `---@class`, etc.) whenever possible.

Class-based modules are named in PascalCase; functional modules are named in snake_case.

Module-scope `local` variables are prefixed with `_`, except:
- a local name bound directly from `require()`
- the conventional `M` module table
- class type names like `MyType`

Inside a class, private members are prefixed with `_`.

Function local variable names should NOT begin with `_`. 