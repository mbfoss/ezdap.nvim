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
---`item_type`/`item_format` name.
---@alias ezdap.InputType
---| "string"   # the default
---| "boolean"
---| "integer"
---| "number"
---| "list"     # a table of entries
---| "map"      # a table of `key=value` entries

---An optional *extension* of a type: the value stays that type, read the same way,
---and the format only narrows it — normalizing it, refusing part of its range or
---completing it differently. Each names the type it extends.
---@alias ezdap.InputFormat
---| "file"        # extends string: a file path, normalized
---| "dir"         # extends string: a directory path, normalized
---| "command"     # extends string: a command line, verbatim (each token completed as a path)
---| "port"        # extends integer: range-checked (0-65535)

---A collection declares its *entries* with `item_type`/`item_format`, a scalar itself
---with `type`/`format`. A format may be named in either type slot (`type = "port"`),
---where it stands for the type it extends; naming a type it doesn't extend is an error.
---@class ezdap.Input
---@field required?    boolean  unset is an error (default false)
---@field type?        ezdap.InputType    default `string`
---@field format?      ezdap.InputFormat  an extension of `type`, for a scalar input
---@field item_type?   ezdap.InputType    a `list`/`map` entry's type, default `string`
---@field item_format? ezdap.InputFormat  an extension of `item_type`
---@field choices?     string[]  suggested values for the input
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
