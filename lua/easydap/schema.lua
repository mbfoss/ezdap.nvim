---@brief Schema engine behind `:Debug new_task` and `:Debug quick_run`.
---
---Each adapter in `easydap.adapters` may declare a `launch_schema` and/or
---`attach_schema`: a `native_key -> easydap.ParamSpec` table describing that
---adapter's own DAP launch/attach parameters. This module reads those schemas to
---coerce raw strings into a native request body (`build`) and to locate
---role-tagged fields (`key_of_role`, for `quick_run`). Rendering a schema as a
---run_file template (for `new_task`) lives in `easydap.scaffold`, which builds on
---the `group_fields`/`is_group`/`resolve_default` helpers exposed here. This module
---speaks each adapter's native keys directly — no portable field vocabulary between.
---
---A ParamSpec carries three orthogonal descriptors:
---  * `type` — the pure Lua/JSON type of the value (string/boolean/integer/…), or
---    the sentinel `"schema"` marking a nested group (a `{fields=…}` subschema).
---  * `kind` — an optional *data* refinement (file/dir/env/enum/host/port/list)
---    that drives string coercion, completion and validation. A `kind` implies its
---    `type` (e.g. `kind="list"` yields a `table`); coercing a CLI string prefers
---    the `kind` parser and falls back to a plain `type` coercion when unset.
---  * `role` — an optional *value-meaning* marker (target/args/cwd/env for launch,
---    pid/host/port for attach) tagging a field so `quick_run` can map its
---    `role=value` inputs onto whatever native keys the adapter uses (see
---    `key_of_role`). A `role` is independent of `kind`/`type` coercion.
---

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

---Coerce a raw CLI string into the value declared by `spec`. The value-meaning
---`role` is honoured first (args → table, target → expanded path), then the data
---`kind`, and finally the pure `type` when neither defines its own parsing.
---@param spec easydap.ParamSpec
---@param raw string
---@return any? value, string? err
function M.coerce(spec, raw)
    if spec.role == "args" then
        return str_util.split_shell_args(raw)
    elseif spec.role == "target" then
        -- The run_target program: a single expanded path (module names pass
        -- through `expand` unchanged, having nothing to expand).
        return vim.fn.expand(raw)
    end
    local kind = spec.kind
    if kind == "file" or kind == "dir" then
        -- A single expanded path; `file`/`dir` differ only in the completion they
        -- drive, not in the coerced value shape.
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
function M.resolve_default(spec)
    if type(spec.default) == "function" then return spec.default() end
    return spec.default
end

---A schema node is either a leaf ParamSpec or a nested group. A group is marked
---explicitly by `type == "schema"` and holds its child nodes under `fields`;
---anything else is a leaf. (The root schema is itself a bare `fields` map — the
---value `M.schema` returns — so `M.group_fields` treats an unmarked table as its
---own field map.)
---@param node table
---@return boolean
function M.is_group(node)
    return type(node) == "table" and node.type == "schema"
end

---The child-node map of a group. For a marked subschema that is its `fields`; for
---the bare root map it is the map itself.
---@param group table
---@return table<string, easydap.ParamSpec>
function M.group_fields(group)
    return group.type == "schema" and group.fields or group
end

