local M = {}

---@type table<string, fun(): vim.api.keyset.highlight>
local _specs = {}

---@type integer?
local _group

-- Named off this module's own table address, so a second loaded copy (e.g. a
-- separate vendoring) gets a distinct augroup instead of clearing this one's.
local _group_name = "ezdap_themed_hl_" .. (tostring(_specs):match("0x%x+") or "0")

---@return integer
local function _ensure_group()
    if _group then return _group end
    _group = vim.api.nvim_create_augroup(_group_name, { clear = true })
    vim.api.nvim_create_autocmd("ColorScheme", {
        group = _group,
        callback = function()
            for name, fn in pairs(_specs) do
                vim.api.nvim_set_hl(0, name, fn())
            end
        end,
    })
    return _group
end

---Define a highlight group whose attributes depend on the current colorscheme.
---@param name string
---@param spec_fn fun(): vim.api.keyset.highlight
function M.define_themed_hl(name, spec_fn)
    _ensure_group()
    _specs[name] = spec_fn
    vim.api.nvim_set_hl(0, name, spec_fn())
end

return M
