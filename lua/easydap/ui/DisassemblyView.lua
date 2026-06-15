---@brief Disassembly pane, source-synced.
---Opens a vertical split showing the instructions around the current program
---counter and keeps a two-way cursor sync with the source window it was
---launched from (Compiler-Explorer / gdb `layout split` style): moving the
---cursor in the source highlights the matching instruction block here, and
---moving the cursor here jumps the source window to the originating line.
---
---Read-only: instruction-granularity stepping and instruction breakpoints are
---deliberately not handled here.

local manager   = require("easydap.manager")
local config    = require("easydap.config")
local ui_util   = require("easydap.util.ui_util")
local throttle  = require("easydap.util.throttle")

local _au_group_gen

-- ── Tunables ───────────────────────────────────────────────────────────────

local _COUNT    = 80  -- fallback instruction count when the window doesn't exist yet
local _ADDR_W   = 18  -- width of the address column
local _PAGE_PAD = 6   -- trigger paging when the cursor is within this many rows of an edge

-- ── Highlight groups ───────────────────────────────────────────────────────

local _PC_HL    = "EasydapDisasmPC"
local _BLOCK_HL = "EasydapDisasmBlock"
local _BP_HL    = "EasydapDisasmBp"

vim.api.nvim_set_hl(0, _PC_HL, { link = "DiffChange", default = true })
vim.api.nvim_set_hl(0, _BLOCK_HL, { link = "CursorLine", default = true })
vim.api.nvim_set_hl(0, _BP_HL, { link = "Debug", default = true })


-- ── Helpers ────────────────────────────────────────────────────────────────

---Compare two adapter addresses, tolerating differing hex widths/zero-padding.
---@param a string?
---@param b string?
---@return boolean
local function _addr_eq(a, b)
    if not a or not b then return false end
    if a == b then return true end
    local na, nb = tonumber(a), tonumber(b)
    return na ~= nil and na == nb
end

---@param path string?
---@return string?
local function _norm(path)
    if not path or path == "" then return nil end
    return vim.fn.fnamemodify(path, ":p")
end

---First line in a row table whose instruction matches `addr`.
---@param rows table<integer, easydap.DisassemblyView.Row>
---@param addr string?
---@return integer?
local function _row_of(rows, addr)
    if not addr then return end
    for lnum, ins in pairs(rows) do
        if _addr_eq(ins.address, addr) then return lnum end
    end
end

---Last non-nil `symbol` in a list — the running symbol a follow-on render would
---inherit, used to decide whether a neighbouring header is still needed.
---@param list easydap.DisassemblyView.Row[]
---@return string?
local function _tail_sym(list)
    for i = #list, 1, -1 do
        if list[i].symbol then return list[i].symbol end
    end
end

---Smallest index `>= i0` at which `_build` would emit a symbol header (the
---instruction starts a new symbol). Used to snap a front trim to a group
---boundary so the retained top keeps owning its header.
---@param instrs easydap.DisassemblyView.Row[]
---@param i0 integer
---@return integer?
local function _group_start_at_or_after(instrs, i0)
    local cur ---@type string?
    for j = 1, i0 - 1 do
        if instrs[j].symbol then cur = instrs[j].symbol end
    end
    for i = i0, #instrs do
        local s = instrs[i].symbol
        if s and s ~= cur then return i end
        if s then cur = s end
    end
end

-- ── Class ──────────────────────────────────────────────────────────────────

---@class easydap.DisassemblyView.SrcRange
---@field first integer  first asm row (1-based) mapped to a source line
---@field last  integer  last asm row mapped to that source line

---Instruction augmented with the resolved/normalised source location.
---@class easydap.DisassemblyView.Row : easydap.dap.proto.DisassembledInstruction
---@field _path?  string  normalised source path
---@field _sline? integer source line

