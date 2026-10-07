# Development

Internals and contributor notes for ndap.nvim. For user-facing usage, see the
[README](README.md).

## Overview

ndap is a Neovim DAP client that speaks the Debug Adapter Protocol directly, no
`nvim-dap` dependency. It manages adapter processes, tracks debug
sessions/breakpoints, and renders a tree-based debug UI. Requires Neovim >= 0.10
(guarded in `setup()`).

`require("ndap").setup(opts)` is the one entry point and is **mandatory**:
nothing exists before it runs. It merges `opts` into
[config.lua](lua/ndap/config.lua), registers the user command, installs the
project-state autocmds, and stops there. There is no `plugin/` script, so ndap
costs nothing until a config asks for it. Because `setup()` is the only door,
`root_markers` and `data_filename` are settled before the saved-state lookup,
which happens inline rather than deferred; it asks
[project.lua](lua/ndap/project.lua) and decodes nothing unless a file exists.

Everything past that is lazy. `_ensure_loaded()` brings up the plugin proper
(UI wiring, DAP subscriptions, restored state) once, on the first `:Ndap` or
API call, or when a state file is found at `setup()` or after a cwd change.
Every public entry point calls `_require_setup()`, which both raises the "call
setup() first" error and *is* that demand, so each body can assume a loaded
plugin. The exceptions are the projections — `available_adapters`,
`load_adapter`, the mode projections (`mode`, `mode_names`, `mode_inputs`,
`mode_required`) and the input projections (`input_seed`) —
which read the runtimepath and the config, bring nothing up, and so answer
before any `setup()`. The
autocmds are guarded the same way: cold means nothing to persist and no session
to disconnect.

The command name is hardcoded, so every message and doc line names `:Ndap`
outright. A name someone else holds is never taken silently: `:Ndap` is left
alone with a warning (the API and the saved state do not go through the
command).

A second `setup()` call is refused, not merged.

## Architecture

The code is layered; **higher layers depend on lower ones, never the reverse**.
Layers communicate through `Signal`s (pub/sub), not direct back-references:
lower layers emit, higher layers subscribe. `manager` is the single dependency
surface for the UI and commands; prefer it over importing `dap/client` or
`dap/breakpoints` directly.

**Public API**: [lua/ndap/init.lua](lua/ndap/init.lua) `setup`, the run entry
points (`run_mode`, `run_file`, `new_run_file`, `rerun`, `remove_run`), and the
view entry points (`open_debug_view`, `close_debug_view`, `toggle_debug_view`,
`open_disassembly_view`), plus the projections named above. Registers the user command (`config.command`)
and hands each invocation to `usercmd`.

**`:Ndap` command line**: [lua/ndap/usercmd.lua](lua/ndap/usercmd.lua) Parses
a typed invocation, routes it to the `commands` tables (or to init's public API
for run/project operations), and completes its arguments. Required lazily from
the command callback, so it -- and `commands` behind it -- load only on first
use. Arguments arrive already split by Neovim's <f-args> rules -- `opts.fargs` to
run, `nvim_parse_cmd` to complete -- so no line is re-parsed here.

**Active session / programmatic API**:
[lua/ndap/manager.lua](lua/ndap/manager.lua) Owns the "which session is
active" concept that keymaps and UI subscribe to. Wraps the session-id-explicit
`dap/client` with the active-session notion, taking operation details directly
as arguments (`continue`/`next`/`step_*`, selection, `evaluate`,
`goto_targets`/`restart_frame`/…, a `capable` predicate). Performs **no** user
interaction: no prompts, pickers or notifications. Re-exports the client signals
and the breakpoint registry (`manager.breakpoints`) so consumers depend only on
`manager`.

**Commands**: [lua/ndap/commands.lua](lua/ndap/commands.lua) The user-facing
command tables `M.debug.*`, `M.breakpoint.*`, `M.view.*` reached through
`:Ndap …`. Owns all user interaction (pickers, prompts, notifications, cursor
reads) and resolves it into the concrete details it hands to `manager`, its only
path to the DAP layer. `M.view` also owns the DebugView/DisassemblyView
singletons, so this surface never requires `init`. A peer surface to `ui/`, both
consuming `manager`.

**DAP core**: [lua/ndap/dap/](lua/ndap/dap/)
- `client.lua`: session registry & lifecycle; spawning and session-level events.
- `session.lua`: one DAP session. Owns a Connection, holds all runtime state
  (threads, frames, scopes, variables, modules, sources) and drives the protocol
  handshake. Emits events via `session:on(event, fn)`.
