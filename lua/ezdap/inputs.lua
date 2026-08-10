---@brief The input registry: one row per scalar `ezdap.InputType`, and one per
---`ezdap.InputFormat` extending the type it names.

local M = {}

---One scalar type, in every form it is read: an input's whole value, or one entry
---of a `list`/`map`. A row with no `parse` is one whose string form is the string
---itself.
---@class ezdap.InputDef
---@field type       ezdap.InputType   what `build` receives
---@field schema     table               JSON Schema for the typed authored form
---@field seed       any                 starting value for a scaffolded document
---@field parse?     fun(raw: string): any?, string?  the string authored form → a value of `type`
---@field complete?  fun(partial: string): string[]  candidate values, for command lines

---A format **extends** one type row: the type still says what the value is, reads
---it and seeds it, and the format only adds to that reading. Every field is
---optional because every field is an addition.
---@class ezdap.FormatDef
---@field extends    ezdap.InputType   the type this narrows; the value stays that type
---@field schema?    table               constraints merged onto the type's schema
---@field refine?    fun(value: any): any  normalize an accepted value (a path, expanded)
---@field check?     fun(value: any): string?  reject a value of that type this format doesn't take
---@field complete?  fun(partial: string): string[]  candidates, in place of the type's

-- Parsing: a scalar's string authored form

---A path as written, with `~`, `$VAR` and redundant separators resolved. Not
---`expand()`: that reads a leading `%`/`#`/`<` as a cmdline-special name, which
---rewrites a path that starts with one and *raises* when there is nothing to name.
---@param raw string
---@return string
local function _path(raw)
    return vim.fs.normalize(raw)
end

---@param raw string
---@return integer? value, string? err
local function _integer(raw)
    -- Digits only. `tonumber` would also take `0x10`, `1.0` and `1e400` — the last
    -- an infinity that passes every integer test and that no JSON encoder can write.
    local n = raw:match("^%s*[-+]?%d+%s*$") and tonumber(raw)
    if not n then
        return nil, ("expected an integer, got %q"):format(raw)
    end
    return math.floor(n)
end

---@param raw string
---@return number? value, string? err
local function _number(raw)
    local n = tonumber(raw)
    -- A non-finite number is no more sendable than an unparseable one.
    if not n or n ~= n or math.abs(n) == math.huge then
        return nil, ("expected a number, got %q"):format(raw)
    end
    return n
end

---@param raw string
---@return boolean? value, string? err
local function _boolean(raw)
    local low = raw:lower()
    if low == "true" or low == "1" or low == "yes" then return true end
    if low == "false" or low == "0" or low == "no" then return false end
    return nil, ("expected a boolean (true/false), got %q"):format(raw)
end

---@param value integer
---@return string? err
local function _port_range(value)
    if value < 0 or value > 65535 then
        return ("port out of range (0-65535), got %s"):format(value)
    end
end

-- Completion

---Candidates carry their spaces escaped, the way the argument they extend was
---typed: an unescaped candidate no longer starts with the ArgLead it is filtered
---against, and is dropped before it is ever offered.
---@param values string[]
---@return string[]
local function _escaped(values)
    return vim.tbl_map(function(v) return vim.fn.escape(v, " \t") end, values)
end

---Completion drawn from Neovim's own `getcompletion` — paths, for the path-ish
---formats. `kind` is a `getcompletion` type ("file"/"dir").
---@param kind string
---@return fun(partial: string): string[]
local function _complete_path(kind)
    return function(partial) return _escaped(vim.fn.getcompletion(partial, kind)) end
end