---@class easydap.DisassemblyView
---@field private _bufnr?    integer
---@field private _win?      integer  the asm window
---@field private _src_win?  integer  source window kept in sync
---@field private _sess?     easydap.dap.Session
---@field private _rows      table<integer, easydap.DisassemblyView.Row>  asm line -> instruction
---@field private _by_src    table<string, table<integer, easydap.DisassemblyView.SrcRange>>
---@field private _ns_pc     integer  PC line highlight + sign
---@field private _ns_block  integer  transient source-block highlight
---@field private _ns_bp     integer  instruction-breakpoint signs
---@field private _instrs?   easydap.DisassemblyView.Row[]  current ordered instruction list (paging)
---@field private _pc_ref?   string   instructionReference marked as the PC for the current load
---@field private _paging?   boolean  in-flight paging guard
---@field private _aug?      integer  sync autocmd group; created on open, deleted on close
---@field private _gen       integer  generation guard for stale session callbacks
---@field private _syncing   boolean  re-entrancy guard around programmatic moves
---@field private _closing?   boolean  re-entrancy guard around close()
---@field private _src_sync  fun()    throttled source -> asm
---@field private _asm_sync  fun()    throttled asm -> source
local DisassemblyView = {}
DisassemblyView.__index = DisassemblyView

---@return easydap.DisassemblyView
function DisassemblyView.new()
    local self = setmetatable({
        _rows     = {},
        _by_src   = {},
        _ns_pc    = vim.api.nvim_create_namespace("easydap_disasm_pc"),
        _ns_block = vim.api.nvim_create_namespace("easydap_disasm_block"),
        _ns_bp    = vim.api.nvim_create_namespace("easydap_disasm_bp"),
        _gen      = 0,
        _syncing  = false,
    }, DisassemblyView)
    self:_init()
    return self
end

---@private
function DisassemblyView:_init()
    self._src_sync = throttle.throttle_wrap(40, function() self:_sync_from_source() end)
    self._asm_sync = throttle.throttle_wrap(40, function() self:_sync_to_source() end)

    manager.on_active_changed:subscribe(function(_, sess) self:_bind_session(sess) end)
    manager.on_selection_changed:subscribe(function()
        if self:_is_open() then self:_load(false) end
    end)
    self:_bind_session(manager.session())
end

---Create the sync autocmd group (and its source-side listener) on first open.
---@private
function DisassemblyView:_ensure_autocmds()
    if self._aug then return end
    _au_group_gen = _au_group_gen and (_au_group_gen + 1) or 1
    self._aug = vim.api.nvim_create_augroup(("easydap_disasm_sync_%d"):format(_au_group_gen), { clear = true })

    -- source -> asm: a global CursorMoved that only fires while focused in the
    -- bound source window and the pane is open.
    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        group = self._aug,
        callback = function()
            if self._syncing or not self:_is_open() then return end
            if vim.api.nvim_get_current_win() ~= self._src_win then return end
            self._src_sync()
        end,
    })
end

---Delete the sync autocmd group; called whenever the pane closes so the global
---CursorMoved listener does not linger while the pane is hidden.
---@private
function DisassemblyView:_teardown_autocmds()
    if self._aug then
        vim.api.nvim_del_augroup_by_id(self._aug)
        self._aug = nil
    end
end

-- ── Session binding ────────────────────────────────────────────────────────

---@private
---@param sess easydap.dap.Session?
function DisassemblyView:_bind_session(sess)
    self._gen = self._gen + 1
    local gen = self._gen
    self._sess = sess
    if not sess then return end

    sess:on("stopped", function()
        if gen ~= self._gen then return end
        if self:_is_open() then self:_load(false) end
    end)
    sess:on("continued", function()
        if gen ~= self._gen then return end
        self:_clear_pc()
    end)
    sess:on("terminated", function()
        if gen ~= self._gen then return end
        self:close()
    end)
    sess:on("instruction_breakpoints_changed", function()
        if gen ~= self._gen then return end
        if self:_is_open() then self:_draw_bps() end
    end)
end

-- ── Window / buffer plumbing ───────────────────────────────────────────────

---@private
---@return integer
function DisassemblyView:_win_height()
    if self:_is_open() then
        return vim.api.nvim_win_get_height(self._win)
    end
    return _COUNT
end

---Instructions to fetch per load/page. Deliberately larger than the viewport so
---there is always rendered content just beyond the visible area to scroll into
---before the next page is fetched.
---@private
---@return integer
function DisassemblyView:_page_size()
    return self:_win_height() * 2
end

---@private
---@return boolean
function DisassemblyView:_is_open()
    return self._win ~= nil and vim.api.nvim_win_is_valid(self._win)
