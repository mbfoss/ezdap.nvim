---@brief Ephemeral inspect popup: evaluates an expression and shows its value as
---a lazily-expandable tree in a temporary floating window. Built on the same
---TreeBuffer as the DebugView, but throwaway — the buffer/window are wiped as
---soon as the float is left or dismissed.

local TreeBuffer = require("easydap.ui.TreeBuffer")
local manager    = require("easydap.manager")
local config     = require("easydap.config")
local str_util   = require("easydap.tk.strutil")
local ui_util    = require("easydap.util.ui_util")

local M = {}

---@class easydap.ui.InspectView.NodeData
---@field name string
---@field value string?
---@field variablesReference number?
---@field is_root boolean?

---Render one value node: `name = value` (root) / `name: value` (child). Mirrors
---the DebugView variable/expression styling.
---@param data easydap.ui.InspectView.NodeData?
---@return string[][], string[][]
local function _format_node(data)
    if not data then return {}, {} end
    local chunks = {}
    chunks[#chunks + 1] = { data.name }
    chunks[#chunks + 1] = { data.is_root and " = " or ": ", "NonText" }
    local val = str_util.crop_for_ui(tostring(data.value or ""):gsub("\n", "⏎"), config.debug_value_max_len)
    chunks[#chunks + 1] = { val, "@string" }
    return chunks, {}
end

---Open the inspect float for `expr`, evaluated in the active session. No-op with a
---warning when there is no session, nothing to inspect, or the evaluation fails.
---@param expr string
function M.open(expr)
    if not expr or expr == "" then
        vim.notify("[dap] nothing to inspect", vim.log.levels.WARN)
        return
    end
    local sess = manager.session()
    if not sess then
        vim.notify("[dap] no active session", vim.log.levels.WARN)
        return
    end

    manager.evaluate(expr, "hover", function(body, err)
        if err or not body then
            vim.notify("[dap] " .. expr .. ": " .. (err or "not available"), vim.log.levels.WARN)
            return
        end

        local tree = TreeBuffer.new({
            filetype  = "easydap-inspect",
            formatter = function(_, data, _) return _format_node(data) end,
        })

        -- Track which nodes' children have already been fetched so re-expanding a
        -- collapsed node doesn't re-request.
        local loaded = {}

        local win ---@type integer?

        ---Resize the float to fit its current content, capped to 80% of the editor.
        local function fit()
            if not win or not vim.api.nvim_win_is_valid(win) then return end
            local buf = tree:get_bufnr()
            if buf <= 0 then return end
            local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
            local w = 20
            for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
            w = math.min(w + 1, math.floor(vim.o.columns * 0.8))
            local h = math.min(math.max(#lines, 1), math.floor(vim.o.lines * 0.8))
            pcall(vim.api.nvim_win_set_width, win, w)
            pcall(vim.api.nvim_win_set_height, win, h)
        end

        ---Fetch and attach the children of the node at `parent_id`.
        ---@param parent_id any
        ---@param ref number
        local function load_children(parent_id, ref)
            loaded[parent_id] = true
            local tmp = { variablesReference = ref }
            sess:fetch_variables(tmp, function()
                local children = {}
                for i, var in ipairs(tmp.variables or {}) do
                    local expandable = var.variablesReference and var.variablesReference > 0
                    children[#children + 1] = {
                        id         = parent_id .. "::" .. (var.name or i) .. "#" .. i,
                        expandable = expandable,
                        expanded   = false,
                        data       = {
                            name               = var.name or "?",
                            value              = var.value,
                            variablesReference = var.variablesReference,
                        },
                    }
                end
                tree:set_children(parent_id, children)
                fit()
            end)
        end

        tree:subscribe({
            on_toggle = function(id, data, expanded)
                if not expanded then
                    fit()
                    return
                end
                if data and data.variablesReference and data.variablesReference > 0 and not loaded[id] then
                    load_children(id, data.variablesReference)
                else
                    fit()
                end
            end,
        })

        local buf = tree:create_buffer(function() end)
        tree:add_item(nil, {
            id         = "0",
            expandable = body.variablesReference and body.variablesReference > 0 or false,
            expanded   = false,
            data       = {
                name               = expr,
                value              = body.result,
                variablesReference = body.variablesReference,
                is_root            = true,
            },
        })

        local ui_w, ui_h = vim.o.columns, vim.o.lines
        ---@type vim.api.keyset.win_config
        local win_opts = {
            relative  = "editor",
            width     = math.floor(ui_w * 0.4),
            height    = 1,
            style     = "minimal",
            border    = "rounded",
            title     = " " .. expr .. " ",
            title_pos = "center",
        }
        win_opts.row = math.floor((ui_h - win_opts.height) / 2)
        win_opts.col = math.floor((ui_w - win_opts.width) / 2)

        local close
        win = ui_util.create_window(buf, true, win_opts, function() win = nil end)
        close = function()
            if win and vim.api.nvim_win_is_valid(win) then
                vim.api.nvim_win_close(win, true)
            end
        end

        vim.wo[win].wrap = false
        vim.wo[win].winfixbuf = true
        vim.wo[win].winhighlight = "NormalFloat:NormalFloat,FloatBorder:FloatBorder,FloatTitle:FloatTitle"

        vim.keymap.set("n", "q", close, { buffer = buf, silent = true })
        vim.keymap.set("n", "<Esc>", close, { buffer = buf, silent = true })
        vim.api.nvim_create_autocmd("WinLeave", {
            buffer = buf,
            once   = true,
            callback = close,
        })

        fit()
    end)
end

return M
