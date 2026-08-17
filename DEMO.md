# ezdap.nvim in action

Each clip is a recorded Neovim session debugging the same small Python program
through [debugpy](https://github.com/microsoft/debugpy). Commands are typed in
full (`:Debug …`) to show what each step does; map them to keys for daily use —
see [Keymaps example](README.md#keymaps-example).

The editor is Neovim with ezdap,
[dock.nvim](https://github.com/mbfoss/dock.nvim) for the bottom panel and
[keystone.nvim](https://github.com/mbfoss/keystone.nvim)'s statusline.

## Breakpoints, stepping and the debug panel

Set a breakpoint and launch. The panel opens on the stop, showing sessions, call
stack, locals, watch expressions and breakpoints in one tree; the frame's values
are rendered inline in the source.

![Breakpoints and stepping](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/01-breakpoint-step.gif)

## Conditions and logpoints

A breakpoint that only stops when `amount > 50`, and a logpoint that prints
every scaling operation without pausing the program.

![Conditional breakpoints and logpoints](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/02-condition-logpoint.gif)

## Function and exception breakpoints

Break on `scale` by name wherever it is called from, then run into the
program's uncaught `ValueError` and read it with `:Debug exception_info`.

![Function and exception breakpoints](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/03-function-exception.gif)

## Inspecting and changing values

`:Debug inspect` expands the identifier under the cursor, `i` in the panel adds
a watch expression, and `c` on a variable writes a new value back into the
running program.

![Inspect and watch expressions](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/04-watch-inspect.gif)

## REPL and run buffers

Each run has its own buffers: progress log, REPL, adapter terminal and program
output. The REPL evaluates expressions in the stopped frame, function calls
included.

![REPL and run buffers](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/05-repl.gif)

## Jump to cursor, step in and out

Move the execution point to the cursor without running the code in between,
then step into a call and back out. The return value appears in the locals.

![Jump to cursor and stepping in](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/06-step-in-jump.gif)

## Parallel sessions

Two debuggees paused at the same breakpoint at once, each with a panel row and a
dock tab. `:Debug session` selects which one the stepping commands apply to.

![Parallel sessions](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/07-parallel-sessions.gif)

## Persistence

Breakpoints, their conditions and watch expressions are saved per project and
restored on the next start.

![Project-scoped persistence](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/08-persistence.gif)