end

---@private
function DisassemblyView:_ensure_win()
    self:_ensure_autocmds()

    if not (self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr)) then
        -- buffer deleted -> close the window too
        self._bufnr = ui_util.create_scratch_buffer(false, { filetype = "asm" }, function()
            self._bufnr = nil
            self:close()
        end)
        pcall(vim.api.nvim_buf_set_name, self._bufnr, "easydap://disassembly")
        -- identity flag consumers use to recognise the disassembly pane (the
        -- buffer name may be cwd-prefixed, so matching on it is unreliable).
        vim.b[self._bufnr].easydap_disasm = true
        self:_setup_keymaps(self._bufnr)

        -- asm -> source sync + edge paging, bound to the asm buffer.
        vim.api.nvim_create_autocmd("CursorMoved", {
            group    = self._aug,
            buffer   = self._bufnr,
            callback = function()
                self:_maybe_page()
                if self._syncing then return end
                self._asm_sync()
            end,
        })
    end

    if not self:_is_open() then
        -- enter=false: keep focus on the source window; _load() focuses us
        -- explicitly on an interactive open.
        local win                  = ui_util.create_window(self._bufnr, false, {
            split = "left",
            win   = 0,
        }, function()
            -- window closed -> delete the buffer too
            self._win = nil
            self:close()
        end)
        vim.wo[win].number         = false
        vim.wo[win].relativenumber = false
        vim.wo[win].signcolumn     = "yes"
        vim.wo[win].winfixbuf      = true
        self._win                  = win
    end
end

---@private
---@param lines string[]
function DisassemblyView:_set_lines(lines)
    local buf = self._bufnr
    if not buf then return end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
end

-- ── Loading & rendering ────────────────────────────────────────────────────

---Fetch and render disassembly for the active frame.
---@private
---@param focus boolean  focus the pane afterwards (only on explicit open)
function DisassemblyView:_load(focus)
    local sess = manager.session()
    if not sess then
        if focus then vim.notify("[dap] no active session", vim.log.levels.WARN) end
        return
    end
    local frame = sess:current_stack_frame()
    local ref   = frame and frame.instructionPointerReference
    if not ref then
        if focus then vim.notify("[dap] no instruction pointer for current frame", vim.log.levels.WARN) end
        return
    end

    local count  = self:_page_size()
    local offset = -math.floor(count / 2)
    sess:disassemble(ref, count, offset, function(instrs, err)
        vim.schedule(function()
            if err or not instrs then
                vim.notify("[dap] disassemble failed: " .. (err or "no instructions"), vim.log.levels.WARN)
                return
            end
            self:_ensure_win()
            self:_render(instrs, ref, true)
            if focus and self:_is_open() then
                vim.api.nvim_set_current_win(self._win)
            end
        end)
    end)
end

