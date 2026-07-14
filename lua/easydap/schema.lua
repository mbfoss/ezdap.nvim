---@brief Schema engine behind `:Debug new_run_file` and `:Debug quick_run`.
---
---Adapters carry no launch/attach schema of their own — each adapter's
---`presets` (named `easydap.Preset` presets, in `easydap.adapters`) are wholly
---self-describing. A preset's `parameters` is a native request body whose
---leaves may be a literal value (including a zero-arg function, resolved at
---fill time — e.g. a computed default), an identity field the preset pins
---itself (e.g. `type`/`name`), or a placeholder string: `"{name}"` (kept as a
---raw string) or `"{name:kind}"` (coerced per `kind` — see `M.coerce`).
---`required` lists placeholder names that must be supplied. This module reads
---those presets to fill a preset's placeholders from `quick_run`'s
---`name=value` inputs (`fill_preset`) and to scaffold a run_file template
---(`easydap.scaffold`, via `preset_placeholder_kind`/`preset`/`presets`). It
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

---A leaf value shaped like a placeholder (`"{name}"` or `"{name:kind}"`), or
---nil.
---@param value any
---@return string? name, string? kind
local function _placeholder(value)
    if type(value) ~= "string" then return nil end
    local name, kind = value:match("^{([%w_]+):?([%w_]*)}$")
    if not name then return nil end
    return name, kind
end

---Walk a (possibly nested) plain body table — a preset's `parameters` or
---`connect` — calling `fn(dotted_key, placeholder_name, kind)` for every leaf
---shaped like a placeholder. Keys are visited in sorted order for a stable
---traversal.
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
            else
                local name, kind = _placeholder(v)
                if name then fn(path, name, kind) end
            end
        end
    end
    rec(body, "")
end

---An adapter's declared `presets`, or an empty table.
---@param adapter string
---@return table<string, easydap.Preset>
function M.presets(adapter)
    local def = require("easydap.adapters")[adapter]
    return (def and def.presets) or {}
end

---A single named preset, or nil.
---@param adapter string
---@param name string
---@return easydap.Preset?
function M.preset(adapter, name)
    return M.presets(adapter)[name]
end

---An adapter's preset names, sorted.
---@param adapter string
---@return string[]
function M.preset_names(adapter)
    local out = {}
    for name in pairs(M.presets(adapter)) do out[#out + 1] = name end
    table.sort(out)
    return out
end

---The distinct placeholder names a preset's `parameters`/`connect` declare,
---sorted, de-duplicated. These are the `name=value` tokens `quick_run` accepts.
---@param adapter string
---@param preset_name string
---@return string[]
function M.preset_placeholders(adapter, preset_name)
    local preset = M.preset(adapter, preset_name)
    if not preset then return {} end
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
    collect(preset.parameters)
    collect(preset.connect)
    table.sort(out)
    return out
end

---The `kind` governing a preset's placeholder (the part after `:` in
---`"{name:kind}"`, `""` for a plain string placeholder), or nil when the
---placeholder isn't found in `parameters`.
---@param adapter string
---@param preset_name string
---@param placeholder_name string
---@return string?
function M.preset_placeholder_kind(adapter, preset_name, placeholder_name)
    local preset = M.preset(adapter, preset_name)
    if not preset or not preset.parameters then return nil end
    local found
    _walk_placeholders(preset.parameters, function(_, name, kind)
        if name == placeholder_name and not found then found = kind end
    end)
    return found
end

---Adapter names `quick_run`/`new_run_file` can drive — those declaring at
---least one preset — sorted.
---@return string[]
function M.quick_run_adapters()
    local out = {}
    for name, def in pairs(require("easydap.adapters")) do
        if def.presets and next(def.presets) then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

---The first `launch` preset declaring a `target` placeholder, or nil. Lets
---run_target map a bare `program`/`args` pair onto an adapter's presets
---without hard-coding native key names. Preset names are scanned in sorted
---order so the pick is stable if an adapter ever declares more than one.
---@param adapter string
---@return string?
function M.target_preset(adapter)
    for _, name in ipairs(M.preset_names(adapter)) do
        local preset = M.presets(adapter)[name]
        if preset.request == "launch" and vim.tbl_contains(M.preset_placeholders(adapter, name), "target") then
            return name
        end
    end
    return nil
end

---Adapter names that can launch a program target via run_target — those with a
---`target_preset` — sorted.
---@return string[]
function M.target_adapters()
    local out = {}
    for _, name in ipairs(M.quick_run_adapters()) do
        if M.target_preset(name) then out[#out + 1] = name end
    end
    return out
end

---The distinct `request` values ("launch"/"attach") an adapter's presets use,
---sorted.
---@param adapter string
---@return string[]
function M.requests(adapter)
    local seen, out = {}, {}
    for _, preset in pairs(M.presets(adapter)) do
        if not seen[preset.request] then
            seen[preset.request] = true
            out[#out + 1] = preset.request
        end
    end
    table.sort(out)
    return out
end

-- ── Presets (quick_run / new_run_file) ──────────────────────────────────────

---Fill one placeholder-bearing body (a preset's `parameters` or `connect`),
---coercing each supplied value by the placeholder's own `kind`. A
---`values[name]` that is already non-string (e.g. `run_target`'s pre-split
---args) is used as-is, skipping coercion. A literal (non-placeholder) leaf is
---resolved via `M.resolve_value` (so a zero-arg function default is called at
---fill time) and kept as-is otherwise — this is how a preset pins identity
---fields (`type`/`name`) or computed defaults directly in `parameters`. An
---unset placeholder is only an error when its name is listed in the preset's
---`required`; otherwise it is simply omitted from the body.
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
            local name, kind = _placeholder(v)
            if not name then
                out[key] = M.resolve_value(v)
            else
                local raw = values[name]
                if raw == nil then
                    if required[name] then missing[#missing + 1] = name end
                elseif type(raw) ~= "string" then
                    out[key] = raw
                else
                    local val, cerr = M.coerce(kind, raw)
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

---Fill a named preset's `{placeholder}` tokens from `values` (placeholder
---name → raw CLI string, or an already-typed Lua value to use verbatim),
---resolve every literal leaf (identity fields, computed defaults), and
---assemble the resulting native request body / task-level connection.
---@param adapter string
---@param preset_name string
---@param values table<string, any>
---@return table? body, {host?:string, port?:integer}? connect, string? err
function M.fill_preset(adapter, preset_name, values)
    local preset = M.preset(adapter, preset_name)
    if not preset then
        return nil, nil, ("adapter %s has no preset %q (available: %s)")
            :format(adapter, tostring(preset_name), table.concat(M.preset_names(adapter), ", "))
    end
    local required = {}
    for _, name in ipairs(preset.required or {}) do required[name] = true end

    local missing, errs = {}, {}
    local body = _fill_body(preset.parameters or {}, values, required, missing, errs)

    local connect
    if preset.connect then
        connect = {}
        for key, v in pairs(preset.connect) do
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
