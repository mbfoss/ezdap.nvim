# Writing an adapter definition

An adapter definition is a single Lua file under an `ezdap-adapters/` directory on the
runtimepath (beside `lsp/` and `plugin/`, not under `lua/`; it is a definition read by
filename, not a Lua module),
registered under its filename: `myadapter.lua` becomes the `myadapter` adapter, the name
`:Ezdap run` takes. It is configuration only: it says how to reach the debug adapter (the
program that actually speaks DAP, such as `codelldb` or `gdb --interpreter=dap`) and what
that adapter can be asked to do.

Three things get named in these files, and DAP keeps them distinct:

- **debug adapter**: the program ezdap spawns or dials, the one speaking DAP:
  `codelldb`, `lldb-dap`, `gdb --interpreter=dap`, `dlv dap`.
- **debugger**: what that adapter drives underneath. Sometimes a separate program
  (`codelldb` drives LLDB), sometimes the adapter itself (`gdb` and `dlv` speak DAP
  directly).
- **debuggee**: the program being debugged.

"Adapter" on its own always means the first. This file is an adapter *definition*: it
describes an adapter, it is not one.

Each file returns one `ezdap.AdapterDef`:

```lua
return {
    command  = { "gdb", "--interpreter=dap" }, -- how to spawn the adapter; or host/port to connect
    setup    = function(config, ctx, callback) end, -- optional, see below
    modes    = {
        binary = {
            description = "debug a native executable",
            request     = "launch", -- or "attach"
            inputs      = {
                command = { type = "string", completion = "command", required = true, description = "command line to debug" },
            },
            build       = function(inputs) -- inputs -> DAP body
                local program, args = require("ezdap.shared").split_command(inputs.command)
                return { program = program, args = args }
            end,
        },
    },
}
```

Each definition is read the first time something reaches for that adapter by name
(`ezdap.load_adapter`), a run, `:Ezdap adapter_info <adapter>`, and never when
ezdap starts. Listing adapters (`ezdap.available_adapters`, `:checkhealth`) reads
their filenames only, so keep top-level work to building the table: anything
expensive belongs in `setup`, which runs per run. It is read with `loadfile`, so it is never a Lua
module: nothing can `require` it, and it cannot have siblings it requires; pull
shared helpers from `ezdap.shared` instead.

## `ezdap.AdapterDef`

The table an adapter definition returns. Every field is optional; what is set decides how
the adapter is reached and what it can run.

| Field | Type | Meaning |
| --- | --- | --- |
| `command` | `string` \| `string[]` | The adapter process to spawn, spoken to over stdio. A string is split on shell whitespace, so `"python3 -m debugpy"` works; a list is used verbatim. A missing executable is reported before the session starts. **`command` takes priority**: a definition with both `command` and `host`/`port` spawns `command`, and its `host`/`port` are ignored. |
| `host` | `string` | Host of an already-running adapter to connect to, used only when there is no `command`. Defaults to `127.0.0.1`. |
| `port` | `integer` | Port to connect to, used only when there is no `command`; ezdap dials `host:port`, retrying for ~3s. A port that `setup` or a mode's `build` sets for the run still selects TCP over `command`: that is how a definition whose `setup` starts the adapter as a server connects to it. |
| `cwd` | `string` | Working directory for the spawned adapter. Defaults to Neovim's cwd. |
| `env` | `table<string,string>` | Environment for the spawned adapter, meaning the adapter's own environment, not the debuggee's; merged over Neovim's, so set only what the adapter needs, such as a search path or a flag it reads from the environment. |
| `type` | `string` | DAP `adapterID` override. Defaults to the adapter's name, i.e. the filename stem. |
| `defer_launch_attach` | `boolean` | Send `launch`/`attach` after `configurationDone` rather than straight after `initialize`, for adapters that require that order. |
| `modes` | `table<string, ezdap.Mode>` | The named modes this definition offers, keyed by the name `:Ezdap run <adapter> <mode>` takes. |
| `setup` | `fun(config, ctx, callback)` | Runs before the session; see below. |
| `teardown` | `fun(config, state)` | Runs after the session, with whatever `setup` passed as its `state`. |

An `ezdap.Mode` is one runnable configuration:

| Field | Type | Meaning |
| --- | --- | --- |
| `description` | `string` | A line shown in pickers and `:Ezdap new_run_file` output. |
| `request` | `"launch"` \| `"attach"` | Which DAP request the mode issues. |
| `inputs` | `table<string, ezdap.Input>` | What the user is asked for, keyed by the name used as `key=value` on the command line. |
| `build` | `fun(inputs): table?, table\|string?` | Turns answered inputs into the DAP request body and returns it. A second return value is a `host`/`port` table overriding the definition's own. Return `nil, "message"` to abort with that error. It runs in a coroutine, so it may yield; a `vim.ui.select` picker inside `build` is fine. |

