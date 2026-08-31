---@brief The input registry: one row per scalar `ezdap.InputType`, plus the named
---completion sources an input's `completion` may ask for.

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

-- Parsing: a scalar's string authored form

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
---sources. `kind` is a `getcompletion` type ("file"/"dir").
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

---The reading of each scalar type — what an input's own value is, and what a
---collection's entries are read as.
---@type table<string, ezdap.InputDef>
M.types = {
    string  = { type = "string", schema = { type = "string" }, seed = "" },
    integer = { type = "integer", schema = { type = "integer" }, parse = _integer, seed = 0 },
    number  = { type = "number", schema = { type = "number" }, parse = _number, seed = 0 },
    boolean = { type = "boolean", schema = { type = "boolean" }, parse = _boolean, seed = false, complete = _complete_choices({ "true", "false" }) },
}

---The completion an input asks for by name, when what it offers is not a set the
---definition can write out. These only *offer* values — nothing here reads or
---rejects one, so a source never changes what `build` receives.
---@type table<string, fun(partial: string): string[]>
M.sources = {
    file    = _complete_path("file"),
    dir     = _complete_path("dir"),
    command = _complete_command,
}

-- Resolution: an input, once, as the rows that read it

---What every projection needs from an input, looked up once: the scalar row its
---values (or its *entries*) are read by, whether it is a collection, and what the
---input completes with — as a function, plus the values themselves when it named
---a set (a schema can list those; a function has nothing to serialize).
---@class ezdap.inputs.Resolved
---@field def      ezdap.InputDef
---@field kind     "list"|"map"|nil  nil for a scalar input
---@field complete (fun(partial: string): string[])?
---@field values   string[]?

---A mistake in how an input was *declared*, not in the value answering it: the
---mode's `inputs` table says something that can't be read. Said so, because it
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

---One scalar's row, from the name that declared it. Unnamed is `string`, so a
---plain input needs no `type` at all; a name that is no type is a mistake rather
---than a silent string, which is how a value would otherwise stop being read.
---@param type_name string?  the declared type, if any
---@param what string        which slot it was written in, for the error message
---@return ezdap.InputDef def, string? err
local function _scalar_def(type_name, what)
    if not type_name then return M.types.string end
    local def = M.types[type_name]
    if not def then
        return M.types.string, _decl_err("%s %q is not a type", what, type_name)
    end
    return def
end

---Which of an input's declarations don't apply to the shape it is: `item_type`
---on a scalar, an entry type that is itself a collection. A mistake, not a silent
---no-op — either would read as a string.
---@param input ezdap.Input
---@param kind "list"|"map"|nil
---@return string? err
local function _stray_decl(input, kind)
    if not kind then
        return input.item_type and _decl_err("item_type: only a list or map declares entries") or nil
    end
    if _collection_kind(input.item_type) then
        return _decl_err("item_type %q: a collection's entries are scalars", input.item_type)
    end
end

---What an input completes with, from the three forms `completion` is written in:
---a named source, the values themselves, or a function computing them. Nil is the
---input that enumerates nothing, and its type's own completion then answers.
---@param completion ezdap.Completion?
---@return (fun(partial: string): string[])? complete, string[]? values, string? err
local function _completion(completion)
    if completion == nil then return nil end
    if type(completion) == "function" then return completion end
    if type(completion) == "string" then
        local source = M.sources[completion]
        if not source then
            return nil, nil, _decl_err("completion %q: no such source (%s)",
                completion, table.concat(vim.fn.sort(vim.tbl_keys(M.sources)), ", "))
        end
        return source
    end
    if type(completion) == "table" and vim.islist(completion) then
        for _, value in ipairs(completion) do
            if type(value) ~= "string" then
                return nil, nil, _decl_err("completion: expected strings, got a %s entry", type(value))
            end
        end
        return _complete_choices(completion), completion
    end
    return nil, nil, _decl_err("completion: expected a source name, a list of values or a function")
end

