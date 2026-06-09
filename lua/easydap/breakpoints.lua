---@brief Global breakpoint registry.
---All breakpoints are stored here independent of any session.
---Sessions call sync helpers when they need to push state to an adapter.

local Signal = require("easydap.util.Signal")

---@class easydap.SourceBreakpoint
---@field _id         integer   internal stable id (for signs)
---@field source      string    absolute file path
---@field line        integer
---@field condition   string?
---@field hit_condition string?
---@field log_message string?
---@field disabled    boolean
---@field verified    boolean
---@field id          integer?         adapter-assigned id
---@field message     string?
---@field hits        integer

---@class easydap.FunctionBreakpoint
---@field _id      integer
---@field name     string
---@field disabled boolean
---@field verified boolean
---@field id       integer?

---@class easydap.ExceptionBreakpoint
---@field filter   string
---@field label    string
---@field default  boolean
---@field disabled boolean

---@class easydap.ExceptionFilterDef
---@field filter  string
---@field label   string
---@field default boolean?

---@alias easydap.ExceptionBreakMode "never"|"always"|"unhandled"|"userUnhandled"

---@class easydap.ExceptionNameBreakpoint
---@field _id        integer
---@field name       string
---@field break_mode easydap.ExceptionBreakMode
---@field disabled   boolean

---@class easydap.BreakpointData
---@field source             table[]                    stripped easydap.SourceBreakpoint records
---@field functions          easydap.FunctionBreakpoint[]
---@field exception_names    easydap.ExceptionNameBreakpoint[]?
---@field exception_filters  table<string,boolean>?     filter → disabled

---@alias easydap.BreakpointChangeKind "source" | "function" | "exception" | "exception_name" | "restore"

local M = {}

---Fires whenever any breakpoint is added, removed, or its state changes.
M.on_change = Signal.new() ---@type easydap.util.Signal<fun(kind: easydap.BreakpointChangeKind)>

---@type easydap.SourceBreakpoint[]
local _source_bps = {}
---@type easydap.FunctionBreakpoint[]
local _function_bps = {}
---@type easydap.ExceptionBreakpoint[]
local _exception_bps = {}
---@type easydap.ExceptionNameBreakpoint[]
local _exception_name_bps = {}
---@type table<string,boolean>  filter → disabled, populated by restore() for use by set_exception_filters()
local _saved_exception_states = {}

local _next_id = 1
local function _new_id()
    local id = _next_id
    _next_id = _next_id + 1
    return id
end

-- ── Source breakpoints ─────────────────────────────────────────────────────

