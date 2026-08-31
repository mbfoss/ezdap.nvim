---@brief Standalone floating fuzzy picker for ezdap.
---A self-contained replacement for `vim.ui.select`: a floating prompt with
---type-to-filter fuzzy matching, an item list, and an optional file-based
---preview pane. No external picker dependency.

local M                  = {}

local fsutil             = require("ezdap.util.fsutil")
local ui_util            = require("ezdap.util.ui")
local timer              = require("ezdap.util.timer")
local str_util           = require("ezdap.util.strutil")

local _NS_CURSOR         = vim.api.nvim_create_namespace("ezdap_select_cursor")
local _NS_CONTENT        = vim.api.nvim_create_namespace("ezdap_select_content")
local _NS_PREVIEW        = vim.api.nvim_create_namespace("ezdap_select_preview")

local _antiflicker_delay = 200

---The end a too-wide line is cut at: `"left"` keeps its tail (paths), `"right"`
---keeps its head. The dropped end is marked with an ellipsis.
---@alias ezdap.select.Crop "left"|"right"

---@class ezdap.select.ItemData
---@field filepath string?
---@field lnum integer?
---@field col integer?
---@field [string] any

---@class ezdap.select.Item
---@field label string  -- display text; fuzzy-matched and match-highlighted
---@field data ezdap.select.ItemData?  -- passed to the callback and previewer
---@field icon string?  -- glyph drawn before the label, excluded from matching
---@field icon_hl string?  -- highlight for `icon`
---@field virt_line {[1]:string,[2]:string?}[]?  -- one display-only line under the item

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
---@field sort_by_score boolean?  -- best match first while filtering (default true); false when the supplied order is itself the meaning
---@field enable_preview boolean?
---@field previewer ezdap.select.Previewer?  -- defaults to the built-in file previewer
---@field initial integer?  -- 1-based index of the item to pre-select (cursor starts on it)
---@field virt_line_crop ezdap.select.Crop?  -- end to cut a too-wide `virt_line` at; nil lets it run past the window
---@field height_ratio number?
---@field width_ratio number?
---@field list_wrap boolean?

---@class ezdap.select.Layout
---@field prompt_row integer
---@field prompt_col integer
---@field prompt_width integer  -- same as `list_width`: they share one frame
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
---@field icon string?
---@field icon_hl string?
---@field label_chunks {[1]:string,[2]:string?}[]?
---@field virt_line {[1]:string,[2]:string?}[]?
---@field score number?
---@field data any

-- Helpers

---Rows and columns the outermost border eats: `nvim_open_win` draws it on the
---row and column it is handed, so a float reaches one cell past its geometry.
---Centring has to allow for it or the picker sits low and to the right.
local _BORDER_SPAN       = 2

-- Helix-style framing. The rule between the two halves is drawn by neither
-- border: it is the list's winbar, filled with `_RULE` and carrying the position
-- count at its right end. A winbar is a window-local option, so a changing count
-- neither re-configures a window nor touches the focused prompt.
local _BORDER_PROMPT     = { "╭", "─", "╮", "│", "", "", "", "│" }
local _BORDER_LIST       = { "", "", "", "│", "╯", "─", "╰", "│" }
local _BORDER_FULL       = "rounded"

-- Fills the list's winbar, so it reads as the rule between the two halves.
local _RULE              = "─"

-- Indent every list row sits at, shared by rendering and wrapped-line indent.
local _ROW_PREFIX        = "  "

-- Elbow drawn before an item's virtual line, and the mark left where a crop cut.
local _VIRT_LINE_ELBOW   = "╰─ "
local _ELLIPSIS          = "…"

-- Rows the prompt half of the frame costs: its top border, its single line of
-- text, and the rule below it, which the list window draws as its winbar.
local _PROMPT_ROWS       = 3

---@param v number
---@param min number
---@param max number
---@return number
local function _clamp(v, min, max)
    return math.max(min, math.min(max, v))
end

--- Whether a statusline is drawn at the bottom of the editor. With
--- `laststatus == 1`, assume no status line
---@return boolean
local function _has_statusline()
    local laststatus = vim.o.laststatus
    return laststatus ~= 0 and laststatus ~= 1
