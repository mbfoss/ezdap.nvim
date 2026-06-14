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

-- ── Tunables ───────────────────────────────────────────────────────────────

local _COUNT    = 80  -- instructions requested per initial disassemble
local _OFFSET   = -20 -- start a little before the PC so it sits mid-pane
local _ADDR_W   = 18  -- width of the address column
local _PAGE     = 40  -- instructions fetched per on-demand page
local _PAGE_PAD = 6   -- trigger paging when the cursor is within this many rows of an edge

-- ── Highlight groups ───────────────────────────────────────────────────────

local _PC_HL    = "EasydapDisasmPC"
local _BLOCK_HL = "EasydapDisasmBlock"
local _BP_HL    = "EasydapDisasmBp"

local function _define_highlights()
    vim.api.nvim_set_hl(0, _PC_HL, { bg = ui_util.auto_bg(0xD4A017), default = true })
    vim.api.nvim_set_hl(0, _BLOCK_HL, { bg = ui_util.auto_bg(0x4A6FA5), default = true })
    vim.api.nvim_set_hl(0, _BP_HL, { link = "DiagnosticError", default = true })
end

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
---@field private _ns        integer  static render highlights (symbols, addresses)
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
    _define_highlights()

    local self = setmetatable({
        _rows     = {},
        _by_src   = {},
        _ns       = vim.api.nvim_create_namespace("easydap_disasm"),
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
    self._aug = vim.api.nvim_create_augroup("easydap_disasm_sync", { clear = true })

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
---@return boolean
function DisassemblyView:_is_open()
    return self._win ~= nil and vim.api.nvim_win_is_valid(self._win)
end

---@private
function DisassemblyView:_ensure_win()
    self:_ensure_autocmds()

    if not (self._bufnr and vim.api.nvim_buf_is_valid(self._bufnr)) then
        -- buffer deleted -> close the window too
        self._bufnr = ui_util.create_sratch_buffer(false, { filetype = "asm" }, function()
            self._bufnr = nil
            self:close()
        end)
        pcall(vim.api.nvim_buf_set_name, self._bufnr, "easydap://disassembly")
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

        -- steps issued while focused here use instruction granularity.
        vim.api.nvim_create_autocmd("BufEnter", {
            group    = self._aug,
            buffer   = self._bufnr,
            callback = function() manager.set_granularity("instruction") end,
        })
        vim.api.nvim_create_autocmd("BufLeave", {
            group    = self._aug,
            buffer   = self._bufnr,
            callback = function() manager.set_granularity("line") end,
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

    sess:disassemble(ref, _COUNT, _OFFSET, function(instrs, err)
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

---@private
---@param instrs easydap.dap.proto.DisassembledInstruction[]
---@param pc_ref string?
---@param recenter boolean?  center the cursor on the PC row (fresh loads only)
function DisassemblyView:_render(instrs, pc_ref, recenter)
    local lines   = {} ---@type string[]
    local rows    = {} ---@type table<integer, easydap.DisassemblyView.Row>
    local by_src  = {} ---@type table<string, table<integer, easydap.DisassemblyView.SrcRange>>
    local headers = {} ---@type integer[]
    local pc_row  = nil ---@type integer?
    local cur_sym = nil ---@type string?

    for _, ins in ipairs(instrs) do
        if ins.symbol and ins.symbol ~= cur_sym then
            cur_sym               = ins.symbol
            lines[#lines + 1]     = ins.symbol .. ":"
            headers[#headers + 1] = #lines
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

---@private
---@param addr string?
---@return integer?
function DisassemblyView:_row_of_addr(addr)
    if not addr then return end
    for lnum, ins in pairs(self._rows) do
        if _addr_eq(ins.address, addr) then return lnum end
    end
end

---Fetch more instructions when the cursor nears either edge of the buffer.
---@private
function DisassemblyView:_maybe_page()
    if self._paging or not self:_is_open() then return end
    if not self._instrs or #self._instrs == 0 then return end
    local row   = vim.api.nvim_win_get_cursor(self._win)[1]
    local total = vim.api.nvim_buf_line_count(self._bufnr)
    if row <= _PAGE_PAD then
        self:_page("up")
    elseif row >= total - _PAGE_PAD then
        self:_page("down")
    end
end

---Extend the instruction window in the given direction and re-render in place.
---@private
---@param dir "up"|"down"
function DisassemblyView:_page(dir)
    local sess   = self._sess
    local instrs = self._instrs
    if not sess or not instrs or #instrs == 0 then return end
    self._paging      = true

    -- anchor the view on the instruction under the cursor so it doesn't jump
    local anchor      = self._rows[vim.api.nvim_win_get_cursor(self._win)[1]]
    local anchor_addr = anchor and anchor.address

    local ref, offset
    if dir == "up" then
        ref, offset = instrs[1].address, -_PAGE
    else
        ref, offset = instrs[#instrs].address, 1
    end
    if not ref then
        self._paging = false; return
    end

    sess:disassemble(ref, _PAGE, offset, function(new, err)
        vim.schedule(function()
            self._paging = false
            local cur = self._instrs
            if err or not new or #new == 0 or not cur or not self:_is_open() then return end

            local have = {}
            for _, i in ipairs(cur) do have[i.address] = true end
            local add = {}
            for _, i in ipairs(new) do
                if i.address and not have[i.address] then add[#add + 1] = i end
            end
            if #add == 0 then return end

            local merged ---@type easydap.DisassemblyView.Row[]
            if dir == "up" then
                merged = {}
                vim.list_extend(merged, add)
                vim.list_extend(merged, cur)
            else
                merged = cur
                vim.list_extend(merged, add)
            end

            self:_render(merged, self._pc_ref, false)

            local r = self:_row_of_addr(anchor_addr)
            if r then
                self._syncing = true
                pcall(vim.api.nvim_win_set_cursor, self._win, { r, 0 })
                vim.schedule(function() self._syncing = false end)
            end
        end)
    end)
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
    else
        -- inlined frame: instruction maps to a different file
        local asm = self._win
        vim.api.nvim_set_current_win(win)
        local newwin = ui_util.smart_open_file(ins._path, ins._sline, 0, false)
        if newwin and newwin > 0 then self._src_win = newwin end
        if asm and vim.api.nvim_win_is_valid(asm) then
            vim.api.nvim_set_current_win(asm)
        end
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

return DisassemblyView