---An input as the rows that read it. A collection declares its *entries* separately
---— `item_type`, so a list of names and a list of integers are both sayable — and a
---scalar its own `type`. `completion` describes an entry either way.
---@param input ezdap.Input?
---@return ezdap.inputs.Resolved, string? err
local function _resolve(input)
    input = input or {}
    local kind = _collection_kind(input.type)
    local resolved = { def = M.types.string, kind = kind }

    local err = _stray_decl(input, kind)
    if not err then
        resolved.complete, resolved.values, err = _completion(input.completion)
    end
    if err then return resolved, err end

    local def, def_err
    if kind then
        def, def_err = _scalar_def(input.item_type, "item_type")
    else
        def, def_err = _scalar_def(input.type, "type")
    end
    resolved.def = def
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

---Hold one scalar to the shape its type names. Both authored forms pass through
---here — a parsed string leaving `parse`, a typed value entering `read` — and this
---is the whole of what the registry refuses: what a *path* or a *port* additionally
---is, `build` says, with the helpers in `ezdap.shared`.
---@param r ezdap.inputs.Resolved
---@param value any
---@return any? value, string? err
local function _accept(r, value)
    if not _is_type[r.def.type](value) then
        return nil, ("expected %s, got %s"):format(r.def.type, _show(value))
    end
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

---Split a collection's string form on its separating commas. `\,` is a literal
---comma in an entry; every other backslash is part of the value, since these
---entries are paths and command lines.
---@param raw string
---@return string[]
local function _split_entries(raw)
    local entries, entry, i = {}, {}, 1
    local function flush()
        local text = table.concat(entry)
        if text ~= "" then entries[#entries + 1] = text end
        entry = {}
    end
    while i <= #raw do
        local c = raw:sub(i, i)
        if c == "\\" and raw:sub(i + 1, i + 1) == "," then
            entry[#entry + 1] = ","
            i = i + 2
        elseif c == "," then
            flush()
            i = i + 1
        else
            entry[#entry + 1] = c
            i = i + 1
        end
    end
    flush()
    return entries
end

---Read a collection's string form: comma-separated entries, each element kept
---whole so it may contain spaces (a full LLDB command line), and each `key=value`
---for a `map` — environment variables, source-path remappings.
---@param r ezdap.inputs.Resolved  its `def` reads one entry
---@param raw string
---@return table? value, string? err
local function _parse_collection(r, raw)
    local out = {}
    for _, entry in ipairs(_split_entries(raw)) do
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

---Read a collection's typed form. Its `item_type` describes one entry, so that is
---what each of them answers to; the collection is rebuilt rather than the caller's
---own table written through.
---@param r ezdap.inputs.Resolved  its `def` reads one entry
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
    -- A collection's `item_type` and its completion describe one *entry*, so both land
    -- on the element schema — the array's items, the object's values. Only a written-out
    -- set of values is sayable here: a source or a function has nothing to serialize.
    local r = _resolve(input)
    local schema = vim.deepcopy(r.def.schema)
    if r.values then schema.examples = vim.deepcopy(r.values) end

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
    -- describes one element — has nothing to say here.
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
---input's own `completion` answers first, then its row. Empty when nothing enumerates.
---@param input ezdap.Input?
---@param partial string?  the value typed so far
---@return string[]
function M.completion(input, partial)
    local r = _resolve(input)
    local head, tail = _entry_at(r.kind, partial or "")
    if not head or not tail then return {} end

    -- What the input asked for stands in place of its type's own: it is the narrower
    -- set of the two, and the only one that knows this particular value.
    local complete = r.complete or r.def.complete
    if not complete then return {} end

    local values = complete(tail)
    if head == "" then return values end
    return vim.tbl_map(function(v) return head .. v end, values)
end

---What is wrong with how an input is *declared*, if anything: a type that is no
---type, a scalar declaring an entry type, an entry type that is itself a
---collection, a completion in none of its three forms. Nil when the input reads.
---@param input ezdap.Input?
---@return string? err
function M.check(input)
    local _, err = _resolve(input)
    return err
end

return M
