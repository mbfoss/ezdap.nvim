local base = require("ezdap.tk.ui")

local M = setmetatable({}, { __index = base })

---@type table<string, fun(): vim.api.keyset.highlight>?
local _themed_hl_data

---Pull content down into any blank space at the bottom of a window so the viewport
---stays full instead of showing a few lines over a field of `~`. Scrolls the view
---only (never the cursor), and only when there are earlier lines to pull down.
---@param winid integer
function M.fill_viewport(winid)
    if not vim.api.nvim_win_is_valid(winid) then return end
    local h    = vim.api.nvim_win_get_height(winid)
    local info = vim.fn.getwininfo(winid)[1]
    if not info then return end

    local visible = info.botline - info.topline + 1
    if visible >= h or info.topline <= 1 then return end

    vim.api.nvim_win_call(winid, function()
        local view   = vim.fn.winsaveview()
        view.topline = math.max(1, view.topline - (h - visible))
        vim.fn.winrestview(view)
    end)
end

---Convert a color to a 24-bit integer.
---@param color integer|string
---@return integer
function M.normalize_color(color)
    if type(color) == "number" then
        return color
    end
    if type(color) == "string" then
        color = color:gsub("^#", "")
        local n = tonumber(color, 16)
        if n then
            return n
        end
    end
    error("invalid color: " .. tostring(color))
end

---Linearly blend two 24-bit integer colors.
---@param c1 integer|string  -- base color
---@param c2 integer|string  -- blend-toward color
---@param alpha number  -- 0 = all c1, 1 = all c2
---@return integer
function M.blend_colors(c1, c2, alpha)
    c1, c2 = M.normalize_color(c1), M.normalize_color(c2)
    local r1 = bit.rshift(c1, 16)
    local g1 = bit.band(bit.rshift(c1, 8), 0xFF)
    local b1 = bit.band(c1, 0xFF)
    local r2 = bit.rshift(c2, 16)
    local g2 = bit.band(bit.rshift(c2, 8), 0xFF)
    local b2 = bit.band(c2, 0xFF)
    local r = math.floor(r1 * (1 - alpha) + r2 * alpha)
    local g = math.floor(g1 * (1 - alpha) + g2 * alpha)
    local b = math.floor(b1 * (1 - alpha) + b2 * alpha)
    return bit.bor(bit.lshift(r, 16), bit.lshift(g, 8), b)
end

---Define a highlight group whose attributes depend on the current colorscheme.
---@param name string
---@param spec_fn fun(): vim.api.keyset.highlight
function M.define_themed_hl(name, spec_fn)
    if not _themed_hl_data then
        _themed_hl_data = {}
        local themed_group = vim.api.nvim_create_augroup("EzdapThemedHl", { clear = true })
        vim.api.nvim_create_autocmd("ColorScheme", {
            group = themed_group,
            callback = function()
                for hl_name, fn in pairs(_themed_hl_data) do
                    vim.api.nvim_set_hl(0, hl_name, fn())
                end
            end,
        })
    end
    _themed_hl_data[name] = spec_fn
    vim.api.nvim_set_hl(0, name, spec_fn())
end

---Return `basename` if no buffer has that name, otherwise `basename#1`, `basename#2`, …
---@param basename string
---@return string
function M.unique_buf_name(basename)
    local name = basename
    local n    = 0
    while vim.fn.bufnr(name) ~= -1 do
        n    = n + 1
        name = basename .. "#" .. n
    end
    return name
end

return M
