---@brief Standalone run panel for easydap.
---
---A single pinned bottom split that hosts the buffers a run registers (report,
---REPL, output, terminal, DAP messages) and pages between them through a
---clickable winbar. This is a trimmed standalone counterpart to easytasks'
---status panel: easydap has no dependency on easytasks, so it ships its own.
---
---Debug tasks can run in parallel, so tabs are grouped by run: each run's
---buffers sit under a header showing the run's name, and the group disappears
---when its buffers are gone. Group-less buffers (the shared report) render
---first, before any run group.
---
---The panel never steals focus. Buffers are owned by their producers; the panel
---only displays them. A newly added buffer auto-surfaces only when it outranks
---the current page, so a busy view (e.g. a running program's terminal) is never
---yanked away — including by a parallel run starting in the background. Per-buffer
---autoscroll keeps append-only logs pinned to the bottom while they are active.

local M = {}

-- Sentinel group id for group-less (shared) entries such as the report page.
local _GLOBAL = "\0global"

---@class easydap.ui.PanelEntry
---@field bufnr      integer
---@field label      string
---@field priority   integer
---@field autoscroll boolean
---@field group      string   run id, or _GLOBAL for shared entries
---@field seq        integer  insertion order, for stable tie-breaking

---@class easydap.ui.PanelGroup
---@field id    string
---@field label string

---@class easydap.ui.PanelAdd
---@field label?       string
---@field priority?    integer  higher = surfaced preferentially (default 0)
---@field autoscroll?  boolean  keep pinned to the last line while active
---@field group?       string   run id; buffers sharing a group are tabbed together
---@field group_label? string   display name for the group header (first add wins)

---@class easydap.ui.Panel
---@field private _entries  easydap.ui.PanelEntry[]   insertion order
---@field private _groups   easydap.ui.PanelGroup[]   run groups, in creation order
---@field private _win      integer?                  the panel window, when open
---@field private _active   integer?                  bufnr currently displayed
---@field private _height   integer
---@field private _seq      integer
---@field private _attached table<integer, boolean>   buffers with an autoscroll listener
local Panel = {}
Panel.__index = Panel

local _DEFAULT_HEIGHT = 12

-- Winbar clicks call a global by name; route them to the panel that rendered the
-- bar. Only one run panel is shown at a time, so a single target suffices.
local _click_target ---@type easydap.ui.Panel?

---@param minwid integer  1-based display index, encoded as the winbar item's minwid
function _G.EasydapPanelClick(minwid)
    if _click_target then _click_target:show_index(minwid) end
end

---@param opts? { height?: integer }
---@return easydap.ui.Panel
function M.new(opts)
    opts = opts or {}
    return setmetatable({
        _entries  = {},
        _groups   = {},
        _win      = nil,
        _active   = nil,
        _height   = opts.height or _DEFAULT_HEIGHT,
        _seq      = 0,
        _attached = {},
    }, Panel)
end

-- ── Window ────────────────────────────────────────────────────────────────

---@return boolean
function Panel:is_open()
    return self._win ~= nil and vim.api.nvim_win_is_valid(self._win)
end

---Open the panel as a bottom split without stealing focus. No-op when already
---open. The first display entry (or an empty scratch) is shown.
function Panel:open()
    if self:is_open() then return end
    local cur = vim.api.nvim_get_current_win()
    vim.cmd("botright " .. self._height .. "split")
    self._win = vim.api.nvim_get_current_win()

    vim.wo[self._win].number         = false
    vim.wo[self._win].relativenumber = false
    vim.wo[self._win].winfixheight   = true
    vim.wo[self._win].wrap           = false

    local display = self:_display()
    local first   = self._active or (display[1] and display[1].bufnr)
    self:_set_buf(first or vim.api.nvim_create_buf(false, true))
    _click_target = self
    if vim.api.nvim_win_is_valid(cur) then vim.api.nvim_set_current_win(cur) end
end

---Close the panel window. Hosted buffers persist; reopening restores them.
function Panel:close()
    if self:is_open() then vim.api.nvim_win_close(self._win, false) end
    self._win = nil
    if _click_target == self then _click_target = nil end
end

---Toggle the panel window. Hosted buffers persist across hide/show.
function Panel:toggle()
    if self:is_open() then self:close() else self:open() end
end

-- ── Buffer display ────────────────────────────────────────────────────────

---Display `bufnr` in the panel window and refresh the winbar. Pins terminal and
---autoscroll buffers to their last line. The window is `winfixbuf` so stray edits
---or jumps cannot hijack it; the lock is lifted only for our own tab switch.
---@param bufnr integer
function Panel:_set_buf(bufnr)
    if not self:is_open() or not vim.api.nvim_buf_is_valid(bufnr) then return end
    vim.wo[self._win].winfixbuf = false
    vim.api.nvim_win_set_buf(self._win, bufnr)
    vim.wo[self._win].winfixbuf = true
    self._active = bufnr
    self:_attach(bufnr)
    if vim.bo[bufnr].buftype == "terminal" then
        pcall(vim.api.nvim_win_set_cursor, self._win, { vim.api.nvim_buf_line_count(bufnr), 0 })
    end
    self:_render_winbar()
end

---@param bufnr integer
---@return easydap.ui.PanelEntry?
function Panel:_entry(bufnr)
    for _, e in ipairs(self._entries) do
        if e.bufnr == bufnr then return e end
    end
end

---Attach a one-shot autoscroll listener that keeps `bufnr` at its last line
---while it is the active page (only for entries that asked for autoscroll).
---@param bufnr integer
function Panel:_attach(bufnr)
    if self._attached[bufnr] then return end
    local entry = self:_entry(bufnr)
    if not entry or not entry.autoscroll then return end
    self._attached[bufnr] = true
    vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function()
            if not self:is_open() then return true end
            if vim.api.nvim_win_get_buf(self._win) ~= bufnr then return end
            vim.schedule(function()
                if not self:is_open() then return end
                if vim.api.nvim_win_get_buf(self._win) ~= bufnr then return end
                pcall(vim.api.nvim_win_set_cursor, self._win, { vim.api.nvim_buf_line_count(bufnr), 0 })
            end)
        end,
        on_detach = function() self._attached[bufnr] = nil end,
    })
