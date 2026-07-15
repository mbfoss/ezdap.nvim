---@brief Schema engine behind `:Debug new_run_file` and `:Debug quick_run`.
---
---Adapters carry no launch/attach schema of their own — each adapter's
---`configurations` (named `easydap.Configuration` templates, in `easydap.adapters`)
---are wholly self-describing. A configuration declares its inputs up front in a
---`placeholders` table — `name -> { type = <type>, required = <bool>,
---description = <string> }` — and its `parameters` is a native request body whose
---leaves may be a literal value (including a zero-arg function, resolved at fill
---time — e.g. a computed default), an identity field the configuration pins itself
---(e.g. `type`/`name`), or a `"{name}"` token referring to a declared placeholder.
---A token is read by its placeholder's declared `type` (see `M.coerce`); the
---`"{name:transform}"` form applies an `easydap.PlaceholderTransform` for one use
---instead, which is how a single input feeds two fields differently (a shell
---command line split into `program`/`args`). A placeholder with `required = true`
---must be supplied.
---
---Types and transforms are distinct vocabularies: a *type* says what an input is
---(`file`, `port`, `env`, …) and may be declared on a placeholder; a *transform*
---(`shell_program`, `shell_rest_args`) says what one field takes *from* an input
---and only ever appears in a token. `M.coerce` accepts either — an
---`easydap.PlaceholderKind`.
---
---This module reads those configurations to fill a configuration's placeholders
---from `quick_run`'s `name=value` inputs (`fill_configuration`) and to scaffold a
---run_file template (`easydap.scaffold`, via `configuration_placeholder_types`/
---`configuration`/`configurations`). It speaks each adapter's native keys directly
--- — no portable field vocabulary between adapters.

local str_util = require("easydap.tk.strutil")

local M = {}

-- ── Coercion ───────────────────────────────────────────────────────────────

---Read a raw CLI string into a value, by a placeholder's declared `type` or by
---the per-use transform in `"{name:transform}"` — an `easydap.PlaceholderKind`.
---An empty/absent kind means a plain string.
---@param kind easydap.PlaceholderKind?
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

-- One placeholder token — `{name}` or `{name:transform}` — anywhere in a string.
-- Captures the name, then the per-use transform (empty when absent, i.e. when the
-- placeholder's declared `type` applies).
local _PLACEHOLDER_PAT = "{([%w_]+):?([%w_]*)}"

---A leaf value that is *entirely* one placeholder token (`"{name}"` or
---`"{name:transform}"`), or nil. A whole-string token is filled with its read
---value (which may be non-string — a list, integer, …); tokens merely *embedded*
---in a longer string are handled separately, by interpolation (see `_fill_leaf`).
---@param value any
---@return string? name, string? transform  `""` when the token carries none
local function _placeholder(value)
    if type(value) ~= "string" then return nil end
    local name, transform = value:match("^" .. _PLACEHOLDER_PAT .. "$")
    if not name then return nil end
    return name, transform
end

---Walk a (possibly nested) plain body table — a configuration's `parameters` or
---`connect` — calling `fn(dotted_key, placeholder_name, transform)` for every
---placeholder token found in a leaf. A single string leaf may hold several tokens
---(e.g. `"gdb-remote {host}:{port}"`), each reported in turn. Keys are visited in
---sorted order for a stable traversal.
---@param body table
---@param fn fun(key: string, name: string, transform: string)
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
                for name, transform in v:gmatch(_PLACEHOLDER_PAT) do
                    fn(path, name, transform)
                end
            end
        end
    end
    rec(body, "")
end

---The placeholder → declared `type` map for one configuration: every name its
---`placeholders` table declares, mapped to that placeholder's `type` (`""` for an
---untyped/plain-string placeholder). A token naming a placeholder the
---configuration never declared is still accepted — it falls back to the token's
---own transform — so a configuration written against the older inline style keeps
---working.
---@param configuration easydap.Configuration
---@return table<string, string>
local function _types(configuration)
    local types = {}
    for name, spec in pairs(configuration.placeholders or {}) do
        types[name] = spec.type or ""
    end
    local function collect(body)
        if not body then return end
        _walk_placeholders(body, function(_, name, transform)
            if types[name] == nil then types[name] = transform end
        end)
    end
    collect(configuration.parameters)
    collect(configuration.connect)
    return types
end

---The set of placeholder names a configuration insists on — those its
---`placeholders` table marks `required = true`.
---@param configuration easydap.Configuration
---@return table<string, boolean>
local function _required(configuration)
    local required = {}
    for name, spec in pairs(configuration.placeholders or {}) do
        if spec.required then required[name] = true end
    end
    return required
end

---What to read one token use by: its own transform when it carries one, else the
---placeholder's declared `type`.
---@param types table<string, string>
---@param name string
---@param transform string?
---@return easydap.PlaceholderKind
local function _kind_of(types, name, transform)
    if transform and transform ~= "" then return transform end
    return types[name] or ""
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

---The placeholder → `type` map a configuration declares (`""` for an untyped
---placeholder). This is the primitive behind `configuration_placeholders`, and
---what drives type-aware value completion and run_file seeding; callers that need
---every placeholder's type should read it once rather than looking types up
---name-by-name. A per-use `"{name:transform}"` in a body is *not* reflected here —
---this is the placeholder's own declared type.
---@param adapter string
---@param configuration_name string
---@return table<string, string>
function M.configuration_placeholder_types(adapter, configuration_name)
    local configuration = M.configuration(adapter, configuration_name)
    if not configuration then return {} end
    return _types(configuration)
