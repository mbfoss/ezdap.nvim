---@brief The input-format registry: one row per `ezdap.InputFormat`.
---
---A profile's `inputs` declares a *value space*, and each consumer wants a
---different projection of it — `quick_run` parses a command-line string into it,
---a tasks-file LSP describes it as JSON Schema, the scaffolders seed a starting
---document with it, and `:Debug` completion offers paths for the path-ish formats.
---Each projection used to be its own switch over the format enum, spread across
---two plugins, so adding a format meant finding all four and no two could be
---checked against each other. They live here instead, one row each.
---
---A value space has two authoring forms, and a format row describes both:
---
--- * the **string form** — a command line, where everything is text. `parse` reads
---   it. This is what `:Debug quick_run`'s `name=value` arguments are.
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
---Nothing outside this module switches on a format name; consumers call the
---projections below and let an unknown or absent format fall back to `type` alone.

local M = {}

-- The registry

---One format, in all the ways it is read. `parse` may be omitted when the string
---form is just the `type` read back. `seed` is a starting value for a scaffolded
---document; `item_type` is what one element of a collection format becomes.
---@class ezdap.FormatDef
---@field type       ezdap.InputType   what `build` receives
---@field item_type? ezdap.InputType   what one element becomes, for a collection
---@field schema     table               JSON Schema for the typed authored form
---@field parse?     fun(raw: string): any?, string?  the string authored form → a value of `type`
---@field seed?      any                 starting value for a scaffolded document
---@field complete?  "file"|"dir"        value completion kind, for command lines

---Read a raw string as a value of `input_type`. This is the no-format path — the
---string form of a format-less input, and the fallback for a row without a `parse`.
---@param input_type ezdap.InputType?
---@param raw string
---@return any? value, string? err
local function _by_type(input_type, raw)
    if input_type == nil or input_type == "" or input_type == "string" then
        return raw
    elseif input_type == "integer" then
        local n = tonumber(raw)
        if not n or n ~= math.floor(n) then
            return nil, ("expected an integer, got %q"):format(raw)
        end
        return math.floor(n)
    elseif input_type == "number" then
        local n = tonumber(raw)
        if not n then return nil, ("expected a number, got %q"):format(raw) end
        return n
    elseif input_type == "boolean" then
        local low = raw:lower()
        if low == "true" or low == "1" or low == "yes" then return true end
        if low == "false" or low == "0" or low == "no" then return false end
        return nil, ("expected a boolean (true/false), got %q"):format(raw)
    elseif input_type == "table" then
        -- Nothing about `table` says how a string becomes one — only a format does.
        return nil, "a table input needs a format (map/list)"
    end
    return raw
end

---@param raw string
---@return string
local function _expand(raw)
    return vim.fn.expand(raw)
end

---Resolve to an absolute path so `.`/relative dirs are anchored to Neovim's cwd,
---not the adapter's own working directory (which may differ).
---@param raw string
---@return string
local function _abspath(raw)
    return vim.fn.fnamemodify(vim.fn.expand(raw), ":p")
end

---@param raw string
---@return integer? value, string? err
local function _port(raw)
    local n, err = _by_type("integer", raw)
    if err then return nil, err end
    if n < 0 or n > 65535 then
        return nil, ("port out of range (0-65535), got %d"):format(n)
    end
    return n
end

---Comma-separated list of verbatim strings (each element kept whole, so entries
---may contain spaces — e.g. full LLDB command lines).
---@param raw string
---@return string[]
local function _list(raw)
    return vim.split(raw, ",", { plain = true, trimempty = true })
end

---Comma-separated `key=value` pairs — environment variables, source-path
---remappings, anything written as a flat string→string mapping.
---@param raw string
---@return table<string, string>? value, string? err
local function _map(raw)
    local out = {}
    for _, pair in ipairs(vim.split(raw, ",", { plain = true, trimempty = true })) do
        local eq = pair:find("=", 1, true)
        if not eq then
            return nil, ("expected KEY=VALUE pairs, got %q"):format(pair)
        end
        out[pair:sub(1, eq - 1)] = pair:sub(eq + 1)
    end
    return out
end

---Every declared `ezdap.InputFormat`. `file`/`dir` differ only in the completion
---they drive, not in the value they produce.
---@type table<string, ezdap.FormatDef>
M.formats = {
    file       = { type = "string",  schema = { type = "string" }, parse = _expand,  seed = "", complete = "file" },
    dir        = { type = "string",  schema = { type = "string" }, parse = _expand,  seed = "", complete = "dir" },
    cwd        = { type = "string",  schema = { type = "string" }, parse = _abspath, seed = "", complete = "dir" },
    host       = { type = "string",  schema = { type = "string" }, seed = "" },
    port       = { type = "integer", schema = { type = "integer", minimum = 0, maximum = 65535 }, parse = _port, seed = 0 },
    map        = { type = "table",   item_type = "string", schema = { type = "object", additionalProperties = { type = "string" } }, parse = _map,  seed = {} },
    list       = { type = "table",   item_type = "string", schema = { type = "array", items = { type = "string" } },    parse = _list, seed = {} },
}

-- Projections

---The row for an input's declared format, or nil when it declares none (or one
---this version doesn't know, which is a declaration bug — `type` still answers).
---@param input ezdap.Input?
---@return ezdap.FormatDef?
local function _def(input)
    local format = input and input.format
    if format == nil or format == "" then return nil end
    return M.formats[format]
end

---Read an input's **string form** — a raw `name=value` argument — into a value of
---its declared `type`. The format, when it declares a `parse`, is what does the
---reading; otherwise the string is read by `type` alone.
---@param input ezdap.Input
---@param raw string
---@return any? value, string? err
function M.parse(input, raw)
    local def = _def(input)
    if not def then return _by_type(input.type, raw) end
    if not def.parse then return _by_type(def.type, raw) end
    return def.parse(raw)
end

---JSON Schema for an input's **typed form** — how a structured file writes it.
---A fresh table each call: callers annotate it (with the input's `description`)
---and must not reach the registry's own rows.
---@param input ezdap.Input?
---@return table
function M.json_schema(input)
    local def = _def(input)
    if def then return vim.deepcopy(def.schema) end

    local input_type = input and input.type
    if input_type == "integer" or input_type == "number" or input_type == "boolean" then
        return { type = input_type }
    end
    -- A format-less `table` has no authoring form at all (`parse` says so); there
    -- is no schema that makes such a declaration true, so describe it as the string
    -- it will be written as and let the parse error name the real problem.
    return { type = "string" }
end

---A starting value for an input in a scaffolded document, appropriate to the form
---it is authored in. Deep-copied, so callers may keep or mutate it.
---@param input ezdap.Input?
---@return any
function M.seed(input)
    local def = _def(input)
    if def and def.seed ~= nil then return vim.deepcopy(def.seed) end

    local input_type = input and input.type
    if input_type == "integer" or input_type == "number" then return 0 end
    if input_type == "boolean" then return false end
    return ""
end

---The completion kind for an input's value on a command line, or nil for an input
---whose values can't be enumerated.
---@param input ezdap.Input?
---@return "file"|"dir"|nil
function M.completion(input)
    local def = _def(input)
    return def and def.complete or nil
end

---What one element of an input's value becomes — a `list` entry, a `map` value.
---Nil for an input that isn't a collection, and for a format-less one.
---@param input ezdap.Input?
---@return ezdap.InputType?
function M.item_type(input)
    local def = _def(input)
    return def and def.item_type or nil
end

return M
