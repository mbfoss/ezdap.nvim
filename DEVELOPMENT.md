# Development

Internals and contributor notes for ezdap.nvim. For user-facing usage, see the
[README](README.md).

## Overview

ezdap is a Neovim DAP client that speaks the Debug Adapter Protocol directly —
no `nvim-dap` dependency. It manages adapter processes, tracks debug
sessions/breakpoints, and renders a tree-based debug UI. Requires Neovim >= 0.10
(guarded in `setup()`).

The entry point is [lua/ezdap/init.lua](lua/ezdap/init.lua): `setup(opts)`
merges config, wires autocmds/signals, and registers the user command. Nothing
is installed before `setup()` runs — there is no `plugin/` script — so options
that decide what is read off disk (`root_markers`, `data_filename`) or what the
command is called (`command`, default `Debug`) are always in place first.

## Architecture

The code is layered; **higher layers depend on lower ones, never the reverse**.
Layers communicate through `Signal`s (pub/sub), not direct back-references: lower
layers emit, higher layers subscribe. `manager` is the single dependency surface
for the UI and commands — prefer it over importing `dap/client` or
`dap/breakpoints` directly.

**Public API** — [lua/ezdap/init.lua](lua/ezdap/init.lua)
`setup`, the run entry points (`run_mode`, `run_file`, `new_run_file`,
`rerun`, `remove_run`), the debug/disassembly view accessors, and registration of
the user command (`config.command`, dispatching to the command surface).

**Active session / programmatic API** — [lua/ezdap/manager.lua](lua/ezdap/manager.lua)
Owns the "which session is active" concept that keymaps and UI subscribe to.
Wraps the session-id-explicit `dap/client` with the active-session notion, taking
operation details directly as arguments (`continue`/`next`/`step_*`, selection,
`evaluate`, `goto_targets`/`restart_frame`/…, a `capable` predicate). Performs
**no** user interaction — no prompts, pickers or notifications. Re-exports the
client signals and the breakpoint registry (`manager.breakpoints`) so consumers
depend only on `manager`.

**Command surface** — [lua/ezdap/command.lua](lua/ezdap/command.lua)
The user-facing command tables `M.debug.*`, `M.breakpoint.*`, `M.view.*` reached
through `:Debug …`. Owns all user interaction — pickers, prompts, notifications,
cursor reads — and resolves it into the concrete details it hands to `manager`,
its only path to the DAP layer.

**DAP core** — [lua/ezdap/dap/](lua/ezdap/dap/)
- `client.lua` — session registry & lifecycle; spawning and session-level events.
- `session.lua` — one DAP session: owns a Connection, holds all runtime state
  (threads, frames, scopes, variables, modules, sources) and drives the protocol
  handshake. Emits events via `session:on(event, fn)`.
- `connection.lua` — a single adapter connection (stdio pipe or TCP socket);
  Content-Length framing, request/response correlation, event dispatch.
- `transport.lua` — streaming Content-Length parser.
- `breakpoints.lua` — global, session-independent breakpoint registry (source,
  function, exception-filter, exception-name breakpoints).
- `proto.lua` — a `---@meta` file of DAP spec types; never `require()` it.

**Adapters & tasks**
- [adapters.lua](lua/ezdap/adapters.lua) — the loaded definitions: a plain
  `name → ezdap.AdapterDef` table of native DAP process/connection config plus
  optional named `modes`, filled as `ezdap.load_adapter` reads them. Users can
  assign into it directly. One file per adapter under `ezdap-adapters/` on the
  runtimepath, keyed by filename — the generic `remote` adapter ships as one;
  `ezdap.available_adapters` names them without reading any. The DAP core never
  reads `modes` — only `ezdap.schema` does.
- [task.lua](lua/ezdap/task.lua) — the task runner backend. Consumes a native
  task (`name`/`adapter`/`request`/`parameters` + optional `host`/`port`) and
  sends `parameters` as the DAP request body verbatim.
