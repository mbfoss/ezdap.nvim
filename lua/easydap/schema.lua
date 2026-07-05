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
---  * `kind` — an optional semantic refinement (file/dir/target/args/env/enum/
---    host/port/list) that drives string coercion, completion and validation.
---When both are present the `kind` implies the `type` (e.g. `kind="args"` yields a
---`table`); coercing a CLI string prefers the `kind` parser and falls back to a
---plain `type` coercion when no `kind` is set.
---
---`target` and `args` double as role markers: they tag an adapter's program field
---and arguments field so `run_target` can map its `<program>`/`<args>` inputs onto
---whatever native keys that adapter uses (see `key_of_kind`).

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
    if kind == "file" or kind == "dir" or kind == "target" then
        -- All three are a single expanded path. `file`/`dir` differ only in the
        -- completion they drive; `target` additionally serves as run_target's
        -- role marker. None changes the coerced value shape.
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
    elseif kind == "args" then
        return str_util.split_shell_args(raw)
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

---A schema node is either a leaf ParamSpec or a nested group of further nodes.
---A leaf is recognised by its scalar descriptor fields (`type`/`kind`/`fixed`);
---a group is just a map of names to nodes and has none of them at its own level.
---@param node table
---@return boolean
local function _is_leaf(node)
    return type(node.type) == "string"
        or type(node.kind) == "string"
        or type(node.fixed) == "boolean"
end

---Walk a (possibly nested) schema, calling `fn(dotted_key, spec)` for every leaf.
---Keys are visited in sorted order at each level, so the traversal is stable and
---`key_of_kind`'s "first match" is deterministic. Nested groups contribute a
---dotted path prefix (e.g. `connect.host`).
---@param schema table
---@param fn fun(key: string, spec: easydap.ParamSpec)
local function _walk_leaves(schema, fn)
    local function rec(group, prefix)
        local keys = {}
        for k in pairs(group) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local node = group[k]
            local path = prefix == "" and k or (prefix .. "." .. k)
            if _is_leaf(node) then fn(path, node) else rec(node, path) end
        end
    end
    rec(schema, "")
end

---Resolve a dotted `key` (e.g. "connect.host") to its leaf spec in a nested
---schema, or nil when the path is unknown or lands on a group rather than a leaf.
---@param schema table
---@param key string
---@return easydap.ParamSpec?
local function _find_leaf(schema, key)
    local node = schema
    for part in vim.gsplit(key, ".", { plain = true }) do
        if type(node) ~= "table" then return nil end
        node = node[part]
    end
    if type(node) == "table" and _is_leaf(node) then return node end
    return nil
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

---The first user-settable param key in an adapter's request schema whose spec has
---the given `kind` (e.g. `"target"` for the program field, `"args"` for the
---arguments field), or nil. Lets run_target map program/args onto an adapter's
---native keys without hard-coding their names. Keys are scanned in sorted order so
---the pick is stable if a schema ever declares two of the same kind.
---@param adapter string
---@param request string  "launch"|"attach"
---@param kind string
---@return string?
function M.key_of_kind(adapter, request, kind)
    local schema = M.schema(adapter, request)
    if not schema then return nil end
    local found
    _walk_leaves(schema, function(key, spec)
        if not found and not spec.fixed and spec.kind == kind then found = key end
    end)
    return found
end

---Adapter names that can launch a program target via run_target — those whose
---launch schema declares a `target`-kind field — sorted.
---@return string[]
function M.target_adapters()
    local out = {}
    for _, name in ipairs(M.adapter_names()) do
        if M.key_of_kind(name, "launch", "target") then out[#out + 1] = name end
    end
    return out
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
---`fixed` (fixed params are not settable from the command line). `key` is a dotted
---path into nested groups (e.g. "connect.host").
---@param adapter string
---@param request string
---@param key string
---@return easydap.ParamSpec?
function M.spec(adapter, request, key)
    local schema = M.schema(adapter, request)
    local spec   = schema and _find_leaf(schema, key)
    if not spec or spec.fixed then return nil end
    return spec
end

---User-settable param names (excludes `fixed` entries) for an adapter's request,
---sorted. Nested groups yield dotted names. For completion.
---@param adapter string
---@param request string
---@return string[]
function M.param_names(adapter, request)
    local schema = M.schema(adapter, request)
    if not schema then return {} end
    local out = {}
    _walk_leaves(schema, function(key, spec)
        if not spec.fixed then out[#out + 1] = key end
    end)
    table.sort(out)
    return out
end

---Assemble an adapter-native launch/attach body from already-coerced `values`
---(keyed by dotted param path). Mirrors the schema's shape: nested groups produce
---nested body tables. Applies `fixed` values and `default`s for keys the caller
---did not supply, enforces `required`, and omits groups that end up empty. Unknown
---keys in `values` are ignored (the caller validates those).
---@param adapter string
---@param request string  "launch"|"attach"
---@param values table<string, any>
---@return table? body, string? err
function M.build(adapter, request, values)
    local schema = M.schema(adapter, request)
    if not schema then
        return nil, ("adapter %s has no %s schema"):format(tostring(adapter), tostring(request))
    end
    ---@param group table
    ---@param prefix string
    ---@return table? node, string? err
    local function assemble(group, prefix)
        local out = {}
        for key, node in pairs(group) do
            local path = prefix == "" and key or (prefix .. "." .. key)
            if _is_leaf(node) then
                local val
                if node.fixed then
                    val = _resolve_default(node)
                elseif values[path] ~= nil then
                    val = values[path]
                elseif node.default ~= nil then
                    val = _resolve_default(node)
                end
                if val == nil and node.required then
                    return nil, ("%s is required"):format(path)
                end
                if val ~= nil then out[key] = val end
            else
                local sub, err = assemble(node, path)
                if not sub then return nil, err end
                if next(sub) ~= nil then out[key] = sub end
            end
        end
        return out
    end
    return assemble(schema, "")
end

return M
