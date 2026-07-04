# easydap.nvim

A Debug Adapter Protocol (DAP) client for Neovim. It spawns and manages adapter
processes, tracks sessions and breakpoints, and renders a tree-based debug UI.

easydap can be used on its own or as the debug backend for
[easytasks.nvim](https://github.com/mbfoss/easytasks.nvim).

## Features

- Pure-Lua DAP runtime — Content-Length framing, request/response correlation,
  and event dispatch implemented in-tree.
- Manages adapter lifecycle: stdio-pipe and TCP-socket adapters, plus adapters
  that need a server spawned first (debugpy, js-debug, …).
- Full breakpoint surface: line, column, conditional, hit-condition, logpoints,
  function breakpoints, exception filters/types, and data breakpoints
  (watchpoints).
- Multiple concurrent sessions and threads, with an "active session" concept the
  UI and keymaps follow automatically.
- Tree-based **debug view**: sessions → threads/frames → scopes → variables,
  plus watch expressions and a breakpoint list.
- Gutter signs, inline variable values, a current-line highlight, an integrated
  REPL, and a disassembly view.
- Stepping the full menu: step over/in/out, step-into-targets, jump-to-cursor,
  restart frame, reverse-continue / step-back (when the adapter supports it).
- A run **panel** that pages between a run's report, REPL, program output,
  terminal, and raw-DAP-message buffers.
- Per-project persistence of breakpoints and watch expressions in a single JSON
  file at the project root.

## Requirements

- Neovim ≥ 0.10
- A DAP adapter for the language you want to debug (see [Adapters](#adapters)).

Run `:checkhealth easydap` to verify your Neovim version, confirm `setup()` ran,
and see which built-in adapters are available on your system.

## Installation

Any plugin manager works. easydap has no Lua dependencies.

**[lazy.nvim](https://github.com/folke/lazy.nvim)**

```lua
{
  "mbfoss/easydap.nvim",
  opts = {},               -- calls require("easydap").setup(opts)
}
```

**[mini.deps](https://github.com/echasnovski/mini.deps)**

```lua
add("mbfoss/easydap.nvim")
require("easydap").setup()
```

**Built-in packages (`:h packages`)**

Clone into `pack/*/opt/` (or `start/`) and call `setup` from your config:

```lua
require("easydap").setup()
```

## Quick start

1. Define a debug task as a Lua file that returns a task table:

   ```lua
   -- debug.lua
   return {
     name    = "debug app",
     adapter = "codelldb",      -- a key from require("easydap.adapters")
     request = "launch",
     command = { "./a.out", "--flag" },
     cwd     = vim.fn.getcwd(),
     stop_on_entry = false,
   }
   ```

2. Set a breakpoint on the current line, then start the task:

   ```vim
   :Debug breakpoint toggle
   :Debug run debug.lua
   ```

   Pass a directory instead of a file to pick from the `*.lua` tasks in it:

   ```vim
   :Debug run ./debug
   ```

3. The debug view opens automatically on the first session. Step through with
   `:Debug step_over`, `:Debug step_in`, `:Debug continue`, and inspect values in
   the tree.

You can also run a task table directly from Lua:

```lua
require("easydap").run({ name = "tests", adapter = "delve", request = "launch" })
```

## Task fields

A task is a plain table consumed by the runtime; adapters translate these
generic fields into a DAP `launch`/`attach` request.

| Field             | Type                     | Notes |
| ----------------- | ------------------------ | ----- |
| `name`            | `string`                 | Defaults to `"debug"`; also the run/panel group name. |
| `adapter`         | `string`                 | **Required.** A key in `require("easydap.adapters")`. |
| `request`         | `"launch"` \| `"attach"` | Defaults to the adapter's default. |
| `command`         | `string` \| `string[]`   | Program to debug; `[program, arg1, …]` shorthand allowed. |
| `cwd`             | `string`                 | Working directory. |
| `env`             | `table<string,string>`   | Merged into the process environment. |
| `clear_env`       | `boolean`                | Pass `env` verbatim without merging the process environment. |
| `host` / `port`   | `string` / `integer`     | Attach targets (required for the `remote` adapter). |
| `run_in_terminal` | `boolean`                | Use the DAP `runInTerminal` flow. |
| `stop_on_entry`   | `boolean`                | Break at program entry. |
| `request_args`    | `table`                  | Sent verbatim in the launch/attach body; overrides the generic fields. |
| `raw_messages`    | `boolean`                | Capture raw DAP protocol traffic in a dedicated buffer. |

The generic fields above are a convenience: `require("easydap.derive")`
translates them into the adapter's native launch/attach body before the task
runs (the DAP core itself only ever sees native `request_args`). When you need
full control, set `request_args` directly — it is forwarded unchanged, and it is
deep-merged over the derived body (native keys win) when both are present.

## Adapters

Built-in adapter definitions live in
[`adapters.lua`](lua/easydap/adapters.lua) as a plain `name -> config` table:

| Name | Tooling |
| ---- | ------- |
| `debugpy`, `debugpy-module`, `debugpy-remote` | Python (debugpy) |
| `codelldb` | C/C++/Rust (CodeLLDB) |
| `lldb`, `lldb-dap` | C/C++/Rust (lldb-dap) |
| `gdb` | C/C++ (`gdb --interpreter=dap`) |
| `delve` | Go (`dlv dap`) |
| `netcoredbg` | .NET |
| `js-debug` | JavaScript / TypeScript (js-debug) |
| `bash-debug-adapter` | Bash |
| `php-debug-adapter` | PHP (Xdebug) |
| `local-lua-debugger` | Lua (local-lua-debugger-vscode) |
| `java-debug-server` | Java (external debug server, e.g. nvim-jdtls) |
| `remote` | Generic TCP attach to a running DAP server |

Several adapters resolve their binaries from a [Mason](https://github.com/mason-org/mason.nvim)
install (`stdpath("data")/mason/packages/...`) and otherwise fall back to the
system `PATH`.

### Adding or overriding adapters

The adapters table is mutable — add your own or tweak a built-in directly. An
adapter config is **pure native DAP** (no generic-task knowledge):

```lua
local adapters = require("easydap.adapters")

-- New adapter
adapters.myadapter = {
  command = { "my-dap-server", "--stdio" },
  request = "launch",
}

-- Override a built-in field
adapters.codelldb.command = "/opt/codelldb/codelldb"
```

Key adapter-config fields: `command` (string or argv), `host`/`port` (for TCP
adapters), `request`, and a `setup`/`teardown` pair for adapters that must spawn
a server first. See the `easydap.dap.Config` annotation in
[`adapters.lua`](lua/easydap/adapters.lua).

Translating the generic task fields into a native launch/attach body is a
separate, opt-in concern in [`derive.lua`](lua/easydap/derive.lua) — a registry
keyed by adapter name, parallel to `adapters`. Add or override a translation
there:

```lua
local derive = require("easydap.derive")

derive.adapters.myadapter = {
  launch = function(task) return { program = task.command, args = {} } end,
}

-- Override just one built-in translation
derive.adapters.codelldb.launch = function(task) … end
```

## Commands

Everything is under the `:Debug` command (with completion).

**Session & stepping**

| Command | Action |
| ------- | ------ |
| `:Debug run {file\|dir}` | Run a task from a Lua file, or pick from a directory. |
| `:Debug rerun` | Re-run the most recently run task from scratch. |
| `:Debug view` | Toggle the debug view. |
| `:Debug continue` / `continue_all` | Continue the active session / all sessions. |
| `:Debug step_over` (`next`) / `step_in` / `step_out` | Step. |
| `:Debug step_into_targets` | Step into a chosen call on the current line. |
| `:Debug step_back` / `reverse_continue` | Reverse execution (adapter permitting). |
| `:Debug jump_to_cursor` | Set the next statement to the line under the cursor. |
| `:Debug restart_frame` | Restart the selected stack frame. |
| `:Debug pause` / `restart` | Pause / restart the session. |
| `:Debug stop` (`terminate`) / `terminate_all` | Stop the active session / all. |
| `:Debug session` / `thread` / `frame` | Pick the active session / thread / frame. |
| `:Debug terminate_thread` | Pick and terminate a thread. |
| `:Debug inspect` | Hover-evaluate the word under the cursor, or the visual selection when invoked from visual mode. |
| `:Debug exception_info` | Show details of the current exception. |
| `:Debug disassemble` | Open the disassembly view for the current frame. |
| `:Debug panel [toggle\|next\|previous\|jump N]` | Control the run panel (`:N Debug panel` jumps to tab N). |
| `:Debug project` | Show the resolved project root. |

**Breakpoints** — `:Debug breakpoint {sub}` (also reachable as `:Debug breakpoint`):

| Subcommand | Action |
| ---------- | ------ |
| `toggle` / `add [cond]` / `remove` | Line breakpoint at the cursor. |
| `column` | Column breakpoint (picks valid columns when a session is live). |
| `condition` / `logpoint` | Set condition + hit-condition / log message. |
| `enable` / `disable` / `enable_all` / `disable_all` | Toggle enabled state. |
| `clear_file` / `clear_fn` / `clear_all` | Bulk removal. |
| `fn [name]` | Toggle a function breakpoint. |
| `exception_filter` | Toggle an adapter-provided exception filter. |
| `exception_type [name] [mode]` | Break on a named exception type. |
| `data [name]` / `data_clear` / `data_list` | Data breakpoints (watchpoints). |
| `list` | Pick from all breakpoints (with preview) and jump to one. |

## Debug view

The debug view is a tree of the live debug state. It opens automatically when a
session starts, or with `:Debug view`. In-view keymaps (press `g?` for this
list):

| Key    | Action |
| ------ | ------ |
| `<CR>` | Select session / switch frame / jump to breakpoint source |
| `K`    | Show full value / frame details / exception info / breakpoint details |
| `i`    | Add watch expression, function breakpoint, or data breakpoint |
| `d`    | Remove watch expression or breakpoint |
| `r`    | Rename watch expression |
| `x`    | Toggle breakpoint enabled/disabled |
| `c`    | Change variable value / breakpoint condition / break mode / access type |

## Configuration

`setup(opts)` merges over the defaults in [`config.lua`](lua/easydap/config.lua):

```lua
require("easydap").setup({
  root_markers        = { ".git" },   -- identifies the project root
  data_filename       = ".easydap.json",
  debug_value_max_len = 70,           -- truncate variable/expression values past this
  antiflicker_delay   = 200,          -- ms before clearing stale UI during step-through
  inline_vars         = "eol",     -- value placement: "inline" | "eol" | "eol_right_align" | "right_align" | "off"
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

## Persistence

Breakpoints and watch expressions are saved per project to a single JSON file
(`.easydap.json` by default) at the nearest ancestor directory containing a
`root_markers` entry. State is persisted on `cwd` change and on exit, and
restored when you return to a project. Source paths are stored project-relative
so the file stays portable. Add it to your `.gitignore` if you don't want to
share it.

## Suggested keymaps

easydap sets no global keymaps — wire the commands to whatever you prefer:

```lua
local map = vim.keymap.set
map("n", "<F5>",  "<Cmd>Debug continue<CR>",          { desc = "Debug: continue" })
map("n", "<F9>",  "<Cmd>Debug breakpoint toggle<CR>", { desc = "Debug: toggle breakpoint" })
map("n", "<F10>", "<Cmd>Debug step_over<CR>",         { desc = "Debug: step over" })
map("n", "<F11>", "<Cmd>Debug step_in<CR>",           { desc = "Debug: step in" })
map("n", "<F12>", "<Cmd>Debug step_out<CR>",          { desc = "Debug: step out" })
map("n", "<leader>du", "<Cmd>Debug view<CR>",         { desc = "Debug: toggle view" })
map({ "n", "x" }, "<leader>di", "<Cmd>Debug inspect<CR>", { desc = "Debug: inspect" })
```

For richer integration, the `require("easydap.manager")` module exposes the same
actions as Lua functions (`manager.debug.*`, `manager.breakpoint.*`,
`manager.view.*`) along with session signals you can subscribe to.

## Architecture

The code is layered — higher layers depend on lower ones, communicating through
`Signal` pub/sub rather than back-references:

- **Public API** — [`init.lua`](lua/easydap/init.lua): `setup`, `run`, the debug
  view, and the `:Debug` command surface.
- **Command surface** — [`manager.lua`](lua/easydap/manager.lua): the active-session
  concept and the user-facing `debug` / `breakpoint` / `view` command tables.
- **DAP core** — [`lua/easydap/dap/`](lua/easydap/dap/): `client` (session
  registry), `session` (one DAP session), `connection` + `transport` (the wire),
  and `breakpoints` (the global registry).
- **Adapters & tasks** — [`adapters.lua`](lua/easydap/adapters.lua),
  [`task.lua`](lua/easydap/task.lua), [`runner.lua`](lua/easydap/runner.lua).
- **UI** — [`lua/easydap/ui/`](lua/easydap/ui/): the debug view, signs, inline
  values, REPL, disassembly, and run panel.

See [CLAUDE.md](CLAUDE.md) for a fuller breakdown.
```