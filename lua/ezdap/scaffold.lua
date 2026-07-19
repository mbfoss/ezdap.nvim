---@brief run_file scaffolding for `:Debug new_run_file`.
---
---Writes a runnable Lua run_file for an adapter + one of its `profiles`. The
---generated file is profile-based, exactly like `:Debug quick_run`: it names the
---`adapter` and `profile` and lists that profile's declared inputs under
---`parameters`, each seeded with a starting value (`ezdap.inputs`' `seed`) and
---annotated with its `description`. `:Debug run_file` resolves it through the
---profile's `build` (see `ezdap.schema`), so a run file and `quick_run`
---share one description of a profile — its `inputs` — and never drift.

local schema = require("ezdap.schema")
local inputs_registry = require("ezdap.inputs")

local M = {}

---@param msg string
local function _warn(msg) vim.notify("[ezdap] " .. msg, vim.log.levels.WARN) end

---@param msg string
local function _err(msg) vim.notify("[ezdap] " .. msg, vim.log.levels.ERROR) end

---Render a seed value as Lua source. Seeds are simple — strings, numbers,
---booleans, and (usually empty) tables — so this handles just those, emitting a
---one-line literal in each case. Array-like and map-like tables are both rendered
---inline; empty tables become `{}`.
---@param v any
---@return string
local function _lua_literal(v)
    local t = type(v)
    if t == "string" then return string.format("%q", v) end
    if t == "number" or t == "boolean" then return tostring(v) end
    if t == "table" then
        if next(v) == nil then return "{}" end
        local parts = {}
        if vim.islist(v) then
            for _, item in ipairs(v) do parts[#parts + 1] = _lua_literal(item) end
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, k in ipairs(keys) do
                parts[#parts + 1] = ("[%q] = %s"):format(k, _lua_literal(v[k]))
            end
        end
        return "{ " .. table.concat(parts, ", ") .. " }"
    end
    return "nil"
end

---Build the `parameters = { … }` lines for a profile: one `name = <seed>,` entry
---per declared input, sorted by name, each trailed by a `-- description` comment.
---Required inputs are written active; every other input is commented out, so the
---scaffolded file supplies only what a run needs and the reader uncomments the rest.
---Returns nil when the profile declares no inputs, so the caller can emit
---`parameters = {}` instead of an empty sandwich.
---@param adapter string
---@param profile_name string
---@return string[]?  the interior lines, already indented to sit inside `parameters`
local function _input_lines(adapter, profile_name)
    local names = schema.profile_input_names(adapter, profile_name)
    if #names == 0 then return nil end
    local specs = schema.profile_inputs(adapter, profile_name)

    -- Two passes: build each input's code — a `name = <seed>,` assignment, commented
    -- out unless the input is required — then pad them all to a common width so the
    -- trailing `-- description` comments line up.
    local codes, width = {}, 0
    for i, name in ipairs(names) do
        local assign = ("%s = %s,"):format(name, _lua_literal(inputs_registry.seed(specs[name])))
        codes[i] = specs[name].required and assign or ("-- " .. assign)
        width = math.max(width, #codes[i])
    end

    local lines = {}
    for i, name in ipairs(names) do
        local comment = specs[name].description or ""
        local line = "        " .. codes[i]
        if comment ~= "" then
            line = line .. string.rep(" ", width - #codes[i]) .. "  -- " .. comment
        end
        lines[i] = line
    end
    return lines
end

---Scaffold a run_file for an `adapter` + one of its `profiles`: write a Lua
---file that names the adapter + profile and seeds its inputs under `parameters`,
---then open it for editing. Run it afterwards with `:Debug run_file`, which resolves
---the `parameters` through the profile's `build` — the same path `quick_run` takes.
---`assignments` is positional: the adapter (required), the profile name
---(defaults to the adapter's sole profile), then the destination path
---(defaulting to `<project root or cwd>/<adapter>_<profile>.lua`). Fails if the
---destination already exists, rather than overwriting or picking a different name.
---Reports a clear error for every failure mode instead of throwing.
---@param assignments string[]  positional adapter, profile, path, e.g. { "codelldb", "launch", "./foo.lua" }
---@return string? path  the file that was created
function M.new_run_file(assignments)
    -- Every argument is positional: `new_run_file <adapter> [profile] [path]`.
    local adapter, profile_name, path
    for _, tok in ipairs(assignments or {}) do
        if not adapter then
            adapter = tok
        elseif not profile_name then
            profile_name = tok
        elseif not path then
            path = tok
        else
            _warn("new_run_file: unexpected argument '" .. tok ..
                "' (usage: new_run_file <adapter> [profile] [path])")
            return
        end
    end

    if not adapter or adapter == "" then
        _warn("new_run_file: usage: new_run_file <adapter> [profile] [path]")
        return
    end
    local base = require("ezdap.adapters")[adapter]
    if not base then
        _err("new_run_file: unknown adapter: " .. adapter ..
            " (available: " .. table.concat(schema.profiled_adapters(), ", ") .. ")")
        return
    end

    -- Resolve the profile: given, else the adapter's sole profile — reject an
    -- adapter that declares none, or an ambiguous choice among several.
    local names = schema.profile_names(adapter)
    if #names == 0 then
        _err("new_run_file: adapter " .. adapter .. " declares no profiles")
        return
    end
    if profile_name and profile_name ~= "" then
        if not vim.tbl_contains(names, profile_name) then
            _err(("new_run_file: adapter %s has no profile %q (available: %s)")
                :format(adapter, profile_name, table.concat(names, ", ")))
            return
        end
    elseif #names == 1 then
        profile_name = names[1]
    else
        _err(("new_run_file: adapter %s has multiple profiles, pick one (available: %s)")
            :format(adapter, table.concat(names, ", ")))
        return
    end

    -- Resolve the destination; fail rather than clobber or rename an existing file.
    local root = require("ezdap.store").root() or vim.fn.getcwd()
    local dest = (path and path ~= "") and vim.fn.fnamemodify(vim.fn.expand(path), ":p")
        or vim.fs.joinpath(root, adapter .. "_" .. profile_name .. ".lua")
    if not dest:match("%.lua$") then dest = dest .. ".lua" end
    if vim.uv.fs_stat(dest) then
        _err("new_run_file: file already exists: " .. dest)
        return
    end

    local lines = {
        "-- ezdap run file",
        "return {",
        ("    name       = %q,"):format(adapter),
        ("    adapter    = %q,"):format(adapter),
        ("    profile    = %q,"):format(profile_name),
    }
    -- The profile's declared inputs are answered under `parameters`. A profile with
    -- no inputs gets an empty `parameters` rather than a `{` / blank line / `}`
    -- sandwich.
    local input_lines = _input_lines(adapter, profile_name)
    if not input_lines then
        lines[#lines + 1] = "    parameters = {},"
    else
        lines[#lines + 1] = "    parameters = {"
        vim.list_extend(lines, input_lines)
        lines[#lines + 1] = "    },"
    end
    vim.list_extend(lines, { "}", "" })

    local ok, werr = require("ezdap.tk.fsutil").write_content(dest, table.concat(lines, "\n"))
    if not ok then
        _err("new_run_file: failed to write " .. dest .. ": " .. tostring(werr))
        return
    end
    require("ezdap.util.ui_util").smart_open_file(vim.fn.fnameescape(dest))
    return dest
end

return M