---Completion for a command line: paths, for the program and for every argument
---after it. A debuggee is a binary the project built, not a name on `$PATH`, so
---this is `file` completion applied to whichever token is being typed.
---@param partial string
---@return string[]
local function _complete_command(partial)
    -- Vim's argument splitting means the line arrives with its spaces escaped
    -- (`command=./a.out\ --flag`); tokens are found in the real line, and the head
    -- goes back onto each candidate.
    local line = (partial:gsub("\\(%s)", "%1"))
    local head = line:match("^.*%s") or ""
    local tail = line:sub(#head + 1)
    return _escaped(vim.tbl_map(function(v) return head .. v end,
        vim.fn.getcompletion(tail, "file")))
end

---Completion over a fixed set of values, offering those that extend `partial`.
---@param values string[]
---@return fun(partial: string): string[]
local function _complete_choices(values)
    return function(partial)
        return vim.tbl_filter(function(v) return vim.startswith(v, partial) end, values)
    end
end

-- The rows

---The plain reading of each scalar type — what an input says when it names no
---format, and what a collection's entries are read as.
---@type table<string, ezdap.InputDef>
M.types = {
    string  = { type = "string", schema = { type = "string" }, seed = "" },
    integer = { type = "integer", schema = { type = "integer" }, parse = _integer, seed = 0 },
    number  = { type = "number", schema = { type = "number" }, parse = _number, seed = 0 },
    boolean = { type = "boolean", schema = { type = "boolean" }, parse = _boolean, seed = false, complete = _complete_choices({ "true", "false" }) },
}

---Each format extends one type above with a narrower reading of the same value —
---a string that is a path, an integer that is a port. Nothing a type already
---answers (how the value is parsed, seeded, what it is) is restated here.
---@type table<string, ezdap.FormatDef>
M.formats = {
    file    = { extends = "string", refine = _path, complete = _complete_path("file") },
    dir     = { extends = "string", refine = _path, complete = _complete_path("dir") },
    command = { extends = "string", complete = _complete_command },
    port    = { extends = "integer", schema = { minimum = 0, maximum = 65535 }, check = _port_range },
}

-- Resolution: an input, once, as the rows that read it

---What every projection needs from an input, looked up once: the scalar row its
---values (or its *entries*) are read by, the format extending that row, whether it
---is a collection, and the input's own enumerated values.
---@class ezdap.inputs.Resolved
---@field def     ezdap.InputDef
---@field fmt     ezdap.FormatDef?
---@field kind    "list"|"map"|nil  nil for a scalar input
---@field choices string[]?

---A mistake in how an input was *declared*, not in the value answering it: the
---profile's `inputs` table says something that can't be read. Said so, because it
---reaches the user down the same path as "expected an integer, got …".
---@param msg string
---@param ... any
---@return string
local function _decl_err(msg, ...)
    return "Error in adapter definition - invalid input: " .. msg:format(...)
end

---@param input_type ezdap.InputType?
---@return "list"|"map"|nil
local function _collection_kind(input_type)
    if input_type == "list" then return "list" end
    if input_type == "map" then return "map" end
    return nil
end

---One scalar's row and the format extending it, from the pair of names that
---declared them. The type decides, so a format that extends another type doesn't
---apply and is reported. Unknown or unnamed is `string`, so the lookup is total.
---@param type_name string?    the declared type, if any
---@param format_name string?  the declared format, if any
---@param what string          how the two are spelled, for the error message
---@return ezdap.InputDef def, ezdap.FormatDef? fmt, string? err
local function _scalar_def(type_name, format_name, what)
    -- Authors see one flat vocabulary, so a format may be named in the type slot and
    -- stands for the type it extends. An explicit format still decides — a type that
    -- named a different one is then the disagreement reported below.
    local named = type_name and M.formats[type_name]
    if named then
        format_name, type_name = format_name or type_name, named.extends
    end
    local scalar = not _collection_kind(type_name) and type_name or nil
    local fmt = format_name and M.formats[format_name] or nil
    if fmt then
        if scalar and scalar ~= fmt.extends then
            return M.types[scalar] or M.types.string, nil,
                _decl_err("%s %q extends %s, but the input is declared %s",
                    what, format_name, fmt.extends, scalar)
        end
        return M.types[fmt.extends], fmt
    end
    return M.types[scalar] or M.types.string
end

---Which of an input's declarations don't apply to the shape it is: the pair that
---describes entries on a scalar, the pair that describes a whole value on a
---collection. A mistake, not a silent no-op — either would read as a string.
---@param input ezdap.Input
---@param kind "list"|"map"|nil
---@return string? err
local function _stray_decl(input, kind)
    if kind then
        if input.format then
            return _decl_err("format %q: a collection declares its entries with item_format", input.format)
        end
        if _collection_kind(input.item_type) then
            return _decl_err("item_type %q: a collection's entries are scalars", input.item_type)
        end
        return nil
    end
    local stray = input.item_type and "item_type" or input.item_format and "item_format"
    return stray and _decl_err("%s: only a list or map declares entries", stray) or nil
end

---An input as the rows that read it. A collection declares its *entries* separately
---— `item_type`/`item_format`, so a list of paths and a list of integers are both
---sayable — and a scalar its own `type`/`format`.
---@param input ezdap.Input?
---@return ezdap.inputs.Resolved, string? err
local function _resolve(input)
    input = input or {}
    local kind = _collection_kind(input.type)
    local resolved = { def = M.types.string, kind = kind, choices = input.choices }

    local err = _stray_decl(input, kind)
    if err then return resolved, err end

    local def, fmt, def_err
    if kind then
        def, fmt, def_err = _scalar_def(input.item_type, input.item_format, "item_format")
    else
        def, fmt, def_err = _scalar_def(input.type, input.format, "format")
    end
    resolved.def, resolved.fmt = def, fmt
    return resolved, def_err
end

-- Reading a value, in either authored form

---Does a value have the Lua shape a scalar type names? `integer` is the one that
---isn't just `type()`: Lua has a single number type, so integer-ness is a test on
---the value, and a non-finite number is neither an integer nor encodable.
---@type table<string, fun(v: any): boolean>
local _is_type = {
    string  = function(v) return type(v) == "string" end,
    boolean = function(v) return type(v) == "boolean" end,
    number  = function(v) return type(v) == "number" and v == v and math.abs(v) ~= math.huge end,
    integer = function(v) return type(v) == "number" and v == math.floor(v) and math.abs(v) ~= math.huge end,
}

---A value as an error message names it, without spelling out a whole table.
---@param value any
---@return string
local function _show(value)
    if type(value) == "table" then return "a table" end
    return vim.inspect(value)
end

---Hold one scalar to its type, then to the format extending it: the shape the type
---names, the format's own normalization, then what the format refuses. Both forms
---pass through here — a parsed string leaving `parse`, a typed value entering `read`.
---@param r ezdap.inputs.Resolved
---@param value any
---@return any? value, string? err
local function _accept(r, value)
    if not _is_type[r.def.type](value) then
        return nil, ("expected %s, got %s"):format(r.def.type, _show(value))
    end
    local fmt = r.fmt
    if not fmt then return value end
    if fmt.refine then value = fmt.refine(value) end
    local err = fmt.check and fmt.check(value)
    if err then return nil, err end
    return value
end

---Read one scalar — an input's whole value, or one element of a collection — from
---its string form. A row with no `parse` is one whose string form is the string itself.
---@param r ezdap.inputs.Resolved
---@param raw string
---@return any? value, string? err
local function _parse_scalar(r, raw)
    local value = raw
    if r.def.parse then
        local err
        value, err = r.def.parse(raw)
        if err then return nil, err end
    end
    return _accept(r, value)
end

---An empty Lua table encodes as a JSON array, so an empty map must say it is one.
---@param kind "list"|"map"
---@param out table
---@return table
local function _sealed(kind, out)
    if kind == "map" and next(out) == nil then return vim.empty_dict() end
    return out
end

---Read a collection's string form: comma-separated entries, each element kept
---whole so it may contain spaces (a full LLDB command line), and each `key=value`
---for a `map` — environment variables, source-path remappings.
---@param r ezdap.inputs.Resolved  its `def`/`fmt` read one entry
---@param raw string
---@return table? value, string? err
local function _parse_collection(r, raw)
    local out = {}
    for _, entry in ipairs(vim.split(raw, ",", { plain = true, trimempty = true })) do
        local key, text = nil, entry
        if r.kind == "map" then
            local eq = entry:find("=", 1, true)
            if not eq then
                return nil, ("expected KEY=VALUE pairs, got %q"):format(entry)
            end
            key, text = entry:sub(1, eq - 1), entry:sub(eq + 1)
        end
        local value, err = _parse_scalar(r, text)
        if err then return nil, err end
        if key then out[key] = value else out[#out + 1] = value end
    end
    return _sealed(r.kind, out)
end

---Read a collection's typed form. Its type and format describe one entry, so that
---is what each of them answers to; a refined entry is a new value, so the collection
---is rebuilt rather than the caller's own table written through.
---@param r ezdap.inputs.Resolved  its `def`/`fmt` read one entry
---@param value any
---@return table? value, string? err
local function _read_collection(r, value)
    if type(value) ~= "table" then
        return nil, ("expected a %s, got %s"):format(r.kind, _show(value))
    end
    if r.kind == "list" and not vim.islist(value) then
        return nil, "expected a list of entries, got a keyed table"
    end
    local out = {}
    for key, item in pairs(value) do
        if r.kind == "map" and type(key) ~= "string" then
            return nil, ("expected string keys, got %s"):format(_show(key))
        end
        local entry, err = _accept(r, item)
        if err then return nil, ("%s: %s"):format(key, err) end
        out[key] = entry
    end
    return _sealed(r.kind, out)
end

-- The projections

---@param input ezdap.Input?
---@param raw string
---@return any? value, string? err
function M.parse(input, raw)
    local r, err = _resolve(input)
    if err then return nil, err end
    if r.kind then return _parse_collection(r, raw) end
    return _parse_scalar(r, raw)
end

---@param input ezdap.Input?
---@param value any
---@return any? value, string? err
function M.read(input, value)
    local r, err = _resolve(input)
    if err then return nil, err end
    if r.kind then return _read_collection(r, value) end
    return _accept(r, value)
end

---@param input ezdap.Input?
---@return table
function M.json_schema(input)
    -- A collection's `item_type`/`item_format` and its choices describe one *entry*, so
    -- all of them land on the element schema — the array's items, the object's values. A
    -- format only constrains what its type already said, so its schema is merged onto it.
    local r = _resolve(input)
    local schema = vim.deepcopy(r.def.schema)
    if r.fmt and r.fmt.schema then
        schema = vim.tbl_extend("force", schema, vim.deepcopy(r.fmt.schema))
    end
    if r.choices then schema.examples = vim.deepcopy(r.choices) end

    if r.kind == "list" then return { type = "array", items = schema } end
    if r.kind == "map" then return { type = "object", additionalProperties = schema } end
    return schema
end

---A starting value for an input in a scaffolded document, appropriate to the form
---it is authored in. Deep-copied, so callers may keep or mutate it.
---@param input ezdap.Input?
---@return any
function M.seed(input)
    -- A collection is seeded empty whatever its elements are, so its row — which
    -- describes one element — has nothing to say here. A format narrows a value,
    -- never starts a different one, so the type row seeds either way.
    local r = _resolve(input)
    if r.kind == "map" then return vim.empty_dict() end
    if r.kind then return {} end
    return vim.deepcopy(r.def.seed)
end

---The part of a collection's string form a value completes: everything before it
---is kept, everything after is what was typed. A comma starts a fresh entry, and in
---a `map` the value follows that entry's `=` — until it is typed, there is no value.
---@param kind "list"|"map"|nil
---@param partial string
---@return string? head, string? tail  nil when what is being typed is a map's key
local function _entry_at(kind, partial)
    if not kind then return "", partial end
    local head = partial:match("^.*,") or ""
    if kind == "map" then
        local key = partial:sub(#head + 1):match("^[^=]*=")
        if not key then return nil, nil end
        head = head .. key
    end
    return head, partial:sub(#head + 1)
end

---Candidate values for an input's **string form** — what a command line offers for
---the value half of `name=value`, or for the entry being typed in a collection. An
---input's own `choices` answer first, then its row. Empty when nothing enumerates.
---@param input ezdap.Input?
---@param partial string?  the value typed so far
---@return string[]
function M.completion(input, partial)
    local r = _resolve(input)
    local head, tail = _entry_at(r.kind, partial or "")
    if not head or not tail then return {} end

    -- A format completes in place of its type: it is the narrower set of the two.
    local complete = r.choices and _complete_choices(r.choices)
        or (r.fmt and r.fmt.complete)
        or r.def.complete
    if not complete then return {} end

    local values = complete(tail)
    if head == "" then return values end
    return vim.tbl_map(function(v) return head .. v end, values)
end

---What one element of an input's value becomes — a `list` entry, a `map` value:
---the type of the row its elements are read by, which its `item_type` names. Nil
---for an input that isn't a collection.
---@param input ezdap.Input?
---@return ezdap.InputType?
function M.item_value_type(input)
    local r = _resolve(input)
    return r.kind and r.def.type or nil
end

return M
