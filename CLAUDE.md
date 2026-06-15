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
  exposes user-facing command tables: `M.debug.*`, `M.breakpoint.*`, `M.panel.*`.
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
  plain `name -> easydap.dap.Config` table; users add/override keys directly.
- [task.lua](lua/easydap/task.lua) — task runner (`easydap.TaskTypeDef`); the
  `run` backend for external task runners.
- [templates.lua](lua/easydap/templates.lua) — starter task templates (LLDB, CodeLLDB, …).

**Persistence** — [store.lua](lua/easydap/store.lua)
- Project-scoped: root is cwd when it directly contains a `root_markers` entry
  (default `.git`). Namespaces merge into a single data file at the root (`.easydap.json` by default).
  Writes are deferred; `flush()` persists. Breakpoints and expressions are saved
  on `VimLeavePre` and project-leave, restored on project-enter.

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
