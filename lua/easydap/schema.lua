---@brief Schema engine behind `:Debug new_run_file` and `:Debug quick_run`.
---
---Adapters carry no launch/attach schema of their own — each adapter's
---`configurations` (named `easydap.Configuration` configurations, in `easydap.adapters`) are wholly
---self-describing. A configuration's `parameters` is a native request body whose
---leaves may be a literal value (including a zero-arg function, resolved at
---fill time — e.g. a computed default), an identity field the configuration pins
---itself (e.g. `type`/`name`), or a placeholder string: `"{name}"` (kept as a
---raw string) or `"{name:kind}"` (coerced per `kind` — see `M.coerce`).
---`required` lists placeholder names that must be supplied. This module reads
---those configurations to fill a configuration's placeholders from `quick_run`'s
---`name=value` inputs (`fill_configuration`) and to scaffold a run_file template
---(`easydap.scaffold`, via `configuration_placeholder_kinds`/`configuration`/`configurations`). It
---speaks each adapter's native keys directly — no portable field vocabulary
---between adapters.

local str_util = require("easydap.tk.strutil")

local M = {}

-- ── Coercion ───────────────────────────────────────────────────────────────

---Coerce a raw CLI string into the value a placeholder's `kind` describes
---(the part after `:` in `"{name:kind}"`; an empty/absent kind means a plain
---string).
---@param kind string?
---@param raw string
---@return any? value, string? err
function M.coerce(kind, raw)
    if kind == nil or kind == "" or kind == "string" then
        return raw
    elseif kind == "file" or kind == "dir" then
        -- A single expanded path; `file`/`dir` differ only in the completion
        -- they drive, not in the coerced value shape.
        return vim.fn.expand(raw)
    elseif kind == "cwd" then
        -- Resolve to an absolute path so `.`/relative dirs are anchored to
        -- Neovim's cwd, not the adapter's own working directory (which may differ).
        return vim.fn.fnamemodify(vim.fn.expand(raw), ":p")
    elseif kind == "shell_args" then
        return str_util.split_shell_args(raw)
    elseif kind == "shell_program" then
        -- First word of a shell command line, expanded as a path — lets a
        -- `program`/`args` pair share one raw `command` placeholder.
        local parts = str_util.split_shell_args(raw)
        return vim.fn.expand(parts[1] or "")
    elseif kind == "shell_rest_args" then
        local parts = str_util.split_shell_args(raw)
        return { unpack(parts, 2) }
    elseif kind == "host" then
        return raw
    elseif kind == "port" or kind == "integer" then
        local n = tonumber(raw)
        if not n or n ~= math.floor(n) then
            return nil, ("expected an integer, got %q"):format(raw)
        end
        n = math.floor(n)
        if kind == "port" and (n < 0 or n > 65535) then
            return nil, ("port out of range (0-65535), got %d"):format(n)
        end
        return n
    elseif kind == "number" then
        local n = tonumber(raw)
        if not n then return nil, ("expected a number, got %q"):format(raw) end
        return n
    elseif kind == "boolean" then
        local low = raw:lower()
        if low == "true" or low == "1" or low == "yes" then return true end
        if low == "false" or low == "0" or low == "no" then return false end
        return nil, ("expected a boolean (true/false), got %q"):format(raw)
    elseif kind == "list" then
        -- Comma-separated list of verbatim strings (each element kept whole, so
        -- entries may contain spaces — e.g. full LLDB command lines).
        return vim.split(raw, ",", { plain = true, trimempty = true })
    elseif kind == "env" then
        local out = {}
        for _, pair in ipairs(vim.split(raw, ",", { plain = true, trimempty = true })) do
            local eq = pair:find("=", 1, true)
            if not eq then
                return nil, ("expected VAR=VAL pairs, got %q"):format(pair)
            end
            out[pair:sub(1, eq - 1)] = pair:sub(eq + 1)
        end
        return out
    end
    return raw
end

---Resolve a value that may be a literal or a zero-arg function (so computed
---defaults like `getcwd()` are evaluated at use time, not module load).
---@param value any
---@return any
function M.resolve_value(value)
    if type(value) == "function" then return value() end
    return value
end

-- ── Introspection ──────────────────────────────────────────────────────────

-- One placeholder token — `{name}` or `{name:kind}` — anywhere in a string.
-- Captures the name, then the kind (empty when the `:kind` suffix is absent).
local _PLACEHOLDER_PAT = "{([%w_]+):?([%w_]*)}"

