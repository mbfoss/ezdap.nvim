---@brief run_file scaffolding for `:Debug new_run_file`.
---
---Writes a runnable Lua run_file for an `adapter` + `request`, pre-populating its
---`parameters` from the adapter's launch/attach schema (defaults and
---type-appropriate placeholders for the rest, each annotated with its description).
---It renders the schema — read via `easydap.schema` — into Lua source; the DAP core
---and body assembly stay in `easydap.schema`.

local schema = require("easydap.schema")

local M = {}

---Preferred position of well-known keys in a rendered `parameters` block: the
---identity/target/args/cwd/env fields adapters consistently declare first
---(mirroring their declaration order in `easydap.adapters`). Keys absent here sort
---alphabetically after all of these.
---@type table<string, integer>
local _key_priority = { type = 1, name = 2, program = 3, module = 3, args = 4, cwd = 5, env = 6 }

---@param msg string
local function _warn(msg) vim.notify("[easydap] " .. msg, vim.log.levels.WARN) end

---@param msg string
local function _err(msg) vim.notify("[easydap] " .. msg, vim.log.levels.ERROR) end

---A blank value of the shape `spec` expects, used to seed a template entry the
---caller has no default for (so the generated file is valid Lua to edit).
---@param spec easydap.ParamSpec
---@return any
local function _placeholder(spec)
    if spec.role == "args" then return {} end
    local k = spec.kind
    if k == "list" or k == "env" then return {} end
    if k == "enum" then return (spec.enum and spec.enum[1]) or "" end
    if k == "port" then return 0 end
    local t = spec.type
    if t == "boolean" then return false end
    if t == "integer" or t == "number" then return 0 end
    if t == "table" then return {} end
    return "" -- string / file / dir / host + target role
end

---Render an adapter's request schema as the body of a Lua `parameters` table — a
---multi-line source string for a run_file template (see `new_run_file`). Each leaf
---param is emitted on its own line, seeded with its resolved default or a
---type-appropriate placeholder, with a trailing `-- desc` comment; nested groups
---are rendered inline. Fields marked `fixed` (e.g. `type`/`name` identity fields
---the adapter pins itself) are omitted entirely — they are not meant to be
---user-edited. `indent` is the column (in spaces) the outermost params sit
---at. Keys are sorted by `_key_priority` (identity/target/args/cwd/env first), then
---alphabetically, for stable, readable output.
---@param adapter string
---@param request string
---@param indent integer
---@return string? lua, string? err
local function _render_params(adapter, request, indent)
    local sch = schema.schema(adapter, request)
    if not sch then
        return nil, ("adapter %s has no %s schema"):format(tostring(adapter), tostring(request))
    end
    local lines = {}
    local function emit(group, pad)
        local fields = schema.group_fields(group)
        local keys = {}
        for k in pairs(fields) do keys[#keys + 1] = k end
        table.sort(keys, function(a, b)
            local pa, pb = _key_priority[a] or math.huge, _key_priority[b] or math.huge
            if pa ~= pb then return pa < pb end
            return a < b
        end)
        for _, k in ipairs(keys) do
            local node = fields[k]
            if schema.is_group(node) then
                lines[#lines + 1] = ("%s%s = {"):format(pad, k:match("^[%a_][%w_]*$") and k or ("[%q]"):format(k))
                emit(node, pad .. "    ")
                lines[#lines + 1] = ("%s},"):format(pad)
            elseif not node.fixed then
                -- Bare identifier keys stay unquoted; anything else needs ["..."].
                local lhs     = k:match("^[%a_][%w_]*$") and k or ("[%q]"):format(k)
                local val     = (node.default ~= nil) and schema.resolve_default(node) or _placeholder(node)
                local line    = ("%s%s = %s,"):format(pad, lhs, vim.inspect(val))
                local comment = node.desc
                if comment then line = line .. "  -- " .. comment end
                lines[#lines + 1] = line
            end
        end
    end
    emit(sch, string.rep(" ", indent))
    return table.concat(lines, "\n")
end

---Scaffold a run_file for an `adapter` + `request`: write a Lua file that returns a
---task table whose `parameters` are pre-populated from the adapter's schema (defaults,
---and type-appropriate placeholders for the rest, each annotated
---with its description), then open it for editing. Run it afterwards with `:Debug
---run_file`. `assignments` leads with the adapter (required) and request
---(positional; defaults to the adapter's own default request, or its sole schema)
---as bare tokens, then an optional `path=` token (destination file, defaulting to
---`<project root or cwd>/<adapter>_<request>.lua`). Fails if the destination
---already exists, rather than overwriting or picking a different name. Reports a
---clear error for every failure mode instead of throwing.
---@param assignments string[]  adapter, request, then optional "path=value", e.g. { "codelldb", "launch", "path=./foo.lua" }
---@return string? path  the file that was created
function M.new_run_file(assignments)
    -- The adapter and request come first as bare positional arguments
    -- (`new_run_file codelldb launch`); `path=` is the only keyed token.
    local adapter, request, path
    for _, tok in ipairs(assignments or {}) do
        local eq = tok:find("=", 1, true)
        if eq then
            local key = tok:sub(1, eq - 1)
            if key == "path" then
                path = tok:sub(eq + 1)
            else
                _warn("new_run_file: unknown key '" .. key .. "' (supported: path; adapter/request are positional)")
                return
            end
        elseif not adapter then
            adapter = tok
        elseif not request then
            request = tok
        else
            _warn("new_run_file: unexpected argument '" .. tok .. "' (expected path=value)")
            return
        end
    end

    if not adapter or adapter == "" then
        _warn("new_run_file: usage: new_run_file <adapter> [request] [path=value]")
        return
    end
    local base = require("easydap.adapters")[adapter]
    if not base then
        _err("new_run_file: unknown adapter: " .. adapter ..
            " (available: " .. table.concat(schema.adapter_names(), ", ") .. ")")
        return
    end

    -- Resolve the request: given, else the adapter's DAP default, else its sole
    -- schema — then reject anything the adapter has no schema for.
    local supported = schema.requests(adapter)
    if #supported == 0 then
        _err("new_run_file: adapter " .. adapter .. " declares no launch/attach schema")
        return
    end
    request = (request and request ~= "") and request or (base.request or "launch")
    if not vim.tbl_contains(supported, request) then
        if #supported == 1 then
            request = supported[1]
        else
            _err(("new_run_file: adapter %s has no %s schema (supports: %s)")
                :format(adapter, request, table.concat(supported, ", ")))
            return
        end
    end

    -- Resolve the destination; fail rather than clobber or rename an existing file.
    local root = require("easydap.store").root() or vim.fn.getcwd()
    local dest = (path and path ~= "") and vim.fn.fnamemodify(vim.fn.expand(path), ":p")
        or vim.fs.joinpath(root, adapter .. "_" .. request .. ".lua")
    if not dest:match("%.lua$") then dest = dest .. ".lua" end
    if vim.uv.fs_stat(dest) then
        _err("new_run_file: file already exists: " .. dest)
        return
    end

    local params_src, perr = _render_params(adapter, request, 8)
    if not params_src then
        _err("new_run_file: " .. tostring(perr))
        return
    end

    local lines = {
        ("-- easydap run — %s (%s)"):format(adapter, request),
        "-- Edit the parameters, then run with:  :Debug run_file " .. vim.fn.fnamemodify(dest, ":~:."),
        "return {",
        ("    name       = %q,"):format(adapter),
        ("    adapter    = %q,"):format(adapter),
        ("    request    = %q,"):format(request),
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
