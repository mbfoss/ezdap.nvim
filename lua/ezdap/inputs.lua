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
---optional because every field is an addition — a format that stated the whole
---reading would be a type.
---@class ezdap.FormatDef
---@field extends    ezdap.InputType   the type this narrows; the value stays that type
---@field schema?    table               constraints merged onto the type's schema
---@field refine?    fun(value: any): any  normalize an accepted value (a path, expanded)
---@field check?     fun(value: any): string?  reject a value of that type this format doesn't take
---@field complete?  fun(partial: string): string[]  candidates, in place of the type's

---@param input_type ezdap.InputType?
---@return boolean
local function _is_collection(input_type)
    return input_type == "list" or input_type == "map"
end

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
---@param def ezdap.InputDef
---@param fmt ezdap.FormatDef?
---@param value any
---@return any? value, string? err
local function _accept(def, fmt, value)
    if not _is_type[def.type](value) then
        return nil, ("expected %s, got %s"):format(def.type, _show(value))
    end
    if not fmt then return value end
    if fmt.refine then value = fmt.refine(value) end
    local err = fmt.check and fmt.check(value)
    if err then return nil, err end
    return value
end

---Read one scalar — an input's whole value, or one element of a collection — by
---its type row. A row with no `parse` is one whose string form is the string itself.
---@param def ezdap.InputDef
---@param fmt ezdap.FormatDef?
---@param raw string
---@return any? value, string? err
local function _read(def, fmt, raw)
    local value = raw
    if def.parse then
        local err
        value, err = def.parse(raw)
        if err then return nil, err end
    end
    return _accept(def, fmt, value)
end

