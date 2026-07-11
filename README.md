# easydap.nvim

A batteries-included **Debug Adapter Protocol (DAP) client for Neovim**.

easydap speaks the DAP wire protocol directly — there is **no `nvim-dap` dependency**.
It manages adapter processes and connections, tracks your sessions and
breakpoints, and renders a clean, tree-based debug UI. Point it at a debug
adapter, set a breakpoint, and start stepping.

> **Status:** easydap is under active development. The core is usable day to day,
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
- [Recommended keymaps](#recommended-keymaps)
- [Adding your own adapter](#adding-your-own-adapter)
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
- **Inline variable values** — see values right in your source while stopped,
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
- **`:checkhealth easydap`** — verifies your Neovim version and adapter tooling.

## Requirements

- **Neovim >= 0.10**
- A debug adapter for your language (see [Built-in adapters](#built-in-adapters)).
  Many are trivially installed via [mason.nvim](https://github.com/williamboman/mason.nvim) —
  easydap auto-resolves several of them from Mason's install path.

## Installation

easydap has no plugin dependencies. Install it with your plugin manager of choice
and call `setup()`.

<details open>
<summary><b>lazy.nvim</b></summary>

```lua
{
  "mbfoss/easydap.nvim",
  opts = {},           -- passed to require("easydap").setup()
}
```
</details>

<details>
<summary><b>packer.nvim</b></summary>

```lua
use {
  "mbfoss/easydap.nvim",
  config = function()
    require("easydap").setup()
  end,
}
```
</details>

<details>
<summary><b>Native packages / <code>vim.pack</code></b></summary>

```lua
-- Neovim 0.12+
vim.pack.add({ "https://github.com/mbfoss/easydap.nvim" })
require("easydap").setup()
```

Or clone into a package directory and `require("easydap").setup()` from your config:

```sh
git clone https://github.com/mbfoss/easydap.nvim \
  ~/.local/share/nvim/site/pack/plugins/start/easydap.nvim
```
</details>

Calling `setup()` is required — it registers the `:Debug` command, wires up
persistence, and initialises the UI.

## Quick start

```lua
require("easydap").setup()
```

Then start debugging. The fastest path is `:Debug quick_run`, which launches
(or attaches to) an adapter with a few `role=value` arguments:

```vim
" Launch a native binary under codelldb
:Debug quick_run codelldb launch target=./a.out args=--verbose

" Debug a Python file
:Debug quick_run debugpy launch target=./main.py

" Attach to a running process
:Debug quick_run debugpy attach pid=41234
```

Set a breakpoint on the current line and step through your program:

```vim
:Debug breakpoint          " toggle a breakpoint at the cursor
:Debug continue            " run to the next breakpoint
:Debug step_over           " step over the current line
```

The debug panel opens automatically when a session starts, showing the call
stack, variables and breakpoints. See [The debug UI](#the-debug-ui) and
[Recommended keymaps](#recommended-keymaps) to make this comfortable.

## Built-in adapters

Adapters live in `require("easydap.adapters")` as a plain `name → definition`
table. You can override any of them or add your own — see
[Adding your own adapter](#adding-your-own-adapter).

| Adapter              | Language(s)          | Requests          | Tooling                                                       |
| -------------------- | -------------------- | ----------------- | ------------------------------------------------------------- |
| `debugpy`            | Python               | launch / attach   | `debugpy` (auto-resolved from Mason, else system `python3`)   |
| `debugpy-remote`     | Python (remote)      | attach            | as `debugpy`; connects to a remote debugpy endpoint          |
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

Run `:checkhealth easydap` to see which adapters have their tooling available on
your machine.

## Starting a debug session

easydap gives you several ways to launch or attach, from one-liners to
version-controlled run files.

### `:Debug quick_run` — one-shot launch/attach

Fill an adapter's native fields with portable `role=value` tokens. The adapter
and request come first as bare words, then any roles:

```vim
:Debug quick_run <adapter> <launch|attach> [role=value ...]
```

Roles map onto whatever native keys the adapter uses:

| Role     | Meaning                       | Used by            |
| -------- | ----------------------------- | ------------------ |
| `target` | program / module / file       | launch             |
| `args`   | program arguments             | launch             |
| `cwd`    | working directory             | launch             |
| `env`    | environment (`A=1,B=2`)       | launch             |
| `pid`    | process id to attach to       | attach             |
| `host`   | host to connect to            | attach             |
| `port`   | port to connect to            | attach             |

Tab-completion offers adapters, requests, and the roles available for each.

### Run files — versionable debug configs

A run file is a Lua file that returns a single task table. Keep it in your
project and run it whenever you need it:

```lua
-- debug.lua
return {
  name       = "debug app",       -- run/panel label (defaults to "debug")
  adapter    = "codelldb",        -- an entry in require("easydap.adapters")
  request    = "launch",          -- "launch" or "attach"
  parameters = {                  -- the adapter's native launch/attach body, sent verbatim
    program = "./build/app",
    args    = { "--verbose" },
    cwd     = "${workspaceFolder}",
  },
}
```

Run it — pass a file, or a **directory** to pick from its `.lua` files:

```vim
:Debug run_file debug.lua
:Debug run_file ./debug/         " opens a picker over the folder's run files
:Debug rerun                     " re-launch the most recently run task
```

`parameters` is the adapter's **raw** DAP launch/attach body, sent as-is. See
each adapter's upstream documentation for the fields it accepts.

### `:Debug new_run_file` — scaffold a run file

Don't remember an adapter's fields? Generate a ready-to-edit run file,
pre-populated from the adapter's schema with defaults, placeholders and inline
descriptions:

```vim
:Debug new_run_file codelldb launch
" → writes <project root>/codelldb_launch.lua and opens it
```

Edit the fields, then `:Debug run_file` it.

### From Lua

Everything above is available programmatically:

```lua
local easydap = require("easydap")

-- Run a task table directly
easydap.run({ adapter = "delve", request = "launch", parameters = { mode = "test" } })

-- Convenience: launch a program under an adapter (maps program/args for you)
easydap.run_target("codelldb", "./a.out", { "--verbose" })

-- The quick_run / run_file / new_run_file / rerun entry points, too
easydap.quick_run({ "debugpy", "launch", "target=./main.py" })
easydap.run_file("debug.lua")
easydap.rerun()
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

The main panel is a tree of your **sessions → threads → stack frames → scopes →
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

While stopped, easydap renders variable values inline in your source. Choose the
placement with the `inline_vars` option (`inline`, `eol`, `eol_right_align`,
`right_align`, or `off`). See [Configuration](#configuration).

### Run panel (`:Debug panel`)

Each run gets a bottom split hosting its buffers, paged via a winbar:

- **Messages** — adapter/run progress
- **REPL** — evaluate DAP expressions interactively
- **Output** — your program's output
- **Terminal** — when the adapter launches the debuggee in a terminal
- **DAP Messages** — raw protocol log (enable with `raw_messages = true` on the task)

```vim
:Debug panel            " toggle the run panel
:Debug panel next       " next tab (also: previous, jump)
:Debug panel clean      " drop finished runs
```

### Inspect, disassembly & REPL

```vim
:Debug inspect          " hover the value of the word under the cursor
:'<,'>Debug inspect     " inspect the visual selection
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
require("easydap").setup({
  -- Project detection: the nearest ancestor holding one of these marks the root.
  root_markers        = { ".git" },
  -- Per-project state file, written at the project root.
  data_filename       = ".easydap.json",

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
| `quick_run …`         | Launch/attach from `role=value` tokens            |
| `new_run_file …`      | Scaffold a run file from an adapter's schema       |
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
automatically. The project root is the nearest ancestor of your cwd containing a
`root_markers` entry (default `.git`); state is written to a single JSON file at
that root (`.easydap.json` by default), using project-relative paths so it stays
portable.

State is saved when you leave a project (cwd change) and on exit, and reloaded
when you enter a project. Outside any project, easydap warns once that state
won't be persisted. Check where you are with:

```vim
:Debug project
```

> Consider adding `.easydap.json` to your project's `.gitignore` (or commit it to
> share breakpoints with your team — your call).

## Health check

```vim
:checkhealth easydap
```

Reports your Neovim version, whether `setup()` has run, the resolved project
state, and which built-in adapters have their tooling installed.

## Recommended keymaps

easydap ships no global keymaps — wire up whatever suits you. A function-key
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
map("n", "<leader>dj", function()
  vim.cmd("Debug panel jump " .. vim.v.count1)
end, { desc = "Debug: jump to run panel tab [count]" })

map("n", "<leader>di", "<Cmd>Debug inspect<CR>",              { desc = "Debug: inspect" })
map("x", "<leader>di", "<Cmd>Debug inspect<CR>",              { desc = "Debug: inspect selection" })
```

## Adding your own adapter

`require("easydap.adapters")` is a plain table — add or override entries directly.
A minimal process-based adapter needs a `command` and a default `request`:

```lua
local adapters = require("easydap.adapters")

adapters.myadapter = {
  command = "my-debug-adapter",   -- string or string[]; launched over stdio
  request = "launch",
}
```

For a connection-based adapter, give a `host`/`port` instead of a `command`. An
optional `setup`/`teardown` pair lets you spawn a server, pick a free port, or
provision tooling before the session connects (this is how the `debugpy` and
`js-debug` adapters work).

To make an adapter work with `:Debug quick_run` and `:Debug new_run_file`, add a
`launch_schema`/`attach_schema` describing its native fields. See
[`lua/easydap/adapters.lua`](lua/easydap/adapters.lua) for fully worked examples,
and [DEVELOPMENT.md](DEVELOPMENT.md) for the schema format.

## Contributing

Contributions are welcome. See [DEVELOPMENT.md](DEVELOPMENT.md) for the
architecture overview, module map, and conventions.
