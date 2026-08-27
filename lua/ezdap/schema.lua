---@brief Schema engine behind `:Debug new_run_file` and `:Debug run`.
---
---Adapters carry no launch/attach schema of their own — each adapter's
---`modes` (named `ezdap.Mode` entries, in `ezdap.adapters`)
---are wholly self-describing. A mode declares its inputs up front in an
---`inputs` table — `name -> ezdap.Input` — which both `:Debug run` and a
---scaffolded run file read, then resolve the same way: `resolve_task` runs the
---mode's `build` over the supplied values to assemble a runnable task.
---

local inputs_registry = require("ezdap.inputs")

local M = {}

-- Introspection

---An adapter's declared `modes`, or an empty table.
---@param adapter string
---@return table<string, ezdap.Mode>
function M.modes(adapter)
    local def = require("ezdap.adapters")[adapter]
    return (def and def.modes) or {}
end

---A single named mode, or nil.
---@param adapter string
---@param name string
---@return ezdap.Mode?
function M.mode(adapter, name)
    return M.modes(adapter)[name]
end

---An adapter's mode names, sorted.
---@param adapter string
---@return string[]
function M.mode_names(adapter)
    local out = {}
    for name in pairs(M.modes(adapter)) do out[#out + 1] = name end
    table.sort(out)
    return out
end

---The inputs a mode declares (`name -> ezdap.Input`), or an empty table. Hand an
---entry to `ezdap.inputs` to learn how to read, describe, seed or complete it; read
---the table once rather than looking entries up name-by-name.
---@param adapter string
---@param mode_name string
---@return table<string, ezdap.Input>
function M.mode_inputs(adapter, mode_name)
    local mode = M.mode(adapter, mode_name)
    return (mode and mode.inputs) or {}
end

---The input names a mode declares, sorted. These are the `name=value`
---tokens `:Debug run` accepts, and the `parameters` keys a tasks file may set.
---@param adapter string
---@param mode_name string
---@return string[]
function M.mode_input_names(adapter, mode_name)
    local out = {}
    for name in pairs(M.mode_inputs(adapter, mode_name)) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

---The input names a mode marks `required = true`, sorted — the ones
---`resolve_task` errors on when left unset.
---@param adapter string
---@param mode_name string
---@return string[]
function M.mode_required(adapter, mode_name)
    local out = {}
    for name, spec in pairs(M.mode_inputs(adapter, mode_name)) do
        if spec.required then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

---Adapter names a mode-driven front end can offer — those declaring at
---least one mode — sorted.
---@return string[]
function M.adapters_with_modes()
    local out = {}
    for name, def in pairs(require("ezdap.adapters")) do
        if def.modes and next(def.modes) then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

---The distinct `request` values ("launch"/"attach") an adapter's modes use,
---sorted.
---@param adapter string
---@return string[]
function M.requests(adapter)
    local seen, out = {}, {}
    for _, mode in pairs(M.modes(adapter)) do
        if not seen[mode.request] then
            seen[mode.request] = true
            out[#out + 1] = mode.request
        end
    end
    table.sort(out)
    return out
end

-- Validation

---One mode's declaration problems, each already prefixed with the mode name.
---@param adapter string
---@param mode_name string
---@param out string[]  appended to
local function _check_mode(adapter, mode_name, out)
    local mode = M.mode(adapter, mode_name)
    local function problem(fmt, ...) out[#out + 1] = mode_name .. ": " .. fmt:format(...) end

    if mode.request ~= "launch" and mode.request ~= "attach" then
        problem("request is %s, expected \"launch\" or \"attach\"", vim.inspect(mode.request))
    end
    if type(mode.description) ~= "string" or mode.description == "" then
        problem("no description")
    end
    if mode.build ~= nil and type(mode.build) ~= "function" then
        problem("build is %s, expected a function", type(mode.build))
    end
    if mode.inputs ~= nil and type(mode.inputs) ~= "table" then
        problem("inputs is %s, expected a table", type(mode.inputs))
        return
    end

    for _, name in ipairs(M.mode_input_names(adapter, mode_name)) do
        local spec = M.mode_inputs(adapter, mode_name)[name]
        local err = inputs_registry.check(spec)
        if err then problem("input %s: %s", name, err) end
        if spec.choices ~= nil and not vim.islist(spec.choices) then
            problem("input %s: choices is not a list", name)
        end
    end
end

---Everything wrong with one registered adapter's definition, as messages — a
---mode that requests neither launch nor attach, an input that cannot be read.
---An empty list is a definition that resolves, not one that runs: whether the
---adapter's tooling is installed is `:checkhealth ezdap`.
---@param adapter string
---@return string[] problems
function M.validate(adapter)
    local def = require("ezdap.adapters")[adapter]
    if type(def) ~= "table" then
        return { ("not a table, got %s"):format(type(def)) }
    end

    local out = {}
    if def.command == nil and def.host == nil and def.port == nil and def.setup == nil then
        out[#out + 1] = "no command, host/port or setup: nothing says how to reach the adapter"
    end

    local names = M.mode_names(adapter)
    if #names == 0 then
        out[#out + 1] = "declares no modes: `:Debug run` cannot reach it"
    end
    for _, name in ipairs(names) do _check_mode(adapter, name, out) end
    return out
end

---Every registered adapter's problems, keyed by adapter name. Adapters that
---resolve cleanly are absent, so an empty table is a clean registry.
---@return table<string, string[]>
function M.validate_all()
    local out = {}
    for name in pairs(require("ezdap.adapters")) do
        local problems = M.validate(name)
        if #problems > 0 then out[name] = problems end
    end
    return out
end

-- Resolving

---Read every declared input from `values`, in whichever form it was authored: a
---string is the string form and is `parse`d, any other Lua value is the typed form
---and is `read`. Unset inputs are absent (recorded in `missing` when `required`).
---@param mode ezdap.Mode
---@param values table<string, any>  input name → a value in either authoring form
---@return table<string, any> inputs, string[] missing, string[] errs
local function _read_inputs(mode, values)
    local inputs, missing, errs = {}, {}, {}
    for name, spec in pairs(mode.inputs or {}) do
        local raw = values[name]
        -- An input cleared rather than answered (`:Debug run … cwd=`) is one that was
        -- not supplied: `build` assigns it unconditionally, and only nil drops the field.
        if raw == nil or raw == "" then
            if spec.required then missing[#missing + 1] = name end
        else
            local val, cerr
            if type(raw) == "string" then
                val, cerr = inputs_registry.parse(spec, raw)
            else
                val, cerr = inputs_registry.read(spec, raw)
            end
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

---What to resolve: an adapter's named mode, the values for its inputs, and
---the name the resulting task should run under.
---@class ezdap.ResolveSpec
---@field adapter       string
---@field mode string
---@field name?         string              run group name for the resolved task
---@field values?       table<string, any>  input name → a value in either authoring form

---Resolve one of an adapter's named modes, plus values for its inputs, into a
---runnable `ezdap.Task` — request kind and any task-level connection already in
---place. This is the single seam between a mode and a front end.
---@param spec ezdap.ResolveSpec
---@param done fun(task: ezdap.Task?, err: string?)
---@return fun() cancel
function M.resolve_task(spec, done)
    local settled, cancelled = false, false

    ---@param task ezdap.Task?
    ---@param err string?
    local function finish(task, err)
        if settled or cancelled then return end
        done(task, err)
        settled = true -- set after done() because it may fail and settle with error
    end

    local function cancel() cancelled = true end

    local mode = M.mode(spec.adapter, spec.mode)
    if not mode then
        finish(nil, ("adapter %s has no mode %q (available: %s)")
            :format(spec.adapter, tostring(spec.mode),
                table.concat(M.mode_names(spec.adapter), ", ")))
        return cancel
    end

    local inputs, missing, errs = _read_inputs(mode, spec.values or {})
    if #errs > 0 then
        finish(nil, table.concat(errs, "; "))
        return cancel
    end
    if #missing > 0 then
        finish(nil, "missing: " .. table.concat(missing, ", "))
        return cancel
    end

    local body, connect = {}, {}

    ---Package what `build` assembled in place into the task it describes.
    local function deliver()
        -- No spec governs `connect` (it's task-level, not a body field), so an unset
        -- host/port is always optional: a `build` that leaves it empty reports none,
        -- and the resolved AdapterDef's own host/port apply instead.
        local has_connect = next(connect) ~= nil
        finish({
            name       = spec.name,
            adapter    = spec.adapter,
            mode       = spec.mode,
            request    = mode.request,
            parameters = body,
            host       = has_connect and connect.host or nil,
            port       = has_connect and connect.port or nil,
        })
    end

    if not mode.build then
        deliver()
        return cancel
    end

    local co = coroutine.create(function()
        local ok, berr = xpcall(mode.build, debug.traceback, body, connect, inputs)
        if not ok then return finish(nil, berr) end
        -- `build` gave up — a cancelled picker.
        if berr then return finish(nil, berr) end
        deliver()
    end)
    local ok, err = coroutine.resume(co)
    if not ok then finish(nil, tostring(err)) end

    return cancel
end

return M