end

---Editor rows the picker may occupy: everything `vim.o.lines` counts, less the
---command line and the statusline. Floats are placed relative to the editor,
---whose row 0 is the top of the screen, so those rows come off the bottom.
---@return integer
local function _usable_lines()
    local reserved = vim.o.cmdheight + (_has_statusline() and 1 or 0)
    return math.max(1, vim.o.lines - reserved)
end

---Nudge `span` so the leftover after centring it inside `available` divides in
---two: the callers' `math.floor` would hand an odd spare cell to the bottom (or
---the right), so spend it on the picker. Grows, shrinking only if it cannot.
---@param span integer
---@param available integer
---@return integer
local function _even_gaps(span, available)
    if (available - span - _BORDER_SPAN) % 2 == 0 then
        return span
    elseif span + _BORDER_SPAN < available then
        return span + 1
    end
    return math.max(1, span - 1)
end

---@param opts { has_preview:boolean, height_ratio:number?, width_ratio:number? }
---@return ezdap.select.Layout
local function _get_horizontal_layout(opts)
    local cols         = vim.o.columns
    local lines        = _usable_lines()

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

    -- The spare cell of an odd remainder goes to the float that can take it.
    local total_width = list_width + preview_width + spacing
    local grow        = _even_gaps(total_width, cols) - total_width
    if has_preview and preview_width + grow >= 1 then
        preview_width = preview_width + grow
    else
        list_width = math.max(1, list_width + grow)
    end
    total_width        = list_width + preview_width + spacing

    local total_height = _even_gaps(math.ceil(lines * _clamp(opts.height_ratio or 0.7, 0.3, 0.8)), lines)
    -- The frame's shared edge costs one row, not two: the prompt's text and rule
    -- sit above the list, and only the list's bottom border closes it.
    local list_height  = _clamp(total_height - (_PROMPT_ROWS - 1), 1, lines)

    local row          = math.floor((lines - total_height - _BORDER_SPAN) / 2)
    local col          = math.floor((cols - total_width - _BORDER_SPAN) / 2)

    return {
        prompt_row     = row,
        prompt_col     = col,
        -- The prompt spans the list alone; the two share one frame.
        prompt_width   = list_width,

        -- One row up from the list's own first line: the list's winbar is the
        -- rule they share.
        list_row       = row + _PROMPT_ROWS - 1,
        list_col       = col,
        list_width     = list_width,
        list_height    = list_height,

        -- Its top border lands on the prompt's, and its height is the rows
        -- between the two, so it closes level with the frame beside it.
        preview_row    = row,
        preview_col    = col + list_width + spacing,
        preview_width  = preview_width,
        preview_height = list_height + _PROMPT_ROWS - 1,
    }
end

