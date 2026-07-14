---@brief run_file scaffolding for `:Debug new_run_file`.
---
---Writes a runnable Lua run_file for an adapter + one of its `configurations`,
---pre-populating `parameters` from that configuration's literal fields (identity
---fields, computed defaults) and a blank, type-appropriate placeholder for
---each of its `{name}`/`{name:kind}` tokens. It renders the configuration — read via
---`easydap.schema` — into Lua source; the DAP core and body assembly stay in
---`easydap.schema`.

local schema = require("easydap.schema")

local M = {}

---Preferred position of well-known keys in a rendered `parameters` block: the
---identity/target/args/cwd/env fields configurations consistently declare first.
---Keys absent here sort alphabetically after all of these.
---@type table<string, integer>
local _key_priority = { type = 1, name = 2, program = 3, module = 3, args = 4, cwd = 5, env = 6 }

---@param msg string
local function _warn(msg) vim.notify("[easydap] " .. msg, vim.log.levels.WARN) end

---@param msg string
local function _err(msg) vim.notify("[easydap] " .. msg, vim.log.levels.ERROR) end

---A blank value of the shape a placeholder `kind` expects, used to seed a
---template entry with no default (so the generated file is valid Lua to edit).
---@param kind string?
---@return any
local function _blank(kind)
    if kind == "list" or kind == "env" or kind == "shell_args" then return {} end
    if kind == "port" or kind == "integer" then return 0 end
    if kind == "number" then return 0 end
    if kind == "boolean" then return false end
    return "" -- string / file / dir / cwd / host / unset
end