---@param source string
---@param line   integer
---@param opts   { condition?: string, hit_condition?: string, log_message?: string, disabled?: boolean }?
---@return easydap.SourceBreakpoint
function M.add(source, line, opts)
    opts = opts or {}
    for _, bp in ipairs(_source_bps) do
        if bp.source == source and bp.line == line then
            bp.condition     = opts.condition
            bp.hit_condition = opts.hit_condition
            bp.log_message   = opts.log_message
            bp.disabled      = opts.disabled or false
            M.on_change:emit("source")
            return bp
        end
    end
    ---@type easydap.SourceBreakpoint
    local bp = {
        _id           = _new_id(),
        source        = source,
        line          = line,
        condition     = opts.condition,
        hit_condition = opts.hit_condition,
        log_message   = opts.log_message,
        disabled      = opts.disabled or false,
        verified      = false,
        id            = nil,
        message       = nil,
        hits          = 0,
    }
    _source_bps[#_source_bps + 1] = bp
    M.on_change:emit("source")
    return bp
end

---Update individual fields on an existing breakpoint without clearing the others.
---Creates the breakpoint if it doesn't exist yet.
---Pass `""` for a string field to clear it.
---@param source string
---@param line   integer
---@param opts   { condition?: string, hit_condition?: string, log_message?: string, disabled?: boolean }
---@return easydap.SourceBreakpoint
function M.patch(source, line, opts)
    local bp
    for _, b in ipairs(_source_bps) do
        if b.source == source and b.line == line then bp = b; break end
    end
    if not bp then
        bp = {
            _id = _new_id(), source = source, line = line,
            disabled = false, verified = false, id = nil, message = nil, hits = 0,
        }
        _source_bps[#_source_bps + 1] = bp
    end
    if opts.condition     ~= nil then bp.condition     = opts.condition     ~= "" and opts.condition     or nil end
    if opts.hit_condition ~= nil then bp.hit_condition = opts.hit_condition ~= "" and opts.hit_condition or nil end
    if opts.log_message   ~= nil then bp.log_message   = opts.log_message   ~= "" and opts.log_message   or nil end
    if opts.disabled      ~= nil then bp.disabled      = opts.disabled                                          end
    M.on_change:emit("source")
    return bp
end

---@param source string
---@param line   integer
---@return boolean
function M.remove(source, line)
    for i, bp in ipairs(_source_bps) do
        if bp.source == source and bp.line == line then
            table.remove(_source_bps, i)
            M.on_change:emit("source")
            return true
        end
    end
    return false
end

---@param source string
---@param line   integer
---@param opts   { condition?: string, hit_condition?: string, log_message?: string, disabled?: boolean }?
---@return easydap.SourceBreakpoint?
function M.toggle(source, line, opts)
    for i, bp in ipairs(_source_bps) do
        if bp.source == source and bp.line == line then
            table.remove(_source_bps, i)
            M.on_change:emit("source")
            return nil
        end
    end
    return M.add(source, line, opts)
end

---@param source string
---@return easydap.SourceBreakpoint[]
function M.for_source(source)
    local r = {}
    for _, bp in ipairs(_source_bps) do
        if bp.source == source then r[#r + 1] = bp end
    end
    return r
end

---@return string[]
function M.all_sources()
    local seen, r = {}, {}
    for _, bp in ipairs(_source_bps) do
        if not seen[bp.source] then
            seen[bp.source] = true
            r[#r + 1] = bp.source
        end
    end
    return r
end

---@return easydap.SourceBreakpoint[]
function M.all()
    return vim.list_extend({}, _source_bps)
end

-- ── Function breakpoints ───────────────────────────────────────────────────

---@param name string
---@param opts { disabled?: boolean }?
---@return easydap.FunctionBreakpoint
function M.add_function(name, opts)
    opts = opts or {}
    for _, bp in ipairs(_function_bps) do
        if bp.name == name then
            bp.disabled = opts.disabled or false
            M.on_change:emit("function")
            return bp
        end
    end
    local bp = { _id = _new_id(), name = name, disabled = opts.disabled or false, verified = false, id = nil }
    _function_bps[#_function_bps + 1] = bp
    M.on_change:emit("function")
    return bp
end

---@param name string
---@return boolean
function M.remove_function(name)
    for i, bp in ipairs(_function_bps) do
        if bp.name == name then
            table.remove(_function_bps, i)
            M.on_change:emit("function")
            return true
        end
    end
    return false
end

---@return easydap.FunctionBreakpoint[]
function M.function_breakpoints()
    return vim.list_extend({}, _function_bps)
end

-- ── Exception breakpoints ──────────────────────────────────────────────────

---@param filter_defs easydap.ExceptionFilterDef[]
function M.set_exception_filters(filter_defs)
    local old = {}
    for _, bp in ipairs(_exception_bps) do old[bp.filter] = bp end
    _exception_bps = {}
    for _, def in ipairs(filter_defs) do
        local prev = old[def.filter]
        local disabled
        if prev then
            disabled = prev.disabled
        elseif _saved_exception_states[def.filter] ~= nil then
            disabled = _saved_exception_states[def.filter]
        else
            disabled = not (def.default == true)
        end
        _exception_bps[#_exception_bps + 1] = {
            filter   = def.filter,
            label    = def.label,
            default  = def.default,
            disabled = disabled,
        }
    end
    M.on_change:emit("exception")
end

---@return easydap.ExceptionBreakpoint[]
function M.exception_breakpoints()
    return vim.list_extend({}, _exception_bps)
end

---@param filter  string
---@param enabled boolean
---@return boolean
function M.set_exception_enabled(filter, enabled)
    for _, bp in ipairs(_exception_bps) do
        if bp.filter == filter then
            bp.disabled = not enabled
            M.on_change:emit("exception")
            return true
        end
    end
    return false
end

-- ── Exception name breakpoints ─────────────────────────────────────────────

---@param name       string
---@param break_mode easydap.ExceptionBreakMode?  defaults to "always"
---@return easydap.ExceptionNameBreakpoint
function M.add_exception_name(name, break_mode)
    break_mode = break_mode or "always"
    for _, bp in ipairs(_exception_name_bps) do
        if bp.name == name then
            bp.break_mode = break_mode
            bp.disabled   = false
            M.on_change:emit("exception_name")
            return bp
        end
    end
    local bp = { _id = _new_id(), name = name, break_mode = break_mode, disabled = false }
    _exception_name_bps[#_exception_name_bps + 1] = bp
    M.on_change:emit("exception_name")
    return bp
end

---@param name string
---@return boolean
function M.remove_exception_name(name)
    for i, bp in ipairs(_exception_name_bps) do
        if bp.name == name then
            table.remove(_exception_name_bps, i)
            M.on_change:emit("exception_name")
            return true
        end
    end
    return false
end

---Toggle: removes if present, adds (with break_mode) if absent.
---@param name       string
---@param break_mode easydap.ExceptionBreakMode?
---@return easydap.ExceptionNameBreakpoint?
function M.toggle_exception_name(name, break_mode)
    for i, bp in ipairs(_exception_name_bps) do
        if bp.name == name then
            table.remove(_exception_name_bps, i)
            M.on_change:emit("exception_name")
            return nil
        end
    end
    return M.add_exception_name(name, break_mode)
end

---@return easydap.ExceptionNameBreakpoint[]
function M.exception_name_breakpoints()
    return vim.list_extend({}, _exception_name_bps)
end

---@param name    string
---@param enabled boolean
---@return boolean
function M.set_exception_name_enabled(name, enabled)
    for _, bp in ipairs(_exception_name_bps) do
        if bp.name == name then
            bp.disabled = not enabled
            M.on_change:emit("exception_name")
            return true
        end
    end
    return false
end

-- ── Lookup ─────────────────────────────────────────────────────────────────

---@param id integer  adapter-assigned id
---@return easydap.SourceBreakpoint|easydap.FunctionBreakpoint|nil
function M.find_by_id(id)
    for _, bp in ipairs(_source_bps)   do if bp.id == id then return bp end end
    for _, bp in ipairs(_function_bps) do if bp.id == id then return bp end end
end

---Enable all source breakpoints.
function M.enable_all()
    local changed = false
    for _, bp in ipairs(_source_bps) do
        if bp.disabled then bp.disabled = false; changed = true end
    end
    if changed then M.on_change:emit("source") end
end

---Disable all source breakpoints.
function M.disable_all()
    local changed = false
    for _, bp in ipairs(_source_bps) do
        if not bp.disabled then bp.disabled = true; changed = true end
    end
    if changed then M.on_change:emit("source") end
end

---Notify listeners that breakpoint state was mutated externally (e.g. verified by adapter).
---@param kind easydap.BreakpointChangeKind
function M.notify_change(kind)
    M.on_change:emit(kind)
end

-- ── Persistence ────────────────────────────────────────────────────────────

---@return easydap.BreakpointData
function M.get_data()
    local strip = { verified = true, id = true, message = true, hits = true }
    local function clean(bp)
        local t = {}
        for k, v in pairs(bp) do if not strip[k] then t[k] = v end end
        return t
    end
    local exc_states = {}
    for _, bp in ipairs(_exception_bps) do exc_states[bp.filter] = bp.disabled end
    return {
        source            = vim.tbl_map(clean, _source_bps),
        functions         = _function_bps,
        exception_names   = _exception_name_bps,
        exception_filters = exc_states,
    }
end

---@param data easydap.BreakpointData?
function M.restore(data)
    _source_bps               = (type(data) == "table" and data.source)            or {}
    _function_bps             = (type(data) == "table" and data.functions)         or {}
    _exception_name_bps       = (type(data) == "table" and data.exception_names)   or {}
    _saved_exception_states  = (type(data) == "table" and type(data.exception_filters) == "table"
                                    and data.exception_filters) or {}
    local max_id = 0
    for _, bp in ipairs(_source_bps)         do if bp._id and bp._id > max_id then max_id = bp._id end end
    for _, bp in ipairs(_function_bps)       do if bp._id and bp._id > max_id then max_id = bp._id end end
    for _, bp in ipairs(_exception_name_bps) do if bp._id and bp._id > max_id then max_id = bp._id end end
    if max_id >= _next_id then _next_id = max_id + 1 end
    for _, bp in ipairs(_source_bps)         do if not bp._id then bp._id = _new_id() end end
    for _, bp in ipairs(_function_bps)       do if not bp._id then bp._id = _new_id() end end
    for _, bp in ipairs(_exception_name_bps) do if not bp._id then bp._id = _new_id() end end
    M.on_change:emit("restore")
end

return M
