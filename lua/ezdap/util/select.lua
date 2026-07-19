---@brief Standalone floating fuzzy picker for ezdap.
---A self-contained replacement for `vim.ui.select`: a floating prompt with
---type-to-filter fuzzy matching, an item list, and an optional file-based
---preview pane. No external picker dependency.

local M                  = {}

local fsutil             = require("ezdap.tk.fsutil")
local ui_util            = require("ezdap.util.ui_util")
local timer              = require("ezdap.tk.timer")

local _NS_CURSOR         = vim.api.nvim_create_namespace("ezdap_select_cursor")
local _NS_CONTENT        = vim.api.nvim_create_namespace("ezdap_select_content")
local _NS_PREVIEW        = vim.api.nvim_create_namespace("ezdap_select_preview")

local _antiflicker_delay = 200

---@class ezdap.select.ItemData
---@field filepath string?
---@field lnum integer?
---@field col integer?
---@field [string] any

---@class ezdap.select.Item
---@field label string  -- display text; fuzzy-matched and match-highlighted
---@field data ezdap.select.ItemData?  -- passed to the callback and previewer

---@class ezdap.select.Preview
---@field content string|string[]|nil
---@field filetype string?
---@field filepath string?
---@field pos integer[]?  -- { lnum (1-based), col (0-based) }
---@field error_msg string?

---@alias ezdap.select.Previewer fun(data:any, callback:fun(preview:ezdap.select.Preview?)):(fun()?)

---@class ezdap.select.Opts
---@field prompt string?
---@field items (ezdap.select.Item|string)[]  -- a bare string == { label = s, data = s }
---@field enable_preview boolean?
---@field previewer ezdap.select.Previewer?  -- defaults to the built-in file previewer
---@field initial integer?  -- 1-based index of the item to pre-select (cursor starts on it)
---@field height_ratio number?
---@field width_ratio number?
---@field list_wrap boolean?

---@class ezdap.select.Layout
---@field prompt_row integer
---@field prompt_col integer
---@field prompt_width integer
---@field list_row integer
---@field list_col integer
---@field list_width integer
---@field list_height integer
---@field preview_row integer
---@field preview_col integer
---@field preview_width integer
---@field preview_height integer

---@class ezdap.select.ListItem
---@field label string
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field score number?
---@field data any

-- ── Helpers ────────────────────────────────────────────────────────────────

---@param v number
---@param min number
---@param max number
---@return number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

---@param opts { has_preview:boolean, height_ratio:number?, width_ratio:number? }
---@return ezdap.select.Layout
local function _get_horizontal_layout(opts)
    local cols         = vim.o.columns
    local lines        = vim.o.lines

    local has_preview  = opts.has_preview
    local spacing      = has_preview and 2 or 0
    local half_spacing = math.floor(spacing / 2)

    local list_width   = math.ceil(cols * _clamp(opts.width_ratio or 0.4, 0.1, 0.8))
    local preview_width
    if has_preview then
        local width   = math.min(list_width * 2, cols)
        preview_width = _clamp(width - list_width - half_spacing, 1, width)
    else
        preview_width = 0
    end

    local total_height = math.ceil(lines * _clamp(opts.height_ratio or 0.7, 0.3, 0.8))
    local list_height  = _clamp(total_height - 3, 1, lines)

    local row          = math.floor((lines - total_height - 1) / 2)
    local col          = math.floor((cols - (list_width + preview_width + spacing)) / 2)

    return {
        prompt_row     = row,
        prompt_col     = col,
        prompt_width   = list_width + preview_width + spacing,

        list_row       = row + 3,
        list_col       = col,
        list_width     = list_width,
        list_height    = list_height,

        preview_row    = row + 3,
        preview_col    = col + list_width + spacing,
        preview_width  = preview_width,
        preview_height = list_height,
    }
end

---@param text string  the final string to be shown
---@param positions integer[]  matched (1-based) indices
---@param hl_group string?  override for the match highlight
---@return {[1]:string,[2]:string?}[] chunks
local function _build_highlight_chunks(text, positions, hl_group)
    if not positions or #positions == 0 then
        return { { text } }
    end

    local hl      = hl_group or "Todo"
    local chunks  = {}
    local pos_map = {}
    for _, p in ipairs(positions) do pos_map[p] = true end

    local current_chunk  = ""
    local last_was_match = pos_map[1] or false
    local nchars         = vim.fn.strchars(text)

    for i = 1, nchars do
        local char     = vim.fn.strcharpart(text, i - 1, 1)
        local is_match = pos_map[i] or false
        if is_match ~= last_was_match then
            table.insert(chunks, last_was_match and { current_chunk, hl } or { current_chunk })
            current_chunk  = char
            last_was_match = is_match
        else
            current_chunk = current_chunk .. char
        end
    end

    if current_chunk ~= "" then
        table.insert(chunks, last_was_match and { current_chunk, hl } or { current_chunk })
    end
    return chunks
