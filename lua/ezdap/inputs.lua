---@brief The input-format registry: one row per `ezdap.InputFormat`.
---
---A profile's `inputs` declares a *value space*, and each consumer wants a
---different projection of it — `:Debug run` parses a command-line string into it,
---a tasks-file LSP describes it as JSON Schema, the scaffolders seed a starting
---document with it, and `:Debug` completion offers the values it can enumerate.
---Each projection used to be its own switch over the format enum, spread across
---two plugins, so adding a format meant finding all four and no two could be
---checked against each other. They live here instead, one row each.
---
---A value space has two authoring forms, and a format row describes both:
---
--- * the **string form** — a command line, where everything is text. `parse` reads
---   it. This is what `:Debug run`'s `name=value` arguments are.
--- * the **typed form** — a structured file that already has types (easytasks'
---   `tasks.toml`). `schema` describes it.
---
---`type` is what `build` receives, and both forms land there. They are not rival
---answers to "what is legal": they are one value space reached from a typed file
---or from an untyped command line, which is why a caller may mix the two per input
---(easytasks may write one input in string form and the next in typed form in the
---same task). `map` shows it plainly — `"A=1,B=2"` on a command line, an object of
---the same pairs in a typed file, and `build` receives the same table either way.
---
---A format's two forms describe *one* value, so a row whose forms disagree about
---what the value even is doesn't belong here. Splitting a command line into
---arguments is such a case: it is a transformation of one string into a different
---shape, not a second way of writing the same value, and it lived here for a while
---as `shell_args` — declaring a `string` schema against a `table` type, the only
---row that had to be explained twice. It is now where it belongs, in the `build`
---that wants the split (`shared.split_command`).
---
---A format never changes the declared `type`, which is why *every row here is a
---scalar*. Being a collection is a `type` — `list` or `map` — and a collection's
---row is the one its **elements** are read by, so `list` × `file` is a list of
---paths and `map` × `port` a mapping to ports, without either being a row. The
---projections below compose the two.
---
---A type is itself a format — the one that constrains nothing — so the plain
---reading of each scalar is a row here too, and an input's row is `format` if it
---names one and `type` otherwise. That makes the lookup **total**: every input
---resolves to a row, so every input has a schema, a seed and a way to be read by
---construction rather than by a fallback ladder in each projection, and a `list` of
---anything is said the same way a scalar is (`format = "integer"`). Nothing outside
---this module switches on a format name; consumers call the projections below.

local M = {}

-- The registry

---One format, in all the ways it is read — a scalar value, whether it is an
---input's whole value or one element of a `list`/`map`. `parse` is omitted by the
---rows whose string form *is* the string; `seed` is a starting value for a
---scaffolded document.
---@class ezdap.FormatDef
---@field type       ezdap.InputType   what `build` receives
---@field schema     table               JSON Schema for the typed authored form
---@field seed       any                 starting value for a scaffolded document
---@field parse?     fun(raw: string): any?, string?  the string authored form → a value of `type`
---@field complete?  fun(partial: string): string[]  candidate values, for command lines

---Is this a collection type — one whose string form is a comma-separated list of
---entries, each read by the input's format?
---@param input_type ezdap.InputType?
---@return boolean
local function _is_collection(input_type)
    return input_type == "list" or input_type == "map"
end

---@param raw string
---@return string
local function _expand(raw)
    return vim.fn.expand(raw)
end

---@param raw string
---@return integer? value, string? err
local function _integer(raw)
    local n = tonumber(raw)
    if not n or n ~= math.floor(n) then
        return nil, ("expected an integer, got %q"):format(raw)
    end
    return math.floor(n)
end

---@param raw string
---@return number? value, string? err
local function _number(raw)
    local n = tonumber(raw)
    if not n then return nil, ("expected a number, got %q"):format(raw) end
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

---@param raw string
---@return integer? value, string? err
local function _port(raw)
    local n, err = _integer(raw)
    if err then return nil, err end
    if n < 0 or n > 65535 then
        return nil, ("port out of range (0-65535), got %d"):format(n)
    end
    return n
end

---Read one scalar — an input's whole value, or one element of a collection — by
---its row. A row with no `parse` is one whose string form is the string itself.
---@param def ezdap.FormatDef
---@param raw string
---@return any? value, string? err
local function _read(def, raw)
    if not def.parse then return raw end
    return def.parse(raw)
end

---Read a collection's string form: comma-separated entries, each element kept
---whole so it may contain spaces (a full LLDB command line), and each `key=value`
---for a `map` — environment variables, source-path remappings.
---@param input_type "list"|"map"
---@param def ezdap.FormatDef  the row its elements are read by
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
    return out
end

---Completion drawn from Neovim's own `getcompletion` — paths, for the path-ish
---formats. `kind` is a `getcompletion` type ("file"/"dir").
---@param kind string
---@return fun(partial: string): string[]
local function _complete_path(kind)
    return function(partial) return vim.fn.getcompletion(partial, kind) end
end