---Read a collection's string form: comma-separated entries, each element kept
---whole so it may contain spaces (a full LLDB command line), and each `key=value`
---for a `map` — environment variables, source-path remappings.
---@param input_type "list"|"map"
---@param def ezdap.InputDef  the row its elements are read by
---@param fmt ezdap.FormatDef?
---@param raw string
---@return table? value, string? err
local function _read_collection(input_type, def, fmt, raw)
    local out = {}
    for _, entry in ipairs(vim.split(raw, ",", { plain = true, trimempty = true })) do
        local key, text = nil, entry
        if input_type == "map" then
            local eq = entry:find("=", 1, true)
            if not eq then
                return nil, ("expected KEY=VALUE pairs, got %q"):format(entry)
            end
            key, text = entry:sub(1, eq - 1), entry:sub(eq + 1)
        end
        local value, err = _read(def, fmt, text)
        if err then return nil, err end
        if key then out[key] = value else out[#out + 1] = value end
    end
    -- An empty Lua table encodes as a JSON array, so an empty map must say it is one.
    if input_type == "map" and next(out) == nil then return vim.empty_dict() end
    return out
end

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
    local scalar = not _is_collection(type_name) and type_name or nil
    local fmt = format_name and M.formats[format_name] or nil
    if fmt then
        if scalar and scalar ~= fmt.extends then
            return M.types[scalar] or M.types.string, nil,
                ("%s %q extends %s, but the input is declared %s")
                :format(what, format_name, fmt.extends, scalar)
        end
        return M.types[fmt.extends], fmt
    end
    return M.types[scalar] or M.types.string
end

---The row an input's values are read by, and the format extending it. A collection
---declares its *entries* separately — `item_type`/`item_format`, so a list of paths
---and a list of integers are both sayable — and a scalar its own `type`/`format`.
---@param input ezdap.Input?
---@return ezdap.InputDef def, ezdap.FormatDef? fmt, string? err
local function _def(input)
    input = input or {}
    -- The pair that doesn't apply is a mistake, not a silent no-op: an entry declared
    -- under `format` (or a scalar under `item_type`) would otherwise read as a string.
    local collection = _is_collection(input.type)
    local stray = collection and input.format and "format"
        or (not collection and (input.item_type and "item_type" or input.item_format and "item_format"))
    if stray then
        return M.types.string, nil, collection
            and ("format %q: a collection declares its entries with item_format"):format(input.format)
            or ("%s: only a list or map declares entries"):format(stray)
    end
    if not collection then
        return _scalar_def(input.type, input.format, "format")
    end
    if input.item_type and _is_collection(input.item_type) then
        return M.types.string, nil,
            ("item_type %q: a collection's entries are scalars"):format(input.item_type)
    end
    return _scalar_def(input.item_type, input.item_format, "item_format")
end

---@param input ezdap.Input?
---@param raw string
---@return any? value, string? err
function M.parse(input, raw)
    local def, fmt, err = _def(input)
    if err then return nil, err end
    local input_type = input and input.type
    if _is_collection(input_type) then
        return _read_collection(input_type --[[@as "list"|"map"]], def, fmt, raw)
    end
    return _read(def, fmt, raw)
end

---@param input ezdap.Input?
---@param value any
---@return any? value, string? err
function M.read(input, value)
    local def, fmt, err = _def(input)
    if err then return nil, err end
    local input_type = input and input.type
    if not _is_collection(input_type) then
        return _accept(def, fmt, value)
    end

    if type(value) ~= "table" then
        return nil, ("expected a %s, got %s"):format(input_type, _show(value))
    end
    if input_type == "list" and not vim.islist(value) then
        return nil, "expected a list of entries, got a keyed table"
    end
    -- A collection's type and format describe one entry, so that is what each of them
    -- answers to. A refined entry is a new value, so the collection is rebuilt rather
    -- than the caller's own table written through.
    local out = {}
    for key, item in pairs(value) do
        if input_type == "map" and type(key) ~= "string" then
            return nil, ("expected string keys, got %s"):format(_show(key))
        end
        local entry, entry_err = _accept(def, fmt, item)
        if entry_err then return nil, ("%s: %s"):format(key, entry_err) end
        out[key] = entry
    end
    if input_type == "map" and next(out) == nil then return vim.empty_dict() end
    return out
end

---@param input ezdap.Input?
---@return table
function M.json_schema(input)
    -- A collection's `item_type`/`item_format` and its choices describe one *entry*, so
    -- all of them land on the element schema — the array's items, the object's values. A
    -- format only constrains what its type already said, so its schema is merged onto it.
    local def, fmt = _def(input)
    local schema = vim.deepcopy(def.schema)
    if fmt and fmt.schema then schema = vim.tbl_extend("force", schema, vim.deepcopy(fmt.schema)) end
    local choices = input and input.choices
    if choices then schema.examples = vim.deepcopy(choices) end

    local input_type = input and input.type
    if input_type == "list" then return { type = "array", items = schema } end
    if input_type == "map" then return { type = "object", additionalProperties = schema } end
    return schema
end

---A starting value for an input in a scaffolded document, appropriate to the form
---it is authored in. Deep-copied, so callers may keep or mutate it.
---@param input ezdap.Input?
---@return any
function M.seed(input)
    -- A collection is seeded empty whatever its elements are, so its row — which
    -- describes one element — has nothing to say here. An empty table encodes as a
    -- JSON array, which is why a map is seeded with the one that doesn't. A format
    -- narrows a value, never starts a different one, so the type row seeds either way.
    local input_type = input and input.type
    if input_type == "map" then return vim.empty_dict() end
    if _is_collection(input_type) then return {} end
    return vim.deepcopy(_def(input).seed)
end

---The part of a collection's string form a value completes: everything before it
---is kept, everything after is what was typed. A comma starts a fresh entry, and in
---a `map` the value follows that entry's `=` — until it is typed, there is no value.
---@param input_type ezdap.InputType?
---@param partial string
---@return string? head, string? tail  nil when what is being typed is a map's key
local function _entry_at(input_type, partial)
    if not _is_collection(input_type) then return "", partial end
    local head = partial:match("^.*,") or ""
    if input_type == "map" then
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
    local def, fmt = _def(input)
    local choices = input and input.choices
    local head, tail = _entry_at(input and input.type, partial or "")
    if not head or not tail then return {} end

    -- A format completes in place of its type: it is the narrower set of the two.
    local complete = (fmt and fmt.complete) or def.complete
    local values
    if choices then
        values = _complete_choices(choices)(tail)
    elseif complete then
        values = complete(tail)
    else
        return {}
    end

    if head == "" then return values end
    return vim.tbl_map(function(v) return head .. v end, values)
end

---What one element of an input's value becomes — a `list` entry, a `map` value:
---the type of the row its elements are read by, which its `item_type` names. Nil
---for an input that isn't a collection.
---@param input ezdap.Input?
---@return ezdap.InputType?
function M.item_value_type(input)
    if not _is_collection(input and input.type) then return nil end
    return _def(input).type
end

return M
