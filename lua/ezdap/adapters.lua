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
local M = {
    remote = remote,
}

-- Definitions whose file failed to load, `name → message`. A name that is simply
-- absent is the one thing a registry of names cannot report, so `:checkhealth` reads
-- these; they sit on the metatable to keep `pairs(M)` adapter names only.
local _errors = {} ---@type table<string, string>
setmetatable(M, { errors = _errors })

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

-- Find each `ezdap-adapters/*.lua` on the runtimepath and load it. Nothing requires
-- this module at startup — a run, the docs and `:checkhealth` are what reach it — so
-- the registry is built in one pass here rather than per entry on first read.
local _seen = {} ---@type table<string, boolean>
for _, path in ipairs(vim.api.nvim_get_runtime_file("ezdap-adapters/*.lua", true)) do
    local name = vim.fn.fnamemodify(path, ":t:r")
    -- Runtimepath order, so the first match for a name shadows any later one: a
    -- definition in your config overrides the plugin's.
    if not _seen[name] then
        _seen[name] = true
        local def, err = _load(path)
        if def then
            M[name] = def
        else
            -- The name is spoken for either way: a broken override shadows what it
            -- meant to replace, rather than silently running a different definition
            -- than the one being edited.
            M[name] = nil
            _errors[name] = err
            vim.notify(("[ezdap] failed to load adapter '%s' (%s): %s"):format(name, path, err),
                vim.log.levels.ERROR)
        end
    end
end

return M