---Render a configuration's `parameters` as the body of a Lua `parameters` table — a
---multi-line source string for a run_file template (see `new_run_file`). Each
---leaf is emitted on its own line: a placeholder becomes a blank value shaped
---like its `kind`; a literal (including a zero-arg function default) is
---resolved via `schema.resolve_value` and kept as-is — those are typically
---identity fields the configuration pins itself, so editing them has no effect once
---the file runs through the same configuration again. `indent` is the column (in
---spaces) the outermost params sit at. Keys are sorted by `_key_priority`
---(identity/target/args/cwd/env first), then alphabetically, for stable,
---readable output.
---@param adapter string
---@param configuration_name string
---@param indent integer
---@return string? lua, string? err
local function _render_params(adapter, configuration_name, indent)
    local configuration = schema.configuration(adapter, configuration_name)
    if not configuration then
        return nil, ("adapter %s has no configuration %q"):format(adapter, tostring(configuration_name))
    end

    local lines = {}
    local function emit(fields, pad)
        local keys = {}
        for k in pairs(fields) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            local pa, pb = _key_priority[a] or math.huge, _key_priority[b] or math.huge
            if pa ~= pb then return pa < pb end
            return a < b
        end)
        for _, k in ipairs(keys) do
            local node = fields[k]
            -- Bare identifier keys stay unquoted; anything else needs ["..."].
            local lhs = k:match("^[%a_][%w_]*$") and k or ("[%q]"):format(k)
            if type(node) == "table" then
                lines[#lines + 1] = ("%s%s = {"):format(pad, lhs)
                emit(node, pad .. "    ")
                lines[#lines + 1] = ("%s},"):format(pad)
            else
                local val = node
                if type(node) == "string" then
                    local name, kind = node:match("^{([%w_]+):?([%w_]*)}$")
                    if name then val = _blank(kind) end
                elseif type(node) == "function" then
                    val = schema.resolve_value(node)
                end
                lines[#lines + 1] = ("%s%s = %s,"):format(pad, lhs, vim.inspect(val))
            end
        end
    end
    emit(configuration.parameters or {}, string.rep(" ", indent))
    return table.concat(lines, "\n")
end

---Scaffold a run_file for an `adapter` + one of its `configurations`: write a Lua file
---that returns a task table whose `parameters` are pre-populated from the
---configuration's literal fields and blank placeholders, then open it for
---editing. Run it afterwards with `:Debug run_file`. `assignments` is
---positional: the adapter (required), the configuration name (defaults to the
---adapter's sole configuration), then the destination path (defaulting to `<project
---root or cwd>/<adapter>_<configuration>.lua`). Fails if the destination already
---exists, rather than overwriting or picking a different name. Reports a clear
---error for every failure mode instead of throwing.
---@param assignments string[]  positional adapter, configuration, path, e.g. { "codelldb", "launch", "./foo.lua" }
---@return string? path  the file that was created
function M.new_run_file(assignments)
    -- Every argument is positional: `new_run_file <adapter> [configuration] [path]`.
    local adapter, configuration_name, path
    for _, tok in ipairs(assignments or {}) do
        if not adapter then
            adapter = tok
        elseif not configuration_name then
            configuration_name = tok
        elseif not path then
            path = tok
        else
            _warn("new_run_file: unexpected argument '" .. tok ..
                "' (usage: new_run_file <adapter> [configuration] [path])")
            return
        end
    end

    if not adapter or adapter == "" then
        _warn("new_run_file: usage: new_run_file <adapter> [configuration] [path]")
        return
    end
    local base = require("easydap.adapters")[adapter]
    if not base then
        _err("new_run_file: unknown adapter: " .. adapter ..
            " (available: " .. table.concat(schema.quick_run_adapters(), ", ") .. ")")
        return
    end

    -- Resolve the configuration: given, else the adapter's sole configuration — reject an
    -- adapter that declares none, or an ambiguous choice among several.
    local names = schema.configuration_names(adapter)
    if #names == 0 then
        _err("new_run_file: adapter " .. adapter .. " declares no configurations")
        return
    end
    if configuration_name and configuration_name ~= "" then
        if not vim.tbl_contains(names, configuration_name) then
            _err(("new_run_file: adapter %s has no configuration %q (available: %s)")
                :format(adapter, configuration_name, table.concat(names, ", ")))
            return
        end
    elseif #names == 1 then
        configuration_name = names[1]
    else
        _err(("new_run_file: adapter %s has multiple configurations, pick one (available: %s)")
            :format(adapter, table.concat(names, ", ")))
        return
    end
    local configuration = assert(schema.configuration(adapter, configuration_name))

    -- Resolve the destination; fail rather than clobber or rename an existing file.
    local root = require("easydap.store").root() or vim.fn.getcwd()
    local dest = (path and path ~= "") and vim.fn.fnamemodify(vim.fn.expand(path), ":p")
        or vim.fs.joinpath(root, adapter .. "_" .. configuration_name .. ".lua")
    if not dest:match("%.lua$") then dest = dest .. ".lua" end
    if vim.uv.fs_stat(dest) then
        _err("new_run_file: file already exists: " .. dest)
        return
    end

    local params_src, perr = _render_params(adapter, configuration_name, 8)
    if not params_src then
        _err("new_run_file: " .. tostring(perr))
        return
    end

    local lines = {
        "-- easydap run file",
        "return {",
        ("    name       = %q,"):format(adapter),
        ("    adapter    = %q,"):format(adapter),
        ("    request    = %q,"):format(configuration.request),
    }
    -- TCP adapters carry host/port at the task level, not in the body; seed them.
    if base.host ~= nil or base.port ~= nil then
        lines[#lines + 1] = ("    host       = %q,"):format(base.host or "127.0.0.1")
        lines[#lines + 1] = ("    port       = %d,"):format(base.port or 0)
    end
    vim.list_extend(lines, { "    parameters = {", params_src, "    },", "}", "" })

    local ok, werr = require("easydap.tk.fsutil").write_content(dest, table.concat(lines, "\n"))
    if not ok then
        _err("new_run_file: failed to write " .. dest .. ": " .. tostring(werr))
        return
    end
    require("easydap.util.ui_util").smart_open_file(vim.fn.fnameescape(dest))
    return dest
end

return M