end

-- ── Groups & ordering ──────────────────────────────────────────────────────

---Register a run group (or refresh its label). No-op for the shared group.
---@param id     string
---@param label? string
function Panel:_ensure_group(id, label)
    if id == _GLOBAL then return end
    for _, g in ipairs(self._groups) do
        if g.id == id then
            if label then g.label = label end
            return
        end
    end
    self._groups[#self._groups + 1] = { id = id, label = label or id }
end

---Drop a group from the header list once it has no entries left.
---@param id string
function Panel:_prune_group(id)
    if id == _GLOBAL then return end
    for _, e in ipairs(self._entries) do
        if e.group == id then return end
    end
    for i, g in ipairs(self._groups) do
        if g.id == id then
            table.remove(self._groups, i)
            return
        end
    end
end

---@param id string
---@return string?
function Panel:_group_label(id)
    for _, g in ipairs(self._groups) do
        if g.id == id then return g.label end
    end
end

---Entries in render order: the shared group first, then each run group in
---creation order; within a group, highest priority first, ties in insertion order.
---@return easydap.ui.PanelEntry[]
function Panel:_display()
    local out = {}
    local function push(gid)
        local es = {}
        for _, e in ipairs(self._entries) do
            if e.group == gid then es[#es + 1] = e end
        end
        table.sort(es, function(a, b)
            if a.priority ~= b.priority then return a.priority > b.priority end
            return a.seq < b.seq
        end)
        for _, e in ipairs(es) do out[#out + 1] = e end
    end
    push(_GLOBAL)
    for _, g in ipairs(self._groups) do push(g.id) end
    return out
end

---Render the tab bar: shared tabs first, then one clickable label per entry
---grouped under its run's header, with the active page highlighted.
function Panel:_render_winbar()
    if not self:is_open() then return end
    local parts     = {}
    local cur_group = nil
    for i, e in ipairs(self:_display()) do
        if e.group ~= cur_group then
            cur_group = e.group
            if e.group ~= _GLOBAL then
                parts[#parts + 1] = ("%%#Title# %s %%*"):format(self:_group_label(e.group) or "")
            end
        end
        local hl = e.bufnr == self._active and "%#TabLineSel#" or "%#TabLine#"
        parts[#parts + 1] = ("%%%d@v:lua.EasydapPanelClick@%s %s %%X"):format(i, hl, e.label)
    end
    vim.wo[self._win].winbar = table.concat(parts) .. "%#TabLineFill#"
end

-- ── Public API ─────────────────────────────────────────────────────────────

---Register a buffer with the panel and surface it when warranted. Opens the
---panel on the first buffer. A buffer added with a strictly higher priority than
---the current page is switched to; otherwise it only joins the winbar — so a
---parallel run starting in the background never steals the active view.
---@param bufnr integer
---@param opts? easydap.ui.PanelAdd
function Panel:add(bufnr, opts)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    opts = opts or {}
    local group = opts.group or _GLOBAL
    self:_ensure_group(group, opts.group_label)

    local existing = self:_entry(bufnr)
    if existing then
        existing.label    = opts.label or existing.label
        existing.priority = opts.priority or existing.priority
    else
        self._seq = self._seq + 1
        self._entries[#self._entries + 1] = {
            bufnr      = bufnr,
            label      = opts.label or vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t"),
            priority   = opts.priority or 0,
            autoscroll = opts.autoscroll or false,
            group      = group,
            seq        = self._seq,
        }
        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
            buffer = bufnr, once = true,
            callback = function() self:remove(bufnr) end,
        })
    end

    local was_open  = self:is_open()
    self:open()
    -- Surface the new buffer when nothing meaningful is shown yet (fresh panel /
    -- empty scratch) or when it outranks the current page; otherwise just list it.
    local cur_entry = self._active and self:_entry(self._active)
    if not was_open or self._active == bufnr or not cur_entry then
        self:_set_buf(bufnr)
    elseif (opts.priority or 0) > cur_entry.priority then
        self:_set_buf(bufnr)
    else
        self:_render_winbar()
    end
end

---Show the i-th entry in display order. Used by the winbar click handler.
---@param i integer
function Panel:show_index(i)
    local e = self:_display()[i]
    if e then self:_set_buf(e.bufnr) end
end

---Show the panel away from a removed buffer, falling back to the next entry or
---an empty scratch when nothing is left.
function Panel:_fallback()
    if not self:is_open() then return end
    local nxt = self:_display()[1]
    self:_set_buf(nxt and nxt.bufnr or vim.api.nvim_create_buf(false, true))
end

---Drop a buffer from the panel. If it was showing, fall back to another entry.
---@param bufnr integer
function Panel:remove(bufnr)
    local removed ---@type easydap.ui.PanelEntry?
    for i, e in ipairs(self._entries) do
        if e.bufnr == bufnr then
            removed = e
            table.remove(self._entries, i)
            break
        end
    end
    self._attached[bufnr] = nil
    if removed then self:_prune_group(removed.group) end
    if self._active == bufnr then
        self._active = nil
        self:_fallback()
    elseif self:is_open() then
        self:_render_winbar()
    end
end

---Drop every buffer belonging to a run group (the buffers themselves are left
---alone). Used when a finished run is cleared from the panel.
---@param group string
function Panel:remove_group(group)
    local kept, dropped_active = {}, false
    for _, e in ipairs(self._entries) do
        if e.group == group then
            self._attached[e.bufnr] = nil
            if self._active == e.bufnr then dropped_active = true end
        else
            kept[#kept + 1] = e
        end
    end
    self._entries = kept
    self:_prune_group(group)
    if dropped_active then
        self._active = nil
        self:_fallback()
    elseif self:is_open() then
        self:_render_winbar()
    end
end

return M
