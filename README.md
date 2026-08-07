# ezdap.nvim

A batteries-included **Debug Adapter Protocol (DAP) client for Neovim**.

It manages adapter processes and connections, tracks sessions and
breakpoints, and renders a clean, tree-based debug UI. Point it at a debug
adapter, set a breakpoint, and start stepping.

> **Status:** ezdap is under active development. The core is usable day to day,
> but expect rough edges and occasional breaking changes.

---

## Table of contents

- [Highlights](#highlights)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Adapters](#adapters)
- [Starting a debug session](#starting-a-debug-session)
- [Breakpoints](#breakpoints)
- [The debug UI](#the-debug-ui)
- [Stepping & execution control](#stepping--execution-control)
- [Configuration](#configuration)
- [Command reference](#command-reference)
- [Persistence](#persistence)
- [Health check](#health-check)
- [Keymaps example](#keymaps-example)
- [Adding a custom adapter](#adding-a-custom-adapter)
- [Contributing](#contributing)

---

## Highlights

- **No `nvim-dap` dependency** — a self-contained DAP client.
- **Any DAP adapter, no glue plugins** — point ezdap at an adapter with a small
  self-describing file and it's fully wired: completion, scaffolding and a
  process picker come for free (see [Adapters](#adapters)).
- **Full breakpoint palette** — line, conditional, hit-count, **logpoints**,
  **column**, **function**, **exception** (filters and named types) and
  **data breakpoints / watchpoints**.
- **Tree-based debug panel** — sessions, threads, call stacks, scopes,
  variables, watch expressions and breakpoints in one navigable view.
- **Inline variable values** — see values right in the source while stopped,
  in several placement styles.
- **Run buffers on the session** — REPL, program output, adapter terminal and an
  optional raw-DAP-message log, listed under their session in the debug view.
- **Reverse debugging** — step back and reverse-continue when the adapter
  supports it.
- **Power moves** — jump-to-cursor, restart frame, step-into-targets,
  exception info, disassembly view and instruction-level stepping.
- **Parallel sessions** — run several debuggees at once and switch between them.
- **Project-scoped persistence** — breakpoints and watch expressions are saved
  per project and restored automatically.
- **`:checkhealth ezdap`** — verifies the Neovim version and adapter tooling.

## Requirements

- **Neovim >= 0.10**
- A debug adapter for the target language, plus a small ezdap adapter file that
  points at it (see [Adapters](#adapters)). Many debug adapters are trivially
  installed via [mason.nvim](https://github.com/williamboman/mason.nvim); an
  adapter file can resolve its executable from Mason's install path.

## Installation

ezdap has no plugin dependencies. Install it with any plugin manager and call
`setup()`.

<details open>
<summary><b>Native packages / <code>vim.pack</code></b></summary>

```lua
-- Neovim 0.12+
vim.pack.add({ "https://github.com/mbfoss/ezdap.nvim" })
require("ezdap").setup()
```

Or clone into a package directory and `require("ezdap").setup()` from the config:

```sh
git clone https://github.com/mbfoss/ezdap.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/ezdap.nvim
```
</details>

<details>
<summary><b>lazy.nvim</b></summary>

```lua
{
  "mbfoss/ezdap.nvim",
  opts = {},           -- passed to require("ezdap").setup()
}
```
</details>

Calling `setup()` is required — it registers the `:Debug` command, wires up
persistence, and initialises the UI.

## Quick start

```lua
require("ezdap").setup()
```

First tell ezdap about an adapter — one small file per adapter under
`lua/ezdap-adapters/` on your runtimepath (see [Adapters](#adapters)). With,
say, `codelldb` and `debugpy` files in place, start debugging.

The fastest path is `:Debug run`, which launches (or attaches to) an
adapter using one of its named profiles, filled in with a few `input=value`
arguments:

```vim
" Launch a native binary under codelldb
:Debug run codelldb launch command=./a.out\ --verbose

" Debug a Python file
:Debug run debugpy launch command=./main.py\ --verbose

" Attach to a running process
:Debug run debugpy attach pid=41234
```

Set a breakpoint on the current line and step through the program:

```vim
:Debug breakpoint          " toggle a breakpoint at the cursor
:Debug continue            " run to the next breakpoint
:Debug step_over           " step over the current line
```

The debug panel opens automatically when a session starts, showing the call
stack, variables and breakpoints. See [The debug UI](#the-debug-ui) and
[Keymaps example](#keymaps-example) to make this comfortable.

## Adapters

ezdap ships **one** adapter — `remote`, a generic TCP attach that connects to a
DAP server already listening on `host:port`. Every language adapter is one you
add: a small file that says how to reach the debug adapter and what its
launch/attach profiles accept.

Adapters live in `require("ezdap.adapters")` as a plain `name → definition`
table. It is assembled at load time from two sources:

- the shipped `remote` entry, and
- every `lua/ezdap-adapters/*.lua` file found on your runtimepath — one
  `AdapterDef` per file, keyed by its filename stem. Drop
  `~/.config/nvim/lua/ezdap-adapters/debugpy.lua` and a `debugpy` adapter
  appears; a file named `remote.lua` overrides the shipped one.

The table is also writable at runtime, so you can add or override an entry
straight from your config (`require("ezdap.adapters").foo = { … }`).

An adapter file is small and self-describing: native process/connection config
plus named **profiles** that declare their inputs. From that one description,
ezdap wires completion, scaffolding (`:Debug new_run_file`), and the resolve
path for `:Debug run` and run files — no per-adapter glue. Writing one is the
subject of [Adding a custom adapter](#adding-a-custom-adapter).

Run `:checkhealth ezdap` to see which registered adapters have their tooling
available on the current machine.

## Starting a debug session

ezdap gives you several ways to launch or attach, from one-liners to
version-controlled run files.

### `:Debug run` — one-shot launch/attach

Each adapter declares one or more named **profiles** (`launch_program`,
`attach_process`, `remote`, …), each declaring the **inputs** it accepts. Supply them as
`input=value` tokens; the adapter and profile name come first as bare
words:

```vim
:Debug run <adapter> <profile> [input=value ...]
```

Inputs are specific to each adapter/profile — e.g. every `launch_program`
profile takes `command` (a full shell command line, split into the
adapter's own program/args fields) plus `cwd` and `env`; an `attach_process`
profile takes `pid`, and a `remote` one takes `host`/`port`. Each input
declares a **type** that decides how the value is read: `file`/`dir`/`cwd`
(path expansion), `command` (a command line, completed path by path),
`map` (`A=1,B=2`), `list` (`a,b`) and
`integer`/`port`/`boolean`. An input left out is simply omitted from the
request, unless the profile marks it required.

Arguments split on whitespace the way Vim's own commands do (`:h <f-args>`):
quotes are *not* special, and a value containing a space is written with a
backslash — `command=./a.out\ --verbose`, `cwd=/tmp/my\ project`.

Tab-completion offers adapters, then profile names, then the inputs
available for the chosen profile — and, once you type `=`, the values that
input can take: paths for the path-like ones, `true`/`false` for a boolean,
and the fixed set an input like `console` or `backend` names.

### Run files — versionable debug configs

A run file is a Lua file that returns a single task table. Keep it in the
project and run it on demand. Two shapes are accepted, told apart by
whether a `profile` or a `configuration` field is present.

**Profile-based** — names a `profile` and answers its declared inputs under
`parameters`. It resolves exactly like `:Debug run`, so a required input
left unset is an error and an attach with no `pid` pops a process picker:

```lua
-- debug.lua
return {
  name       = "debug app",    -- run label (defaults to "debug")
  adapter    = "codelldb",     -- an entry in require("ezdap.adapters")
  profile    = "launch_program", -- one of the adapter's named profiles
  parameters = {               -- answers to the profile's declared inputs
    command = "./build/app --verbose",
    cwd     = vim.fn.getcwd(),
  },
}
```

**Raw** — no `profile`; you supply an nvim-dap-like `configuration` table of raw
DAP parameters that includes `request`, forwarded to the adapter verbatim:

```lua
-- debug.lua
return {
  name          = "debug app",
  adapter       = "codelldb",
  configuration = {                 -- raw DAP body; `request` selects launch/attach
    request = "launch",             -- "launch" or "attach"
    program = "./build/app",
    args    = { "--verbose" },
    cwd     = "${workspaceFolder}",
  },
}
```

Run either — pass a file, or a **directory** to pick from its `.lua` files:

```vim
:Debug run_file debug.lua
:Debug run_file ./debug/         " opens a picker over the folder's run files
:Debug rerun                     " re-launch the most recently run task
```

For the native shape, see each adapter's upstream documentation for the
`parameters` fields it accepts.

### Why inputs, and not just raw DAP parameters?

The raw shape above is always available, and nothing is hidden behind the
profile one — so why do profiles declare `inputs` at all?

Because **raw DAP parameters are not a thing you can ask someone for.** The DAP
spec deliberately says nothing about the body of a `launch` or `attach` request:
it is whatever that adapter decided. `lldb-dap` wants `program` + `args`;
`debugpy` wants `module` or `program` and spells its environment `env`; delve
wants a `mode`; js-debug nests half of it. There is no field list to complete
against, no way to know which combination is valid, and no way to tell that
`waitFor` is meaningless unless you are attaching by name. A raw table is the
right thing to *send* and the wrong thing to *type*.

A declared input fixes that by adding the one thing the raw body lacks — a
description of itself:

- **Completion knows what to offer.** `:Debug run lldb launch_program <Tab>`
  lists that profile's inputs, and `command=<Tab>` completes paths, because the
  input said it was path-like. A raw table can only be completed by guessing.
- **Errors arrive before the adapter starts.** A required input left unset, a
  port outside 0–65535, a malformed `A=1,B=2` — all are caught while resolving,
  where the message can name the input. Send a bad raw body and you get whatever
  the adapter says on stderr, if anything.
- **Scaffolding is derived, not templated.** `:Debug new_run_file` writes a run
  file straight from `inputs` — every field with its description — so there is no
  template to drift out of sync with what the adapter accepts.
- **One value, two places to write it.** An input can be answered on a command
  line or in a typed run file, and both land at the same `build` (`env` is
  `A=1,B=2` in one and a table in the other). That is why `:Debug run` and a run
  file can't disagree: they resolve through the same declaration.
- **A profile can answer for you.** Inputs are declarations, so a profile can do
  something smarter than "omit the field" when one is missing — every attach
  profile with no `pid` opens a process picker. A raw body has nowhere to put
  that behaviour.

What ezdap deliberately does **not** do is invent a portable vocabulary on top.
There is no generic `stopOnEntry`-for-everyone field that gets translated per
adapter; each profile's `build` writes that adapter's own native keys, and the
input names sit close to them. The goal is to make the adapter's real interface
askable — not to hide it behind a lowest common denominator. When you outgrow a
profile, drop to `configuration` and write the body yourself; the two shapes
produce the same task.

### `:Debug new_run_file` — scaffold a run file

Generate a ready-to-edit, profile-based run file from one of the adapter's
profiles. Required inputs are written active; every other input is listed
commented out with its description, so you uncomment just what you need:

```vim
:Debug new_run_file codelldb launch
" → writes <project root>/codelldb_launch.lua and opens it
```

Fill in the `parameters`, then `:Debug run_file` it. It resolves through the same
path as `:Debug run`. (Prefer the raw shape above instead? Just drop the
`profile`/`parameters` keys and write a `configuration` table by hand.)

### From Lua

Everything above is available programmatically:

```lua
local ezdap = require("ezdap")

-- Run a task table directly
ezdap.run_task({ adapter = "delve", request = "launch", parameters = { mode = "test" } })

-- The run_profile / run_file / new_run_file / rerun entry points, too
ezdap.run_profile("debugpy", "launch", { command = "./main.py" })
ezdap.run_file("debug.lua")
ezdap.rerun()
```

## Breakpoints

All breakpoint operations live under `:Debug breakpoint <sub>`. Breakpoints work
before a session starts and are synced live to running sessions.

```vim
:Debug breakpoint                 " toggle a line breakpoint at the cursor
:Debug breakpoint condition       " set a condition + hit condition on the cursor line
:Debug breakpoint logpoint        " turn the breakpoint into a logpoint (log, don't stop)
:Debug breakpoint column          " set a column breakpoint (picks a valid column when live)
:Debug breakpoint fn <name>       " function breakpoint by name
:Debug breakpoint data            " watchpoint on a variable/expression (running session)
:Debug breakpoint exception_filter" toggle an adapter exception filter
:Debug breakpoint exception_type <name> [mode]  " break on a named exception type
:Debug breakpoint list            " fuzzy-pick and jump to any breakpoint
```

Enable/disable without removing, and clear in bulk:

```vim
:Debug breakpoint toggle_enabled  " enable/disable the breakpoint at the cursor
:Debug breakpoint disable_all
:Debug breakpoint clear_file      " remove every breakpoint in the current file
:Debug breakpoint clear_all       " remove every breakpoint everywhere
```

`clear_all` removes all source, function and exception-type breakpoints across
every file. Adapter exception filters have no removed state, so they are turned
off instead.

Gutter signs distinguish each kind (verified vs. pending, conditional,
logpoint, disabled, exception). The full list of subcommands is in the
[command reference](#command-reference), and the sign glyphs are
[configurable](#configuration).

## The debug UI

### Debug panel (`:Debug view`)

The main panel is a tree of **sessions → threads → stack frames → scopes →
variables**, plus **watch expressions** and **breakpoints**. It opens
automatically when a session starts; open or focus it any time with
`:Debug view`.

Inside the panel:

| Key   | Action                                                                       |
| ----- | ---------------------------------------------------------------------------- |
| `<CR>`| Expand/collapse, select a session, switch to a frame, or jump to a breakpoint's source |
| `K`   | Show the full value / frame details / exception info / breakpoint details    |
| `i`   | Add a watch expression, a function breakpoint, or a data breakpoint (on a variable) |
| `d`   | Remove the watch expression or breakpoint under the cursor                   |
| `r`   | Rename the watch expression under the cursor                                 |
| `x`   | Toggle the breakpoint under the cursor enabled/disabled                      |
| `c`   | Change a value / breakpoint condition / exception break mode / data access type |
| `g?`  | Show this keymap cheatsheet                                                  |
| `zo` `zc` `za` `zO` `zC` | Fold controls (expand / collapse / toggle / all)          |

### Output window (`:Debug output`)

A run spawns several buffers — Terminal, Output, REPL, its progress Log, DAP
messages. They share one bottom split, which holds whichever of them has the
highest priority (the Terminal outranks the Output, which outranks the REPL,
which outranks the Log). It opens on the run's first buffer, follows along as
higher-priority buffers appear or the shown one is deleted, and closes with the
run's last buffer. `:Debug output` toggles it; `panel_auto_open` and
`panel_height_ratio` tune it.

Each run keeps its own log — `ezdap://<run>-log`, wiped with the run — rather
than appending to a shared one, so parallel runs never interleave.

With [dock.nvim](https://github.com/mbfoss/dock.nvim) installed, ezdap uses it
instead — no configuration needed. Each run becomes a tab in dock's shared panel,
one page per buffer, badged with the run's state; parallel runs get a tab each
rather than competing for one window, and `:Dock clean` sheds the finished ones.
dock's own options (`auto_open`, `size`, position) govern the window there, so
`panel_auto_open`/`panel_height_ratio` do not apply.

### Inline variable values

While stopped, ezdap renders variable values inline in the source. Choose the
placement with the `inline_vars` option (`inline`, `eol`, `eol_right_align`,
`right_align`, or `off`). See [Configuration](#configuration).

### Run buffers

A run's buffers are listed under its session row in the debug view; `<CR>` on one
opens it in a regular window:

- **REPL** — Debugger interactive console
- **Output** — the debuggee's output
- **Terminal** — when the adapter launches the debuggee in a terminal

Adapters that offer an external console (`console = externalTerminal`,
codelldb's `terminal = external`) launch the debuggee in a terminal emulator of
its own instead, chosen by the `external_terminal` option — see
[Configuration](#configuration). If that option is unset or the emulator can't be
spawned, the request fails rather than falling back to an integrated terminal.

```vim
:Debug clean            " drop finished runs and wipe their buffers
```

### Inspect, disassembly & REPL

```vim
:Debug inspect          " hover the value of the word under the cursor (or selected expression in visual mode)
:Debug value            " same target, but shows the full value straight away instead of the expandable tree
:Debug disassemble      " open the disassembly view for the current frame
:Debug exception_info   " details of the exception at the current stop
```

In the disassembly view, `<CR>` opens the corresponding source line and `K`
shows the instruction reference. Breakpoints and stepping become
instruction-level while it is focused.

## Stepping & execution control

```vim
:Debug continue         " continue the active session
:Debug continue_all     " continue every session
:Debug step_over        " (alias: :Debug next)
:Debug step_in
:Debug step_out
:Debug step_into_targets" pick which call on the line to step into
:Debug step_back        " reverse debugging (adapter permitting)
:Debug reverse_continue
:Debug jump_to_cursor   " set the next statement to the cursor line
:Debug restart_frame    " restart the selected stack frame
:Debug pause
:Debug restart          " DAP restart request on the live session
:Debug stop             " stop the active session
:Debug stop_all         " stop every session
```

Stepping granularity follows the focused window: line-wise everywhere, and
instruction-wise while the disassembly view is current.

Switch what's active with pickers:

```vim
:Debug session          " choose the active session
:Debug thread           " choose the active thread
:Debug frame            " choose the active stack frame
```

## Configuration

Pass options to `setup()`. Defaults shown:

```lua
require("ezdap").setup({
  -- Project detection: the nearest ancestor holding one of these marks the root.
  root_markers        = { ".git" },
  -- Per-project state file, written at the project root.
  data_filename       = ".ezdap.json",

  -- Max call-stack frames shown (extended when the current frame is deeper).
  stack_trace_limit   = 10,
  -- Delay (ms) before clearing stale UI, to avoid flicker while stepping.
  antiflicker_delay   = 200,
  -- Max lines kept in Output / DAP-message buffers (0 = unlimited).
  output_max_lines    = 10000,
  -- Open the bottom output window as soon as a run registers its first buffer.
  panel_auto_open = true,
  -- Height of the bottom output window, as a fraction of the editor's lines.
  panel_height_ratio = 0.25,
  -- Width of the debug panel on first open, as a fraction of the editor's columns.
  debug_view_width_ratio = 0.2,
  -- Side the debug panel splits off on: "left" | "right".
  debug_view_position = "left",

  -- Inline value placement: "inline" | "eol" | "eol_right_align" | "right_align" | "off"
  inline_vars         = "eol",

  -- Log every DAP message to a "dap" buffer. For debugging ezdap or an
  -- adapter; leave off otherwise.
  raw_messages        = false,

  -- Terminal emulator (command + args) used when an adapter asks to run the
  -- debuggee in an external terminal; its command line is appended. Unset, an
  -- integrated terminal is used instead. E.g. { "alacritty", "-e" }.
  -- external_terminal = { "wezterm", "start", "--" },

  -- Gutter sign glyphs.
  signs = {
    debug_frame              = "▶",   -- current execution position
    active_breakpoint        = "●",   -- enabled + verified
    inactive_breakpoint      = "○",   -- enabled, not yet verified by the adapter
    cond_breakpoint          = "■",   -- conditional, verified
    inactive_cond_breakpoint = "□",
    logpoint                 = "◆",
    inactive_logpoint        = "◇",
    disabled_breakpoint      = "ø",
    disabled_cond_breakpoint = "ø",
    disabled_logpoint        = "ø",
    exception_breakpoint     = "↯",
    unsupported_breakpoint   = "✗",
  },
})
```

## Command reference

Everything is under the `:Debug` command, with completion for every subcommand.

<details>
<summary><b><code>:Debug</code> subcommands</b></summary>

| Subcommand            | Description                                        |
| --------------------- | ------------------------------------------------- |
| `run …`               | Launch/attach from `input=value` tokens           |
| `run_file [path]`     | Run a Lua task file, or pick from a directory     |
| `new_run_file …`      | Scaffold a run file from a profile's inputs        |
| `rerun`               | Re-launch the most recently run task              |
| `view`                | Open/focus the debug panel                        |
| `output`              | Toggle the bottom output window                   |
| `continue` / `continue_all` | Continue the active / every session         |
| `step_over` (`next`) / `step_in` / `step_out` | Stepping             |
| `step_into_targets`   | Pick a call target to step into                   |
| `step_back` / `reverse_continue` | Reverse debugging                      |
| `jump_to_cursor`      | Set the next statement to the cursor line         |
| `restart_frame`       | Restart the selected stack frame                  |
| `exception_info`      | Show details of the current exception             |
| `pause` / `restart`   | Pause / DAP-restart the session                   |
| `stop` / `stop_all`   | Stop the active / every session                   |
| `session` / `thread` / `terminate_thread` / `frame` | Selection pickers   |
| `inspect`             | Hover a value (word under cursor or selection)    |
| `value`               | Same, showing the full value instead of the tree  |
| `disassemble`         | Open the disassembly view                         |
| `clean`               | Drop finished runs and wipe their buffers         |
| `project`             | Report the resolved project root                  |
| `breakpoint …`        | Breakpoint subcommands (below)                    |

</details>

<details>
<summary><b><code>:Debug breakpoint</code> subcommands</b></summary>

| Subcommand           | Description                                         |
| -------------------- | -------------------------------------------------- |
| `toggle` (default)   | Toggle a line breakpoint at the cursor             |
| `add [condition]`    | Add a breakpoint (optionally conditional)          |
| `remove`             | Remove the breakpoint at the cursor                |
| `column`             | Set a column breakpoint                            |
| `condition`          | Set condition + hit condition                      |
| `logpoint`           | Set/clear a log message (logpoint)                 |
| `enable` / `disable` / `toggle_enabled` | Per-breakpoint enable state     |
| `enable_all` / `disable_all` | Bulk enable/disable                        |
| `clear_file` / `clear_fn` | Clear the current file / function breakpoints |
| `clear_all`          | Clear every breakpoint; disables exception filters |
| `fn [name]`          | Toggle a function breakpoint                        |
| `exception_filter`   | Toggle an adapter exception filter                 |
| `exception_type [name] [mode]` | Break on a named exception type          |
| `data [name]`        | Toggle a data breakpoint / watchpoint              |
| `data_clear` / `data_list` | Manage data breakpoints                      |
| `list`               | Fuzzy-pick and jump to a breakpoint                |

</details>

## Persistence

Breakpoints and watch expressions are saved **per project** and restored
automatically. The project root is the nearest ancestor of the cwd containing a
`root_markers` entry (default `.git`); state is written to a single JSON file at
that root (`.ezdap.json` by default), using project-relative paths so it stays
portable.

State is saved when you leave a project (cwd change) and on exit, and reloaded
when you enter a project. Outside any project, ezdap warns once that state
won't be persisted. Check where you are with:

```vim
:Debug project
```

> Consider adding `.ezdap.json` to the project's `.gitignore`, or commit it to
> share breakpoints across a team.

## Health check

```vim
:checkhealth ezdap
```

Reports the Neovim version, whether `setup()` has run, the resolved project
state, and which registered adapters have their tooling installed.

## Keymaps example

ezdap ships no global keymaps — wire up whatever suits you. A function-key
layout to get started:

```lua
local map = vim.keymap.set

map("n", "<F5>",   "<Cmd>Debug continue<CR>",          { desc = "Debug: continue" })
map("n", "<F10>",  "<Cmd>Debug step_over<CR>",         { desc = "Debug: step over" })
map("n", "<F11>",  "<Cmd>Debug step_in<CR>",           { desc = "Debug: step in" })
map("n", "<F12>",  "<Cmd>Debug step_out<CR>",          { desc = "Debug: step out" })
map("n", "<F9>",   "<Cmd>Debug breakpoint<CR>",        { desc = "Debug: toggle breakpoint" })

map("n", "<leader>dc", "<Cmd>Debug breakpoint condition<CR>", { desc = "Debug: conditional breakpoint" })
map("n", "<leader>dl", "<Cmd>Debug breakpoint logpoint<CR>",  { desc = "Debug: logpoint" })
map("n", "<leader>dr", "<Cmd>Debug rerun<CR>",                { desc = "Debug: re-run last" })
map("n", "<leader>du", "<Cmd>Debug view<CR>",                 { desc = "Debug: focus debug view" })
map("n", "<leader>dq", "<Cmd>Debug stop<CR>",                 { desc = "Debug: stop" })

map("n", "<leader>di", "<Cmd>Debug inspect<CR>",              { desc = "Debug: inspect" })
map("x", "<leader>di", "<Cmd>Debug inspect<CR>",              { desc = "Debug: inspect selection" })
```

## Adding a custom adapter

Every adapter beyond `remote` is one you add. There are two ways, and they build
the same `name → definition` registry — there is no registration call and no
`adapters` option in `setup()`.

**Drop a file (recommended).** Put one file per adapter under
`lua/ezdap-adapters/` anywhere on your runtimepath, returning a single
definition. ezdap globs these at load and keys each by its filename stem, so
`lua/ezdap-adapters/myadapter.lua` becomes the `myadapter` adapter:

```lua
-- ~/.config/nvim/lua/ezdap-adapters/myadapter.lua
---@type ezdap.AdapterDef
return {
  command = { "my-dap-adapter", "--stdio" },  -- stdio adapter: spawned, framed over its pipes
}
```

**Assign at runtime.** `require("ezdap.adapters")` is a plain, writable table.
Assigning a new key adds an adapter; assigning an existing one overrides it. Do
it anywhere after the plugin loads:

```lua
local adapters = require("ezdap.adapters")

adapters.myadapter = {
  command = { "my-dap-adapter", "--stdio" },
}
```

Either way, that bare definition is already enough to run — from a run file,
using the raw shape (`adapter` + `configuration`) described in
[Run files](#run-files--versionable-debug-configs):

```lua
-- debug.lua
return {
  name          = "my thing",
  adapter       = "myadapter",
  configuration = {
    request     = "launch",
    program     = "/path/to/thing",
    stopOnEntry = true,
  },
}
```

Everything but `request` is sent to the adapter as the DAP launch/attach body
verbatim — ezdap never rewrites the keys, so use whatever the adapter's own
documentation calls them.

### The adapter definition

Every field is optional except a way to reach the adapter — either a `command`
to spawn or a `host`/`port` to connect to.

| Field                 | Meaning                                                                                   |
| --------------------- | ----------------------------------------------------------------------------------------- |
| `command`             | Executable (string) or argv (list) for a stdio adapter.                                    |
| `cwd`, `env`          | Working directory and environment for that process.                                        |
| `host`, `port`        | Connect over TCP instead of stdio. A task's own `host`/`port` override these.               |
| `type`                | DAP `adapterID` sent in `initialize`; defaults to the adapter's key.                        |
| `defer_launch_attach` | Send `launch`/`attach` only after `initialized`, for adapters that require that ordering.   |
| `setup` / `teardown`  | Hooks around the connection — see below.                                                   |
| `profiles`            | Named launch/attach descriptions, the subject of the next section.                          |

`setup(config, ctx, callback)` runs before ezdap connects, and may mutate
`config` — most usefully `config.host`/`config.port`, which is how an adapter
that is really a TCP server gets started and then connected to. It reports
progress with `ctx.report(msg)`, registers any terminal buffers it spawns with
`ctx.add_bufnr(bufnr, opts)` so they are listed under the session, and must call
`callback(err, state)` exactly once — an `err` string aborts the run. Whatever
`state` it passes comes back as the second argument to `teardown`, which is
where you stop what you started.

`ctx.profile` is the name of the profile the run was resolved from — the config
itself does not record it — so a `setup` can gate one profile rather than the
whole adapter, e.g. refusing a profile whose feature the installed binary is too
old for. A raw task (a run file's `configuration`, or `run()` called directly)
names no profile, so treat `nil` as "none of mine" and let the run proceed.

```lua
adapters.myserver = {
  setup = function(config, ctx, callback)
    local handle = start_the_server()          -- e.g. via ezdap.tk.term.spawn
    ctx.add_bufnr(handle.bufnr, { label = "my-dap server" })
    ctx.report("waiting for server port")
    wait_for_port(handle, function(port)
      config.host, config.port = "127.0.0.1", port
      callback(nil, { handle = handle })
    end)
  end,
  teardown = function(_, state)
    if state and state.handle then state.handle.stop() end
  end,
}
```

Note that when an adapter defines `setup`, ezdap leaves `config.host`/`port`
entirely to it and ignores the task's — the adapter knows where it put the
server. A `delve`-style adapter is the canonical example: it spawns `dlv dap`,
scrapes the "DAP server listening at:" line, and points the connection there.

### Adding profiles

A bare definition is runnable but not *askable*: nothing completes, and nothing
can be scaffolded, because a raw DAP body describes nothing about itself (see
[Why inputs](#why-inputs-and-not-just-raw-dap-parameters)). Adding `profiles`
fixes that. Each profile declares the `inputs` it accepts and a `build` that
turns supplied values into the native body:

```lua
adapters.myadapter = {
  command = { "my-dap-adapter", "--stdio" },
  profiles = {
    launch_program = {
      description = "debug an executable",
      request     = "launch",
      inputs = {
        command       = { type = "string",  format = "command", required = true, description = "command line to debug" },
        cwd           = { type = "string",  format = "cwd",     description = "working directory" },
        env           = { type = "table",   format = "map",     description = "environment variables" },
        stop_on_entry = { type = "boolean",                      description = "break at program entry" },
      },
      build = function(params, connect, inputs)
        params.program, params.args = require("ezdap.shared").split_command(inputs.command)
        params.cwd         = inputs.cwd
        params.env         = inputs.env
        params.stopOnEntry = inputs.stop_on_entry
      end,
    },
  },
}
```

The profile is now everywhere it should be, with no further wiring:

```vim
:Debug run myadapter launch_program command=./a.out cwd=/src stop_on_entry=true
:Debug new_run_file myadapter launch_program
```

How the pieces fit:

- **`inputs`** — one entry per accepted value, keyed by the name typed on the
  command line or written in a run file's `parameters`. `type` is what `build`
  receives (`string`, `boolean`, `integer`, `number`, `table`); `format` says how
  the authored forms reach that type and drives completion — `file`/`dir`/`cwd`
  (path expansion), `command` (a command line, taken verbatim; the program and
  each argument complete as paths), `host`, `port` (range-checked), `map`
  (`A=1,B=2` → table), `list` (`a,b` → table). Omit `format` and the value is
  read by `type` alone.
  The full vocabulary is one row per format in
  [inputs.lua](lua/ezdap/inputs.lua) — every consumer reads those rows, so a new
  format is a single addition there, never a `if format == …` anywhere else.
- **`choices`** — the values an input is normally written with, when the adapter
  names them itself (`console`, `terminal`, `backend`, …). Completion offers them
  and a typed file's schema lists them as `examples`, but nothing rejects a value
  outside them. A boolean input completes as `true`/`false` on its own.
- **`required`** — an unset required input is a resolve error naming the input.
  Leave it off and an unset input simply arrives as `nil`; since Lua drops
  nil-valued keys, `params.cwd = inputs.cwd` omits `cwd` entirely. Assign
  unconditionally and optional fields take care of themselves.
- **`build(params, connect, inputs)`** — fills both tables in place. `params` is
  the native DAP body (write the adapter's own key names, plus any identity
  fields it pins, as literals). `connect` is for adapters whose *connection*
  is what an input configures — set `connect.host`/`connect.port` and leave it
  alone otherwise, so the definition's own values stay in force. `inputs`
  arrives already read into each declared `type`, whichever form the caller
  authored it in. Return nothing on success, or an **error string** to abort.
- **Asking the user** — `build` runs on a coroutine, so it may yield. That is how
  an attach profile with no `pid` opens a process picker rather than sending a
  meaningless body: `local pid, err = shared.resolve_pid(inputs.pid); if not pid
  then return err end`. It must always resume — return a value or an error
  string — so the caller waiting on it hears back.

Because `:Debug run`, `:Debug new_run_file` and profile-based run files all resolve
through the same `inputs` → `build` path, a profile is described in exactly one
place and the three cannot drift apart. The shipped `remote` adapter in
[adapters.lua](lua/ezdap/adapters.lua) is a compact reference for a profile that
configures `connect` (a task-level `host`/`port`) instead of `params`; for a
spawn-then-connect adapter that starts a server and points the connection at it,
see the `setup`/`teardown` example [above](#the-adapter-definition).

Adapters you add are picked up by `:checkhealth ezdap` too — it reports whether
each definition's `command` is present on the current machine.

## Contributing

Contributions are welcome. See [DEVELOPMENT.md](DEVELOPMENT.md) for the
architecture overview, module map, and conventions.
