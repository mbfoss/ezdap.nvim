---@brief Schema engine behind `:Debug new_run_file` and `:Debug quick_run`.
---
---Adapters carry no launch/attach schema of their own — each adapter's
---`profiles` (named `ezdap.Profile` entries, in `ezdap.adapters`)
---are wholly self-describing. A profile declares its inputs up front in an
---`inputs` table — `name -> ezdap.Input` — which both `:Debug quick_run` and a
---scaffolded run file read, then resolve the same way: `resolve_task` runs the
---profile's `build` over the supplied values to assemble a runnable task.
---

local inputs_registry = require("ezdap.inputs")

local M = {}

-- ── Introspection ──────────────────────────────────────────────────────────

---An adapter's declared `profiles`, or an empty table.
---@param adapter string
---@return table<string, ezdap.Profile>
function M.profiles(adapter)
    local def = require("ezdap.adapters")[adapter]
    return (def and def.profiles) or {}
end

---A single named profile, or nil.
---@param adapter string
---@param name string
---@return ezdap.Profile?
function M.profile(adapter, name)
    return M.profiles(adapter)[name]
end

---An adapter's profile names, sorted.
---@param adapter string
---@return string[]
function M.profile_names(adapter)
    local out = {}
    for name in pairs(M.profiles(adapter)) do out[#out + 1] = name end
    table.sort(out)
    return out
end

---The inputs a profile declares (`name -> ezdap.Input`), or an empty table.
---Hand an entry to `ezdap.inputs` to learn how to read, describe, seed or complete
---it; callers that need several inputs should read the table once rather than
---looking entries up name-by-name.
---@param adapter string
---@param profile_name string
---@return table<string, ezdap.Input>
function M.profile_inputs(adapter, profile_name)
    local profile = M.profile(adapter, profile_name)
    return (profile and profile.inputs) or {}
end

---The input names a profile declares, sorted. These are the `name=value`
---tokens `quick_run` accepts, and the `parameters` keys a tasks file may set.
---@param adapter string
---@param profile_name string
---@return string[]
function M.profile_input_names(adapter, profile_name)
    local out = {}
    for name in pairs(M.profile_inputs(adapter, profile_name)) do
        out[#out + 1] = name
    end
    table.sort(out)
    return out
end

---The input names a profile marks `required = true`, sorted — the ones
---`resolve_task` errors on when left unset.
---@param adapter string
---@param profile_name string
---@return string[]
function M.profile_required(adapter, profile_name)
    local out = {}
    for name, spec in pairs(M.profile_inputs(adapter, profile_name)) do
        if spec.required then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

---Adapter names a profile-driven front end can offer — those declaring at
---least one profile — sorted.
---@return string[]
function M.profiled_adapters()
    local out = {}
    for name, def in pairs(require("ezdap.adapters")) do
        if def.profiles and next(def.profiles) then out[#out + 1] = name end
    end
    table.sort(out)
    return out
end

---The distinct `request` values ("launch"/"attach") an adapter's profiles use,
---sorted.
---@param adapter string
---@return string[]
function M.requests(adapter)
    local seen, out = {}, {}
    for _, profile in pairs(M.profiles(adapter)) do
        if not seen[profile.request] then
            seen[profile.request] = true
            out[#out + 1] = profile.request
        end
    end
    table.sort(out)
    return out
end

-- ── Resolving ──────────────────────────────────────────────────────────────

---Read every declared input from `values`. A string is that input's string form and
---is parsed by its `type`/`format`; any other Lua value is already the typed form
---and is taken verbatim (see `ezdap.inputs` on the two forms). Unset inputs are
---simply absent from the result (recorded in `missing` when `required`), which is
---what lets `build` omit their fields by assigning nil — or source them some other
---way, as an attach profile does for an unset `pid`.
---@param profile ezdap.Profile
---@param values table<string, any>  input name → a value in either authoring form
---@return table<string, any> inputs, string[] missing, string[] errs
local function _read_inputs(profile, values)
    local inputs, missing, errs = {}, {}, {}
    for name, spec in pairs(profile.inputs or {}) do
        local raw = values[name]
        if raw == nil then
            if spec.required then missing[#missing + 1] = name end
        elseif type(raw) ~= "string" then
            inputs[name] = raw
        else
            local val, cerr = inputs_registry.parse(spec, raw)
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

---What to resolve: an adapter's named profile, the values for its inputs, and
---the name the resulting task should run under.
---@class ezdap.ResolveSpec
---@field adapter       string
---@field profile string
---@field name?         string              run/panel group name for the resolved task
---@field values?       table<string, any>  input name → a value in either authoring form

---Resolve one of an adapter's named profiles, plus values for its inputs,
---into a runnable `ezdap.Task` — everything `run`/`start_task` needs, with the
---request kind and any task-level connection already in place. This is the single
---seam between a profile and a front end: a caller supplies values and gets
---back a task, and never has to rejoin the two itself.
---@param spec ezdap.ResolveSpec
---@param done fun(task: ezdap.Task?, err: string?)
---@return fun() cancel
function M.resolve_task(spec, done)
    local settled, cancelled = false, false

    ---@param task ezdap.Task?
    ---@param err string?
    local function finish(task, err)
        if settled or cancelled then return end
        settled = true
        done(task, err)
    end

    local function cancel() cancelled = true end

    local profile = M.profile(spec.adapter, spec.profile)
    if not profile then
        finish(nil, ("adapter %s has no profile %q (available: %s)")
            :format(spec.adapter, tostring(spec.profile),
                table.concat(M.profile_names(spec.adapter), ", ")))
        return cancel
    end

    local inputs, missing, errs = _read_inputs(profile, spec.values or {})
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
            request    = profile.request,
            parameters = body,
            host       = has_connect and connect.host or nil,
            port       = has_connect and connect.port or nil,
        })
    end

    if not profile.build then
        deliver()
        return cancel
    end

    local co = coroutine.create(function()
        local ok, berr = xpcall(profile.build, debug.traceback, body, connect, inputs)
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
