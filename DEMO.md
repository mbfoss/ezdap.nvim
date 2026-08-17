# ezdap.nvim in action

Every clip below is a real session recorded in Neovim against the same small
Python program, debugged through [debugpy](https://github.com/microsoft/debugpy).
Commands are typed out in full (`:Debug …`) so what's happening stays visible;
in daily use they sit behind keymaps — see
[Keymaps example](README.md#keymaps-example).

The editor in the clips is stock Neovim plus ezdap,
[dock.nvim](https://github.com/mbfoss/dock.nvim) for the bottom panel and
[keystone.nvim](https://github.com/mbfoss/keystone.nvim)'s statusline.

## Breakpoints, stepping and the debug panel

Set a breakpoint, launch, and the panel opens on the stop: sessions, call stack,
locals, watch expressions and breakpoints in one tree — with the frame's values
rendered inline in the source.

![Breakpoints and stepping](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/01-breakpoint-step.gif)

## Conditions and logpoints

A breakpoint that only stops when `amount > 50`, and a logpoint that prints
every withdrawal without ever pausing the program.

![Conditional breakpoints and logpoints](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/02-condition-logpoint.gif)

## Function and exception breakpoints

Break on `withdraw` by name wherever it is called from, then run into the
program's uncaught `ValueError` and read it with `:Debug exception_info`.

![Function and exception breakpoints](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/03-function-exception.gif)

## Inspecting and changing values

`:Debug inspect` expands the identifier under the cursor, `i` in the panel adds
a watch expression, and `c` on a variable writes a new value back into the
running program.

![Inspect and watch expressions](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/04-watch-inspect.gif)

## REPL and run buffers

Each run brings its own buffers — progress log, REPL, adapter terminal, program
output. The REPL evaluates in the stopped frame, calls included.

![REPL and run buffers](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/05-repl.gif)

## Jump to cursor, step in and out

Move the execution point to the cursor without running the code in between,
then step into a call and back out — the return value lands in the locals.

![Jump to cursor and stepping in](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/06-step-in-jump.gif)

## Parallel sessions

Two debuggees paused at the same breakpoint at once, a panel row and a dock tab
each; `:Debug session` picks which one the stepping commands drive.

![Parallel sessions](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/07-parallel-sessions.gif)

## Persistence

Breakpoints, their conditions and watch expressions are saved per project.
Quit Neovim, come back, and they are already there.

![Project-scoped persistence](https://raw.githubusercontent.com/mbfoss/ezdap.nvim/assets/demos/08-persistence.gif)
