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
            build = function(_, connect, inputs)
                connect.host = inputs.host
                connect.port = inputs.port
            end,
        },
    },
}

-- The registry: the shipped `remote` adapter, plus every user adapter found in an
-- `ezdap-adapters/` directory on the runtimepath. Each file returns one AdapterDef
-- and is keyed by its filename stem; a file named `remote.lua` overrides the shipped one.

---@type table<string, ezdap.AdapterDef>
local M = {
    remote = remote,
}

---Load `path` into the stand-in that stands for it, so the entry is an ordinary
---table from then on. Fields already written by hand win over the file's, and a
---file that errors is reported and drops out of the registry.
---@param proxy table
---@param name string
---@param path string
local function _hydrate(proxy, name, path)
    setmetatable(proxy, nil)

    local def, err = nil, nil
    local chunk, load_err = loadfile(path)
    if not chunk then
        err = load_err
    else
        local ok, result = pcall(chunk)
        if not ok then
            err = result
        elseif type(result) ~= "table" then
            err = ("expected a table, got %s"):format(type(result))
        else
            def = result
        end
    end

    if not def then
        vim.notify(("[ezdap] failed to load adapter '%s' (%s): %s"):format(name, path, err),
            vim.log.levels.ERROR)
        if rawequal(rawget(M, name), proxy) then M[name] = nil end
        return
    end

    for k, v in pairs(def) do
        if rawget(proxy, k) == nil then rawset(proxy, k, v) end
    end
end

---A stand-in for the definition in `path`: an empty table that loads the file the
---first time any field is read. Reading a definition is what a run, the docs and
---`:checkhealth` all do, so nothing has to know the entry started out empty.
---@param name string
---@param path string
---@return ezdap.AdapterDef
local function _lazy(name, path)
    return setmetatable({}, {
        __index = function(proxy, key)
            _hydrate(proxy, name, path)
            return rawget(proxy, key)
        end,
    })
end

-- Find each `ezdap-adapters/*.lua` on the runtimepath, without loading any of them:
-- the glob is one pass over the runtimepath, while the files themselves cost whatever
-- their definitions do. The directory holds definitions only, never Lua modules, so
-- every file in it is an adapter and each is read from the path found here.
local _seen = {} ---@type table<string, boolean>
for _, path in ipairs(vim.api.nvim_get_runtime_file("ezdap-adapters/*.lua", true)) do
    local name = vim.fn.fnamemodify(path, ":t:r")
    -- Runtimepath order, so the first match for a name shadows any later one: a
    -- definition in your config overrides the plugin's.
    if not _seen[name] then
        _seen[name] = true
        M[name] = _lazy(name, path)
    end
end

return M
