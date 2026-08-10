---@brief The input registry: one row per scalar `ezdap.InputType`, plus one per
---`ezdap.InputFormat` refining the type it names.

local M = {}

---One scalar reading, in every form it is read: an input's whole value, or one
---entry of a `list`/`map`. A row with no `parse` is one whose string form is the
---string itself.
---@class ezdap.InputDef
---@field type       ezdap.InputType   what `build` receives
---@field schema     table               JSON Schema for the typed authored form
---@field seed       any                 starting value for a scaffolded document
---@field parse?     fun(raw: string): any?, string?  the string authored form → a value of `type`
---@field check?     fun(value: any): string?  reject a value of the right `type` this row doesn't take
---@field complete?  fun(partial: string): string[]  candidate values, for command lines

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

---Hold one scalar to its row: the shape its `type` names, then whatever the row
---itself refuses. Both forms pass through here — a parsed string on its way out of
---`parse`, a typed value on its way in.
---@param def ezdap.InputDef
---@param value any
---@return string? err
local function _check(def, value)
    if not _is_type[def.type](value) then
        return ("expected %s, got %s"):format(def.type, _show(value))
    end
    return def.check and def.check(value) or nil
end

---Read one scalar — an input's whole value, or one element of a collection — by
---its row. A row with no `parse` is one whose string form is the string itself.
---@param def ezdap.InputDef
---@param raw string
---@return any? value, string? err
local function _read(def, raw)
    local value = raw
    if def.parse then
        local err
        value, err = def.parse(raw)
        if err then return nil, err end
    end
    local err = _check(def, value)
    if err then return nil, err end
    return value
end

---Read a collection's string form: comma-separated entries, each element kept
---whole so it may contain spaces (a full LLDB command line), and each `key=value`
---for a `map` — environment variables, source-path remappings.
---@param input_type "list"|"map"
---@param def ezdap.InputDef  the row its elements are read by
---@param raw string
---@return table? value, string? err
local function _read_collection(input_type, def, raw)
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
        local value, err = _read(def, text)
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

---Each format is a narrower reading of the type it names — a string that is a
---path, an integer that is a port — so a row here says which type it refines and
---then only what that plain reading doesn't.
---@type table<string, ezdap.InputDef>
M.formats = {
    file    = { type = "string", schema = { type = "string" }, parse = _path, seed = "", complete = _complete_path("file") },
    dir     = { type = "string", schema = { type = "string" }, parse = _path, seed = "", complete = _complete_path("dir") },
    command = { type = "string", schema = { type = "string" }, seed = "", complete = _complete_command },
    port    = { type = "integer", schema = { type = "integer", minimum = 0, maximum = 65535 }, parse = _integer, check = _port_range, seed = 0 },
}

---The row one input's values are read by: its format when it names one, its type
---otherwise — and for a collection, the row its *entries* answer to, which is why
---a formatless one reads them as strings. Unknown names fall back to `string`, so
---every input resolves to a row.
---@param input ezdap.Input?
---@return ezdap.InputDef
local function _def(input)
    local format = input and input.format
    if format ~= nil and M.formats[format] then
        return M.formats[format]
    end
    local input_type = input and input.type
    if _is_collection(input_type) then return M.types.string end
    return M.types[input_type] or M.types.string
end

---@param input ezdap.Input?
---@param raw string
---@return any? value, string? err
function M.parse(input, raw)
    local def = _def(input)
    local input_type = input and input.type
    if _is_collection(input_type) then
        return _read_collection(input_type --[[@as "list"|"map"]], def, raw)
    end
    return _read(def, raw)
end

---@param input ezdap.Input?
---@param value any
---@return any? value, string? err
function M.read(input, value)
    local def = _def(input)
    local input_type = input and input.type
    if not _is_collection(input_type) then
        local err = _check(def, value)
        if err then return nil, err end
        return value
    end

    if type(value) ~= "table" then
        return nil, ("expected a %s, got %s"):format(input_type, _show(value))
    end
    if input_type == "list" and not vim.islist(value) then
        return nil, "expected a list of entries, got a keyed table"
    end
    -- A collection's row describes one entry, so that is what each of them answers to.
    for key, item in pairs(value) do
        if input_type == "map" and type(key) ~= "string" then
            return nil, ("expected string keys, got %s"):format(_show(key))
        end
        local err = _check(def, item)
        if err then return nil, ("%s: %s"):format(key, err) end
    end
    if input_type == "map" and next(value) == nil then return vim.empty_dict() end
    return value
end

---@param input ezdap.Input?
---@return table
function M.json_schema(input)
    -- A collection's row and choices describe one *entry*, so both land on the
    -- element schema — the array's items, the object's values.
    local schema = vim.deepcopy(_def(input).schema)
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
    -- JSON array, which is why a map is seeded with the one that doesn't.
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
    local def = _def(input)
    local choices = input and input.choices
    local head, tail = _entry_at(input and input.type, partial or "")
    if not head or not tail then return {} end

    local values
    if choices then
        values = _complete_choices(choices)(tail)
    elseif def.complete then
        values = def.complete(tail)
    else
        return {}
    end

    if head == "" then return values end
    return vim.tbl_map(function(v) return head .. v end, values)
end

---What one element of an input's value becomes — a `list` entry, a `map` value:
---the type of the row its elements are read by. Nil for an input that isn't a
---collection.
---@param input ezdap.Input?
---@return ezdap.InputType?
function M.item_type(input)
    if not _is_collection(input and input.type) then return nil end
    return _def(input).type
end

return M