end

---@param text string  what we match against
---@param query string  user input
---@return { score:number, chunks:{[1]:string,[2]:string?}[] }?
local function _match_label(text, query)
    if query == "" then
        return { score = 0, chunks = _build_highlight_chunks(text, {}) }
    end
    local result = vim.fn.matchfuzzypos({ text }, query)
    if #result[1] == 0 then return nil end
    local raw_positions = result[2][1]
    local positions     = {}
    for _, p in ipairs(raw_positions) do
        positions[#positions + 1] = p + 1 -- matchfuzzypos is 0-based; chunk builder is 1-based
    end
    return {
        score  = result[3][1],
        chunks = _build_highlight_chunks(text, positions),
    }
end

---@param items ezdap.select.ListItem[]
local function _sort_by_score(items)
    table.sort(items, function(a, b)
        return (a.score or 0) > (b.score or 0)
    end)
end

---The built-in file previewer. Reads `data.filepath`/`data.lnum`/`data.col` and
---asynchronously loads the file content. Cancellable via the returned function.
---@type ezdap.select.Previewer
local function _file_preview(data, callback)
    local _max_size = 10124 * 10124
    local _filepath = data and data.filepath
    if not _filepath or _filepath == "" then
        callback({})
        return
    end
    if not fsutil.file_exists(_filepath) then
        callback({ error_msg = "Invalid file path: " .. tostring(_filepath) })
        return
    end
    local _cancelled = false
    local _cancel_fn
    vim.uv.fs_stat(_filepath, vim.schedule_wrap(function(stat_err, stat)
        if _cancelled then return end
        if stat_err or not stat then
            callback({ error_msg = stat_err })
            return
        end
        if stat.size > _max_size then
            callback({ error_msg = "Maximum file size exceeded" })
            return
        end
        _cancel_fn = fsutil.async_load_text_file(_filepath, { timeout = 3000 },
            function(load_err, content)
                callback({
                    content   = content,
                    filepath  = _filepath,
                    pos       = data.lnum and { data.lnum, data.col or 0 } or nil,
                    error_msg = load_err,
                })
            end)
    end))
    return function()
        _cancelled = true
        if _cancel_fn then _cancel_fn() end
    end
end

---Place the preview cursor and highlight the target line.
---@param win integer
---@param buf integer
---@param pos integer[]?  -- { lnum (1-based), col (0-based) }
local function _apply_preview_pos(win, buf, pos)
    vim.api.nvim_buf_clear_namespace(buf, _NS_PREVIEW, 0, -1)
    if not pos then
        pcall(vim.api.nvim_win_set_cursor, win, { 1, 0 })
        return
    end
    local lnum      = _clamp(pos[1], 1, vim.api.nvim_buf_line_count(buf))
    local line_text = vim.api.nvim_buf_get_lines(buf, lnum - 1, lnum, false)[1] or ""
    local col       = math.max(0, math.min(pos[2] or 0, #line_text))
    pcall(vim.api.nvim_win_set_cursor, win, { lnum, col })
    vim.api.nvim_win_call(win, function() vim.cmd("normal! zz") end)
    vim.api.nvim_buf_set_extmark(buf, _NS_PREVIEW, lnum - 1, 0, {
        end_row  = lnum,
        hl_group = "Visual",
        hl_eol   = true,
        hl_mode  = "blend",
    })
end

---@param msg string
---@param width number
---@param height number
---@return string[]
local function _center_for_previewer(msg, width, height)
    local pad_left = math.max(0, math.floor((width - #msg) / 2) + 1)
    local centered = string.rep(" ", pad_left) .. msg
    local pad_top  = math.max(0, math.floor((height + 1) / 2))

    local lines    = {}
    for _ = 1, pad_top do table.insert(lines, "") end
    table.insert(lines, centered)
    return lines
end

-- ── Picker ─────────────────────────────────────────────────────────────────

---@type ezdap.select.Picker?
local _active_picker = nil

---@class ezdap.select.Picker
---@field opts ezdap.select.Opts
---@field callback fun(data:any?)
---@field preview_enabled boolean
---@field layout ezdap.select.Layout
---@field query_text string
---@field closed boolean
---@field pbuf integer?
---@field lbuf integer?
---@field vbuf integer?
---@field pwin integer?
---@field lwin integer?
---@field vwin integer?
---@field list_items ezdap.select.ListItem[]
---@field async_preview_context integer
---@field async_preview_cancel fun()?
---@field preview_timer table?
---@field _source_items ezdap.select.ListItem[]
---@field _initial integer?
local Picker = {}
Picker.__index = Picker

function Picker:new(...)
    local obj = setmetatable({}, self)
    obj:init(...)
    return obj
end

---@param opts ezdap.select.Opts
---@param callback fun(data:any?)
function Picker:init(opts, callback)
    self.opts                  = opts
    self.callback              = callback
    self.preview_enabled       = opts.enable_preview or false
    self.closed                = false
    self.query_text            = ""
    self.list_items            = {}
    self.async_preview_context = 0
    self.async_preview_cancel  = nil

    ---@type ezdap.select.ListItem[]
    self._source_items         = {}
    for _, it in ipairs(opts.items or {}) do
        local label, data
        if type(it) == "string" then
            label, data = it, it
        else
            label, data = it.label or "", it.data
        end
        label = (tostring(label):gsub("\n", " "))
        table.insert(self._source_items, { label = label, data = data })
    end

    self._initial = type(opts.initial) == "number" and opts.initial or nil

    if _active_picker and not _active_picker.closed then
        _active_picker:close()
    end
    _active_picker = self

    self:relayout()
    self:setup_input()

    assert(self.pwin)
    vim.api.nvim_set_current_win(self.pwin)

    self:run_filter()
    vim.schedule(function()
        if not self.closed then vim.cmd("startinsert!") end
    end)
end

function Picker:relayout()
    if self.closed then return end
    local opts        = self.opts
    local title       = opts.prompt and (" " .. opts.prompt .. " ") or ""
    local has_preview = self.preview_enabled

    self.layout       = _get_horizontal_layout {
        has_preview  = has_preview,
        height_ratio = opts.height_ratio,
        width_ratio  = opts.width_ratio,
    }

    local base_cfg    = { relative = "editor", style = "minimal", border = "rounded" }
    local winhl       = "NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Title"

    -- Prompt window
    if not self.pwin then
        if not self.pbuf then
            self.pbuf = ui_util.create_scratch_buffer(false, { modifiable = true }, function()
                self.pbuf = nil
                if not self.closed then vim.schedule(function() self:close() end) end
            end)
        end
        local pwin_augroup
        self.pwin, pwin_augroup = ui_util.create_window(self.pbuf, true, vim.tbl_extend("force", base_cfg, {
            row       = self.layout.prompt_row,
            col       = self.layout.prompt_col,
            width     = self.layout.prompt_width,
            height    = 1,
            title     = title,
            title_pos = "center",
        }), function()
            self.pwin = nil
            if not self.closed then vim.schedule(function() self:close() end) end
        end)
        vim.wo[self.pwin].winhighlight = winhl
        vim.wo[self.pwin].wrap = false

        assert(type(pwin_augroup) == "number")
        vim.api.nvim_create_autocmd("WinEnter", {
            group = pwin_augroup,
            callback = function()
                if self.closed then return end
                local win      = vim.api.nvim_get_current_win()
                local cfg      = vim.api.nvim_win_get_config(win)
                local is_float = cfg.relative and cfg.relative ~= ""
                if not is_float and win ~= self.pwin and win ~= self.lwin and win ~= self.vwin then
                    vim.schedule(function() self:close() end)
                end
            end,
        })
        vim.api.nvim_create_autocmd("VimResized", {
            group = pwin_augroup,
            callback = function()
                if self.closed then return end
                vim.schedule(function() self:relayout() end)
            end,
        })
    else
        vim.api.nvim_win_set_config(self.pwin, vim.tbl_extend("force", base_cfg, {
            row    = self.layout.prompt_row,
            col    = self.layout.prompt_col,
            width  = self.layout.prompt_width,
            height = 1,
        }))
    end

    -- List window
    if not self.lwin then
        if not self.lbuf then
            self.lbuf = ui_util.create_scratch_buffer(false, { modifiable = false }, function()
                self.lbuf = nil
                if not self.closed then vim.schedule(function() self:close() end) end
            end)
        end
        self.lwin = ui_util.create_window(self.lbuf, false, vim.tbl_extend("force", base_cfg, {
            row    = self.layout.list_row,
            col    = self.layout.list_col,
            width  = self.layout.list_width,
            height = self.layout.list_height,
        }), function()
            self.lwin = nil
            if not self.closed then vim.schedule(function() self:close() end) end
        end)
        vim.wo[self.lwin].winhighlight = winhl
        vim.wo[self.lwin].wrap = self.opts.list_wrap ~= false
        vim.wo[self.lwin].cursorline = false
    else
        vim.api.nvim_win_set_config(self.lwin, vim.tbl_extend("force", base_cfg, {
            row    = self.layout.list_row,
            col    = self.layout.list_col,
            width  = self.layout.list_width,
            height = self.layout.list_height,
        }))
    end

    -- Preview window (optional)
    if has_preview then
        if not self.vwin then
            if not self.vbuf then
                self.vbuf = ui_util.create_scratch_buffer(false, { modifiable = false }, function()
                    self.vbuf = nil
                end)
                local vkey = { buffer = self.vbuf, nowait = true, silent = true }
                vim.keymap.set("n", "<CR>", function() self:confirm() end, vkey)
                vim.keymap.set("n", "<Esc>", function() self:close() end, vkey)
            end
            self.vwin = ui_util.create_window(self.vbuf, false, vim.tbl_extend("force", base_cfg, {
                row    = self.layout.preview_row,
                col    = self.layout.preview_col,
                width  = self.layout.preview_width,
                height = self.layout.preview_height,
            }), function()
                self.vwin = nil
            end)
            vim.wo[self.vwin].wrap = true
            vim.wo[self.vwin].winhighlight = winhl
        else
            vim.api.nvim_win_set_config(self.vwin, vim.tbl_extend("force", base_cfg, {
                row    = self.layout.preview_row,
                col    = self.layout.preview_col,
                width  = self.layout.preview_width,
                height = self.layout.preview_height,
            }))
        end
        self:update_preview()
    end
end

---Filter `_source_items` by the current query and rebuild the visible list.
function Picker:run_filter()
    local query     = self.query_text
    self.list_items = {}

    if query == "" then
        for _, src in ipairs(self._source_items) do
            table.insert(self.list_items, {
                label        = src.label,
                data         = src.data,
                label_chunks = { { src.label } },
                score        = nil,
            })
        end
    else
        for _, src in ipairs(self._source_items) do
            local m = _match_label(src.label, query)
            if m then
                table.insert(self.list_items, {
                    label        = src.label,
                    data         = src.data,
                    label_chunks = m.chunks,
                    score        = m.score,
                })
            end
        end
        _sort_by_score(self.list_items)
    end

    self:render_list()

    -- `initial` pre-selects a row by index, honoured only on the first
    -- (empty-query) render where the list order still matches the supplied
    -- items; once the user types, the best fuzzy match leads at row 1.
    local target = 1
    if self._initial then
        if #self.list_items > 0 then
            target = _clamp(self._initial, 1, #self.list_items)
        end
        self._initial = nil
    end

    if #self.list_items > 0 and self.lwin and vim.api.nvim_win_is_valid(self.lwin) then
        vim.api.nvim_win_set_cursor(self.lwin, { target, 0 })
    end
    self:render_cursor()
    self:render_position()
    self:update_preview()
end

function Picker:render_list()
    if not self.lbuf then return end
    local prefix   = "  "
    local lines    = {}
    local extmarks = {}

    for row_idx, item in ipairs(self.list_items) do
        local row = row_idx - 1
        table.insert(lines, prefix .. item.label)
        if item.label_chunks then
            local col = #prefix
            for _, chunk in ipairs(item.label_chunks) do
                local text, hl = chunk[1], chunk[2]
                if text and #text > 0 then
                    if hl then
                        table.insert(extmarks, {
                            row  = row,
                            col  = col,
                            opts = { end_col = col + #text, hl_group = hl },
                        })
                    end
                    col = col + #text
                end
            end
        end
    end

    vim.bo[self.lbuf].modifiable = true
    vim.api.nvim_buf_set_lines(self.lbuf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CONTENT, 0, -1)
    for _, mark in ipairs(extmarks) do
        vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CONTENT, mark.row, mark.col, mark.opts)
    end
    vim.bo[self.lbuf].modifiable = false

    if self.lwin and vim.api.nvim_win_is_valid(self.lwin) then
        vim.wo[self.lwin].cursorline = #self.list_items > 0
    end
end

---@return integer?
function Picker:get_cursor()
    if not self.lwin or not vim.api.nvim_win_is_valid(self.lwin) then return nil end
    return vim.api.nvim_win_get_cursor(self.lwin)[1]
end

---@param row integer
---@param force boolean?
---@param clamp boolean?
function Picker:move_cursor(row, force, clamp)
    if not self.lwin or not vim.api.nvim_win_is_valid(self.lwin) then return end
    local total = #self.list_items
    if total == 0 then return end
    if not force and row == self:get_cursor() then return end

    if clamp then
        row = _clamp(row, 1, total)
    else
        if row > total then row = 1 end
        if row < 1 then row = total end
    end

    vim.api.nvim_win_set_cursor(self.lwin, { row, 0 })
    self:render_cursor()
    self:render_position()
    self:update_preview()
end

function Picker:render_position()
    if not self.pbuf then return end
    vim.api.nvim_buf_clear_namespace(self.pbuf, _NS_CURSOR, 0, -1)
    local total = #self.list_items
    if total == 0 then return end
    local cur  = self:get_cursor() or 1
    local text = string.format("%d/%d", cur, total)
    vim.api.nvim_buf_set_extmark(self.pbuf, _NS_CURSOR, 0, 0, {
        virt_text     = { { text, "NonText" } },
        virt_text_pos = "eol_right_align",
        hl_mode       = "blend",
        priority      = 50,
    })
end

function Picker:render_cursor()
    if not self.lbuf then return end
    vim.api.nvim_buf_clear_namespace(self.lbuf, _NS_CURSOR, 0, -1)
    local total = #self.list_items
    if total == 0 then return end
    local cur = self:get_cursor() or 1
    vim.api.nvim_buf_set_extmark(self.lbuf, _NS_CURSOR, cur - 1, 0, {
        virt_text     = { { "❯ ", "Special" } },
        virt_text_pos = "overlay",
        priority      = 100,
    })
end

function Picker:update_preview()
    self.async_preview_context = self.async_preview_context + 1
    local preview_context = self.async_preview_context

    if self.closed then return end
    if not self.vbuf then return end

    self:request_clear_preview()

    if self.async_preview_cancel then
        self.async_preview_cancel()
        self.async_preview_cancel = nil
    end

    local cursor = self:get_cursor()
    local item   = cursor and self.list_items[cursor] or nil
    if not item then return end

    local preview_width       = math.max(0, self.layout.preview_width - 2) -- -2 for borders
    local preview_height      = math.max(0, self.layout.preview_height - 2) -- -2 for borders

    local preview_fn          = self.opts.previewer or _file_preview

    self.async_preview_cancel = preview_fn(
        item.data or {},
        vim.schedule_wrap(function(preview)
            if self.closed or preview_context ~= self.async_preview_context then return end
            preview = preview or {}
            self:cancel_clear_preview_req()

            if not self.vbuf or not vim.api.nvim_buf_is_valid(self.vbuf) then return end

            local content = preview.content
            local lines ---@type string[]
            if content then
                lines = type(content) == "string" and vim.split(content, "\n") or content
            elseif preview.error_msg then
                lines = _center_for_previewer(preview.error_msg, preview_width, preview_height)
            else
                lines = _center_for_previewer("No preview", preview_width, preview_height)
            end
            lines = lines or {}

            vim.bo[self.vbuf].modifiable = true
            vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, lines)
            vim.bo[self.vbuf].modifiable = false

            local filetype = content and (preview.filetype
                or (preview.filepath and vim.filetype.match({ filename = preview.filepath }))
                or "") or ""
            -- don't set bo[].filetype to avoid slowness and flickering triggered by treesiter/lsp etc...
            vim.bo[self.vbuf].syntax = filetype

            if self.vwin and vim.api.nvim_win_is_valid(self.vwin) then
                _apply_preview_pos(self.vwin, self.vbuf, content and preview.pos or nil)
            end
        end)
    )
end

---@param immediate boolean?
function Picker:request_clear_preview(immediate)
    local clear = function()
        if self.vbuf and not self.closed and vim.api.nvim_buf_is_valid(self.vbuf) then
            vim.bo[self.vbuf].modifiable = true
            vim.api.nvim_buf_set_lines(self.vbuf, 0, -1, false, {})
            vim.bo[self.vbuf].modifiable = false
            vim.api.nvim_buf_clear_namespace(self.vbuf, _NS_PREVIEW, 0, -1)
        end
    end
    if immediate then
        self:cancel_clear_preview_req()
        clear()
    elseif not self.preview_timer then
        self.preview_timer = vim.defer_fn(function()
            self.preview_timer = nil
            clear()
        end, _antiflicker_delay)
    end
end

function Picker:cancel_clear_preview_req()
    self.preview_timer = timer.stop_and_close_timer(self.preview_timer)
end

function Picker:confirm()
    local cursor = self:get_cursor()
    local item   = cursor and self.list_items[cursor] or nil
    self:close(item and item.data or nil)
end

---@param selected_data any?
function Picker:close(selected_data)
    if self.closed then return end
    self.closed = true
    if _active_picker == self then _active_picker = nil end

    self.preview_timer = timer.stop_and_close_timer(self.preview_timer)
    if self.async_preview_cancel then self.async_preview_cancel() end

    for _, w in pairs({ self.pwin, self.lwin, self.vwin }) do
        if w and vim.api.nvim_win_is_valid(w) then
            pcall(vim.api.nvim_win_close, w, true)
        end
    end
    for _, b in pairs({ self.pbuf, self.lbuf, self.vbuf }) do
        if b and vim.api.nvim_buf_is_valid(b) then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end

    vim.cmd("stopinsert!")
    vim.schedule(function()
        self.callback(selected_data)
    end)
end

function Picker:setup_input()
    ---@param buf integer
    local function key_opts(buf)
        return { buffer = buf, nowait = true, silent = true }
    end

    local p    = key_opts(self.pbuf)
    local expr = vim.tbl_extend("force", p, { expr = true })

    vim.keymap.set({ "i", "n" }, "<CR>", function() self:confirm() end, p)
    vim.keymap.set("n", "<Esc>", function() self:close() end, p)
    vim.keymap.set("i", "<C-c>", function() self:close() end, p)

    vim.keymap.set("n", "<C-n>", function() self:move_cursor((self:get_cursor() or 0) + 1) end, p)
    vim.keymap.set("n", "<C-p>", function() self:move_cursor((self:get_cursor() or 1) - 1) end, p)

    vim.keymap.set("i", "<C-n>", function()
        if vim.fn.pumvisible() == 1 then return "<C-n>" end
        self:move_cursor((self:get_cursor() or 0) + 1)
        return ""
    end, expr)
    vim.keymap.set("i", "<C-p>", function()
        if vim.fn.pumvisible() == 1 then return "<C-p>" end
        self:move_cursor((self:get_cursor() or 1) - 1)
        return ""
    end, expr)
    vim.keymap.set("i", "<Down>", function()
        if vim.fn.pumvisible() == 1 then return "<Down>" end
        self:move_cursor((self:get_cursor() or 0) + 1)
        return ""
    end, expr)
    vim.keymap.set("i", "<Up>", function()
        if vim.fn.pumvisible() == 1 then return "<Up>" end
        self:move_cursor((self:get_cursor() or 1) - 1)
        return ""
    end, expr)

    vim.keymap.set({ "i", "n" }, "<C-d>", function()
        local cur = self:get_cursor()
        if cur then self:move_cursor(cur + math.floor(self.layout.list_height / 2), false, true) end
    end, p)
    vim.keymap.set({ "i", "n" }, "<C-u>", function()
        local cur = self:get_cursor()
        if cur then self:move_cursor(cur - math.floor(self.layout.list_height / 2), false, true) end
    end, p)

    vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = self.pbuf,
        callback = function()
            local text = vim.api.nvim_buf_get_lines(self.pbuf, 0, 1, false)[1] or ""
            if text ~= self.query_text then
                self.query_text = text
                self:run_filter()
            end
        end,
    })

    local l = key_opts(self.lbuf)
    vim.keymap.set("n", "<Esc>", function() self:close() end, l)
    vim.keymap.set("n", "<CR>", function() self:confirm() end, l)
end

-- ── Public API ─────────────────────────────────────────────────────────────

---Open a floating fuzzy picker. `callback` receives the selected item's `data`
---(or the bare string for string items), or `nil` when cancelled.
---@param opts ezdap.select.Opts
---@param callback fun(data:any?)
function M.open(opts, callback)
    assert(type(opts) == "table", "select.open: opts must be a table")
    assert(type(callback) == "function", "select.open: callback must be a function")
    Picker:new(opts, callback)
end

return M