---A leaf value that is *entirely* one placeholder (`"{name}"` or `"{name:kind}"`),
---or nil. A whole-string placeholder is filled with its coerced typed value (which
---may be non-string — a list, integer, …); placeholders merely *embedded* in a
---longer string are handled separately, by interpolation (see `_fill_leaf`).
---@param value any
---@return string? name, string? kind
local function _placeholder(value)
    if type(value) ~= "string" then return nil end
    local name, kind = value:match("^" .. _PLACEHOLDER_PAT .. "$")
    if not name then return nil end
    return name, kind
end

---Walk a (possibly nested) plain body table — a configuration's `parameters` or
---`connect` — calling `fn(dotted_key, placeholder_name, kind)` for every
---placeholder token found in a leaf. A single string leaf may hold several tokens
---(e.g. `"gdb-remote {host:host}:{port:port}"`), each reported in turn. Keys are
---visited in sorted order for a stable traversal.
---@param body table
---@param fn fun(key: string, name: string, kind: string)
local function _walk_placeholders(body, fn)
    local function rec(node, prefix)
        local keys = {}
        for k in pairs(node) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local v = node[k]
            local path = prefix == "" and k or (prefix .. "." .. k)
            if type(v) == "table" then
                rec(v, path)
            elseif type(v) == "string" then
                for name, kind in v:gmatch(_PLACEHOLDER_PAT) do
                    fn(path, name, kind)
                end
            end
        end
    end
    rec(body, "")
end

---An adapter's declared `configurations`, or an empty table.
---@param adapter string
---@return table<string, easydap.Configuration>
function M.configurations(adapter)
    local def = require("easydap.adapters")[adapter]
    return (def and def.configurations) or {}
end

---A single named configuration, or nil.
---@param adapter string
---@param name string
---@return easydap.Configuration?
function M.configuration(adapter, name)
    return M.configurations(adapter)[name]
end

