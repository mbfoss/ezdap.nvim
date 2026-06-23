---@brief Project-scoped persistence for easydap.nvim.
---Project root is the cwd when it directly contains a root marker from config.
---All namespaces are merged into a single data file at the project root.
---Writes are deferred; flush() persists the cache to disk.

local M                      = {}

local Signal                 = require("easydap.util.Signal")
local fsutil                 = require("easydap.util.fsutil")
local config                 = require("easydap.config")

local _cached_root           = nil ---@type string|nil
local _cache                 = {} ---@type table<string, any>
local _initialized           = false
local _default_data_filename = ".easydap.json"

--- Emitted with the root path just before the cwd leaves a project (cache still intact).
--- Subscribe here to push in-memory state into the cache before it is flushed to disk.
M.on_project_leave_pre       = Signal.new() ---@type easydap.util.Signal<fun(root: string)>

--- Emitted with the root path after the cwd enters a project.
M.on_project_enter           = Signal.new() ---@type easydap.util.Signal<fun(root: string)>

--- Emitted after the cwd leaves a project.
M.on_project_leave           = Signal.new() ---@type easydap.util.Signal<fun()>

---Returns true when the table holds no data — empty, or only (nested) empty tables.
---@param  tbl table
---@return boolean
local function _is_empty(tbl)
    for _, v in pairs(tbl) do
        if type(v) ~= "table" then return false end
        if not _is_empty(v) then return false end
    end
    return true
end

---@return string|nil root
local function _find_root()
    local markers = config.root_markers
    if not markers or #markers == 0 then return nil end
    local cwd = vim.fn.getcwd() --[[@as string]]
    for _, marker in ipairs(markers) do
        ---@diagnostic disable-next-line: undefined-field
        if vim.uv.fs_stat(vim.fs.joinpath(cwd, marker)) then
            return cwd
        end
    end
    return nil
end

---@param root string
local function _warm(root)
    _cache            = {}
    _cached_root      = root
    local filename    = config.data_filename or _default_data_filename
    local path        = vim.fs.joinpath(root, filename)
    local ok, content = fsutil.read_content(path)
    if not ok then return end
    local dec_ok, data = pcall(vim.json.decode, content, { luanil = { object = true, array = true } })
    if dec_ok and type(data) == "table" then
        _cache = data
    end
end

local function _flush_cache()
    if not _cached_root then return end
    if _is_empty(_cache) then return end
    local filename        = config.data_filename or _default_data_filename
    local path            = vim.fs.joinpath(_cached_root, filename)
    local ok, json_or_err = pcall(vim.json.encode, _cache)
    if not ok then return end
    fsutil.write_content(path, json_or_err)
end

local function _init()
    if _initialized then return end
    _initialized = true

    vim.api.nvim_create_autocmd("DirChangedPre", {
        callback = function()
            if not _cached_root then return end
            M.on_project_leave_pre:emit(_cached_root)
            _flush_cache()
        end,
        desc = "easydap: flush project store before cwd change",
    })
    vim.api.nvim_create_autocmd("DirChanged", {
        callback = function()
            local was_in_project = _cached_root ~= nil
            _cached_root         = nil
            _cache               = {}
            local root           = _find_root()
            if root then
                _warm(root)
                M.on_project_enter:emit(root)
            elseif was_in_project then
                M.on_project_leave:emit()
            end
        end,
        desc = "easydap: warm project store after cwd change",
    })

    local root = _find_root()
    if root then _warm(root) end
end

---@return boolean
function M.in_project()
    _init()
    return _cached_root ~= nil
end

---The current project root, or nil when the cwd is not inside a project.
---@return string|nil
function M.root()
    _init()
    return _cached_root
end

---Convert an absolute path to one relative to the project root, for portable
---storage. Paths outside the project (or when there is no project) are kept
---absolute so they still resolve when restored.
---@param  path string
---@return string
function M.relativize(path)
    local root = M.root()
    if not root then return path end
    local prefix = root .. "/"
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return path
end

---Resolve a stored path back to absolute against the project root.
---Already-absolute paths pass through unchanged.
---@param  path string
---@return string
function M.absolutize(path)
    local root = M.root()
    if not root or path:sub(1, 1) == "/" then return path end
    return vim.fs.joinpath(root, path)
end

---Load a namespace from the project cache. Returns nil when not in a project.
---@param  namespace string
---@return table|nil
function M.get(namespace)
    _init()
    return _cache[namespace]
end

---Update a namespace in the in-memory cache. No-op when not in a project.
---Call flush() to persist.
---@param namespace string
---@param data      table
function M.set(namespace, data)
    _init()
    if not _cached_root then return end
    _cache[namespace] = data
end

---Persist all cached namespaces to the project data file.
---No-op when not in a project.
---@return boolean ok
---@return string? err
function M.flush()
    if not _cached_root then return true end
    if _is_empty(_cache) then return true end
    local filename = config.data_filename or _default_data_filename
    local path = vim.fs.joinpath(_cached_root, filename)
    local ok, json_or_err = pcall(vim.json.encode, _cache)
    if not ok then
        return false, "json encode failed: " .. tostring(json_or_err)
    end
    return fsutil.write_content(path, json_or_err)
end

return M