- `connection.lua`: a single adapter connection (stdio pipe or TCP socket);
  Content-Length framing, request/response correlation, event dispatch.
- `transport.lua`: streaming Content-Length parser.
- `breakpoints.lua`: global, session-independent breakpoint registry (source,
  function, exception-filter, exception-name breakpoints).
- `proto.lua`: a `---@meta` file of DAP spec types; never `require()` it.

**Types**: [lua/ndap/meta.lua](lua/ndap/meta.lua) is the `---@meta` file of
declaration-only types — the adapter definition (`ndap.AdapterDef`, its modes
and inputs) and `ndap.Module`, the public surface [init.lua](lua/ndap/init.lua)
returns; that file binds `M` to the class, so a field that drifts from it is a
diagnostic. Never `require()` it, like `proto.lua`.

**Adapters & tasks**
- [init.lua](lua/ndap/init.lua) `M.adapters`: the loaded definitions, a plain
  `name → ndap.AdapterDef` table of native DAP process/connection config plus
  optional named `modes`, filled as `ndap.load_adapter` reads them. Users can
  assign into it directly. One file per adapter under `ndap-adapters/` on the
  runtimepath, keyed by filename; the generic `remote` adapter ships as one;
  `ndap.available_adapters` names them without reading any. The DAP core never
  reads `modes`; only `ndap.run.schema` does.
- [task.lua](lua/ndap/run/task.lua): the task runner backend. Consumes a native
  task (`name`/`adapter`/`request`/`parameters` + optional `host`/`port`) and
  sends `parameters` as the DAP request body verbatim.
- [runner.lua](lua/ndap/run/runner.lua): the run tracker behind `:Ndap
  run`/`run_file`/`rerun`/`clean`, and the single path from a mode to a running
  session: it resolves the mode, tracks every run and cancels it. Every run is
  handed a `runner.Presenter` that takes its buffers, progress and outcome;
  nothing here knows about windows.
- [run_display.lua](lua/ndap/ui/run_display.lua): the presenter ndap's own
  runs get. `for_panel` closes it over one `ui.Panel`
  ([Panel.lua](lua/ndap/ui/Panel.lua)) and `setup` installs
  the result on the runner. It makes the run's log buffer, holds the buffers the
  run spawned so `clean` can wipe them, and forwards all of it to that panel. A
  caller passing a `runner.Presenter` of its own (as tomltasks' `debug` task
  type does) replaces this module for that run: ndap's own panel never sees it,
  `clean` does not touch it, and it leaves ndap through `remove_run`.
- [inputs.lua](lua/ndap/run/inputs.lua): the input registry. `M.types` holds one
  row per scalar type, stating every way it is read (parsed from a command line,
  seeded into a scaffolded document, completed), and `M.sources`, the completion
  an input may ask for by name.
  Nothing else switches on a type name, so adding one is a single row.
- [schema.lua](lua/ndap/run/schema.lua): the engine behind `:Ndap run`, the reader
  for `new_run_file`, and the mode engine `runner` resolves every run through.
  `resolve_task` reads a mode's declared `inputs` from a table of parameters and
  calls its `build`, delivering a complete `ndap.Task` to a `done` callback, a
  `build` may stop to ask the user something first, and the returned `cancel`
  drops the answer if the caller has given up by then. Only `runner` resolves:
  every front end names a mode and lets the run do the rest.
- [scaffold.lua](lua/ndap/run/scaffold.lua): backs `:Ndap new_run_file`, writing a
  runnable Lua run file naming the `adapter` and `mode` and listing that mode's
  declared inputs under `parameters`, each seeded via `ndap.run.inputs` and
  commented with its `description`, then opens it.

**Persistence**: [store.lua](lua/ndap/store.lua) A thin path + read/write
helper. The project root is the nearest ancestor of the cwd holding a
`root_markers` entry; all project state lives in one JSON file at that root. The
store knows nothing about *what* is stored: the lifecycle (autocmds, path
conversion at the persistence seam) lives in [init.lua](lua/ndap/init.lua).

**UI**: [lua/ndap/ui/](lua/ndap/ui/) `DebugView.lua` (the main tree view,
built on `TreeBuffer`), plus `DisassemblyView`, `InspectView`, `ReplBuffer`,
`OutputBuffer`, the run display (`run_display`) and its panel
(`Panel`), shared presentation (`format`, `value_hover`,
`node_details`) and the sign/inline-value modules (`breakpoints_ui`,
`debugline_ui`, `inlinevars`, `expressions`).

