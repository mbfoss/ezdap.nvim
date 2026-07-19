---@brief Append-only scratch buffer with an optional line cap.
---Owns a non-modifiable scratch buffer that lines are appended to; when a
---`max_lines` cap is set, the oldest lines are trimmed once the buffer grows
---past it. Used for the run Output and raw DAP-messages panels.

local ui_util = require "ezdap.util.ui_util"
local ansi    = require "ezdap.ui.ansi"

---@class ezdap.OutputBuffer
---@field private _bufnr      integer?  nil once the buffer is deleted/wiped
---@field private _max_lines  integer   0 = unlimited
---@field private _autoscroll boolean   keep windows pinned to the last line
---@field private _ansi_ns    integer?  namespace for ANSI highlights, nil when disabled
---@field private _ansi_state ezdap.ui.ansi.State?  running SGR state across appends
local OutputBuffer = {}
OutputBuffer.__index = OutputBuffer

---@class ezdap.OutputBuffer.Opts
---@field name       string   buffer name
---@field listed?    boolean  whether the buffer is listed (default true)
---@field max_lines? integer  cap on retained lines; oldest are trimmed past it (0 = unlimited, default = 10000)
---@field on_delete? fun()    called when the buffer is deleted/wiped
---@field autoscroll boolean? autoscroll the buffer in all visible windows when the cursor is on the last line 
---@field ansi_colors boolean? parse and render ansi colors

---@param opts ezdap.OutputBuffer.Opts
---@return ezdap.OutputBuffer
function OutputBuffer.new(opts)
    local self = setmetatable({
        _bufnr      = nil,
        _max_lines  = opts.max_lines or 10000,
        _autoscroll = opts.autoscroll or false,
        _ansi_ns    = opts.ansi_colors and vim.api.nvim_create_namespace("") or nil,
        _ansi_state = opts.ansi_colors and ansi.new_state() or nil,
    }, OutputBuffer)
    self:_init(opts)
    return self
end

---@param opts ezdap.OutputBuffer.Opts
function OutputBuffer:_init(opts)
    local listed = opts.listed ~= false
    local buf    = ui_util.create_scratch_buffer(listed, {
        buftype    = "nofile",
        swapfile   = false,
        buflisted  = listed,
        bufhidden  = "hide",
        modifiable = false,
    }, function()
        self._bufnr = nil
        if opts.on_delete then opts.on_delete() end
    end)
    vim.api.nvim_buf_set_name(buf, opts.name)
    self._bufnr = buf
end

---@return integer?
function OutputBuffer:bufnr()
    return self._bufnr
end

---@return boolean
function OutputBuffer:is_valid()
    return self._bufnr ~= nil and vim.api.nvim_buf_is_valid(self._bufnr)
end

---Append `lines` to the end of the buffer, trimming the oldest lines if the
---configured cap is exceeded. When `ansi_colors` is set, escape sequences are
---stripped from the rendered text and applied as highlights instead.
---@param lines string[]
function OutputBuffer:append(lines)
    local buf = self._bufnr
    if #lines == 0 or buf == nil or not vim.api.nvim_buf_is_valid(buf) then return end

    -- Snapshot which windows are pinned to the bottom before the buffer grows,
    -- so we only follow along in windows the user hadn't scrolled away from.
    local pinned = {}
    if self._autoscroll then
        local last = vim.api.nvim_buf_line_count(buf)
        for _, win in ipairs(vim.fn.win_findbuf(buf)) do
            if vim.api.nvim_win_get_cursor(win)[1] >= last then
                pinned[#pinned + 1] = win
            end
        end
    end

    -- Parse ANSI first, so what we insert is already escape-free.
    local spans_by_line
    if self._ansi_ns then
        spans_by_line = {}
        local clean = {}
        for i, line in ipairs(lines) do
            clean[i], spans_by_line[i] = ansi.parse(self._ansi_state, line)
        end
        lines = clean
    end

    vim.bo[buf].modifiable = true
    local start_row = vim.api.nvim_buf_line_count(buf)
    vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)

    -- Apply highlights before trimming; extmarks shift/drop with the lines.
    if spans_by_line then
        for i, spans in ipairs(spans_by_line) do
            local row = start_row + i - 1
            for _, span in ipairs(spans) do
                vim.api.nvim_buf_set_extmark(buf, self._ansi_ns, row, span.s, {
                    end_col   = span.e,
                    hl_group  = span.hl,
                })
            end
        end
    end

    if self._max_lines > 0 then
        local excess = vim.api.nvim_buf_line_count(buf) - self._max_lines
        if excess > 0 then
            vim.api.nvim_buf_set_lines(buf, 0, excess, false, {})
        end
    end
    vim.bo[buf].modifiable = false

    local last = vim.api.nvim_buf_line_count(buf)
    for _, win in ipairs(pinned) do
        if vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_cursor(win, { last, 0 })
        end
    end
end

return OutputBuffer