---Completion for a command line: paths, for the program and for every argument
---after it. A debuggee is a binary the project built, not a name on `$PATH`, so
---this is `file` completion applied to whichever token is being typed.
---@param partial string
---@return string[]
local function _complete_command(partial)
    -- Vim's argument splitting means the line arrives with its spaces escaped
    -- (`command=./a.out\ --flag`); tokens are found in the real line, and the head
    -- goes back onto each candidate — escaped again, so it still extends what was typed.
    local line = (partial:gsub("\\(%s)", "%1"))
    local head = line:match("^.*%s") or ""
    local tail = line:sub(#head + 1)
    return vim.tbl_map(function(v) return vim.fn.escape(head .. v, " \t") end,
        vim.fn.getcompletion(tail, "file"))
end

---Completion over a fixed set of values, offering those that extend `partial`.
---@param values string[]
---@return fun(partial: string): string[]
local function _complete_choices(values)
    return function(partial)
        return vim.tbl_filter(function(v) return vim.startswith(v, partial) end, values)
    end
end

---Every declared `ezdap.InputFormat`, plus the plain reading of each scalar type —
---a type *is* a format, the one that constrains nothing, which is what lets an
---input with no format of its own still resolve to a row. `file`/`dir` differ only
---in the completion they drive, not in the value they produce, which is why `dir`
---covers a working directory too; `command` is a verbatim string the wanting
---`build` splits itself. A host needs no row: it is the plain `string`, and the
---addresses worth offering are the adapter's to name as `choices`.
---@type table<string, ezdap.FormatDef>
M.formats = {
    string  = { type = "string", schema = { type = "string" }, seed = "" },
    integer = { type = "integer", schema = { type = "integer" }, parse = _integer, seed = 0 },
    number  = { type = "number", schema = { type = "number" }, parse = _number, seed = 0 },
    boolean = { type = "boolean", schema = { type = "boolean" }, parse = _boolean, seed = false, complete = _complete_choices({ "true", "false" }) },

    file    = { type = "string", schema = { type = "string" }, parse = _expand, seed = "", complete = _complete_path("file") },
    dir     = { type = "string", schema = { type = "string" }, parse = _expand, seed = "", complete = _complete_path("dir") },
    command = { type = "string", schema = { type = "string" }, seed = "", complete = _complete_command },
    port    = { type = "integer", schema = { type = "integer", minimum = 0, maximum = 65535 }, parse = _port, seed = 0 },
}

-- Projections

---The row an input's value is read by: its declared format, else the plain reading
---of its `type`. For a collection that row is its *elements*' — which is why a
---`list`/`map` lands on `string` when it names no format. Never nil, so no
---projection needs a type ladder of its own; an unknown format or type is a
---declaration bug, and the plainest reading is what answers it.
---@param input ezdap.Input?
---@return ezdap.FormatDef
local function _def(input)
    local format = input and input.format
    if format ~= nil and format ~= "" and M.formats[format] then
        return M.formats[format]
    end
    local input_type = input and input.type
    if _is_collection(input_type) then return M.formats.string end
    return M.formats[input_type] or M.formats.string
end

---Read an input's **string form** — a raw `name=value` argument — into a value of
---its declared `type`, by the row that reads it. A collection type splits into
---entries first, and that row reads each of them.
---@param input ezdap.Input
---@param raw string
---@return any? value, string? err
function M.parse(input, raw)
    local def = _def(input)
    if _is_collection(input.type) then
        return _read_collection(input.type --[[@as "list"|"map"]], def, raw)
    end
    return _read(def, raw)
end

---JSON Schema for an input's **typed form** — how a structured file writes it.
---Every input resolves to a row, so every input has a schema: the row's, wrapped
---in an array/object for a collection. An input's `choices` are `examples`, not an
---`enum`: they are offered, never required, so the typed form stays as permissive
---as the command line. A fresh table each call: callers annotate it (with the
---input's `description`) and must not reach the registry's own rows.
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
    -- describes one element — has nothing to say here.
    if _is_collection(input and input.type) then return {} end
    return vim.deepcopy(_def(input).seed)
end

---The part of a collection's string form a value completes: everything before it
---is kept, everything after is what was typed. A comma starts a fresh entry, and
---in a `map` the value being completed is what follows that entry's `=`.
---@param input_type ezdap.InputType?
---@param partial string
---@return string head, string tail
local function _entry_at(input_type, partial)
    if not _is_collection(input_type) then return "", partial end
    local head = partial:match("^.*,") or ""
    if input_type == "map" then
        head = head .. (partial:sub(#head + 1):match("^[^=]*=") or "")
    end
    return head, partial:sub(#head + 1)
end

---Candidate values for an input's **string form** — what a command line offers for
---the value half of `name=value`, or for the entry being typed in a collection. An
---input's own `choices` answer first, then its row (paths, or the two ways a
---boolean is written). Empty when the values can't be enumerated.
---@param input ezdap.Input?
---@param partial string?  the value typed so far
---@return string[]
function M.completion(input, partial)
    local def = _def(input)
    local choices = input and input.choices
    local head, tail = _entry_at(input and input.type, partial or "")

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
