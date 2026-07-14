---@brief Schema engine behind `:Debug new_run_file` and `:Debug quick_run`.
---
---Each adapter in `easydap.adapters` may declare a `launch_schema` and/or
---`attach_schema`: a `native_key -> easydap.ParamSpec` table describing that
---adapter's own DAP launch/attach parameters. This module reads those schemas to
---coerce raw strings into a native request body (`build`), and reads an adapter's
---`templates` (named `easydap.Template` presets) to fill their `{placeholder}`
---tokens from `quick_run`'s `name=value` inputs (`fill_template`). Rendering a
---schema as a run_file template (for `new_run_file`) lives in `easydap.scaffold`,
---which builds on the `group_fields`/`is_group`/`resolve_default` helpers exposed
---here. This module speaks each adapter's native keys directly — no portable
---field vocabulary between adapters.
---
---A ParamSpec carries two orthogonal descriptors:
---  * `type` — the pure Lua/JSON type of the value (string/boolean/integer/…), or
---    the sentinel `"schema"` marking a nested group (a `{fields=…}` subschema).
---  * `kind` — an optional *data* refinement (file/dir/cwd/env/enum/host/port/
---    list/shell_args) that drives string coercion, completion and validation. A
---    `kind` implies its `type` (e.g. `kind="list"` yields a `table`); coercing a
---    CLI string prefers the `kind` parser and falls back to a plain `type`
---    coercion when unset.
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

---Coerce a raw CLI string into the value declared by `spec`. The data `kind` is
---honoured first, falling back to the pure `type` when unset.
---@param spec easydap.ParamSpec
---@param raw string
---@return any? value, string? err
function M.coerce(spec, raw)
    local kind = spec.kind
    if kind == "file" or kind == "dir" then
        -- A single expanded path; `file`/`dir` differ only in the completion they
        -- drive, not in the coerced value shape.
        return vim.fn.expand(raw)
    elseif kind == "cwd" then
        -- Resolve to an absolute path so `.`/relative dirs are anchored to
        -- Neovim's cwd, not the adapter's own working directory (which may differ).
        return vim.fn.fnamemodify(vim.fn.expand(raw), ":p")
    elseif kind == "shell_args" then
        return str_util.split_shell_args(raw)
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
---Keys are visited in sorted order at each level, so the traversal is stable.
---Nested groups contribute a dotted path prefix (e.g. `connect.host`).
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

