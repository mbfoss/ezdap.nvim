# ndebug.nvim

A **Debug Adapter Protocol (DAP) client for Neovim**: pause a program on a
breakpoint, inspect variables and the call stack, and step through execution
without leaving the editor. It implements the protocol directly, and works with
[any debugger](https://wiki.archlinux.org/title/Debug_adapter_protocol) that
speaks DAP.

<!-- panvimdoc-ignore-start -->

## Features

- **Breakpoints**: line, conditional, hit-count, logpoint, column, function,
  exception (filters and named types) and data breakpoints / watchpoints, 
  all synced live to running sessions and marked with distinct gutter glyphs.
- **Debug view**: one side window with sessions, threads, run buffers, call
  stacks, scopes, variables, watch expressions and breakpoints in a single tree,
  with fold controls and an in-view keymap for inspecting, editing and removing
  entries.
- **Inline variable values**: values shown in the source while stopped, in
  several placements (requires a treesitter parser).
- **Run buffers**: each run gets its own REPL (with Tab completion), program
  output, adapter terminal and progress log, sharing a split panel window.
- **Execution control**: step over/in/out, jump-to-cursor, restart frame,
  step-into-targets, reverse debugging, exception info, disassembly view and
  instruction-level stepping.
- **Inspection**: hover the word under the cursor or a visual selection, as an
  expandable tree or as the full value in one shot.
- **Parallel sessions**: several debuggees at once, each with its own row and
  buffers, with pickers to switch sessions, threads and frames.
- **Project-scoped persistence**: breakpoints and watch expressions saved per
  project and restored automatically.

## Demo

![Breakpoints and stepping](https://raw.githubusercontent.com/mbfoss/ndebug.nvim/assets/demos/01-breakpoint-step.gif)

[More demos](DEMO.md): conditions and logpoints, exception breakpoints, the
REPL, watch expressions, parallel sessions, persistence.

---

## Table of contents

- [Features](#features)
- [Demo](#demo)
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
- [Writing an adapter definition](WRITING-DEFINITIONS.md)
- [License](#license)
- [Contributing](#contributing)

---

<!-- panvimdoc-ignore-end -->

## Requirements

- Neovim >= 0.10
- A debug adapter for the target language (gdb, debugpy, ...). Many are
  available through [mason.nvim](https://github.com/mason-org/mason.nvim),
  which is not required.

## Installation

- Install it with any plugin manager, then call `require("ndebug").setup()` once
from your config. Nothing is registered until you do.

- Adapter definitions come from one of two places. Either install
[ndebug-adapters](https://github.com/mbfoss/ndebug-adapters.nvim) alongside it,
which registers ready-made definitions for the common debuggers and is what the
examples below assume, or drop a single definition file
([your own](#adding-a-custom-adapter), or one copied from ndebug-adapters) into
an `ndebug-adapters/` directory on the runtimepath, such as
`~/.config/nvim/ndebug-adapters/`.

<details open>
<summary><b>Native packages / <code>vim.pack</code></b></summary>

```lua
-- Neovim 0.12+
vim.pack.add({
  "https://github.com/mbfoss/ndebug.nvim",
  "https://github.com/mbfoss/ndebug-adapters.nvim",  -- ready-made adapter definitions
})

require("ndebug").setup({}) -- required; pass options here
```
</details>

<details>
<summary><b>lazy.nvim</b></summary>

```lua
{
  "mbfoss/ndebug.nvim",
  dependencies = { "mbfoss/ndebug-adapters.nvim" },  -- ready-made adapter definitions
  opts = {}, -- required; passed to require("ndebug").setup()
}
```
</details>

`setup()` is the one call you have to make: it applies your options, registers
the `:Ndebug` command and installs the persistence autocmds. `setup({})` with no
options is fine, and everything left out keeps its default. 

## Quick start

`:Ndebug run` launches or attaches to an adapter using one of its named modes,
filling in its inputs with `--name value` flags:

```vim
" Launch a native binary under codelldb
:Ndebug run codelldb binary --command ./program\ argument

" Debug a Python file
:Ndebug run debugpy script --command ./main.py\ argument

" Attach to a running process (opens process selector)
:Ndebug run codelldb attach
```

Set a breakpoint on the current line and step through the program:

```vim
:Ndebug breakpoint          " toggle a breakpoint at the cursor
:Ndebug continue            " run to the next breakpoint
:Ndebug step_over           " step over the current line
```

The debug view opens automatically when a session starts, showing the call
stack, variables and breakpoints. See [The debug UI](#the-debug-ui) and
[Keymaps example](#keymaps-example) for a convenient setup.

## Adapters

To debug a language, ndebug needs an **adapter definition**: a description of how
to reach that language's debug adapter. It is one `ndebug-adapters/<name>.lua`
file on the runtimepath, keyed by its filename stem.

Each adapter declares one or more named **modes** (`binary`, `script`,
`attach`, `remote`, …), and each mode declares the **inputs** it accepts.

The [ndebug-adapters](https://github.com/mbfoss/ndebug-adapters.nvim) plugin
ships definitions for the common debuggers; installing it makes those adapters
available.

`:Ndebug adapter_info` reports which modes an adapter has and what inputs each
mode takes:

```vim
:Ndebug adapter_info            " every available adapter, by name
:Ndebug adapter_info codelldb   " that adapter's modes and each mode's inputs
```

ndebug itself ships **one** adapter, `remote`, a generic TCP attach that connects
to a DAP server already listening on `host:port`, through its single `connect`
mode:

```vim
:Ndebug run remote connect --host 127.0.0.1 --port 4711
```

A definition is read on first use, such as a `:Ndebug run <adapter> ...`.
Listing adapters does not load their definitions (`:Ndebug adapter_info`,
`:checkhealth ndebug`); `:Ndebug adapter_info <adapter>` does, and reports the
modes it supports along with any error in the definition.

## Starting a debug session <!-- tag: sessions -->

There are two ways to start a debug session: from the command line, or from a
run file.

### From the command line <!-- tag: run-command -->

```vim
:Ndebug run <adapter> <mode> [--input value ...]
```

Each input is a `--name` flag followed by its values: exactly one for a scalar,
one per argument for a `list`, and one `KEY=VALUE` per argument for a `map`.
Arguments split on whitespace — quotes are *not* special, and a value containing
a space is written `\ `, as in `:Ndebug run debugpy script --command ./main.py\
--verbose --cwd /tmp/my\ project`. Nothing else is escaped: a comma or backslash
is literal, and it is a map's first `=` that separates its key from its value. A
token that starts with `--` always opens the next input, so a `list` entry may
not begin with `--`:

```vim
:Ndebug run gdb binary --command ./app --env RUST_LOG=debug NO_COLOR=1
:Ndebug run remote connect --host 127.0.0.1 --port 4711
```

**Tab-completion** offers adapters, then mode names, then the inputs available
for the chosen mode as `--name`, and a value once a flag is open: paths for the
path-like ones, `true`/`false` for a boolean.

### Run files

A run file is a Lua file returning a table of session parameters, the Lua
equivalent of the `:Ndebug run ...` arguments:

```lua
-- debug.lua
return {
  name       = "debug app",    -- run label (defaults to "debug")
  adapter    = "codelldb",     -- an entry in require("ndebug").adapters
  mode       = "binary",       -- one of the adapter's named modes
  parameters = {               -- answers to the mode's declared inputs
    command = "./build/app --verbose",
    cwd     = vim.fn.getcwd(),
  },
}
```

Use `:Ndebug run_file <file/dir>` to load and start a session from a run file.

```vim
:Ndebug run_file debug.lua
:Ndebug run_file ./debug/   " picker over the folder's run files
```

### `:Ndebug new_run_file` <!-- tag: new-run-file -->

Generate a run file from one of an adapter's modes. Required inputs are written
active; every other input is listed commented out with its description:

```vim
:Ndebug new_run_file codelldb binary
" → writes <project root>/codelldb_launch.lua and opens it
```

Fill in the `parameters`, then `:Ndebug run_file` it; it resolves through the
same path as `:Ndebug run`.

### `:Ndebug adapter_info` <!-- tag: adapter-info-command -->

Load an adapter's definition, check it, and show what it accepts in a markdown
float rendered from the definition itself. A `status` section gives where the
executable resolved to and anything wrong with the definition, and is left out
when there is nothing to report. A `modes` section follows, with one subsection
per mode: its request kind, its description, and a table of every input with its
type and meaning. Required inputs sort first and are marked `[required]`.

### From Lua <!-- tag: lua-api -->

Everything above is available programmatically:

```lua
local ndebug = require("ndebug")

-- The run_mode / run_file / new_run_file / rerun entry points
ndebug.run_mode("debugpy", "script", { command = "./main.py" })
ndebug.run_file("debug.lua")
ndebug.rerun()
```

## Breakpoints

All breakpoint operations are grouped under `:Ndebug breakpoint <sub>`.
Breakpoints work before a session starts and are synced live to running
sessions.

```vim
:Ndebug breakpoint               " toggle a line breakpoint at the cursor
:Ndebug breakpoint toggle        " the same, spelled out
:Ndebug breakpoint set           " add a line breakpoint, never remove one
:Ndebug breakpoint condition     " condition + hit condition (prompts)
:Ndebug breakpoint logpoint      " logpoint (prompts for log message)
:Ndebug breakpoint set cond=x>3  " conditional breakpoint
:Ndebug breakpoint set col=42    " column breakpoint at column 42
:Ndebug breakpoint column        " toggle a column bp at the cursor word
:Ndebug breakpoint fn <name>     " function breakpoint by name
:Ndebug breakpoint data          " watchpoint on a variable/expression
:Ndebug breakpoint list          " fuzzy-pick and jump to any breakpoint
:Ndebug breakpoint exception_filter              " toggle an adapter filter
:Ndebug breakpoint exception_type <name> [mode]  " named exception type
```

`set` is the non-interactive form: `col=` takes a column number, and
`cond=`/`hit=`/`log=` write the condition, hit condition and log message. Values
are split by Vim's rules, so escape spaces (`cond=x\ >\ 3`), and an empty value
clears a field.

`column` toggles a column breakpoint at the start of the word under the cursor.
A breakpoint already at that column is removed.

Every per-breakpoint subcommand (`condition`, `logpoint`, `remove`, the enable
state) acts on the breakpoint the cursor resolves to. A column breakpoint under
the cursor always wins; otherwise the editing subcommands assume the line
breakpoint, while `remove` asks, so a line carrying both never loses the wrong
one to a guess.

Enable/disable without removing, and clear in bulk:

```vim
:Ndebug breakpoint toggle_enabled  " enable/disable the one at the cursor
:Ndebug breakpoint disable_all
:Ndebug breakpoint clear_file      " remove every breakpoint in the file
:Ndebug breakpoint clear_all       " remove every breakpoint everywhere
```

`clear_all` removes all source, function and exception-type breakpoints across
every file. Adapter exception filters have no removed state, so they are turned
off instead.

Gutter signs distinguish each kind (verified or pending, conditional,
logpoint, disabled, exception). The full list of subcommands is in the
[Command reference](#command-reference), and the glyphs are set with the
`symbols` option in [Configuration](#configuration).

## The debug UI <!-- tag: ui -->

### Debug view <!-- tag: debug-view -->

The debug view is a tree of **sessions → threads → stack frames → scopes →
variables**, plus **watch expressions** and **breakpoints**. It opens
automatically when a session starts; open or focus it any time with
`:Ndebug` (or `:Ndebug view`). `:Ndebug view hide` closes it, and
`:Ndebug view toggle` does one or the other.

Inside the view:

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

### The panel <!-- tag: panel -->

A run spawns several buffers: Terminal, Output, REPL, its progress Log, DAP
messages. They share one bottom split, the panel, which holds whichever of them
ranks highest: Terminal over Output, Output over REPL, REPL over Log. It opens
on the run's first buffer, follows along as higher-priority buffers appear or
the shown one is deleted, and closes with the run's last buffer. `:Ndebug panel`
toggles it; `panel_auto_open` and `panel_height_ratio` adjust it.

Each run keeps its own log, `ndebug://<number>/<name>:log`, wiped with the run. 
Any of a run's buffers can be reached by name; see [Run buffers](#run-buffers).

### Inline variable values <!-- tag: inline-values -->

While stopped, ndebug renders variable values inline in the source. Choose the
placement with the `inline_vars` option (`inline`, `eol`, `eol_right_align`,
`right_align`, or `off`). See [Configuration](#configuration).

### Run buffers

A run's buffers are listed under its session row in the debug view; `<CR>` on one
opens it in a regular window:

- **REPL**: Debugger interactive console
- **Output**: the debuggee's output
- **Terminal**: when the adapter launches the debuggee in a terminal

Adapters that offer an external console (`console = externalTerminal`,
codelldb's `terminal = external`) launch the debuggee in a terminal emulator of
its own instead, chosen by the `external_terminal` option; see
[Configuration](#configuration). If that option is unset or the emulator cannot be
spawned, the request fails rather than falling back to an integrated terminal.

```vim
:Ndebug clean            " drop finished runs and wipe their buffers
```

### Inspect, disassembly & REPL <!-- tag: inspect-repl -->

```vim
:Ndebug inspect          " hover the word under the cursor (or, in visual
                        " mode, the selected expression)
:Ndebug value            " same target, but shows the full value straight
                        " away instead of the expandable tree
:Ndebug disassemble      " open the disassembly view for the current frame
:Ndebug exception_info   " details of the exception at the current stop
```

In the disassembly view, `<CR>` opens the corresponding source line and `K`
shows the instruction reference. Breakpoints and stepping become
instruction-level while it is focused.

### Right-click menu <!-- tag: popup-menu -->

While a session is live, ndebug adds a **Debug Inspect** entry to the right-click
menu, which inspects the word clicked on (or the selection, in visual mode). It
appears with the first session and is removed with the last, so the stock menu
is untouched when nothing is being debugged. Set `popup_menu = false` in
[Configuration](#configuration) to leave the menu alone entirely.

The entry needs a GUI or a terminal with mouse support.

## Stepping & execution control <!-- tag: stepping -->

```vim
:Ndebug continue         " continue the active session
:Ndebug continue_all     " continue every session
:Ndebug step_over        " (alias: :Ndebug next)
:Ndebug step_in
:Ndebug step_out
:Ndebug step_into_targets" pick which call on the line to step into
:Ndebug step_back        " reverse debugging (adapter permitting)
:Ndebug reverse_continue
:Ndebug jump_to_cursor   " set the next statement to the cursor line
:Ndebug restart_frame    " restart the selected stack frame
:Ndebug pause
:Ndebug restart          " DAP restart request on the live session
:Ndebug stop             " stop the active session
:Ndebug stop_all         " stop every session
```

Stepping granularity follows the focused window: line-wise everywhere, and
instruction-wise while the disassembly view is current.

Switch the active target with pickers:

```vim
:Ndebug session          " choose the active session
:Ndebug thread           " choose the active thread
:Ndebug frame            " choose the active stack frame
```

## Configuration <!-- tag: config -->

Pass options to `setup()`. Defaults when `setup({})` is called are:

```lua
require("ndebug").setup({
  -- Project detection: the nearest ancestor holding one of these is
  -- the root.
  root_markers        = { ".git" },
  -- Per-project state file, written at the project root.
  data_filename       = ".ndebug.json",

  -- Adapters to make available, by name. Unset (the default) leaves every
  -- registered adapter available; a list narrows the registry to exactly
  -- those names, hiding the rest from listing, completion and `:Ndebug run`.
  enabled_adapters = nil, -- { "debugpy", "codelldb" },

  -- Max call-stack frames shown (extended when the frame is deeper).
  stack_trace_limit   = 10,
  -- Delay (ms) before clearing stale UI, to avoid flicker while stepping.
  antiflicker_delay   = 200,
  -- Max lines kept in Output / DAP-message buffers (0 = unlimited).
  output_max_lines    = 10000,
  -- Open the panel as soon as a run registers a buffer.
  panel_auto_open = true,
  -- Height of the panel, as a fraction of the editor.
  panel_height_ratio = 0.25,
  -- Width of the debug view on first open, as a fraction of the
  -- editor's columns.
  debug_view_width_ratio = 0.2,
  -- Side the debug view splits off on: "left" | "right".
  debug_view_position = "left",

  -- Inline value placement: "inline" | "eol" | "eol_right_align"
  -- | "right_align" | "off"
  inline_vars         = "eol",

  -- Log every DAP message to a "dap" buffer. For debugging ndebug or an
  -- adapter; leave off otherwise.
  raw_messages        = false,

  -- Terminal emulator (command + args) used when an adapter asks to
  -- run the debuggee in an external terminal; its command line is
  -- appended. Unset, an integrated terminal is used instead.
  -- E.g. { "alacritty", "-e" }.
  -- external_terminal = { "wezterm", "start", "--" },

  -- Add a "Debug Inspect" entry to the right-click menu while a session is
  -- live
  popup_menu          = true,

  -- Glyphs for each debug state, in the gutter and the debug view alike.
  symbols = {
    debug_frame              = "▶",   -- current execution position
    active_breakpoint        = "●",   -- enabled + verified
    inactive_breakpoint      = "○",   -- enabled, not yet verified
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

## Command reference <!-- tag: commands -->

Everything is under the `:Ndebug` command, with completion for every subcommand.
Bare `:Ndebug`, with no subcommand, opens the debug view.

To use another name such as `:Debug`, register an alias after `setup()`. It
forwards arguments, range and completion to `:Ndebug`.

```lua
require("ndebug").create_cmd_alias("Debug")
```

<details>
<summary><b><code>:Ndebug</code> subcommands</b></summary>

| Subcommand            | Description                                        |
| --------------------- | ------------------------------------------------- |
| `run …`               | Launch/attach from `--input value` flags          |
| `run_file [path]`     | Run a Lua run file, or pick from a directory     |
| `new_run_file …`      | Generate a run file from a mode's inputs        |
| `adapter_info [adapter] [mode]` | Report an adapter's modes, inputs and tooling |
| `rerun`               | Re-launch the most recent run                     |
| *(none)* / `view`     | Open/focus the debug view                         |
| `view toggle` / `view hide` | Close the debug view if open / close it       |
| `panel`               | Toggle the panel                                  |
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
<summary><b><code>:Ndebug breakpoint</code> subcommands</b></summary>

| Subcommand           | Description                            |
| -------------------- | -------------------------------------- |
| `toggle` (default)   | Toggle a line breakpoint at the cursor             |
| `set [col=N] [cond=…] [hit=…] [log=…]` | Create or update a breakpoint; bare, a plain line breakpoint |
| `column`             | Toggle a column breakpoint at the cursor word      |
| `remove`             | Remove the breakpoint at the cursor                |
| `condition`          | Set condition + hit condition                      |
| `logpoint`           | Set/clear a log message (logpoint)                 |
| `enable` / `disable` / `toggle_enabled` | Per-breakpoint enable state     |
| `enable_all` / `disable_all` | Bulk enable/disable                        |
| `clear_file` / `clear_fn` | Clear the current file / function breakpoints |
| `clear_all`          | Clear all; disable exception filters |
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
that root (`.ndebug.json` by default), using project-relative paths so it stays
portable.

State is saved on leaving a project (cwd change) and on exit, and reloaded on
entering one. Outside any project, ndebug warns once that state will not be
persisted. The current project is reported by:

```vim
:Ndebug project
```

> Consider adding `.ndebug.json` to the project's `.gitignore`, or commit it to
> share breakpoints across a team.

## Health check <!-- tag: health -->

```vim
:checkhealth ndebug
```

Reports the Neovim version, whether the plugin is initialised, the resolved
project state, and which adapters are available.

## Keymaps example <!-- tag: keymaps -->

ndebug ships no global keymaps; any layout works. An example based on the
function keys:

```lua
vim.keymap.set("n", "<F5>", "<Cmd>Ndebug continue<CR>", { desc = "Debug: continue" })
vim.keymap.set("n", "<F10>", "<Cmd>Ndebug step_over<CR>", { desc = "Debug: over" })
vim.keymap.set("n", "<F11>", "<Cmd>Ndebug step_in<CR>", { desc = "Debug: step in" })
vim.keymap.set("n", "<F12>", "<Cmd>Ndebug step_out<CR>", { desc = "Debug: step out" })
vim.keymap.set("n", "<F9>", "<Cmd>Ndebug breakpoint<CR>", { desc = "Debug: bp" })

vim.keymap.set("n", "<leader>dc", "<Cmd>Ndebug breakpoint condition<CR>", { desc = "Debug: conditional breakpoint" })
vim.keymap.set("n", "<leader>dl", "<Cmd>Ndebug breakpoint logpoint<CR>", { desc = "Debug: logpoint" })
vim.keymap.set("n", "<leader>dr", "<Cmd>Ndebug rerun<CR>", { desc = "Debug: re-run" })
vim.keymap.set("n", "<leader>du", "<Cmd>Ndebug view<CR>",  { desc = "Debug: focus view" })
vim.keymap.set("n", "<leader>dq", "<Cmd>Ndebug stop<CR>",  { desc = "Debug: stop" })

vim.keymap.set("n", "<leader>di", "<Cmd>Ndebug inspect<CR>", { desc = "Debug: inspect" })
vim.keymap.set("x", "<leader>di", "<Cmd>Ndebug inspect<CR>", { desc = "Debug: inspect" })
```

## Adding a custom adapter <!-- tag: custom-adapters -->

For a debugger already covered by
[ndebug-adapters](https://github.com/mbfoss/ndebug-adapters.nvim), install that
plugin, or copy the one definition file you need out of it into
`ndebug-adapters/` in your configuration folder.

More generally, a definition is a single Lua file under an `ndebug-adapters/`
directory anywhere on the runtimepath, returning a table. It needs a way to
reach the adapter (a `command` to spawn, or a `host`/`port` to connect to) and
`modes`, each naming the `inputs` it accepts and a `build` that turns them into
the native DAP body:

```lua
-- ~/.config/nvim/ndebug-adapters/myadapter.lua
---@type ndebug.AdapterDef
return {
  command = { "my-dap-adapter", "--stdio" },
  modes   = {
    binary = {
      description = "debug an executable",
      request     = "launch",
      inputs      = {
        program = { required = true, completion = "file", description = "executable to debug" },
      },
      build = function(inputs)
        return { program = require("ndebug.shared").normalize_path(inputs.program), stopOnEntry = true }
      end,
    },
  },
}
```

`require("ndebug").adapters` is writable, so a definition can also be registered
by hand from a config file (`require("ndebug").adapters.myadapter = { … }`)
instead of from a file. `ndebug.available_adapters()` lists those too, unless
`enabled_adapters` is set and leaves the name out, which withholds it from the
registry entirely.

<!-- panvimdoc-ignore-start -->

The full contract is in [WRITING-DEFINITIONS.md](WRITING-DEFINITIONS.md).

<!-- panvimdoc-ignore-end -->

<!-- vimdoc-only
The full contract is in WRITING-DEFINITIONS.md in the repository.
-->

Added adapters are listed by `:checkhealth ndebug` and `ndebug.available_adapters()`
too, and document themselves: `:Ndebug adapter_info myadapter` renders the modes
and inputs declared above, and, when the definition names a `command`, whether
it is present on this machine.

### Why inputs and not raw DAP <!-- tag: inputs -->

Modes declare `inputs` rather than taking a raw DAP body, which buys:

- **Completion.** `:Ndebug run lldb binary <Tab>` lists that mode's inputs as
  `--name`, and `--command <Tab>` completes paths because the input is declared
  path-like.
- **Validation before launch.** Missing required inputs, a port outside
  0–65535, or a malformed `KEY=VALUE` are reported during resolution, with the
  input named, instead of as adapter stderr.
- **Generated run files.** `:Ndebug new_run_file` writes a run file from
  `inputs`, including each field's description, so no template can diverge from
  what the adapter accepts.
- **One value, two entry points.** An input can be supplied on the command line
  or in a run file (`env` as `--env A=1 B=2` or as a table); both resolve through
  the same declaration into the same `build`.
- **Mode-supplied defaults.** A mode can act on a missing input instead of
  omitting the field.

## License <!-- tag: license -->

[MIT](LICENSE).

<!-- panvimdoc-ignore-start -->

## Contributing <!-- tag: contributing -->

Contributions are welcome.

<!-- panvimdoc-ignore-end -->