- [runner.lua](lua/ezdap/runner.lua) — the run tracker behind `:Debug
  run`/`run_file`/`rerun`/`clean`, and the single path from a mode to a running
  session: it resolves the mode, tracks every run and cancels it. Every run is
  handed a `runner.Presenter` that takes its buffers, progress and outcome;
  nothing here knows about windows.
- [run_display.lua](lua/ezdap/ui/run_display.lua) — the presenter ezdap's own runs
  get. `for_panel` closes it over one `ui.RunPanel`
  ([dock_panel.lua](lua/ezdap/ui/dock_panel.lua) when dock.nvim is installed,
  otherwise [output_win.lua](lua/ezdap/ui/output_win.lua)) and `setup` installs the
  result on the runner. It makes the run's log buffer, holds the buffers the run
  spawned so `clean` can wipe them, and forwards all of it to that panel. A caller passing a
  `runner.Presenter` of its own (as tomltasks' `debug` task type does) replaces
  this module for that run: ezdap's panels never see it, `clean` does not touch
  it, and it leaves ezdap through `remove_run`.
- [inputs.lua](lua/ezdap/inputs.lua) — the input registry: `M.types`, one row per
  scalar type, stating every way it is read (parsed from a command line, described
  as JSON Schema for a typed file, seeded into a scaffolded document, completed),
  and `M.formats`, each row extending one type with a narrower reading of the same
  value. Nothing else switches on a type or format name, so adding one is a single
  row.
- [schema.lua](lua/ezdap/schema.lua) — the engine behind `:Debug run`, the
  reader for `new_run_file`, and the mode engine `runner` resolves every run through.
  `resolve_task` reads a mode's declared `inputs` from a table of values
  and calls its `build`, delivering a complete `ezdap.Task` to a `done` callback —
  a `build` may stop to ask the user something first, and the returned `cancel`
  drops the answer if the caller has given up by then. Only `runner` resolves:
  every front end names a mode and lets the run do the rest.
- [scaffold.lua](lua/ezdap/scaffold.lua) — `:Debug new_run_file`: writes a runnable
  Lua run file naming the `adapter` and `mode` and listing that mode's
  declared inputs under `parameters`, each seeded via `ezdap.inputs` and commented
  with its `description`, then opens it.

**Persistence** — [store.lua](lua/ezdap/store.lua)
A thin path + read/write helper. The project root is the nearest ancestor of the
cwd holding a `root_markers` entry; all project state lives in one JSON file at
that root. The store knows nothing about *what* is stored — the lifecycle
(autocmds, path conversion at the persistence seam) lives in
[init.lua](lua/ezdap/init.lua).

**UI** — [lua/ezdap/ui/](lua/ezdap/ui/)
`DebugView.lua` (the main tree panel, built on `TreeBuffer`), plus
`DisassemblyView`, `InspectView`, `ReplBuffer`, `OutputBuffer`, the run display
(`run_display`) and its two run panels (`dock_panel`, `output_win`), shared
presentation (`format`,
`value_hover`, `node_details`) and the sign/inline-value modules
(`breakpoints_ui`, `debugline_ui`, `inlinevars`, `expressions`).

**Toolkit** — part of [lua/ezdap/util/](lua/ezdap/util/)
Some of that directory is a **vendored** copy of
[neotoolkit.nvim](https://github.com/mbfoss/neotoolkit.nvim): `Signal` (the pub/sub
primitive), `Tree`/`TreeBuffer`, `fileextmarks`, `inputwin`, `floatwin`, `fixedwin`,
`usercmd`, `term`, and the other primitives listed in the script. **Do not edit
those files directly** — they are regenerated by
[scripts/vendor-neotoolkit.sh](scripts/vendor-neotoolkit.sh), which clones
neotoolkit and rewrites `neotoolkit.` → `ezdap.util.`:

```sh
scripts/vendor-neotoolkit.sh            # sync from the upstream repo
LOCAL=../neotoolkit.nvim scripts/vendor-neotoolkit.sh   # sync from a local checkout
```

ezdap's own utilities (`UndoStack`, `select`, `table`, …) sit in the same
directory and are untouched by the vendor script — it copies only the files it
lists.

## The adapter definition format

An `AdapterDef` describes how to launch a DAP adapter (`command`/`host`/`port`,
optional `setup`/`teardown`, default `request`). Its optional `modes` is
a `table<string, ezdap.Mode>` — named launch/attach templates
(`binary`, `attach`, `remote`, …) consumed only by `ezdap.schema`. Adapters carry
no separate schema of their own: each mode is wholly self-describing.

Each `ezdap.Mode`:

| Field         | Meaning                                                                         |
| ------------- | ------------------------------------------------------------------------------- |
| `request`     | `"launch"` or `"attach"`                                                        |
| `inputs`      | what the mode accepts — `name -> ezdap.Input`; see below             |
| `build`       | `fun(inputs): table?, table\|string?` — returns the native request body, plus any task-level TCP endpoint; or `nil, err` to abort |

Each `ezdap.Input` declares one input up front:

| Field      | Meaning                                                                        |
| ---------- | ------------------------------------------------------------------------------ |
| `type`     | what the input *is* — what `build` receives: one of `string`/`boolean`/`integer`/`number`, or a collection, `list` (`a,b`) or `map` (`A=1,B=2`, string keys). Defaults to `string` |
| `format`   | an optional **extension** of `type` with a narrower reading of the same value: `file`/`dir` (a string, normalized and completed as a path), `command` (a string taken verbatim, each token completed as a path), `port` (an integer, range-checked). Types and formats are one flat vocabulary to write in — `{ type = "port" }` and `{ type = "integer", format = "port" }` say the same thing — but naming a `type` the format doesn't extend is an error |
| `item_type` | a collection's *entry* type, declared exactly as `type` is but scalars only — `{ type = "list", item_type = "integer" }` is a list of integers. Defaults to `string` |
| `item_format` | an extension of `item_type`, declared exactly as `format` is — `{ type = "map", item_format = "dir" }` is a map of directories |
| `choices`  | the values the input is normally written with, when the adapter names them itself. Completion offers them and a typed file's schema lists them as `examples`, but nothing rejects a value outside them |
| `required` | when `true`, the user must supply the value; leaving it unset is a resolve error. Any other unset input simply arrives at `build` as nil — which `build` may answer by omitting the field, or some other way: an attach `build` asks the user to pick a process for an unset `pid`, so no adapter marks that input `required` |
| `description` | a few words on what the input means, e.g. `"process id to attach to"` |

Every type and format is one row in [inputs.lua](lua/ezdap/inputs.lua) stating how a
value of it is parsed, described as JSON Schema, seeded and completed — so adding one
is a single row, never an `if format == …` anywhere else.

#### Two authoring forms

An input declares a *value space*, and there are two ways to write into it:

- the **string form** — a command line, where everything is text. `:Debug run
  codelldb launch command='./a.out --verbose'` is this.
- the **typed form** — a structured file that already has types, e.g. an easytasks
  `tasks.toml` writing `env = { A = "1" }` rather than `env=A=1`.

Both land on the input's declared `type`, so `build` never sees the difference and a
single call may mix the two per input. They are not rival answers to what is legal —
they are one value space reached from a CLI or from a typed file.

This is why a row is more than a parser. `map` is the clearest case: you write
`"A=1,B=2"` on a command line or an object of the same pairs in a typed file, and
`build` receives one table either way. The [inputs.lua](lua/ezdap/inputs.lua) row
states both forms, along with how the input gets described to a schema-driven
editor, seeded into a scaffolded document, and completed on a command line. Adding
a type or format means adding one row — every consumer, in ezdap and easytasks
alike, reads it from there.

Both forms must describe the *same* value. A transformation into a different shape
is not a second spelling and doesn't belong in a row: splitting a command line into
`program` + `args` lived here as a `shell_args` type until it moved to the launch
`build`s that wanted it (`shared.split_command`, which takes a command line or an
argument list).

### One description, two entry points

`inputs` is the only description of a mode, and both commands resolve through it:

```
:Debug run     values     ─→ build ─→ body ─→ task
run_file       parameters ─→ build ─→ body ─→ task
new_run_file   inputs ─→ seeded parameters ─→ (you edit it) ─→ run_file
```

A scaffolded run file names the `adapter` and `mode` and lists that mode's
declared inputs under `parameters`, each seeded by its row and commented with its
`description` — so it and `:Debug run` cannot drift, and there is no second field
list to keep in step.

- **`build(inputs)`** returns everything a run needs: the request body, and
  optionally a second table naming a task-level TCP endpoint. `inputs` arrives
  already read into each input's declared `type` whichever form the caller wrote
  them in. Identity fields the adapter pins (`type`/`name`) and fixed defaults go
  in the body too, as plain literals. An unset input is nil, and Lua drops
  nil-valued keys, so `cwd = inputs.cwd` omits `cwd` when it wasn't supplied —
  write the field unconditionally and optional fields take care of themselves.
  Guard only when a field is *derived* from an input (`targetCreateCommands =
  inputs.program and { "target create " .. inputs.program }`), since indexing nil
  would throw. Return no second value unless the adapter takes a task-level TCP
  endpoint — without one the adapter def's own host/port stay in force.

  Omitting the field is only the *default* answer to an unset input; `build` is
  where a mode decides otherwise, because it alone knows what the request
  means. An attach body is nothing without a process, so every attach `build`
  resolves an unset `pid` by asking the user to pick one:

  ```lua
  build = function(inputs)
      local pid, err = shared.resolve_pid(inputs.pid)
      if not pid then return nil, err end   -- cancelled: abort the run
      return { processId = pid }
  end,
  ```

  The schema layer stays out of this — to it a pid is the integer it is. A `build`
  that prompts yields, which is why `resolve_task` runs the `build` call on a
  coroutine and reports through a `done(task, err)` callback rather than a
  return: the pid arrives from a `vim.ui.select` callback, long after a return value
  would have been read. `done` fires synchronously for every `build` that asks
  nothing. Returning `nil` and a message aborts with that error — so always resume
  one way or the other, or the caller waiting on you never hears back.

An input's `description` is what explains the scaffolded file, since it becomes that
field's comment — write it for someone reading the generated run file, not just the
command line. Scaffold a mode after editing it
(`:Debug new_run_file <adapter> <mode> /tmp/x.lua`) to see what it reads like.

Input *names* are `snake_case` (`stop_on_entry`, `wait_for`): they are ezdap's
own user-facing vocabulary — the `name=value` tokens typed at `:Debug run` — not
the adapter's. The `params` keys they fill keep whatever casing the adapter's
wire protocol uses, so pairings like `params.stopOnEntry = inputs.stop_on_entry`
are normal and correct.

Which names a mode takes is up to it — there is no portable role
vocabulary across adapters — but by convention a `launch` mode takes one
`command` input (a `command`-format string) carrying the whole command line, and
`build` splits it into that adapter's own program/args fields via
`shared.split_command`. See each file under `ezdap-adapters/` for worked examples
of every shape, including custom-launch command strings (`codelldb`'s `core`), a
`connect`-only mode (the shipped `remote`), and one input feeding both body and
connection (`java-debug-server`).

## Conventions

- **Lua annotations** — add `---@param`, `---@return`, `---@class`, etc. wherever
  possible.
- **Module naming** — class-based modules are PascalCase; functional modules are
  snake_case.
- **Module-scope `local`s** are prefixed with `_`, except: a name bound directly
  from `require()`, the conventional `M` module table, and class type names.
- **Class privates** are prefixed with `_`. **Function-local** variable names are
  **not** prefixed with `_`.

## Testing & health

```vim
:checkhealth ezdap
```

verifies the Neovim version, whether `setup()` has run, the resolved project
state, and which adapters are registered — by name, since it loads no definition.
`:Debug adapter_info <adapter>` loads one and reports what is wrong with it
(`schema.validate` plus its tooling); `schema.validate_all()` does the same for
every registered definition at once — the quickest smoke test that a local change
hasn't broken adapter resolution.