---Cut `chunks` down to `width` display cells, dropping whole chunks and then
---part of the one straddling the limit. Highlights ride along on what is kept.
---@param chunks {[1]:string,[2]:string?}[]
---@param width integer
---@param side ezdap.select.Crop
---@return {[1]:string,[2]:string?}[]
local function _crop_chunks(chunks, width, side)
    local total = 0
    for _, chunk in ipairs(chunks) do
        total = total + vim.fn.strdisplaywidth(chunk[1] or "")
    end
    if total <= width then return chunks end
    if width <= 1 then return { { _ELLIPSIS, "NonText" } } end

    local budget         = width - 1 -- the ellipsis standing in for the dropped end
    local out            = {}
    local used           = 0
    local from, to, step = 1, #chunks, 1
    if side == "left" then from, to, step = #chunks, 1, -1 end
    for i = from, to, step do
        local text, hl = chunks[i][1] or "", chunks[i][2]
        local w        = vim.fn.strdisplaywidth(text)
        if used + w <= budget then
            used = used + w
        else
            text = str_util.fit_to_width(text, budget - used, side == "left")
            used = budget
        end
        if text ~= "" then
            table.insert(out, side == "left" and 1 or #out + 1, { text, hl })
        end
        if used >= budget then break end
    end
    table.insert(out, side == "left" and 1 or #out + 1, { _ELLIPSIS, "NonText" })
    return out
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
---@return { score:number, chunks:{[1]:string,[2]:string?}[] }?  nil when the query doesn't match
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

---Best match first. `table.sort` is not stable, so equal scores fall back to the
---items' source order — otherwise a keystroke that doesn't change any score
---would still shuffle the list under the cursor.
---@param items ezdap.select.ListItem[]
local function _sort_by_score(items)
    local order = {}
    for i, item in ipairs(items) do order[item] = i end
    table.sort(items, function(a, b)
        local sa, sb = a.score or 0, b.score or 0
        if sa == sb then return order[a] < order[b] end
        return sa > sb
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

-- Picker

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
---@field _has_virt_lines boolean
---@field _position_text string?  -- "cursor/total" currently in the list winbar
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
    -- Separators are not a caller decision: they appear exactly when at least
    -- one item carries a virtual line, to keep an entry and its line together.
    self._has_virt_lines       = false
    for _, it in ipairs(opts.items or {}) do
        local label, data
        if type(it) == "string" then
            label, data = it, it
        else
            label, data = it.label or "", it.data
        end
        label = (tostring(label):gsub("\n", " "))
        local virt_line = type(it) == "table" and it.virt_line or nil
        if virt_line then self._has_virt_lines = true end
        table.insert(self._source_items, {
            label     = label,
            data      = data,
            icon      = type(it) == "table" and it.icon or nil,
            icon_hl   = type(it) == "table" and it.icon_hl or nil,
            virt_line = virt_line,
        })
    end

    self._initial = type(opts.initial) == "number" and opts.initial or nil

    if _active_picker and not _active_picker.closed then
        _active_picker:close()
    end
    _active_picker = self

    self:create_windows()
    self:setup_input()

    assert(self.pwin)
    vim.api.nvim_set_current_win(self.pwin)

    self:run_filter()
    vim.schedule(function()
        if not self.closed then vim.cmd("startinsert!") end
    end)
end

---The list window's winbar: the rule, with `position_text` at its right end. The
---rule itself is the `wbr` fill char stretched by `%=`, so the winbar is never
---empty -- an empty 'winbar' would take the row back and pull the list up.
---@param position_text string?
---@return string
local function _lwin_winbar(position_text)
    return "%#NonText#%=" .. (position_text and (" " .. position_text) or "")
end

---The prompt window's full config, for creating and moving the window.
---@return table
function Picker:_pwin_config()
    return {
        relative  = "editor",
        style     = "minimal",
        row       = self.layout.prompt_row,
        col       = self.layout.prompt_col,
        width     = self.layout.prompt_width,
        height    = 1,
        border    = _BORDER_PROMPT,
        title     = self.opts.prompt and (" " .. self.opts.prompt .. " ") or "",
        title_pos = "center",
    }
end

---The list window's full config, for creating and moving the window. It has no
---top border: its first row is the winbar drawing the rule under the prompt,
---which is what the extra row of height pays for.
---@return table
function Picker:_lwin_config()
    return {
        relative = "editor",
        style    = "minimal",
        row      = self.layout.list_row,
        col      = self.layout.list_col,
        width    = self.layout.list_width,
        height   = self.layout.list_height + 1,
        border   = _BORDER_LIST,
    }
end

---The preview window's full config, for creating and moving the window.
---@return table
function Picker:_vwin_config()
    return {
        relative = "editor",
        style    = "minimal",
        row      = self.layout.preview_row,
        col      = self.layout.preview_col,
        width    = self.layout.preview_width,
        height   = self.layout.preview_height,
        border   = _BORDER_FULL,
    }
end

---Shared window highlights: the picker floats read as plain windows.
local _WINHL = "NormalFloat:Normal,FloatBorder:Normal,FloatTitle:Title," ..
    "WinBar:Normal,WinBarNC:Normal"

---Recompute `self.layout` from the current editor size and the picker's ratios.
function Picker:_compute_layout()
    self.layout = _get_horizontal_layout {
        has_preview  = self.preview_enabled,
        height_ratio = self.opts.height_ratio,
        width_ratio  = self.opts.width_ratio,
    }
end

---Create the picker's buffers and windows. Called once, at open; afterwards the
---windows are only moved and resized, by `relayout()`.
function Picker:create_windows()
    if self.closed then return end
    self:_compute_layout()

    -- Prompt window
    self.pbuf = ui_util.create_scratch_buffer(false, { modifiable = true }, function()
        self.pbuf = nil
        if not self.closed then vim.schedule(function() self:close() end) end
    end)
    local pwin_augroup
    self.pwin, pwin_augroup = ui_util.create_window(self.pbuf, true, self:_pwin_config(), function()
        self.pwin = nil
        if not self.closed then vim.schedule(function() self:close() end) end
    end)
    ui_util.win_setlocal(self.pwin, "winhighlight", _WINHL)
    ui_util.win_setlocal(self.pwin, "wrap", false)

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

    -- List window
    self.lbuf = ui_util.create_scratch_buffer(false, { modifiable = false }, function()
        self.lbuf = nil
        if not self.closed then vim.schedule(function() self:close() end) end
    end)
    self.lwin = ui_util.create_window(self.lbuf, false, self:_lwin_config(), function()
        self.lwin = nil
        if not self.closed then vim.schedule(function() self:close() end) end
    end)
    ui_util.win_setlocal(self.lwin, "winhighlight", _WINHL)
    ui_util.win_setlocal(self.lwin, "wrap", self.opts.list_wrap ~= false)
    ui_util.win_setlocal(self.lwin, "cursorline", false)
    ui_util.win_setlocal(self.lwin, "breakindent", true)
    -- `wbr` is what `%=` stretches across the winbar; `eob` comes with the
    -- window's `style = "minimal"`, and setting 'fillchars' here drops it.
    ui_util.win_setlocal(self.lwin, "fillchars", "eob: ,wbr:" .. _RULE)
    ui_util.win_setlocal(self.lwin, "winbar", _lwin_winbar(self._position_text))

    -- Preview window (optional)
    if self.preview_enabled then
        self.vbuf = ui_util.create_scratch_buffer(false, { modifiable = false }, function()
            self.vbuf = nil
        end)
        local vkey = { buffer = self.vbuf, nowait = true, silent = true }
        vim.keymap.set("n", "<CR>", function() self:confirm() end, vkey)
        vim.keymap.set("n", "<Esc>", function() self:close() end, vkey)

        self.vwin = ui_util.create_window(self.vbuf, false, self:_vwin_config(), function()
            self.vwin = nil
        end)
        ui_util.win_setlocal(self.vwin, "wrap", true)
        ui_util.win_setlocal(self.vwin, "winhighlight", _WINHL)
    end
end

---Move and resize the existing windows for the current editor size.
function Picker:relayout()
    if self.closed then return end
    self:_compute_layout()

    if self.pwin then vim.api.nvim_win_set_config(self.pwin, self:_pwin_config()) end
    if self.lwin then vim.api.nvim_win_set_config(self.lwin, self:_lwin_config()) end
    if self.vwin then
        vim.api.nvim_win_set_config(self.vwin, self:_vwin_config())
        self:update_preview()
    end

    -- The list width the crop is measured against has just moved.
    if #self.list_items > 0 then
        self:render_list()
        self:render_cursor()
    end
end

---Filter `_source_items` by the current query and rebuild the visible list.
function Picker:run_filter()
    local query     = self.query_text
    self.list_items = {}

    for _, src in ipairs(self._source_items) do
        local m = _match_label(src.label, query)
        if m then
            table.insert(self.list_items, {
                label        = src.label,
                icon         = src.icon,
                icon_hl      = src.icon_hl,
                virt_line    = src.virt_line,
                label_chunks = m.chunks,
                data         = src.data,
                score        = query ~= "" and m.score or nil,
            })
        end
    end
    -- An empty query has no scores to rank by, so it always keeps the supplied
    -- order; `sort_by_score = false` keeps it while filtering too.
    if query ~= "" and self.opts.sort_by_score ~= false then
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
        vim.schedule(function()
            if not self.closed and target == #self.list_items then self:_reveal_virt_lines(target) end
        end)
    end
    self:render_cursor()
    self:render_position()
    self:update_preview()
end

function Picker:render_list()
    if not self.lbuf then return end
    local prefix          = _ROW_PREFIX
    local lines           = {}
    local extmarks        = {}

    -- What a virtual line has left after the indent and the elbow before it.
    local crop            = self.opts.virt_line_crop
    local virt_line_width = self.layout.list_width
        - vim.fn.strdisplaywidth(prefix)
        - vim.fn.strdisplaywidth(_VIRT_LINE_ELBOW)

    for row_idx, item in ipairs(self.list_items) do
        local row  = row_idx - 1
        -- The icon sits between the row prefix and the label, and carries its own
        -- highlight; only the label takes part in matching.
        local icon = item.icon and (item.icon .. " ") or ""
        table.insert(lines, prefix .. icon .. item.label)
        local chunks = item.label_chunks
        if chunks then
            local col = #prefix
            if icon ~= "" then
                chunks = vim.list_extend({ { icon, item.icon_hl } }, chunks)
            end
            for _, chunk in ipairs(chunks) do
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

        -- Display-only line hung under the entry: the item's own `virt_line`,
        -- aligned with the label by the row prefix.
        local vlines  = {}
        local vchunks = item.virt_line
        if vchunks then
            -- A virtual line neither wraps nor scrolls, so what runs past the
            -- window is simply lost; `virt_line_crop` picks the end to lose.
            if crop then
                vchunks = _crop_chunks(vchunks, virt_line_width, crop)
            end
            table.insert(vlines, vim.list_extend({ { prefix }, { _VIRT_LINE_ELBOW, "NonText" } }, vchunks))
        end
        if #vlines > 0 then
            table.insert(extmarks, {
                row  = row,
                col  = 0,
                opts = { virt_lines = vlines, hl_mode = "blend" },
            })
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
        ui_util.win_setlocal(self.lwin, "cursorline", #self.list_items > 0)
    end
end

---@return integer?
function Picker:get_cursor()
    if not self.lwin or not vim.api.nvim_win_is_valid(self.lwin) then return nil end
    return vim.api.nvim_win_get_cursor(self.lwin)[1]
end

---Neovim won't scroll to reveal virt_lines hanging below the cursor line, so an
---entry on the bottom row of the viewport has its virtual lines clipped. When
---that's the case, scroll the view up by the entry's own virtual line.
---@param row integer
function Picker:_reveal_virt_lines(row)
    if not self.lwin or not vim.api.nvim_win_is_valid(self.lwin) then return end
    local item = self.list_items[row]
    if not item then return end

    local nvirt = item.virt_line and 1 or 0
    if nvirt == 0 then return end

    vim.api.nvim_win_call(self.lwin, function()
        -- Screen height of the entry's own text (wrapped rows, excluding virt_lines).
        local line_height = vim.api.nvim_win_text_height(self.lwin, {
            start_row = row - 1,
            end_row   = row - 1,
        }).all
        -- Only act when the entry's last row is the bottom row of the viewport.
        -- `winline()` counts from the first text row, the winbar's own row is not
        -- one of those, but the window height counts it.
        if vim.fn.winline() + line_height - 1 < vim.api.nvim_win_get_height(self.lwin) - 1 then
            return
        end
        local view = vim.fn.winsaveview()
        view.topline = view.topline + nvirt
        vim.fn.winrestview(view)
    end)
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
    vim.schedule(function()
        if not self.closed and row == #self.list_items then self:_reveal_virt_lines(row) end
    end)
    self:render_cursor()
    self:render_position()
    self:update_preview()
end

---Show `cursor/total` right-aligned in the list window's winbar, the rule it
---shares with the prompt.
function Picker:render_position()
    if self.closed or not self.lwin or not vim.api.nvim_win_is_valid(self.lwin) then return end
    local total = #self.list_items
    local text  = total > 0 and string.format("%d/%d", self:get_cursor() or 1, total) or nil
    if text == self._position_text then return end
    self._position_text = text
    ui_util.win_setlocal(self.lwin, "winbar", _lwin_winbar(text))
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

    local preview_width       = math.max(0, self.layout.preview_width - 2)  -- -2 for borders
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

-- Public API

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
