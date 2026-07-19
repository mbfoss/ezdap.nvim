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
- [Built-in adapters](#built-in-adapters)
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
- **Batteries-included adapters** — Python, C/C++/Rust, Go, .NET, Node/JS/TS,
  Java, PHP, Bash and Lua work out of the box (see [below](#built-in-adapters)).
- **Full breakpoint palette** — line, conditional, hit-count, **logpoints**,
  **column**, **function**, **exception** (filters and named types) and
  **data breakpoints / watchpoints**.
- **Tree-based debug panel** — sessions, threads, call stacks, scopes,
  variables, watch expressions and breakpoints in one navigable view.
- **Inline variable values** — see values right in the source while stopped,
  in several placement styles.
- **Integrated run panel** — REPL, program output, adapter terminal and an
  optional raw-DAP-message log, paged in a single split.
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
- A debug adapter for the target language (see [Built-in adapters](#built-in-adapters)).
  Many are trivially installed via [mason.nvim](https://github.com/williamboman/mason.nvim) —
  ezdap auto-resolves several of them from Mason's install path.

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

Then start debugging. The fastest path is `:Debug quick_run`, which launches
(or attaches to) an adapter using one of its named profiles, filled in
with a few `input=value` arguments:

```vim
" Launch a native binary under codelldb
:Debug quick_run codelldb launch command="./a.out --verbose"

" Debug a Python file
:Debug quick_run debugpy launch command="./main.py --verbose"

" Attach to a running process
:Debug quick_run debugpy attach pid=41234
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

## Built-in adapters

Adapters live in `require("ezdap.adapters")` as a plain `name → definition`
table. Any entry can be overridden, and new ones added — see
[Adding a custom adapter](#adding-a-custom-adapter).

| Adapter              | Language(s)          | Requests          | Tooling                                                       |
| -------------------- | -------------------- | ----------------- | ------------------------------------------------------------- |
| `debugpy`            | Python (local/remote)| launch / attach   | `debugpy` (auto-resolved from Mason, else system `python3`)   |
| `codelldb`           | C / C++ / Rust       | launch / attach   | `codelldb` on `PATH`                                          |
| `lldb`               | C / C++ / Rust       | launch / attach   | `lldb-dap` on `PATH`                                          |
| `gdb`                | C / C++ / native     | launch / attach   | `gdb` (>= 14, `--interpreter=dap`) on `PATH`                  |
| `delve`              | Go                   | launch / attach   | `dlv` on `PATH` (`dlv dap`)                                   |
| `netcoredbg`         | .NET / C#            | launch / attach   | `netcoredbg` on `PATH`                                        |
| `js-debug`           | JavaScript / TS / Node | launch / attach | `js-debug-adapter` (auto-resolved from Mason), `node`        |
| `bash-debug-adapter` | Bash                 | launch            | `bash-debug-adapter` on `PATH`                                |
| `php-debug-adapter`  | PHP (Xdebug)         | launch (listens)  | `php-debug-adapter` on `PATH`                                 |
| `local-lua-debugger` | Lua                  | launch            | `local-lua-debugger-vscode` (auto-resolved from Mason), `node` |
| `remote`             | any                  | attach            | connects to a DAP server on `host:port`                      |
| `java-debug-server`  | Java                 | attach            | external debug server (e.g. via `nvim-jdtls`)                |

Run `:checkhealth ezdap` to see which adapters have their tooling available on
the current machine.

## Starting a debug session

ezdap gives you several ways to launch or attach, from one-liners to
version-controlled run files.

### `:Debug quick_run` — one-shot launch/attach

Each adapter declares one or more named **profiles** (`launch_program`,
`attach_process`, `remote`, …), each declaring the **inputs** it accepts. Supply them as
`input=value` tokens; the adapter and profile name come first as bare
words:

```vim
:Debug quick_run <adapter> <profile> [input=value ...]
```

Inputs are specific to each adapter/profile — e.g. every `launch_program`
profile takes `command` (a full shell command line, split into the
adapter's own program/args fields) plus `cwd` and `env`; an `attach_process`
profile takes `pid`, and a `remote` one takes `host`/`port`. Each input
declares a **type** that decides how the value is read: `file`/`dir`/`cwd`
(path expansion), `map` (`A=1,B=2`), `list` (`a,b`) and
`integer`/`port`/`boolean`. An input left out is simply omitted from the
request, unless the profile marks it required.

Tab-completion offers adapters, then profile names, then the inputs
available for the chosen profile — and, once you type `=`, path
completion for inputs whose type is path-like.

### Run files — versionable debug configs

A run file is a Lua file that returns a single task table. Keep it in the
project and run it on demand. Two shapes are accepted, told apart by
whether a `profile` or a `configuration` field is present.

**Profile-based** — names a `profile` and answers its declared inputs under
`parameters`. It resolves exactly like `:Debug quick_run`, so a required input
left unset is an error and an attach with no `pid` pops a process picker:

```lua
-- debug.lua
return {
  name       = "debug app",    -- run/panel label (defaults to "debug")
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

- **Completion knows what to offer.** `:Debug quick_run lldb launch_program <Tab>`
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
  `A=1,B=2` in one and a table in the other). That is why `quick_run` and a run
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
path as `:Debug quick_run`. (Prefer the raw shape above instead? Just drop the
`profile`/`parameters` keys and write a `configuration` table by hand.)

### From Lua

Everything above is available programmatically:

```lua
local ezdap = require("ezdap")

-- Run a task table directly
ezdap.run({ adapter = "delve", request = "launch", parameters = { mode = "test" } })

-- The quick_run / run_file / new_run_file / rerun entry points, too
ezdap.quick_run({ "debugpy", "launch", "command=./main.py" })
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
:Debug breakpoint clear_all
```

Gutter signs distinguish each kind (verified vs. pending, conditional,
logpoint, disabled, exception). The full list of subcommands is in the
[command reference](#command-reference), and the sign glyphs are
[configurable](#configuration).

## The debug UI

### Debug panel (`:Debug view`)

The main panel is a tree of **sessions → threads → stack frames → scopes →
variables**, plus **watch expressions** and **breakpoints**. It opens
automatically when a session starts; open or focus it any time with `:Debug view`.

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

### Inline variable values

While stopped, ezdap renders variable values inline in the source. Choose the
placement with the `inline_vars` option (`inline`, `eol`, `eol_right_align`,
`right_align`, or `off`). See [Configuration](#configuration).

### Run panel (`:Debug panel`)

Each run gets a bottom split hosting its buffers, paged via a winbar:

- **Messages** — adapter/run progress
- **REPL** — evaluate DAP expressions interactively
- **Output** — the debuggee's output
- **Terminal** — when the adapter launches the debuggee in a terminal
- **DAP Messages** — raw protocol log (enable with `raw_messages = true` on the task)

```vim
:Debug panel            " toggle the run panel
:Debug panel next       " next tab (also: previous, jump)
:Debug panel clean      " drop finished runs
```

### Inspect, disassembly & REPL

```vim
:Debug inspect          " hover the value of the word under the cursor (or selected expression in visual mode)
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
:Debug stop             " (alias: :Debug terminate)
:Debug terminate_all
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

  -- Max characters shown for a value in the debug panel before truncation.
  debug_value_max_len = 30,
  -- Max call-stack frames shown (extended when the current frame is deeper).
  stack_trace_limit   = 10,
  -- Delay (ms) before clearing stale UI, to avoid flicker while stepping.
  antiflicker_delay   = 200,
  -- Max lines kept in Output / DAP-message buffers (0 = unlimited).
  output_max_lines    = 10000,

  -- Inline value placement: "inline" | "eol" | "eol_right_align" | "right_align" | "off"
  inline_vars         = "eol",

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
    exception_breakpoint_unsupported = "✗",
  },
})
```

## Command reference

Everything is under the `:Debug` command, with completion for every subcommand.

<details>
<summary><b><code>:Debug</code> subcommands</b></summary>

| Subcommand            | Description                                        |
| --------------------- | ------------------------------------------------- |
| `run_file [path]`     | Run a Lua task file, or pick from a directory     |
| `quick_run …`         | Launch/attach from `input=value` tokens           |
| `new_run_file …`      | Scaffold a run file from a profile's inputs        |
| `rerun`               | Re-launch the most recently run task              |
| `view`                | Open/focus the debug panel                        |
| `continue` / `continue_all` | Continue the active / every session         |
| `step_over` (`next`) / `step_in` / `step_out` | Stepping             |
| `step_into_targets`   | Pick a call target to step into                   |
| `step_back` / `reverse_continue` | Reverse debugging                      |
| `jump_to_cursor`      | Set the next statement to the cursor line         |
| `restart_frame`       | Restart the selected stack frame                  |
| `exception_info`      | Show details of the current exception             |
| `pause` / `restart`   | Pause / DAP-restart the session                   |
| `stop` (`terminate`) / `terminate_all` | Stop the active / every session  |
| `session` / `thread` / `terminate_thread` / `frame` | Selection pickers   |
| `inspect`             | Hover a value (word under cursor or selection)    |
| `disassemble`         | Open the disassembly view                         |
| `panel [action]`      | Run panel: `toggle` / `jump` / `next` / `previous` / `clean` |
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
| `clear_file` / `clear_all` / `clear_fn` | Bulk removal                    |
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
state, and which built-in adapters have their tooling installed.

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
map("n", "<leader>du", "<Cmd>Debug view<CR>",                 { desc = "Debug: focus panel" })
map("n", "<leader>dp", "<Cmd>Debug panel<CR>",                { desc = "Debug: toggle run panel" })
map("n", "<leader>dq", "<Cmd>Debug stop<CR>",                 { desc = "Debug: stop" })

-- Count-prefixed panel jump: `2<leader>dj` jumps to run panel tab 2.
-- With no count, `count1` defaults to 1, so a bare `<leader>dj` jumps to tab 1.
map("n", "<leader>dj", function() vim.cmd("Debug panel jump " .. vim.v.count1) end, { desc = "Debug: jump to run panel tab [count]" })

map("n", "<leader>di", "<Cmd>Debug inspect<CR>",              { desc = "Debug: inspect" })
map("x", "<leader>di", "<Cmd>Debug inspect<CR>",              { desc = "Debug: inspect selection" })
```

## Adding a custom adapter

`require("ezdap.adapters")` is a plain `name → definition` table, and it is
writable. Adding an adapter is assigning a key; overriding a built-in is
assigning an existing one. There is no registration call and no `adapters`
option in `setup()` — do it anywhere after the plugin loads:

```lua
local adapters = require("ezdap.adapters")

adapters.myadapter = {
  command = { "my-dap-adapter", "--stdio" },  -- stdio adapter: spawned, framed over its pipes
}
```

That is already enough to run:

```lua
require("ezdap").run({
  adapter    = "myadapter",
  request    = "launch",
  parameters = { program = "/path/to/thing", stopOnEntry = true },
})
```

…or from a run file, using the raw shape (`adapter` + `configuration`) described
in [Run files](#run-files--versionable-debug-configs). `parameters` is sent to
the adapter as the DAP launch/attach body verbatim — ezdap never rewrites the
keys, so use whatever the adapter's own documentation calls them.

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
`ctx.add_bufnr(bufnr, opts)` so they show up in the run panel, and must call
`callback(err, state)` exactly once — an `err` string aborts the run. Whatever
`state` it passes comes back as the second argument to `teardown`, which is
where you stop what you started:

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
server. [delve](lua/ezdap/adapters/delve.lua) is a compact worked example: it
spawns `dlv dap`, scrapes the "DAP server listening at:" line, and points the
connection there.

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
        command       = { type = "string",  required = true, description = "command line to debug" },
        cwd           = { type = "string",  format = "cwd",  description = "working directory" },
        env           = { type = "table",   format = "map",  description = "environment variables" },
        stop_on_entry = { type = "boolean",                  description = "break at program entry" },
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
:Debug quick_run myadapter launch_program command=./a.out cwd=/src stop_on_entry=true
:Debug new_run_file myadapter launch_program
```

How the pieces fit:

- **`inputs`** — one entry per accepted value, keyed by the name typed on the
  command line or written in a run file's `parameters`. `type` is what `build`
  receives (`string`, `boolean`, `integer`, `number`, `table`); `format` says how
  the authored forms reach that type and drives completion — `file`/`dir`/`cwd`
  (path expansion), `host`, `port` (range-checked), `map` (`A=1,B=2` → table),
  `list` (`a,b` → table). Omit `format` and the value is read by `type` alone.
  The full vocabulary is one row per format in
  [inputs.lua](lua/ezdap/inputs.lua) — every consumer reads those rows, so a new
  format is a single addition there, never a `if format == …` anywhere else.
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

Because `quick_run`, `new_run_file` and profile-based run files all resolve
through the same `inputs` → `build` path, a profile is described in exactly one
place and the three cannot drift apart. The built-in adapters under
[lua/ezdap/adapters/](lua/ezdap/adapters/) are the reference: `lldb.lua` for a
plain stdio adapter with several profiles, `delve.lua` for a spawn-then-connect
`setup`, `remote.lua` for a profile that configures `connect` instead of
`params`.

Custom adapters are picked up by `:checkhealth ezdap` too — it reports whether
each definition's `command` is present on the current machine.

## Contributing

Contributions are welcome. See [DEVELOPMENT.md](DEVELOPMENT.md) for the
architecture overview, module map, and conventions.