An `ezdap.Input` describes one value:

| Field | Type | Meaning |
| --- | --- | --- |
| `type` | `"string"` \| `"boolean"` \| `"integer"` \| `"number"` \| `"list"` \| `"map"` | What the value is. Defaults to `string`. `list` is a table of entries, `map` a table of `key=value` entries. |
| `item_type` | as above, scalars only | The entry type of a `list` or `map`. |
| `required` | `boolean` | Leaving it unset is an error. Defaults to `false`. |
| `completion` | `"file"` \| `"dir"` \| `"command"` \| `string[]` \| `fun(partial): string[]` | What the value completes with: a named source, the values themselves, or a function computing them. Suggests only; it never rejects a value. |
| `description` | `string` | A few words on what the input means. This is what `:Ezdap new_run_file` and `quick_run` completion show. |

## Modes

A definition without `modes` cannot be run at all: nothing completes, and nothing can be
generated, because a raw DAP body describes nothing about itself (see
[Why inputs](README.md#why-inputs-and-not-raw-dap)). Each mode declares
the `inputs` it accepts and a `build` that turns supplied values into the native body:

```lua
return {
    command  = { "my-dap-adapter", "--stdio" },
    modes    = {
        binary = {
            description = "debug an executable",
            request     = "launch",
            inputs      = {
                command       = { type = "string",  completion = "command", required = true, description = "command line to debug" },
                cwd           = { type = "string",  completion = "dir",     description = "working directory" },
                env           = { type = "map",                             description = "environment variables" },
                stop_on_entry = { type = "boolean",                         description = "break at program entry" },
            },
            build = function(inputs)
                local shared = require("ezdap.shared")
                local program, args = shared.split_command(inputs.command)
                return {
                    program     = program,
                    args        = args,
                    cwd         = shared.normalize_path(inputs.cwd),
                    env         = inputs.env,
                    stopOnEntry = inputs.stop_on_entry,
                }
            end,
        },
    },
}
```

The mode is now everywhere it should be, with no further wiring:

```vim
:Ezdap run myadapter binary command=./a.out cwd=/src stop_on_entry=true
:Ezdap new_run_file myadapter binary
```

How the pieces fit:

- **`inputs`**: one entry per accepted value, keyed by the name typed on the command line
  or written in a run file's `parameters`. `type` is what `build` receives (`string`,
  `boolean`, `integer`, `number`, and the two collections `list` (`a,b`) and `map`
  (`A=1,B=2`, string keys)), and it is the whole of what an input declares about its value.
  A `list`/`map` declares its *entries* the same way under `item_type`: `{ type = "list",
  item_type = "integer" }` is a list of integers, and a collection that declares none
  holds strings. The full vocabulary is one row per type in
  [inputs.lua](lua/ezdap/inputs.lua); every consumer reads those rows.
- **`completion`**: what the value offers while it is being typed, in whichever of three
  forms fits: a named source (`"file"`, `"dir"`, or `"command"`, which completes each
  token of a command line as a path), the values the input is normally written with when
  the adapter names them itself (`{ "console", "terminal" }`), or a
  `fun(partial): string[]` when they can only be computed: the targets in a workspace,
  the containers running now. On a `list`/`map` it describes one entry. A written-out set
  is also what a typed file's schema lists as `examples` and what
  `:Ezdap new_run_file` writes into the generated file's comments; a source or a
  function has nothing to serialize. Nothing rejects a value outside what completes. A boolean input
  completes as `true`/`false` on its own.
- **Paths and ports**: a path input is a `string` and a port a plain `integer`; what
  either additionally is, `build` says: `shared.normalize_path(inputs.cwd)` resolves `~`
  and `$VAR` (nil in, nil out, and a `list`/`map` entry by entry), and
  `local port, err = shared.resolve_port(inputs.port)` holds a port to its range, giving
  back the `nil, err` pair an abort already returns.
- **`required`**: an unset required input is a resolve error naming the input. Leave it
  off and an unset input simply arrives as `nil`; since Lua drops nil-valued keys,
  `cwd = inputs.cwd` omits `cwd` entirely. Write the field unconditionally and optional
  fields take care of themselves.
- **`build(inputs)`**: returns the native DAP body (write the adapter's own key names,
  plus any identity fields it pins, as literals). `inputs` arrives already read into each
  declared `type`, whichever form the caller authored it in. A **second** return value is
  for adapters whose *connection* is what an input configures: return a `host`/`port`
  table, or nothing at all, and the definition's own values stay in force.
- **Aborting**: return `nil` and a message. The slot that carries the connection on a
  successful call carries the reason on an unsuccessful one, so an abort reads as the
  `nil, err` pair any Lua function returns.
- **Asking the user**: `build` runs on a coroutine, so it may yield. That is how an
  attach mode with no `pid` opens a process picker rather than sending a meaningless
  body: `local pid, err = shared.resolve_pid(inputs.pid); if not pid then return nil, err end`.
  It must always resume, returning either a body or an abort, so the caller waiting on it
  hears back.

Because `:Ezdap run`, `:Ezdap new_run_file` and mode-based run files all resolve through
the same `inputs` → `build` path, a mode is described in exactly one place and the three
cannot drift apart. The shipped `remote` adapter in [remote.lua](ezdap-adapters/remote.lua)
is a compact reference for a mode that returns a connection (a task-level `host`/`port`)
rather than a body; for a spawn-then-connect definition that starts a server and points
the connection at it, see the `setup`/`teardown` example below.

## Setup and teardown

`setup` runs before ezdap connects. Use it to start the adapter as a server and report its
port, or to locate its binary and fail with a readable message. Return errors through `callback("...")`. Pass state as the second argument,
`callback(nil, { handle = h })`, and it arrives as `teardown`'s second argument, which is
how `teardown` stops what `setup` started. It must call `callback(err, state)` exactly
once, so the run either proceeds or aborts.

`setup` may edit `config` in place, most usefully `config.host`/`config.port`, which is
how an adapter that is really a TCP server gets started and then connected to. Its `ctx`
carries `report(msg)` for progress lines, `add_bufnr(bufnr, opts?)` to attach a buffer it
created to the run so it is listed under the session, and `mode`, the mode name
this run resolved from, so a `setup` can gate one mode rather than the whole definition
(refusing a mode whose feature the installed binary is too old for, say). Treat an
unrecognized name as "none of mine" and let the run proceed.

```lua
local shared = require("ezdap.shared")

return {
    setup = function(config, ctx, callback)
        local handle, err
        local done = false -- callback must fire exactly once
        handle, err = shared.spawn({ "my-dap", "--listen", "127.0.0.1:0" }, {
            cwd           = config.cwd,
            line_buffered = true,
            on_stdout     = function(_, lines)
                for _, line in ipairs(lines) do
                    local port = not done and line:match("listening on port (%d+)")
                    if port then
                        done = true
                        config.host, config.port = "127.0.0.1", tonumber(port)
                        callback(nil, { handle = handle })
                    end
                end
            end,
            on_exit       = function(code)
                if done then return end
                done = true
                callback(("my-dap exited (code %d) before reporting a port"):format(code))
            end,
        })
        if not handle then return callback("failed to start my-dap: " .. tostring(err)) end
        ctx.add_bufnr(handle.bufnr, { label = "my-dap server" })
        ctx.report("waiting for server port")
    end,
    teardown = function(_, state)
        if state and state.handle then state.handle.stop() end
    end,
}
```

When a definition has a `setup`, ezdap leaves `config.host`/`port` entirely to it and
ignores the task's: the definition knows where it put the server. Any adapter that
announces its port on startup fits this shape; only the pattern matched against its
output changes.

## Helpers

Locating the adapter binary is most of what a definition does before it can run, so
`ezdap.shared` helps: `split_command`, `normalize_path`, `resolve_port`, `resolve_pid`,
`spawn`, and `resolve_path(candidates, accept, opts?)`, which expands `$VAR` and `~` and
returns the first candidate `accept` approves, plus everything tried:

```lua
local shared = require("ezdap.shared")
local exe, tried = shared.resolve_path({ "dlv", "$GOBIN/dlv" }, shared.is_executable)
```

Use `shared.is_directory` for directories, your own predicate when working means more than
present (a minimum version, say), and `opts.transform` to test a file inside a found
directory (a virtualenv mapped to its `bin/python`, for instance).

## Templates

The definitions in [ezdap-adapters.nvim](https://github.com/mbfoss/ezdap-adapters.nvim) are
worked examples of the common shapes: an adapter spoken to over stdio, one located on
`PATH` or in a package directory, and one started as a server and then connected to. Pick
the one closest to your adapter and adapt it. The full contract is in the
`ezdap.AdapterDef` and `ezdap.Mode` annotations in `lua/ezdap/adapter_def.lua`.

Contributions of new definitions are welcome. Please follow the structure and comment style
of the existing files, and cite the adapter's own documentation that the field set is
based on at the top of the file.