---Render an instruction list into buffer lines and the accompanying lookup
---tables, without touching the buffer or any state. Pure: callers decide how to
---apply the result (full replace for loads, incremental splice for paging).
---@private
---@param instrs easydap.DisassemblyView.Row[]
---@param pc_ref string?
---@return string[] lines
---@return table<integer, easydap.DisassemblyView.Row> rows
---@return table<string, table<integer, easydap.DisassemblyView.SrcRange>> by_src
---@return integer? pc_row
function DisassemblyView:_build(instrs, pc_ref)
    local lines   = {} ---@type string[]
    local rows    = {} ---@type table<integer, easydap.DisassemblyView.Row>
    local by_src  = {} ---@type table<string, table<integer, easydap.DisassemblyView.SrcRange>>
    local pc_row  = nil ---@type integer?
    local cur_sym = nil ---@type string?

    for _, ins in ipairs(instrs) do
        if ins.symbol and ins.symbol ~= cur_sym then
            cur_sym           = ins.symbol
            lines[#lines + 1] = ins.symbol .. ":"
        end

        local addr = ins.address or ""
        lines[#lines + 1] = ("%-" .. _ADDR_W .. "s %s"):format(addr, ins.instruction or "")
        local lnum = #lines

        ---@cast ins easydap.DisassemblyView.Row
        rows[lnum] = ins
        if _addr_eq(addr, pc_ref) then pc_row = lnum end

        local path  = ins.location and _norm(ins.location.path)
        local sline = ins.line
        if path and sline then
            ins._path, ins._sline = path, sline
            by_src[path] = by_src[path] or {}
            local e = by_src[path][sline]
            if e then
                e.first = math.min(e.first, lnum)
                e.last  = math.max(e.last, lnum)
            else
                by_src[path][sline] = { first = lnum, last = lnum }
            end
        end
    end

    return lines, rows, by_src, pc_row
end

---Render an instruction list into the buffer, replacing its entire contents.
---Used for fresh loads; paging edits the buffer incrementally instead.
---@private
---@param instrs easydap.DisassemblyView.Row[]
---@param pc_ref string?
---@param recenter boolean?  center the cursor on the PC row (fresh loads only)
function DisassemblyView:_render(instrs, pc_ref, recenter)
    local lines, rows, by_src, pc_row = self:_build(instrs, pc_ref)

    self:_set_lines(lines)
    self._rows   = rows
    self._by_src = by_src
    self._instrs = instrs
    self._pc_ref = pc_ref

    self:_draw_pc(pc_row)
    self:_draw_bps()

    if recenter and pc_row and self:_is_open() then
        pcall(vim.api.nvim_win_set_cursor, self._win, { pc_row, 0 })
    end
end

-- ── PC marker ──────────────────────────────────────────────────────────────

---@private
---@param pc_row integer?
function DisassemblyView:_draw_pc(pc_row)
    self:_clear_pc()
    if not pc_row then return end
    vim.api.nvim_buf_set_extmark(self._bufnr, self._ns_pc, pc_row - 1, 0, {
        line_hl_group = _PC_HL,
        sign_text     = config.signs.debug_frame,
        sign_hl_group = _PC_HL,
        priority      = 40,
    })
end

---@private
function DisassemblyView:_clear_pc()
    if self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr) then
        vim.api.nvim_buf_clear_namespace(self._bufnr, self._ns_pc, 0, -1)
    end
end

---@private
function DisassemblyView:_clear_block()
    if self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr) then
        vim.api.nvim_buf_clear_namespace(self._bufnr, self._ns_block, 0, -1)
    end
end

-- ── Instruction breakpoints ────────────────────────────────────────────────

---Re-draw breakpoint signs from the active session's instruction-breakpoint set.
---@private
function DisassemblyView:_draw_bps()
    if not (self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr)) then return end
    vim.api.nvim_buf_clear_namespace(self._bufnr, self._ns_bp, 0, -1)

    local sess = self._sess
    if not sess then return end
    local bps = sess:instruction_breakpoints()
    if not bps or vim.tbl_isempty(bps) then return end

    for lnum, ins in pairs(self._rows) do
        local st = ins.address and bps[ins.address]
        if st then
            local sign = st.verified
                and config.signs.active_breakpoint
                or config.signs.inactive_breakpoint
            vim.api.nvim_buf_set_extmark(self._bufnr, self._ns_bp, lnum - 1, 0, {
                sign_text = sign, sign_hl_group = _BP_HL,
            })
        end
    end
end

---Toggle an instruction breakpoint on the instruction under the cursor.
---@private
function DisassemblyView:_toggle_bp_at_cursor()
    if not self:_is_open() then return end
    local ins = self._rows[vim.api.nvim_win_get_cursor(self._win)[1]]
    if not ins or not ins.address then return end
    local sess = self._sess
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN)
        return
    end
    sess:toggle_instruction_breakpoint(ins.address)
end

-- ── Paging ─────────────────────────────────────────────────────────────────

---Fetch more instructions when the cursor nears either edge of the buffer.
---Triggered from CursorMoved, so ordinary scrolling (with `scrolloff` dragging
---the cursor along) keeps fresh instructions flowing in without any explicit
---jump. The trigger margin honours `scrolloff` so paging happens before the
---cursor is pinned against the edge.
---@private
function DisassemblyView:_maybe_page()
    if self._paging or self._syncing or not self:_is_open() then return end
    if not self._instrs or #self._instrs == 0 then return end

    local row   = vim.api.nvim_win_get_cursor(self._win)[1]
    local total = vim.api.nvim_buf_line_count(self._bufnr)
    local so    = vim.wo[self._win].scrolloff
    if so < 0 then so = vim.go.scrolloff end
    local pad   = math.max(_PAGE_PAD, so + 2)

    if row <= pad then
        self:_page("up")
    elseif row >= total - pad then
        self:_page("down")
    end
