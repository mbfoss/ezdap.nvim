---@brief The adapter reference behind `:Debug adapters`.
---
---An adapter definition documents itself: every mode carries a `description`
---and a `request`, every input a type, a format, its `choices` and a line on
---what it means (see `ezdap.adapters`' `ezdap.Input`). This module is the
---reader for that — it renders the registered definitions as markdown and shows
---it in a float, so the same declaration that `:Debug run` validates against and
---`new_run_file` seeds from is also what the docs say.
---
---Nothing here is written by hand, so an adapter you wrote yourself, or a
---definition you edited in your own config, documents itself exactly as the
---shipped ones do.

local schema = require("ezdap.schema")

local M = {}

---Cell text, with the one character a markdown table row cannot hold escaped.
---@param text string
---@return string
local function _cell(text)
    return (text:gsub("|", "\\|"))
end

---A markdown table, its columns padded to a common width so the source reads as
---a table too. Cells carry no inline markup: the float conceals it, and a
---concealed delimiter narrows the row it is on but not the header above it.
---@param headers string[]
---@param rows string[][]
---@param out string[]  appended to
local function _table(headers, rows, out)
    local widths = {}
    for i, head in ipairs(headers) do widths[i] = #head end
    for _, row in ipairs(rows) do
        for i, cell in ipairs(row) do widths[i] = math.max(widths[i] or 0, #cell) end
    end

    local function line(cells)
        local parts = {}
        for i = 1, #headers do
            parts[i] = ("%-" .. widths[i] .. "s"):format(cells[i] or "")
        end
        return "| " .. table.concat(parts, " | ") .. " |"
    end

    out[#out + 1] = line(headers)
    local rule = {}
    for i = 1, #headers do rule[i] = ("-"):rep(widths[i]) end
    out[#out + 1] = line(rule)
    for _, row in ipairs(rows) do out[#out + 1] = line(row) end
end

---How an input's value is written, in the `type[ format]` shape a definition
---declares it: the scalar's own pair, or the entry type of a collection.
---@param input ezdap.Input
---@return string
local function _type_of(input)
    local kind = input.type or "string"
    if kind == "list" or kind == "map" then
        local item = input.item_format or input.item_type
        return item and (kind .. " of " .. item) or kind
    end
    -- A format may stand in the type slot (`type = "port"`), and then it has
    -- already said everything the pair would.
    if input.format and input.format ~= kind then
        return kind .. " " .. input.format
    end
    return kind
end

---An input's description, with its enumerated values folded in — the set is
---part of what the input means, and completion is not available in a float —
---behind a `[required]` marker for the inputs a run fails without.
---@param input ezdap.Input
---@return string
local function _description_of(input)
    local text = input.description or ""
    if input.choices and #input.choices > 0 then
        local listed = "one of " .. table.concat(input.choices, ", ")
        text = text == "" and listed or (listed .. "; " .. text)
    end
    if input.required then
        text = text == "" and "[required]" or ("[required] " .. text)
    end
    return text
end

---One mode's block: its heading, then a row per declared input. Required inputs
---sort first, since those are the ones a run fails without.
---@param adapter string
---@param mode_name string
---@param out string[]  appended to
local function _mode_block(adapter, mode_name, out)
    local mode = schema.mode(adapter, mode_name)
    if not mode then return end

    out[#out + 1] = ("## %s (%s)"):format(mode_name, mode.request or "?")
    if mode.description and mode.description ~= "" then
        out[#out + 1] = ""
        out[#out + 1] = _cell(mode.description)
    end
    out[#out + 1] = ""

    local specs = schema.mode_inputs(adapter, mode_name)
    local names = schema.mode_input_names(adapter, mode_name)
    if #names == 0 then
        out[#out + 1] = "(no inputs)"
        return
    end

    -- Required first, then alphabetical, matching the order `new_run_file`
    -- writes them in: what must be answered, then what may be.
    table.sort(names, function(a, b)
        local ra, rb = specs[a].required or false, specs[b].required or false
        if ra ~= rb then return ra end
        return a < b
    end)

    local rows = {}
    for i, name in ipairs(names) do
        rows[i] = {
            name,
            _cell(_type_of(specs[name])),
            _cell(_description_of(specs[name])),
        }
    end
    _table({ "input", "type", "description" }, rows, out)
end

---Every registered adapter, one row each: its name and the modes it declares.
---What `:Debug adapters` shows when it is not asked about one in particular.
---@return string[]
function M.overview()
    local registry = require("ezdap.adapters")
    local names = vim.tbl_keys(registry)
    table.sort(names)

    local out = { ("## adapters (%d)"):format(#names), "" }
    local rows = {}
    for i, name in ipairs(names) do
        local modes = schema.mode_names(name)
        rows[i] = {
            name,
            #modes > 0 and _cell(table.concat(modes, ", ")) or "(none)",
        }
    end
    _table({ "adapter", "modes" }, rows, out)
    vim.list_extend(out, {
        "",
        ("`:%s adapters <adapter>` for its modes and their inputs")
        :format(require("ezdap.config").command),
    })
    return out
end

---One adapter's reference: a block per mode. `mode_name` narrows it to that
---one mode. Returns nil plus a message when the adapter or mode is not
---registered.
---@param adapter string
---@param mode_name? string
---@return string[]? lines, string? err
function M.render(adapter, mode_name)
    local def = require("ezdap.adapters")[adapter]
    if not def then
        return nil, ("unknown adapter: %s (available: %s)")
            :format(adapter, table.concat(schema.adapters_with_modes(), ", "))
    end

    local names = schema.mode_names(adapter)
    if mode_name and mode_name ~= "" then
        if not vim.tbl_contains(names, mode_name) then
            return nil, ("adapter %s has no mode %q (available: %s)")
                :format(adapter, mode_name, table.concat(names, ", "))
        end
        names = { mode_name }
    end

    -- The float's title already names the adapter, so the body is modes only.
    if #names == 0 then return { "declares no modes" } end

    local out = {}
    for i, name in ipairs(names) do
        if i > 1 then out[#out + 1] = "" end
        _mode_block(adapter, name, out)
    end
    return out
end

---Show the adapter reference in a float: every adapter when `adapter` is nil,
---otherwise that adapter's modes and their inputs, narrowed to `mode_name` when
---given. The entry point behind `:Debug adapters`.
---@param adapter? string
---@param mode_name? string
function M.show(adapter, mode_name)
    local lines, title
    if not adapter or adapter == "" then
        lines, title = M.overview(), "adapters"
    else
        local err
        lines, err = M.render(adapter, mode_name)
        if not lines then
            vim.notify("[ezdap] adapters: " .. tostring(err), vim.log.levels.ERROR)
            return
        end
        title = mode_name and (adapter .. " " .. mode_name) or adapter
    end
    require("ezdap.util.floatwin").open(table.concat(lines, "\n"),
        { title = title, is_markdown = true })
end

return M
