---@brief Schema engine for `:Debug quick_run`.
---
---Each adapter in `easydap.adapters` may declare a `launch_schema` and/or
---`attach_schema`: a `native_key -> easydap.ParamSpec` table describing that
---adapter's own DAP launch/attach parameters. This module reads those schemas to
---coerce `key=value` tokens into a native request body, and to enumerate params
---for completion. quick_run speaks each adapter's native keys directly — there is
---no portable/generic field vocabulary in between.
---
---A ParamSpec carries two orthogonal descriptors:
---  * `type` — the pure Lua/JSON type of the value (string/boolean/integer/…).
---  * `kind` — an optional semantic refinement (path/argv/env/enum/host/port)
---    that drives string coercion, completion and validation.
---When both are present the `kind` implies the `type` (e.g. `kind="argv"` yields a
---`table`); coercing a CLI string prefers the `kind` parser and falls back to a
---plain `type` coercion when no `kind` is set.

local str_util = require("easydap.tk.strutil")

local M = {}

-- ── Coercion ───────────────────────────────────────────────────────────────

---Coerce a raw CLI string using only the value's Lua `type`.
---@param type_ string?
---@param raw string
---@return any? value, string? err
local function _coerce_by_type(type_, raw)
    if type_ == "boolean" then
        local low = raw:lower()
        if low == "true" or low == "1" or low == "yes" then return true end
        if low == "false" or low == "0" or low == "no" then return false end
        return nil, ("expected a boolean (true/false), got %q"):format(raw)
    elseif type_ == "integer" then
        local n = tonumber(raw)
        if not n or n ~= math.floor(n) then
            return nil, ("expected an integer, got %q"):format(raw)
        end
        return math.floor(n)
    elseif type_ == "number" then
        local n = tonumber(raw)
        if not n then return nil, ("expected a number, got %q"):format(raw) end
        return n
    end
    -- "string" (or absent): pass through verbatim.
    return raw
end

---Coerce a raw CLI string into the value declared by `spec`. The `kind` (semantic
---type) wins when it defines its own parsing; otherwise the pure `type` is used.
---@param spec easydap.ParamSpec
---@param raw string
---@return any? value, string? err
function M.coerce(spec, raw)
    local kind = spec.kind
    if kind == "path" then
        return vim.fn.expand(raw)
    elseif kind == "host" then
        return raw
    elseif kind == "port" then
        local n = tonumber(raw)
        if not n or n ~= math.floor(n) then
            return nil, ("expected a port number, got %q"):format(raw)
        end
        n = math.floor(n)
        if n < 0 or n > 65535 then
            return nil, ("port out of range (0-65535), got %d"):format(n)
        end
        return n
    elseif kind == "argv" then
        return str_util.split_shell_args(raw)
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
    elseif kind == "enum" then
        local value, err = _coerce_by_type(spec.type, raw)
        if err then return nil, err end
        if spec.enum and not vim.tbl_contains(spec.enum, value) then
            return nil, ("expected one of %s, got %q")
                :format(table.concat(vim.tbl_map(tostring, spec.enum), "|"), raw)
        end
        return value
    end
    return _coerce_by_type(spec.type, raw)
end

-- ── Body assembly ──────────────────────────────────────────────────────────

---Resolve a spec's default, calling it when it is a function (so computed
---defaults like `getcwd()` are evaluated at build time, not module load).
---@param spec easydap.ParamSpec
---@return any
local function _resolve_default(spec)
    if type(spec.default) == "function" then return spec.default() end
    return spec.default
end

---Assign `value` into `tbl` at a possibly-dotted `path` (e.g. "connect.host"),
---creating intermediate tables as needed.
---@param tbl table
---@param path string
---@param value any
local function _set_path(tbl, path, value)
    if not path:find(".", 1, true) then
        tbl[path] = value
        return
    end
    local parts = vim.split(path, ".", { plain = true })
    local node  = tbl
    for i = 1, #parts - 1 do
        local p = parts[i]
        if type(node[p]) ~= "table" then node[p] = {} end
        node = node[p]
    end
    node[parts[#parts]] = value
end

-- ── Introspection ──────────────────────────────────────────────────────────

---@param adapter string
---@param request string  "launch"|"attach"
---@return table<string, easydap.ParamSpec>? schema
function M.schema(adapter, request)
    local def = require("easydap.adapters")[adapter]
    if not def then return nil end
    if request == "launch" then return def.launch_schema end
    if request == "attach" then return def.attach_schema end
    return nil
end

---Adapter names that declare at least one schema (i.e. quick_run can build a body
---for them), sorted.
---@return string[]
function M.adapter_names()
    local names = {}
    for name, def in pairs(require("easydap.adapters")) do
        if def.launch_schema or def.attach_schema then names[#names + 1] = name end
    end
    table.sort(names)
    return names
end

---Which requests (`"launch"`/`"attach"`) an adapter declares a schema for.
---@param adapter string
---@return string[]
function M.requests(adapter)
    local def = require("easydap.adapters")[adapter]
    if not def then return {} end
    local out = {}
    if def.launch_schema then out[#out + 1] = "launch" end
    if def.attach_schema then out[#out + 1] = "attach" end
    return out
end

---The ParamSpec for a user-settable param, or nil when the key is unknown or
---`fixed` (fixed params are not settable from the command line).
---@param adapter string
---@param request string
---@param key string
---@return easydap.ParamSpec?
function M.spec(adapter, request, key)
    local schema = M.schema(adapter, request)
    local spec   = schema and schema[key]
    if not spec or spec.fixed then return nil end
    return spec
end

---User-settable param names (excludes `fixed` entries) for an adapter's request,
---sorted. For completion.
---@param adapter string
---@param request string
---@return string[]
function M.param_names(adapter, request)
    local schema = M.schema(adapter, request)
    if not schema then return {} end
    local out = {}
    for key, spec in pairs(schema) do
        if not spec.fixed then out[#out + 1] = key end
    end
    table.sort(out)
    return out
end

---Assemble an adapter-native launch/attach body from already-coerced `values`
---(keyed by param name). Applies `fixed` values and `default`s for keys the
---caller did not supply, nests via each spec's `into` path, and enforces
---`required`. Unknown keys in `values` are ignored (the caller validates those).
---@param adapter string
---@param request string  "launch"|"attach"
---@param values table<string, any>
---@return table? body, string? err
function M.build(adapter, request, values)
    local schema = M.schema(adapter, request)
    if not schema then
        return nil, ("adapter %s has no %s schema"):format(tostring(adapter), tostring(request))
    end
    local body = {}
    for key, spec in pairs(schema) do
        local val
        if spec.fixed then
            val = _resolve_default(spec)
        elseif values[key] ~= nil then
            val = values[key]
        elseif spec.default ~= nil then
            val = _resolve_default(spec)
        end
        if val == nil and spec.required then
            return nil, ("%s is required"):format(key)
        end
        if val ~= nil then _set_path(body, spec.into or key, val) end
    end
    return body
end

return M