end

---Slide the loaded instruction window in `dir`: fetch a page just beyond the
---current edge, then hand off to _apply_page to splice it in.
---@private
---@param dir "up"|"down"
function DisassemblyView:_page(dir)
    local sess   = self._sess
    local instrs = self._instrs
    if self._paging or not sess or not instrs or #instrs == 0 then return end
    if not self:_is_open() then return end

    local edge      = dir == "down" and instrs[#instrs] or instrs[1]
    local edge_addr = edge and edge.address
    if not edge_addr then return end

    -- Anchor on the instruction at (or, when sitting on a symbol header, just
    -- below) the cursor. The splice leaves this instruction's line untouched, so
    -- Neovim's own cursor/scroll handling holds the view exactly where it is.
    local cur_line    = vim.api.nvim_win_get_cursor(self._win)[1]
    local anchor      = self._rows[cur_line] or self._rows[cur_line + 1]
    local anchor_addr = anchor and anchor.address
    if not anchor_addr then return end

    self._paging = true
    local page   = self:_page_size()
    local offset = dir == "down" and 1 or -page

    local gen = self._gen
    sess:disassemble(edge_addr, page, offset, function(new, err)
        if gen ~= self._gen then return end
        vim.schedule(function()
            if gen ~= self._gen then return end
            self._paging = false
            if err or not new or #new == 0 or not self:_is_open() then return end
            self:_apply_page(dir, new, page, anchor_addr)
        end)
    end)
end

---Splice a freshly fetched page into the buffer with two localised edits: grow
---one end, trim the other, leaving the anchor instruction's line (and everything
---between it and each edit) byte-identical. Edit ranges are derived from line
---counts and `self._rows` — never from a stored copy of the buffer text. The
---cursor is never set explicitly; Neovim shifts it along with its instruction.
---@private
---@param dir "up"|"down"
---@param new easydap.DisassemblyView.Row[]
---@param page integer
---@param anchor_addr string
function DisassemblyView:_apply_page(dir, new, page, anchor_addr)
    local buf = self._bufnr
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end

    local instrs = self._instrs or {}
    local seen   = {} ---@type table<string, boolean>
    for _, ins in ipairs(instrs) do
        if ins.address then seen[ins.address] = true end
    end

    local cap = page * 2  -- keep at most two pages' worth of instructions loaded
    local merged ---@type easydap.DisassemblyView.Row[]
    local consume = 0     -- old top lines the prepend overwrites (a stale header)

    if dir == "down" then
        local added = 0
        for _, ins in ipairs(new) do
            if ins.address and not seen[ins.address] then
                instrs[#instrs + 1] = ins
                seen[ins.address]   = true
                added               = added + 1
            end
        end
        if added == 0 then return end
        -- trim the front, snapped to a symbol-group boundary so the new top still
        -- owns its header
        if #instrs > cap then
            local f = _group_start_at_or_after(instrs, #instrs - cap + 1)
            merged = f and vim.list_slice(instrs, f, #instrs) or instrs
        else
            merged = instrs
        end
    else
        local head = {} ---@type easydap.DisassemblyView.Row[]
        for _, ins in ipairs(new) do
            if ins.address and not seen[ins.address] then
                head[#head + 1]   = ins
                seen[ins.address] = true
            end
        end
        if #head == 0 then return end
        -- the old first instruction loses its header iff the prepended block now
        -- ends in that same symbol
        local of = instrs[1]
        if of and of.symbol and of.symbol == _tail_sym(head) then consume = 1 end
        merged = head
        for _, ins in ipairs(instrs) do merged[#merged + 1] = ins end
        if #merged > cap then merged = vim.list_slice(merged, 1, cap) end
    end

    local new_lines, rows, by_src, pc_row = self:_build(merged, self._pc_ref)
    local oa = _row_of(self._rows, anchor_addr)
    local na = _row_of(rows, anchor_addr)

    self._syncing          = true
    vim.bo[buf].modifiable = true
    if oa and na then
        local o = vim.api.nvim_buf_line_count(buf)
        local n = #new_lines
        if dir == "down" then
            -- append below, then trim the top (group boundary => oa-na lines)
            vim.api.nvim_buf_set_lines(buf, o, o, false,
                vim.list_slice(new_lines, na + (o - oa) + 1, n))
            if oa > na then
                vim.api.nvim_buf_set_lines(buf, 0, oa - na, false, {})
            end
        else
            -- trim the bottom (old coords) first, then prepend at the top
            if o > oa + (n - na) then
                vim.api.nvim_buf_set_lines(buf, oa + (n - na), o, false, {})
            end
            vim.api.nvim_buf_set_lines(buf, 0, consume, false,
                vim.list_slice(new_lines, 1, na - oa + consume))
        end
    else
        -- anchor vanished (shouldn't happen): fall back to a full replace
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, new_lines)
    end
    vim.bo[buf].modifiable = false
    vim.schedule(function() self._syncing = false end)

    self._rows   = rows
    self._by_src = by_src
    self._instrs = merged

    self:_draw_pc(pc_row)
    self:_draw_bps()
end

-- ── Sync ───────────────────────────────────────────────────────────────────

---Move/highlight the asm pane to match the source cursor.
---@private
function DisassemblyView:_sync_from_source()
    local win = self._src_win
    if not (win and vim.api.nvim_win_is_valid(win)) then return end

    local path = _norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
    local line = vim.api.nvim_win_get_cursor(win)[1]

    self:_clear_block()
    local entry = path and self._by_src[path] and self._by_src[path][line]
    if not entry then return end

    for l = entry.first, entry.last do
        vim.api.nvim_buf_set_extmark(self._bufnr, self._ns_block, l - 1, 0, { line_hl_group = _BLOCK_HL, priority = 30 })
    end

    self._syncing = true
    pcall(vim.api.nvim_win_set_cursor, self._win, { entry.first, 0 })
    vim.schedule(function() self._syncing = false end)
end

---Move the source window to match the asm cursor.
---@private
function DisassemblyView:_sync_to_source()
    if not self:_is_open() then return end
    local ins = self._rows[vim.api.nvim_win_get_cursor(self._win)[1]]
    if not ins or not ins._path then return end

    local win = self._src_win
    if not (win and vim.api.nvim_win_is_valid(win)) then return end

    self._syncing = true
    local curpath = _norm(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)))
    if curpath == ins._path then
        pcall(vim.api.nvim_win_set_cursor, win, { ins._sline, 0 })
    end
    vim.schedule(function() self._syncing = false end)
end

-- ── Keymaps ────────────────────────────────────────────────────────────────

---@private
---@param bufnr integer
function DisassemblyView:_setup_keymaps(bufnr)
    vim.keymap.set("n", "q", function() self:close() end,
        { buffer = bufnr, desc = "Close disassembly pane" })
    vim.keymap.set("n", "<CR>", function() self:_toggle_bp_at_cursor() end,
        { buffer = bufnr, desc = "Toggle instruction breakpoint" })
end

-- ── Public API ─────────────────────────────────────────────────────────────

---Open the disassembly pane for the active frame (or focus + refresh if open).
function DisassemblyView:open()
    if not self:_is_open() then
        self._src_win = vim.api.nvim_get_current_win()
    end
    self:_load(true)
end

---Close the disassembly pane: tears down the window, buffer and autocmds
---together. Re-entrant-safe so it can be driven from either the WinClosed or
---the BufDelete/BufWipeout callback (window and buffer co-terminate).
function DisassemblyView:close()
    if self._closing then return end
    self._closing = true

    self:_clear_block()
    self:_teardown_autocmds()

    local win, buf = self._win, self._bufnr
    self._win, self._bufnr = nil, nil

    if win and vim.api.nvim_win_is_valid(win) then
        pcall(vim.api.nvim_win_close, win, true)
    end
    if buf and vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end

    self._closing = false
end

---Toggle an instruction breakpoint on the instruction under the cursor.

function DisassemblyView:toggle_bp_at_cursor()
    self:_toggle_bp_at_cursor()
end

return DisassemblyView