---Walk a (possibly nested) schema, calling `fn(dotted_key, spec)` for every leaf.
---Keys are visited in sorted order at each level, so the traversal is stable and
---`key_of_role`'s "first match" is deterministic. Nested groups contribute a
---dotted path prefix (e.g. `connect.host`).
---@param schema table
---@param fn fun(key: string, spec: easydap.ParamSpec)
local function _walk_leaves(schema, fn)
    local function rec(group, prefix)
        local fields = M.group_fields(group)
        local keys = {}
        for k in pairs(fields) do keys[#keys + 1] = k end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local node = fields[k]
            local path = prefix == "" and k or (prefix .. "." .. k)
            if M.is_group(node) then rec(node, path) else fn(path, node) end
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
        node = M.group_fields(node)[part]
    end
    if type(node) == "table" and not M.is_group(node) then return node end
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

---Adapter names that declare at least one schema (i.e. `new_task` can scaffold a
---body for them), sorted.
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
---the given `role` (e.g. `"target"` for the program field, `"args"` for the
---arguments field), or nil. Lets run_target map program/args onto an adapter's
---native keys without hard-coding their names. Keys are scanned in sorted order so
---the pick is stable if a schema ever declares two of the same role.
---@param adapter string
---@param request string  "launch"|"attach"
---@param role string
---@return string?
function M.key_of_role(adapter, request, role)
    local schema = M.schema(adapter, request)
    if not schema then return nil end
    local found
    _walk_leaves(schema, function(key, spec)
        if not found and spec.role == role then found = key end
    end)
    return found
end

---Adapter names that can launch a program target via run_target — those whose
---launch schema declares a `target`-role field — sorted.
---@return string[]
function M.target_adapters()
    local out = {}
    for _, name in ipairs(M.adapter_names()) do
        if M.key_of_role(name, "launch", "target") then out[#out + 1] = name end
    end
    return out
end

---The distinct `role`s an adapter's request schema declares, sorted. These are
---the body fields `quick_run` can fill; see `quick_roles` for the completion set
---(which also surfaces a task-level TCP endpoint).
---@param adapter string
---@param request string  "launch"|"attach"
---@return string[]
function M.roles(adapter, request)
    local schema = M.schema(adapter, request)
    if not schema then return {} end
    local seen, out = {}, {}
    _walk_leaves(schema, function(_, spec)
        if spec.role and not seen[spec.role] then
            seen[spec.role] = true
            out[#out + 1] = spec.role
        end
    end)
    table.sort(out)
    return out
end

---The roles `quick_run` accepts for an adapter+request: the schema's declared
---roles (`roles`), plus `host`/`port` when the adapter connects over a task-level
---TCP endpoint (its def carries a `host`/`port`) so `remote`-style attach can set
---them even though they are not body fields. Sorted, de-duplicated.
---@param adapter string
---@param request string  "launch"|"attach"
---@return string[]
function M.quick_roles(adapter, request)
    local roles = M.roles(adapter, request)
    local def = require("easydap.adapters")[adapter]
    if request == "attach" and def and (def.host ~= nil or def.port ~= nil) then
        local seen = {}
        for _, r in ipairs(roles) do seen[r] = true end
        for _, r in ipairs({ "host", "port" }) do
            if not seen[r] then roles[#roles + 1] = r end
        end
        table.sort(roles)
    end
    return roles
end

---Adapter names `quick_run` can drive — those declaring at least one role in
---either schema, or a task-level TCP endpoint (def `host`/`port`) — sorted.
---@return string[]
function M.quick_run_adapters()
    local out = {}
    for name, def in pairs(require("easydap.adapters")) do
        if #M.roles(name, "launch") > 0 or #M.roles(name, "attach") > 0
            or def.host ~= nil or def.port ~= nil then
            out[#out + 1] = name
        end
    end
    table.sort(out)
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

---The ParamSpec for a user-settable param, or nil when the key is unknown.
---`key` is a dotted path into nested groups (e.g. "connect.host").
---@param adapter string
---@param request string
---@param key string
---@return easydap.ParamSpec?
function M.spec(adapter, request, key)
    local schema = M.schema(adapter, request)
    return schema and _find_leaf(schema, key) or nil
end

---User-settable param names for an adapter's request,
---sorted. Nested groups yield dotted names. For completion.
---@param adapter string
---@param request string
---@return string[]
function M.param_names(adapter, request)
    local schema = M.schema(adapter, request)
    if not schema then return {} end
    local out = {}
    _walk_leaves(schema, function(key, spec)
        out[#out + 1] = key
    end)
    table.sort(out)
    return out
end

---Assemble an adapter-native launch/attach body from already-coerced `values`
---(keyed by dotted param path). Mirrors the schema's shape: nested groups produce
---nested body tables. Applies `default`s for keys the caller
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
        for key, node in pairs(M.group_fields(group)) do
            local path = prefix == "" and key or (prefix .. "." .. key)
            if M.is_group(node) then
                local sub, err = assemble(node, path)
                if not sub then return nil, err end
                if next(sub) ~= nil then out[key] = sub end
            else
                local val
                if values[path] ~= nil then
                    val = values[path]
                elseif node.default ~= nil then
                    val = M.resolve_default(node)
                end
                if val == nil and node.required then
                    return nil, ("%s is required"):format(path)
                end
                if val ~= nil then out[key] = val end
            end
        end
        return out
    end
    return assemble(schema, "")
end

return M
