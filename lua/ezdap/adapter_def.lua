---@meta
error("do not require a meta file")

---`mode` names the mode the run was resolved from, which the config itself
---does not record — it is how a `setup` gates one mode rather than the whole
---adapter (e.g. a feature only a newer binary supports). A `setup` should still
---treat nil as "not one of mine" and let the run proceed.
---@class ezdap.AdapterSetupCtx
---@field add_bufnr fun(bufnr: integer, opts?: ezdap.AddBufOpts)
---@field report    fun(message: string)
---@field mode?      string

---What an input's value *is*. A collection holds entries read as scalars, which its
---`item_type` names.
---@alias ezdap.InputType
---| "string"   # the default
---| "boolean"
---| "integer"
---| "number"
---| "list"     # a table of entries
---| "map"      # a table of `key=value` entries

---What an input offers when its value is being typed, in any of three forms: a
---named source, the values themselves, or a function computing them from what has
---been typed so far. Completion only *suggests* — nothing here rejects a value
---written past it, and what a path or a port additionally is, `build` says (see
---`ezdap.shared.normalize_path`, `ezdap.shared.resolve_port`).
---@alias ezdap.Completion
---| "file"     # a file path
---| "dir"      # a directory
---| "command"  # a command line, each token completed as a path
---| string[]   # the values themselves
---| fun(partial: string): string[]

---A collection declares its *entries* with `item_type`, a scalar its own `type`.
---`completion` describes one value either way — an entry, for a collection.
---@class ezdap.Input
---@field required?    boolean  unset is an error (default false)
---@field type?        ezdap.InputType  default `string`
---@field item_type?   ezdap.InputType  a `list`/`map` entry's type, default `string`
---@field completion?  ezdap.Completion  what the value completes with
---@field description? string   a few words on what the input means

---@class ezdap.Mode
---@field description  string
---@field request      "launch"|"attach"
---@field inputs?      table<string, ezdap.Input>  the mode's declared inputs
---@field build?       fun(inputs: table<string, any>): table?, table|string?  the DAP request body, plus an optional host/port overriding the adapter's; or nil and a message to abort

---@class ezdap.AdapterDef
---@field command?               string|string[]
---@field cwd?                   string
---@field env?                   table<string,string>
---@field host?                  string
---@field port?                  integer
---@field type?                  string   DAP adapterID override (defaults to the adapter name)
---@field defer_launch_attach?   boolean
---@field modes?                 table<string, ezdap.Mode>
---@field setup?                 fun(config: ezdap.dap.Config, ctx: ezdap.AdapterSetupCtx, callback: fun(err?: string, state?: any))
---@field teardown?              fun(config: ezdap.dap.Config, ctx: any)
