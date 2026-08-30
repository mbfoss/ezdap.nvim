---@brief DAP adapter registry.

-- adapter defintion type in adapter_def.lua

-- The one shipped adapter: generic TCP attach — connect to a DAP server already
-- listening on host:port. host/port live at the task level (they set the connection),
-- so the attach body itself stays minimal.
---@type ezdap.AdapterDef
local remote = {
    host     = "127.0.0.1",
    port     = 0,
    modes    = {
        connect = {
            description = "attach to a DAP server listening on host:port",
            request     = "attach",
            inputs = {
                host = {
                    type = "string", description = "DAP server host",
                    choices = { "localhost", "127.0.0.1", "::1", "::" },
                },
                port = { type = "integer", format = "port", description = "DAP server port" },
            },
            build = function(inputs)
                return {}, { host = inputs.host, port = inputs.port }
            end,
        },
    },
}

-- The registry: the shipped `remote` adapter, plus every user adapter found in an
-- `ezdap-adapters/` directory on the runtimepath. Each file returns one AdapterDef
-- and is keyed by its filename stem; a file named `remote.lua` overrides the shipped one.

---@type table<string, ezdap.AdapterDef>
local M = {}

-- Definition files by name, discovered on first read. Names come from the
-- filenames alone, so listing adapters runs no definition; a file is loaded when
-- its name is first read and cached on M from there.
local _paths ---@type table<string, string>?

-- Definitions whose file failed to load, `name → message`. A name that is simply
-- absent is the one thing a registry of names cannot report, so the reader of an
-- adapter's report reads these; they sit on the metatable to keep `pairs(M)` names.
local _errors = {} ---@type table<string, string>

---Every `ezdap-adapters/*.lua` on the runtimepath, `name → path`.
---@return table<string, string>
local function _discover()
    if _paths then return _paths end
    _paths = {}
    for _, path in ipairs(vim.api.nvim_get_runtime_file("ezdap-adapters/*.lua", true)) do
        local name = vim.fn.fnamemodify(path, ":t:r")
        -- Runtimepath order, so the first match for a name shadows any later one: a
        -- definition in your config overrides the plugin's.
        if not _paths[name] then _paths[name] = path end
    end
    return _paths
end

---Read the definition in `path`.
---@param path string
---@return ezdap.AdapterDef? def, string? err
local function _load(path)
    local chunk, load_err = loadfile(path)
    if not chunk then return nil, load_err end

    local ok, result = pcall(chunk)
    if not ok then return nil, result end
    if type(result) ~= "table" then
        return nil, ("expected a table, got %s"):format(type(result))
    end
    return result
end

---Load the definition named `name` and cache it on the registry. A file that
---fails to load leaves the name absent — a broken override shadows what it meant
---to replace, rather than silently running a different definition.
---@param registry table<string, ezdap.AdapterDef>
---@param name string
---@return ezdap.AdapterDef?
local function _resolve(registry, name)
    local path = _discover()[name]
    if not path then
        if name ~= "remote" then return nil end
        rawset(registry, name, remote)
        return remote
    end

    local def, err = _load(path)
    if not def then
        -- Every read of a broken name retries the file, so it is reported again only
        -- when what it fails with changes — an edit, rather than a second reader.
        if _errors[name] ~= err then
            vim.notify(("[ezdap] failed to load adapter '%s' (%s): %s"):format(name, path, err),
                vim.log.levels.ERROR)
        end
        _errors[name] = err
        return nil
    end
    _errors[name] = nil
    rawset(registry, name, def)
    return def
end

---Every registered adapter name, sorted — the definition files, read by their
---filenames alone, plus whatever has been assigned to the registry at runtime.
---No definition is loaded to answer.
---@return string[]
local function _names()
    local out, seen = {}, {}
    local function add(name)
        if not seen[name] then out[#out + 1], seen[name] = name, true end
    end
    for name in pairs(_discover()) do add(name) end
    for name in pairs(M) do add(name) end
    add("remote")
    table.sort(out)
    return out
end

setmetatable(M, { __index = _resolve, names = _names, errors = _errors })

return M