---An adapter's configuration names, sorted.
---@param adapter string
---@return string[]
function M.configuration_names(adapter)
    local out = {}
    for name in pairs(M.configurations(adapter)) do out[#out + 1] = name end
    table.sort(out)
    return out
end

---The placeholder → `kind` map a configuration declares across its `parameters`
---and `connect` bodies: for each distinct placeholder, the part after `:` in
---`"{name:kind}"` (`""` for a plain string placeholder). Built in a single walk
---of both bodies; when a name recurs the first occurrence (`parameters` before
---`connect`) wins. This is the primitive behind `configuration_placeholders`;
---callers that need every placeholder's kind should read it once rather than
---looking up kinds name-by-name.
---@param adapter string
---@param configuration_name string
---@return table<string, string>
function M.configuration_placeholder_kinds(adapter, configuration_name)
    local configuration = M.configuration(adapter, configuration_name)
    local kinds = {}
    if not configuration then return kinds end
    local function collect(body)
        if not body then return end
        _walk_placeholders(body, function(_, name, kind)
            if kinds[name] == nil then kinds[name] = kind end
        end)
    end
    collect(configuration.parameters)
    collect(configuration.connect)
    return kinds
end

---The distinct placeholder names a configuration's `parameters`/`connect` declare,
---sorted, de-duplicated. These are the `name=value` tokens `quick_run` accepts.
---@param adapter string
---@param configuration_name string
---@return string[]
function M.configuration_placeholders(adapter, configuration_name)
    local out = {}
    for name in pairs(M.configuration_placeholder_kinds(adapter, configuration_name)) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

---Adapter names `quick_run`/`new_run_file` can drive — those declaring at
---least one configuration — sorted.
---@return string[]
function M.quick_run_adapters()
    local out = {}
    for name, def in pairs(require("easydap.adapters")) do
        if def.configurations and next(def.configurations) then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

---The distinct `request` values ("launch"/"attach") an adapter's configurations use,
---sorted.
---@param adapter string
---@return string[]
function M.requests(adapter)
    local seen, out = {}, {}
    for _, configuration in pairs(M.configurations(adapter)) do
        if not seen[configuration.request] then
            seen[configuration.request] = true
            out[#out + 1] = configuration.request
        end
    end
    table.sort(out)
    return out
end

-- ── Configurations (quick_run / new_run_file) ──────────────────────────────────────

-- Sentinel returned by `_fill_leaf` when a leaf resolves to nothing (an unset,
-- non-required whole-string placeholder): its key is dropped from the body.
local _OMIT = {}

---Fill one leaf of a body table by placeholder-kind.
---
---Three shapes are handled:
--- * a leaf that is *entirely* one placeholder yields that placeholder's coerced
---   typed value (which may be non-string — a list, integer, …); an already-typed
---   `values[name]` is used verbatim, and an unset value returns `_OMIT` (a
---   `required` miss is recorded);
--- * a string with placeholder token(s) *embedded* in surrounding text is
---   interpolated — each token coerced then stringified in place (so
---   `"target create {program:file}"` becomes `"target create /path/a.out"`);
---   an unset embedded token expands to the empty string (a `required` miss is
---   still recorded);
--- * any other leaf is a literal, resolved via `M.resolve_value` (so a zero-arg
---   function default is called at fill time) — this is how a configuration pins
---   identity fields (`type`/`name`) or computed defaults directly in `parameters`.
---@param v any
---@param values table<string, any>
---@param required table<string, boolean>
---@param missing string[]  required placeholder names with no value, appended in place
---@param errs string[]     "name: message" coercion errors, appended in place
---@return any value  the filled value, or the `_OMIT` sentinel to drop the key
local function _fill_leaf(v, values, required, missing, errs)
    -- Whole-string placeholder → coerced typed value.
    local name, kind = _placeholder(v)
    if name then
        local raw = values[name]
        if raw == nil then
            if required[name] then missing[#missing + 1] = name end
            return _OMIT
        elseif type(raw) ~= "string" then
            return raw
        end
        local val, cerr = M.coerce(kind, raw)
        if cerr then
            errs[#errs + 1] = name .. ": " .. cerr
            return _OMIT
        end
        return val
    end

    -- String with embedded placeholder token(s) → interpolate.
    if type(v) == "string" and v:find(_PLACEHOLDER_PAT) then
        return (v:gsub(_PLACEHOLDER_PAT, function(pname, pkind)
            local raw = values[pname]
            if raw == nil then
                if required[pname] then missing[#missing + 1] = pname end
                return ""
            elseif type(raw) ~= "string" then
                return tostring(raw)
            end
            local val, cerr = M.coerce(pkind, raw)
            if cerr then
                errs[#errs + 1] = pname .. ": " .. cerr
                return ""
            end
            return tostring(val)
        end))
    end

    -- Plain literal.
    return M.resolve_value(v)
end

---Fill one placeholder-bearing body (a configuration's `parameters` or `connect`),
---coercing each supplied value by the placeholder's own `kind` (see `_fill_leaf`).
---@param body table
---@param values table<string, any>
---@param required table<string, boolean>
---@param missing string[]  required placeholder names with no value, appended in place
---@param errs string[]     "name: message" coercion errors, appended in place
---@return table
local function _fill_body(body, values, required, missing, errs)
    local out = {}
    for key, v in pairs(body) do
        if type(v) == "table" then
            out[key] = _fill_body(v, values, required, missing, errs)
        else
            local val = _fill_leaf(v, values, required, missing, errs)
            if val ~= _OMIT then
                out[key] = val
            end
        end
    end
    return out
end

---Fill a named configuration's `{placeholder}` tokens from `values` (placeholder
---name → raw CLI string, or an already-typed Lua value to use verbatim),
---resolve every literal leaf (identity fields, computed defaults), and
---assemble the resulting native request body / task-level connection.
---@param adapter string
---@param configuration_name string
---@param values table<string, any>
---@return table? body, {host?:string, port?:integer}? connect, string? err
function M.fill_configuration(adapter, configuration_name, values)
    local configuration = M.configuration(adapter, configuration_name)
    if not configuration then
        return nil, nil, ("adapter %s has no configuration %q (available: %s)")
            :format(adapter, tostring(configuration_name), table.concat(M.configuration_names(adapter), ", "))
    end
    local required = {}
    for _, name in ipairs(configuration.required or {}) do required[name] = true end

    local missing, errs = {}, {}
    local body = _fill_body(configuration.parameters or {}, values, required, missing, errs)

    local connect
    if configuration.connect then
        connect = {}
        for key, v in pairs(configuration.connect) do
            local name = _placeholder(v)
            local raw = name and values[name]
            if not name then
                connect[key] = v
            elseif raw == nil then
                -- No spec governs `connect` (it's task-level, not a body
                -- field), so an unset host/port is always optional: the
                -- resolved AdapterDef's own host/port apply instead.
            elseif key == "port" then
                local n = type(raw) == "number" and raw or tonumber(raw)
                if not n or n ~= math.floor(n) then
                    errs[#errs + 1] = name .. (": expected an integer port, got %q"):format(tostring(raw))
                else
                    connect.port = math.floor(n)
                end
            else
                connect[key] = raw
            end
        end
    end

    if #errs > 0 then return nil, nil, table.concat(errs, "; ") end
    if #missing > 0 then return nil, nil, "missing: " .. table.concat(missing, ", ") end
    return body, connect
end

return M