---Adapter names that declare at least one schema (i.e. `new_run_file` can scaffold a
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

---A leaf value shaped like a placeholder — `"{name}"`, or `"{name:kind}"` to
---pin the coercion `kind` inline (overriding whatever `kind` the matching
---schema leaf declares, or standing alone where there is no schema leaf at
---all, e.g. a template's `connect.host`/`connect.port`). Returns nil when `value`
---isn't placeholder-shaped.
---@param value any
---@return string? name, string? kind
local function _placeholder(value)
    if type(value) ~= "string" then return nil end
    local name, kind = value:match("^{([%w_]+):([%w_]+)}$")
    if name then return name, kind end
    return value:match("^{([%w_]+)}$")
end

---Walk a (possibly nested) plain body table — a template's `parameters` or
---`connect` — calling `fn(dotted_key, placeholder_name)` for every leaf shaped
---like `"{name}"`. Keys are visited in sorted order for a stable traversal.
---@param body table
---@param fn fun(key: string, name: string)
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
            else
                local name = _placeholder(v)
                if name then fn(path, name) end
            end
        end
    end
    rec(body, "")
end

---An adapter's declared `templates`, or an empty table.
---@param adapter string
---@return table<string, easydap.Template>
function M.templates(adapter)
    local def = require("easydap.adapters")[adapter]
    return (def and def.templates) or {}
end

---A single named template, or nil.
---@param adapter string
---@param name string
---@return easydap.Template?
function M.template(adapter, name)
    return M.templates(adapter)[name]
end

---An adapter's template names, sorted.
---@param adapter string
---@return string[]
function M.template_names(adapter)
    local out = {}
    for name in pairs(M.templates(adapter)) do out[#out + 1] = name end
    table.sort(out)
    return out
end

---The distinct placeholder names a template's `parameters`/`connect` declare,
---sorted, de-duplicated. These are the `name=value` tokens `quick_run` accepts.
---@param adapter string
---@param template_name string
---@return string[]
function M.template_placeholders(adapter, template_name)
    local tmpl = M.template(adapter, template_name)
    if not tmpl then return {} end
    local seen, out = {}, {}
    local function collect(body)
        if not body then return end
        _walk_placeholders(body, function(_, name)
            if not seen[name] then
                seen[name] = true
                out[#out + 1] = name
            end
        end)
    end
    collect(tmpl.parameters)
    collect(tmpl.connect)
    table.sort(out)
    return out
end

---Adapter names `quick_run` can drive — those declaring at least one
---template — sorted.
---@return string[]
function M.quick_run_adapters()
    local out = {}
    for name, def in pairs(require("easydap.adapters")) do
        if def.templates and next(def.templates) then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

---The first `launch` template declaring a `target` placeholder, or nil. Lets
---run_target map a bare `program`/`args` pair onto an adapter's templates
---without hard-coding native key names. Template names are scanned in sorted
---order so the pick is stable if an adapter ever declares more than one.
---@param adapter string
---@return string?
function M.target_template(adapter)
    for _, name in ipairs(M.template_names(adapter)) do
        local tmpl = M.templates(adapter)[name]
        if tmpl.request == "launch" and vim.tbl_contains(M.template_placeholders(adapter, name), "target") then
            return name
        end
    end
    return nil
end

---Adapter names that can launch a program target via run_target — those with a
---`target_template` — sorted.
---@return string[]
function M.target_adapters()
    local out = {}
    for _, name in ipairs(M.adapter_names()) do
        if M.target_template(name) then out[#out + 1] = name end
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

-- ── Templates (quick_run) ────────────────────────────────────────────────────

---Fill one placeholder-bearing body (a template's `parameters` or `connect`),
---coercing each supplied value by the ParamSpec at its dotted native path in
---`schema`, with an inline `{name:kind}` overriding (or, where the path has no
---schema leaf — e.g. `connect.host`/`connect.port` — entirely standing in for)
---that spec's `kind`. A `values[name]` that is already non-string (e.g.
---`run_target`'s pre-split args) is used as-is, skipping coercion. A
---placeholder the caller left unset is only an error when its ParamSpec marks
---it `required`; otherwise it falls back to the spec's `default` (when set) or
---is simply omitted from the body — mirroring `M.build`'s own default/required
---handling. `default`/`required` always come from the schema, never from the
---template, even when `kind` is overridden inline.
---@param schema table?  the template's request schema, for spec lookup by path
---@param body table
---@param values table<string, any>
---@param missing string[]  required placeholder names with no value, appended in place
---@param errs string[]     "name: message" coercion errors, appended in place
---@return table
local function _fill_body(schema, body, values, missing, errs, prefix)
    prefix = prefix or ""
    local out = {}
    for key, v in pairs(body) do
        local path = prefix == "" and key or (prefix .. "." .. key)
        if type(v) == "table" then
            out[key] = _fill_body(schema, v, values, missing, errs, path)
        else
            local name, inline_kind = _placeholder(v)
            if not name then
                out[key] = v
            else
                local raw = values[name]
                local spec = schema and _find_leaf(schema, path) or nil
                if raw == nil then
                    if spec and spec.default ~= nil then
                        out[key] = M.resolve_default(spec)
                    elseif spec and spec.required then
                        missing[#missing + 1] = name
                    end
                elseif type(raw) ~= "string" then
                    out[key] = raw
                else
                    local eff_spec = inline_kind
                        and vim.tbl_extend("force", {}, spec or {}, { kind = inline_kind })
                        or spec or {}
                    local val, cerr = M.coerce(eff_spec, raw)
                    if cerr then
                        errs[#errs + 1] = name .. ": " .. cerr
                    else
                        out[key] = val
                    end
                end
            end
        end
    end
    return out
end

---Fill a named template's `{placeholder}` tokens from `values` (placeholder
---name → raw CLI string, or an already-typed Lua value to use verbatim), and
---assemble the resulting native request body / task-level connection.
---@param adapter string
---@param template_name string
---@param values table<string, any>
---@return table? body, {host?:string, port?:integer}? connect, string? err
function M.fill_template(adapter, template_name, values)
    local tmpl = M.template(adapter, template_name)
    if not tmpl then
        return nil, nil, ("adapter %s has no template %q (available: %s)")
            :format(adapter, tostring(template_name), table.concat(M.template_names(adapter), ", "))
    end
    local request_schema = M.schema(adapter, tmpl.request)
    local missing, errs = {}, {}
    local body = _fill_body(request_schema, tmpl.parameters or {}, values, missing, errs)

    -- `connect` is task-level, not a body field, so it has no schema leaf of
    -- its own: `M.coerce` runs on the inline `:kind` alone, falling back to the
    -- key's own name as its kind (`host`/`port`) when the template leaves it
    -- unannotated — an unset host/port is always optional, since the resolved
    -- AdapterDef's own host/port apply instead.
    local connect
    if tmpl.connect then
        connect = {}
        for key, v in pairs(tmpl.connect) do
            local name, inline_kind = _placeholder(v)
            if not name then
                connect[key] = v
            else
                local raw = values[name]
                if type(raw) == "string" then
                    local val, cerr = M.coerce({ kind = inline_kind or key }, raw)
                    if cerr then
                        errs[#errs + 1] = name .. ": " .. cerr
                    else
                        connect[key] = val
                    end
                elseif raw ~= nil then
                    connect[key] = raw
                end
            end
        end
    end

    if #errs > 0 then return nil, nil, table.concat(errs, "; ") end
    if #missing > 0 then return nil, nil, "missing: " .. table.concat(missing, ", ") end
    return body, connect
end

return M