end

---The distinct placeholder names a configuration declares, sorted. These are the
---`name=value` tokens `quick_run` accepts.
---@param adapter string
---@param configuration_name string
---@return string[]
function M.configuration_placeholders(adapter, configuration_name)
    local out = {}
    for name in pairs(M.configuration_placeholder_types(adapter, configuration_name)) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

---The placeholder names a configuration marks `required = true`, sorted — the
---ones `quick_run` errors on when left unset.
---@param adapter string
---@param configuration_name string
---@return string[]
function M.configuration_required(adapter, configuration_name)
    local configuration = M.configuration(adapter, configuration_name)
    local out = {}
    if not configuration then return out end
    for name in pairs(_required(configuration)) do out[#out + 1] = name end
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
-- non-required placeholder): its key is dropped from the body.
local _OMIT = {}

---Drop repeats, keeping first-seen order. One placeholder may be referenced by
---several tokens (`command` fills both `program` and `args`), which reports its
---miss/coercion error once per token; the user should see it once.
---@param list string[]
---@return string[]
local function _dedupe(list)
    local seen, out = {}, {}
    for _, s in ipairs(list) do
        if not seen[s] then
            seen[s] = true
            out[#out + 1] = s
        end
    end
    return out
end

---Fill one leaf of a body table, reading each token by its placeholder's type (or
---its own transform).
---
---Three shapes are handled:
--- * a leaf that is *entirely* one token yields that placeholder's read value
---   (which may be non-string — a list, integer, …); an already-typed
---   `values[name]` is used verbatim, and an unset value returns `_OMIT` (a
---   `required` miss is recorded);
--- * a string with token(s) *embedded* in surrounding text is interpolated —
---   each token read then stringified in place (so `"target create {program}"`
---   becomes `"target create /path/a.out"`) — but only when *every* token has a
---   value; if any embedded token is unset the whole leaf is dropped (returns
---   `_OMIT`), so an optional command string simply vanishes when its input is
---   absent (a `required` miss is still recorded);
--- * any other leaf is a literal, resolved via `M.resolve_value` (so a zero-arg
---   function default is called at fill time) — this is how a configuration pins
---   identity fields (`type`/`name`) or computed defaults directly in `parameters`.
---@param v any
---@param values table<string, any>
---@param types table<string, string>  placeholder name → declared type
---@param required table<string, boolean>
---@param missing string[]  required placeholder names with no value, appended in place
---@param errs string[]     "name: message" coercion errors, appended in place
---@return any value  the filled value, or the `_OMIT` sentinel to drop the key
local function _fill_leaf(v, values, types, required, missing, errs)
    -- Whole-string token → read value.
    local name, transform = _placeholder(v)
    if name then
        local raw = values[name]
        if raw == nil then
            if required[name] then missing[#missing + 1] = name end
            return _OMIT
        elseif type(raw) ~= "string" then
            return raw
        end
        local val, cerr = M.coerce(_kind_of(types, name, transform), raw)
        if cerr then
            errs[#errs + 1] = name .. ": " .. cerr
            return _OMIT
        end
        return val
    end

    -- String with embedded token(s) → interpolate, but only when every token
    -- resolves; any unset token drops the whole leaf.
    if type(v) == "string" and v:find(_PLACEHOLDER_PAT) then
        local omit = false
        local filled = v:gsub(_PLACEHOLDER_PAT, function(pname, ptransform)
            local raw = values[pname]
            if raw == nil then
                if required[pname] then missing[#missing + 1] = pname end
                omit = true
                return ""
            elseif type(raw) ~= "string" then
                return tostring(raw)
            end
            local val, cerr = M.coerce(_kind_of(types, pname, ptransform), raw)
            if cerr then
                errs[#errs + 1] = pname .. ": " .. cerr
                return ""
            end
            return tostring(val)
        end)
        if omit then return _OMIT end
        return filled
    end

    -- Plain literal.
    return M.resolve_value(v)
end

---Fill one placeholder-bearing body (a configuration's `parameters` or `connect`),
---reading each supplied value by its placeholder's type (see `_fill_leaf`).
---@param body table
---@param values table<string, any>
---@param types table<string, string>
---@param required table<string, boolean>
---@param missing string[]  required placeholder names with no value, appended in place
---@param errs string[]     "name: message" coercion errors, appended in place
---@return table
local function _fill_body(body, values, types, required, missing, errs)
    local out = {}
    for key, v in pairs(body) do
        if type(v) == "table" then
            out[key] = _fill_body(v, values, types, required, missing, errs)
        else
            local val = _fill_leaf(v, values, types, required, missing, errs)
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
    local types    = _types(configuration)
    local required = _required(configuration)

    local missing, errs = {}, {}
    local body = _fill_body(configuration.parameters or {}, values, types, required, missing, errs)

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

    if #errs > 0 then return nil, nil, table.concat(_dedupe(errs), "; ") end
    if #missing > 0 then return nil, nil, "missing: " .. table.concat(_dedupe(missing), ", ") end
    return body, connect
end

return M