**Toolkit**: [lua/ndap/util/](lua/ndap/util/) Standalone primitives with no
ndap dependencies: `Signal` (the pub/sub primitive), `Tree`/`TreeBuffer`,
`fileextmarks`, `inputwin`, `floatwin`, `fixedwin`, `term`,
`throttle`, `timer`, `fsutil`, `strutil`, `ui`, plus `UndoStack`, `select`,
`table` and friends.

## The adapter definition format

An `AdapterDef` describes how to launch a DAP adapter (`command`/`host`/`port`,
optional `setup`/`teardown`, default `request`). Its optional `modes` is a
`table<string, ndap.Mode>`: named launch/attach templates (`binary`, `attach`,
`remote`, …) consumed only by `ndap.run.schema`. Adapters carry no separate schema
of their own: each mode is wholly self-describing.

Each `ndap.Mode`:

| Field         | Meaning                                                                         |
| ------------- | ------------------------------------------------------------------------------- |
| `request`     | `"launch"` or `"attach"`                                                        |
| `inputs`      | what the mode accepts: `name -> ndap.Input`; see below             |
| `build`       | `fun(parameters): table?, table\|string?`, returning the native request body, plus any task-level TCP endpoint; or `nil, err` to abort |

Each `ndap.Input` declares one input up front:

| Field      | Meaning                                                                        |
| ---------- | ------------------------------------------------------------------------------ |
| `type`     | what the input *is*, meaning what `build` receives: one of `string`/`boolean`/`integer`/`number`, or a collection, `list` (a table of entries) or `map` (a table of string keys to values). Defaults to `string` |
| `item_type` | a collection's *entry* type, declared exactly as `type` is but scalars only: `{ type = "list", item_type = "integer" }` is a list of integers. Defaults to `string` |
| `completion` | what the value completes with, in one of three forms: a named source (`"file"`, `"dir"`, `"command"`, the last completing each token of a command line as a path), the values themselves (`{ "console", "terminal" }`), or a `fun(partial): string[]` computing them. A written-out set also reaches the scaffolded file as a comment; a source or a function has nothing to serialize. Completion only *suggests*; nothing rejects a value written past it. On a collection it describes one entry |
| `required` | when `true`, the user must supply the value; leaving it unset is a resolve error. Any other unset input arrives at `build` as nil, which `build` may answer by omitting the field, or some other way: an attach `build` asks the user to pick a process for an unset `pid`, so no adapter marks that input `required` |
| `description` | a few words on what the input means, e.g. `"process id to attach to"` |

Every type is one row in [inputs.lua](lua/ndap/run/inputs.lua) stating how a value
of it is parsed, described as JSON Schema, seeded and completed, and every named
completion source one entry beside them, so adding either is a single row, never
an `if type == …` anywhere else.

What a value additionally *is* (a path, a port) is not a row: `build` says it,
with `shared.normalize_path` and `shared.resolve_port`. A row states what a
value **is**; narrowing one kind of string into another was a second vocabulary
layered on that one, paid for in every projection (a schema merge, a refine
step, a check step, and the rule reconciling a `type` with a `format` naming a
different one), and it bought two behaviours a `build` line each expresses.

#### A string form, and the typed form

An input declares a *value space*, reached two ways, but only one of them is
text:

- the **string form**, the command line's: `:Ndap run codelldb launch
  --command ./a.out\ --verbose` is this; a collection instead takes one token per
  entry (`--env A=1 B=2`), which the parser turns into a table.
- the **typed form**, a run file's or an API caller's: a Lua value that already
  has its type -- `env = { A = "1" }`, `port = 8080`, `enabled = true`.

Only `:Ndap run` parses: it reads each token against the input's `type` before
resolving the run. A run file or an API caller is already writing Lua, so its
value must *be* the value -- `port = "8080"` is refused ("expected integer, got
\"8080\""). A collection has no string form at all: it is always the table. Both routes land on
the input's declared `type`, so `build` never sees the difference.

This is why a row is more than a parser. `map` is the clearest case: `--env A=1
B=2` on a command line or `{ A = "1" }` in a typed file, and `build` receives one
table either way. The
[inputs.lua](lua/ndap/run/inputs.lua) row states how a value is read from text
and as a typed value, along with how the input is seeded into a scaffolded
document and completed on a command line.
Adding a type means adding one row, and every consumer, in ndap and easytasks
alike, reads it from there.

Both forms must describe the *same* value. A transformation into a different
shape is not a second spelling and doesn't belong in a row: splitting a command
line into `program` + `args` lived here as a `shell_args` type until it moved to
the launch `build`s that wanted it (`shared.split_command`, which takes a
command line or an argument list).

### One description, two entry points

`inputs` is the only description of a mode, and both commands resolve through
it:

```
:Ndap run     values     ─→ build ─→ body ─→ task
run_file       parameters ─→ build ─→ body ─→ task
new_run_file   inputs ─→ seeded parameters ─→ (you edit it) ─→ run_file
```

A scaffolded run file names the `adapter` and `mode` and lists that mode's
declared inputs under `parameters`, each seeded by its row and commented with
its `description`, so it and `:Ndap run` cannot drift, and there is no second
field list to keep in step.

- **`build(parameters)`** returns everything a run needs: the request body, and
  optionally a second table naming a task-level TCP endpoint. `parameters`
  arrives already read into each input's declared `type` whichever form the
  caller wrote them in. Identity fields the adapter pins (`type`/`name`) and fixed defaults
  go in the body too, as plain literals. An unset input is nil, and Lua drops
  nil-valued keys, so `cwd = parameters.cwd` omits `cwd` when it wasn't supplied;
  write the field unconditionally and optional fields take care of themselves.
  Guard only when a field is *derived* from an input (`targetCreateCommands =
  parameters.program and { "target create " .. parameters.program }`), since indexing
  nil would throw. Return no second value unless the adapter takes a task-level
  TCP endpoint; without one the adapter def's own host/port stay in force.

  Omitting the field is only the *default* answer to an unset input; `build` is
  where a mode decides otherwise, because it alone knows what the request means.
  An attach body is nothing without a process, so every attach `build` resolves
  an unset `pid` by asking the user to pick one:

  ```lua
  build = function(parameters)
      local pid, err = shared.resolve_pid(parameters.pid)
      if not pid then return nil, err end   -- cancelled: abort the run
      return { processId = pid }
  end,
  ```

  The schema layer stays out of this: to it a pid is the integer it is. A
  `build` that prompts yields, which is why `resolve_task` runs the `build` call
  on a coroutine and reports through a `done(task, err)` callback rather than a
  return: the pid arrives from a `vim.ui.select` callback, long after a return
  value would have been read. `done` fires synchronously for every `build` that
  asks nothing. Returning `nil` and a message aborts with that error, so always
  resume one way or the other, or the caller waiting on you never hears back.

An input's `description` is what explains the scaffolded file, since it becomes
that field's comment: write it for someone reading the generated run file, not
just the command line. Scaffold a mode after editing it (`:Ndap new_run_file
<adapter> <mode> /tmp/x.lua`) to see what it reads like.

Input *names* are `snake_case` (`stop_on_entry`, `wait_for`): they are ndap's
own user-facing vocabulary (the `--name` flags typed at `:Ndap run`), not
the adapter's. The `params` keys they fill keep whatever casing the adapter's
wire protocol uses, so pairings like `params.stopOnEntry = parameters.stop_on_entry`
are normal and correct.

Which names a mode takes is up to it, and there is no portable role vocabulary
across adapters, but by convention a `launch` mode takes one `command` input (a
string completing as `"command"`) carrying the whole command line, and `build`
splits it into that adapter's own program/args fields via
`shared.split_command`. The shipped `remote` (under `ndap-adapters/`) is the
`connect`-only shape; the definitions in
[ndap-adapters.nvim](https://github.com/mbfoss/ndap-adapters.nvim) are worked
examples of the rest, such as inputs that feed both the body and the connection.

## Conventions

- **Lua annotations**: add `---@param`, `---@return`, `---@class`, etc. wherever
  possible.
- **Module naming**: class-based modules are PascalCase; functional modules are
  snake_case.
- **Module-scope `local`s** are prefixed with `_`, except: a name bound directly
  from `require()`, the conventional `M` module table, and class type names.
- **Class privates** are prefixed with `_`. **Function-local** variable names
  are **not** prefixed with `_`.

## Testing & health

```vim
:checkhealth ndap
```

verifies the Neovim version, whether the plugin is initialised, the resolved
project state, and which adapters are registered, by name, since it loads no
definition. `:Ndap adapter_info <adapter>` loads one and reports what is wrong
with it (`schema.validate` plus its tooling); `schema.validate_all()` does the
same for every registered definition at once: the quickest smoke test that a
local change hasn't broken adapter resolution.
