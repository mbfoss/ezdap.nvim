# easydap.nvim

A Debug Adapter Protocol (DAP) client for Neovim.

easydap speaks the DAP wire protocol directly. It does not depend on
`nvim-dap`. It manages adapter processes, tracks debug sessions and
breakpoints, and renders a tree-based debug UI.

## Requirements

- Neovim >= 0.10
- A DAP-capable debug adapter for your language (see [Adapters](#adapters))

## Installation

Install with any plugin manager, then call `setup`.

Neovim's built-in package manager (`vim.pack`, requires Neovim >= 0.12):

```lua
vim.pack.add({
  { src = "https://github.com/mbfoss/easydap.nvim" },
})
require("easydap").setup()
```

Pin to a branch or tag with `version`:

```lua
vim.pack.add({
  { src = "https://github.com/mbfoss/easydap.nvim", version = "main" },
})
require("easydap").setup()
```

lazy.nvim:

```lua
{
  "mbfoss/easydap.nvim",
  config = function()
    require("easydap").setup()
  end,
}
```

As a native package (`:h packages`, requires Neovim >= 0.10):

```sh
git clone https://github.com/mbfoss/easydap.nvim \
  ~/.config/nvim/pack/plugins/start/easydap.nvim
```

Then call `setup` in your config:

```lua
require("easydap").setup()
```

Clone into `pack/plugins/opt/` instead to load it on demand with
`:packadd easydap.nvim` (call `setup` after the `packadd`).

## Configuration

`setup` takes an optional table that is merged over the defaults.

```lua
require("easydap").setup({
  -- Project data file (breakpoints, watch expressions), written at the project root.
  data_filename = ".easydap.json",

  -- Milliseconds to wait before clearing stale UI during step-through (reduces flicker).
  antiflicker_delay = 200,

  -- Max characters shown for a value in the debug view before truncating.
  debug_value_max_len = 70,

  -- Filenames/dirs whose presence marks a project root.
  root_markers = { ".git" },

  -- Gutter sign glyphs.
  signs = {
    debug_frame              = "▶",
    active_breakpoint        = "●",
    inactive_breakpoint      = "○",
    cond_breakpoint          = "■",
    inactive_cond_breakpoint = "□",
    logpoint                 = "◆",
    inactive_logpoint        = "◇",
    disabled_breakpoint      = "ø",
    disabled_cond_breakpoint = "ø",
    disabled_logpoint        = "ø",
  },
})
```

## Usage

easydap does not run tasks by itself. It is a debug engine meant to be driven
either by a task runner or directly from your own plugin. Both start a session
by handing easydap a *task*.

### From a task runner

A task runner calls the task entry point, passing a run context and a completion
callback:

```lua
---@param task    easydap.Task      the task to run (fields below)
---@param ctx     easydap.RunCtx    run context: { tasks, add_bufnr, report }
---@param on_done fun(ok: boolean)  called when the session ends
---@return fun()                    handle that stops the run
require("easydap.task").start(task, ctx, on_done)
```

easydap resolves the adapter, derives the DAP launch/attach arguments from the
task fields, starts the session, and opens the debug view. It registers the
session's REPL, program output, and terminal buffers through `ctx.add_bufnr` so
the runner can surface them in its own UI, sends progress to `ctx.report`, and
calls `on_done(ok)` when the run ends.

[easytasks.nvim](https://github.com/mbfoss/easytasks.nvim) is the reference
runner and registers easydap as its default debug backend, so installing both
and calling `setup` is all the wiring needed:

```lua
require("easytasks").setup()   -- debug_backend defaults to "easydap"
require("easydap").setup()
```

A `debug` task is then defined in your task file:

```toml
[tasks.debug-app]
type    = "debug"
adapter = "codelldb"
request = "launch"
command = ["./a.out", "--verbose"]
cwd     = "${workspaceFolder}"
```

### Task fields

A debug task uses these fields:

| Field             | Description                                                       |
| ----------------- | ----------------------------------------------------------------- |
| `adapter`         | Adapter name (required), e.g. `codelldb`, `delve`, `debugpy`.     |
| `request`         | `"launch"` or `"attach"`. Defaults to the adapter's request.      |
| `command`         | Program to debug, with its arguments. String path, or `[program, arg1, ...]`. |
| `cwd`             | Working directory for the debugged program.                      |
| `env`             | Environment variables (merged with the process env).             |
| `clear_env`       | Pass `env` verbatim without merging.                             |
| `run_in_terminal` | Ask the adapter to spawn an integrated terminal for stdio.       |
| `stop_on_entry`   | Pause at the program entry point.                                |
| `host` / `port`   | DAP server address (attach only; required for the `remote` adapter). |
| `request_args`    | DAP request body, merged over the derived args (takes precedence). |
| `raw_messages`    | Capture raw DAP traffic in a dedicated buffer.                   |

`command`, `cwd`, `env`, `clear_env`, `run_in_terminal`, and `stop_on_entry`
are convenience fields. You do not normally write `request_args` by hand: each
adapter maps these generic fields into the DAP `launch`/`attach` body for you
(through its `derive_launch_args` / `derive_attach_args`), so the same task
definition works across adapters even though they name their arguments
differently. In the `debug-app` task above, the `program` and its arguments the
adapter expects are derived from `command`. The mapping is per adapter — an
adapter only translates the fields that make sense for it.

Set `request_args` only when you need an adapter-specific field that the
convenience fields do not cover. It is deep-merged over the derived body and
wins on conflict, so you can override a single derived value without restating
the rest.

Starter task templates for each built-in adapter are available in
`require("easydap.templates")`.

### From your own plugin

Without a task runner, you supply the run context yourself. `add_bufnr` and
`report` may be no-ops; `on_done` is called when the session ends:

```lua
require("easydap.task").start({
  adapter = "codelldb",
  request = "launch",
  command = { "./a.out", "--verbose" },
  cwd     = vim.fn.getcwd(),
}, {
  tasks     = {},
  add_bufnr = function(bufnr, label, priority) end,  -- REPL / output / terminal buffers
  report    = function(message) end,                 -- progress messages
}, function(ok) end)
```

For full control over the raw DAP config — skipping the task-field derivation
entirely — start a session with `manager.start`. `request_args` is sent verbatim
as the DAP `launch`/`attach` body:

```lua
local manager  = require("easydap.manager")
local adapters = require("easydap.adapters")

manager.start(vim.tbl_extend("force", adapters.codelldb, {
  request      = "launch",
  request_args = { program = vim.fn.getcwd() .. "/a.out", args = {} },
}))
```

## Adapters

Built-in adapter definitions live in `require("easydap.adapters")`, a plain
`name -> config` table. Add or override entries directly:

```lua
local adapters = require("easydap.adapters")

-- Override a field on a built-in adapter
adapters.codelldb.command = "/opt/codelldb/codelldb"

-- Add a new adapter
adapters.my_adapter = {
  command = "my-dap-server",
  derive_launch_args = function(task) return { program = task.command } end,
}
```

| Name                 | Target                                            |
| -------------------- | ------------------------------------------------- |
| `codelldb`           | C / C++ / Rust (CodeLLDB)                          |
| `lldb`, `lldb-dap`   | C / C++ / Rust (lldb-dap)                          |
| `gdb`                | C / C++ (gdb `--interpreter=dap`)                  |
| `delve`              | Go (`dlv dap`)                                     |
| `debugpy`            | Python file                                        |
| `debugpy-module`     | Python module                                      |
| `debugpy-remote`     | Attach to a remote debugpy process                |
| `js-debug`           | Node.js / JavaScript / TypeScript                 |
| `netcoredbg`         | .NET                                              |
| `java-debug-server`  | Java (external debug server, e.g. nvim-jdtls)     |
| `bash-debug-adapter` | Bash                                              |
| `php-debug-adapter`  | PHP (Xdebug)                                       |
| `local-lua-debugger` | Lua                                               |
| `remote`             | Generic TCP attach to any DAP server              |

## Commands

All commands are under `:Debug`.

### Session control

| Command                     | Action                                            |
| --------------------------- | ------------------------------------------------- |
| `:Debug view`               | Toggle the debug view panel.                      |
| `:Debug continue`           | Continue the active session.                      |
| `:Debug continue_all`       | Continue all sessions.                             |
| `:Debug step_over` / `next` | Step over.                                         |
| `:Debug step_in`            | Step in.                                           |
| `:Debug step_out`           | Step out.                                          |
| `:Debug step_into_targets`  | Step into a chosen call on the current line.       |
| `:Debug step_back`          | Step back (adapters that support reverse debugging). |
| `:Debug reverse_continue`   | Reverse continue.                                  |
| `:Debug jump_to_cursor`     | Set the next statement to the line under the cursor. |
| `:Debug restart_frame`      | Restart the selected stack frame.                  |
| `:Debug pause`              | Pause the running program.                         |
| `:Debug restart`            | Restart the session.                               |
| `:Debug stop` / `terminate` | Stop the active session.                           |
| `:Debug terminate_all`      | Stop all sessions.                                 |

### Inspection

| Command                  | Action                                               |
| ------------------------ | ---------------------------------------------------- |
| `:Debug inspect`         | Evaluate the word under the cursor in a float.       |
| `:Debug exception_info`  | Show details of the current exception.               |
| `:Debug disassemble`     | Open the disassembly pane for the current frame.     |
| `:Debug session`         | Pick the active session.                             |
| `:Debug thread`          | Pick the selected thread.                            |
| `:Debug terminate_thread`| Terminate a chosen thread.                           |
| `:Debug frame`           | Pick the selected stack frame.                       |

### Breakpoints

Breakpoint commands are under `:Debug breakpoint`.

| Command                              | Action                                          |
| ------------------------------------ | ----------------------------------------------- |
| `:Debug breakpoint toggle`           | Toggle a breakpoint on the current line.        |
| `:Debug breakpoint add [condition]`  | Add a (conditional) breakpoint.                 |
| `:Debug breakpoint remove`           | Remove the breakpoint at the cursor.            |
| `:Debug breakpoint column`           | Set a column breakpoint on the current line.    |
| `:Debug breakpoint condition`        | Set the condition / hit condition.              |
| `:Debug breakpoint logpoint`         | Turn the breakpoint into a logpoint.            |
| `:Debug breakpoint enable` / `disable` | Enable / disable the breakpoint at the cursor. |
| `:Debug breakpoint enable_all` / `disable_all` | Enable / disable all breakpoints.     |
| `:Debug breakpoint clear_file`       | Remove all breakpoints in the current file.     |
| `:Debug breakpoint clear_all`        | Remove all source and function breakpoints.     |
| `:Debug breakpoint clear_fn`         | Remove all function breakpoints.                |
| `:Debug breakpoint fn [name]`        | Toggle a function breakpoint.                   |
| `:Debug breakpoint exception_filter` | Toggle an adapter-provided exception filter.    |
| `:Debug breakpoint exception_type [name] [mode]` | Break on a named exception type.    |
| `:Debug breakpoint data [name]`      | Toggle a data breakpoint (watchpoint).          |
| `:Debug breakpoint data_clear`       | Remove all data breakpoints.                    |
| `:Debug breakpoint data_list`        | List data breakpoints.                          |
| `:Debug breakpoint list`             | Pick a breakpoint and jump to its source.       |

## Debug view

The debug view is a tree of sessions, threads, stack frames, scopes,
variables, watch expressions, and breakpoints. Open it with `:Debug view` or
`require("easydap").open_debug_view()`.

Keymaps inside the panel (`g?` shows this list):

| Key    | Action                                                              |
| ------ | ------------------------------------------------------------------ |
| `<CR>` | Select session / switch frame / jump to breakpoint source.         |
| `K`    | Show full value, frame details, exception info, or breakpoint info. |
| `i`    | Add watch expression, function breakpoint, or data breakpoint.     |
| `d`    | Remove watch expression or breakpoint.                             |
| `r`    | Rename a watch expression.                                         |
| `x`    | Toggle breakpoint enabled / disabled.                              |
| `c`    | Change a variable value, breakpoint condition, or break mode.      |

## Features

- Multiple concurrent debug sessions with an active-session model.
- Source, conditional, log, function, data, and exception breakpoints.
- Watch expressions and an interactive REPL.
- Inline variable values shown as virtual text at their source lines.
- Gutter signs for breakpoints and the current execution position.
- Disassembly view with instruction-level stepping.
- Reverse debugging (step back, reverse continue) where the adapter supports it.

## Persistence

State is scoped to a project. The project root is the current working directory
when it directly contains a [`root_markers`](#configuration) entry (`.git` by
default). Breakpoints and watch expressions are written to the data file at the
root (`.easydap.json` by default), saved on exit and when leaving a project, and
restored when entering one.

## API

`require("easydap")`:

- `setup(opts)` — configure and register commands.
- `open_debug_view()` / `debug_view()` — the debug panel.
- `open_disassembly_view()` / `disassembly_view()` — the disassembly pane.

`require("easydap.task")` is the task entry point: `start(task, ctx, on_done)`
resolves the adapter, derives the DAP request, and runs the session. Call it
from a task runner or your own plugin.

`require("easydap.manager")` is the single dependency surface for commands and
UI. It owns the active session and exposes `start`, `session`, `sessions`,
`select_session`, the `debug.*`, `breakpoint.*`, and `panel.*` command tables,
and the session signals.
