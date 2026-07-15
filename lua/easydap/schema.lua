---@brief Schema engine behind `:Debug new_run_file` and `:Debug quick_run`.
---
---Adapters carry no launch/attach schema of their own — each adapter's
---`configurations` (named `easydap.Configuration` templates, in `easydap.adapters`)
---are wholly self-describing. A configuration declares its inputs up front in an
---`inputs` table — `name -> easydap.Input` — and the two commands read them along
---separate paths that never meet:
---
--- * `quick_run` reads `name=value` arguments, coerces each by its input's declared
---   `type`/`format` (`M.coerce`), and calls the configuration's `build(params, connect,
---   inputs)` to assemble a native request body plus any task-level connection. An
---   unset input arrives as nil, so a field assigned from it never appears in the
---   body at all; an input marked `required = true` must be supplied.
--- * `new_run_file` splices the configuration's `template` — Lua source text for a
---   native body, seeded with example values — into the generated run file (see
---   `easydap.scaffold`). A run file's `parameters` goes to the adapter verbatim
---   (see `easydap.task`); it never passes through `build`.
---
---So `build` is the only thing that assembles a request, and `template` is the only
---thing the scaffolder reads. This module speaks each adapter's native keys
---directly — no portable field vocabulary between adapters.

local str_util = require("easydap.tk.strutil")

local M = {}

-- ── Coercion ───────────────────────────────────────────────────────────────

---Read a raw string into a value of the declared `type`, the way `format` says.
---An absent format reads the string by `type` alone; an absent type is a string.
---@param input_type easydap.InputType?
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
        return nil, "a table input needs a format (env/list/shell_args)"
    end
    return raw
end

---Read a raw `quick_run` string into a value, by its input's declared `type` and
---`format`. The format, when given, is what does the reading — it always produces
---a value of the input's `type`; without one the string is read by `type` alone.
---@param input easydap.Input
---@param raw string
---@return any? value, string? err
function M.coerce(input, raw)
    local format = input.format
    if format == nil or format == "" then
        return _by_type(input.type, raw)
    elseif format == "file" or format == "dir" then
        -- A single expanded path; `file`/`dir` differ only in the completion
        -- they drive, not in the coerced value shape.
        return vim.fn.expand(raw)
    elseif format == "cwd" then
        -- Resolve to an absolute path so `.`/relative dirs are anchored to
        -- Neovim's cwd, not the adapter's own working directory (which may differ).
        return vim.fn.fnamemodify(vim.fn.expand(raw), ":p")
    elseif format == "host" then
        return raw
    elseif format == "port" then
        local n, err = _by_type("integer", raw)
        if err then return nil, err end
        if n < 0 or n > 65535 then
            return nil, ("port out of range (0-65535), got %d"):format(n)
        end
        return n
    elseif format == "shell_args" then
        return str_util.split_shell_args(raw)
    elseif format == "list" then
        -- Comma-separated list of verbatim strings (each element kept whole, so
        -- entries may contain spaces — e.g. full LLDB command lines).
        return vim.split(raw, ",", { plain = true, trimempty = true })
    elseif format == "env" then
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

-- ── Introspection ──────────────────────────────────────────────────────────

---The input → declared `format` map for one configuration (`""` for an input with
---no format, read by its `type` alone).
---@param configuration easydap.Configuration
---@return table<string, string>
local function _input_formats(configuration)
    local formats = {}
    for name, spec in pairs(configuration.inputs or {}) do
        formats[name] = spec.format or ""
    end
    return formats
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

---The input → `format` map a configuration declares (`""` for an input with no
---format). This drives format-aware value completion — which inputs take a path,
---and of what kind; callers that need every input's format should read it once
---rather than looking formats up name-by-name.
---@param adapter string
---@param configuration_name string
---@return table<string, string>
function M.configuration_input_formats(adapter, configuration_name)
    local configuration = M.configuration(adapter, configuration_name)
    if not configuration then return {} end
    return _input_formats(configuration)
end

---The input names a configuration declares, sorted. These are the `name=value`
---tokens `quick_run` accepts.
---@param adapter string
---@param configuration_name string
---@return string[]
function M.configuration_input_names(adapter, configuration_name)
    local out = {}
    for name in pairs(M.configuration_input_formats(adapter, configuration_name)) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

---The input names a configuration marks `required = true`, sorted — the ones
---`quick_run` errors on when left unset.
---@param adapter string
---@param configuration_name string
---@return string[]
function M.configuration_required(adapter, configuration_name)
    local configuration = M.configuration(adapter, configuration_name)
    local out = {}
    if not configuration then return out end
    for name, spec in pairs(configuration.inputs or {}) do
        if spec.required then out[#out + 1] = name end
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

-- ── Filling (quick_run) ────────────────────────────────────────────────────

---Read every declared input from `values`, coercing each by its `type`/`format`.
---A value that is already a non-string Lua value is taken verbatim. Unset inputs
---are simply absent from the result (recorded in `missing` when `required`), which
---is what lets `build` omit their fields by assigning nil.
---@param configuration easydap.Configuration
---@param values table<string, any>  input name → raw CLI string or typed value
---@return table<string, any> inputs, string[] missing, string[] errs
local function _read_inputs(configuration, values)
    local inputs, missing, errs = {}, {}, {}
    for name, spec in pairs(configuration.inputs or {}) do
        local raw = values[name]
        if raw == nil then
            if spec.required then missing[#missing + 1] = name end
        elseif type(raw) ~= "string" then
            inputs[name] = raw
        else
            local val, cerr = M.coerce(spec, raw)
            if cerr then
                errs[#errs + 1] = name .. ": " .. cerr
            else
                inputs[name] = val
            end
        end
    end
    -- `pairs` order is arbitrary; sort so the reported set is stable.
    table.sort(missing)
    table.sort(errs)
    return inputs, missing, errs
end

---Read a named configuration's inputs from `values` (input name → raw CLI string,
---or an already-typed Lua value to use verbatim) and hand them to the
---configuration's `build`, which assembles the native request body and any
---task-level connection in place.
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

    local inputs, missing, errs = _read_inputs(configuration, values)
    if #errs > 0 then return nil, nil, table.concat(errs, "; ") end
    if #missing > 0 then return nil, nil, "missing: " .. table.concat(missing, ", ") end

    local body, connect = {}, {}
    if configuration.build then configuration.build(body, connect, inputs) end

    -- No spec governs `connect` (it's task-level, not a body field), so an unset
    -- host/port is always optional: a `build` that leaves it empty reports none,
    -- and the resolved AdapterDef's own host/port apply instead.
    if next(connect) == nil then connect = nil end
    return body, connect
end

return M
