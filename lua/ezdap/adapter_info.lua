---@brief The adapter reference behind `:Debug adapter_info`.
---
---An adapter definition documents itself: every mode carries a `description`
---and a `request`, every input a type, a format, its `choices` and a line on
---what it means (see `ezdap.adapters`' `ezdap.Input`). This module is the
---reader for that — it renders the registered definitions as text and shows it
---in a float, so the same declaration that `:Debug run` validates against and
---`new_run_file` seeds from is also what the docs say.
---
---Nothing here is written by hand, so an adapter you wrote yourself, or a
---definition you edited in your own config, documents itself exactly as the
---shipped ones do.

local schema = require("ezdap.schema")

local M = {}

---Gap between the columns of an input row.
local _GUTTER = 2

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
---part of what the input means, and completion is not available in a float.
---@param input ezdap.Input
---@return string
local function _description_of(input)
    local text = input.description or ""
    if input.choices and #input.choices > 0 then
        local listed = "one of " .. table.concat(input.choices, ", ")
        text = text == "" and listed or (listed .. "; " .. text)
    end
    return text
end

---One mode's block: its heading, then a row per declared input. Required inputs
---sort first and are starred, since those are the ones a run fails without.
---@param adapter string
---@param mode_name string
---@param out string[]  appended to
local function _mode_block(adapter, mode_name, out)
    local mode = schema.mode(adapter, mode_name)
    if not mode then return end

    local head = ("%s (%s)"):format(mode_name, mode.request or "?")
    if mode.description and mode.description ~= "" then
        head = head .. "  " .. mode.description
    end
    out[#out + 1] = head

    local specs = schema.mode_inputs(adapter, mode_name)
    local names = schema.mode_input_names(adapter, mode_name)
    if #names == 0 then
        out[#out + 1] = "    (no inputs)"
        return
    end

    -- Required first, then alphabetical, matching the order `new_run_file`
    -- writes them in: what must be answered, then what may be.
    table.sort(names, function(a, b)
        local ra, rb = specs[a].required or false, specs[b].required or false
        if ra ~= rb then return ra end
        return a < b
    end)

    local labels, types, name_w, type_w = {}, {}, 0, 0
    for i, name in ipairs(names) do
        labels[i] = specs[name].required and (name .. "*") or name
        types[i]  = _type_of(specs[name])
        name_w    = math.max(name_w, #labels[i])
        type_w    = math.max(type_w, #types[i])
    end

    for i, name in ipairs(names) do
        local row = ("    %-" .. name_w .. "s%s%-" .. type_w .. "s"):format(
            labels[i], (" "):rep(_GUTTER), types[i])
        local desc = _description_of(specs[name])
        if desc ~= "" then row = row .. (" "):rep(_GUTTER) .. desc end
        out[#out + 1] = (row:gsub("%s+$", ""))
    end
end

---How the adapter is reached: the process it starts, the server it connects to,
---or the setup that provisions one on use. Nil when the definition says none.
---@param def ezdap.AdapterDef
---@return string?
local function _reached_by(def)
    if def.command then
        local cmd = def.command
        return type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd)
    end
    if def.host or def.port then
        return ("%s:%s"):format(def.host or "", def.port and tostring(def.port) or "")
    end
    if def.setup then return "provisioned on use" end
    return nil
end

---Every registered adapter, one line each: its name and the modes it declares.
---What `adapter_info` shows when it is not asked about one in particular.
---@return string[]
function M.overview()
    local registry = require("ezdap.adapters")
    local names = vim.tbl_keys(registry)
    table.sort(names)

    local width = 0
    for _, name in ipairs(names) do width = math.max(width, #name) end

    local out = { ("adapters (%d)"):format(#names), "" }
    for _, name in ipairs(names) do
        local modes = schema.mode_names(name)
        out[#out + 1] = ("%-" .. width .. "s%s%s"):format(
            name, (" "):rep(_GUTTER),
            #modes > 0 and table.concat(modes, ", ") or "(no modes)")
    end
    vim.list_extend(out, {
        "",
        (":%s adapter_info <adapter> for its modes and their inputs")
        :format(require("ezdap.config").command),
    })
    return out
end

---One adapter's reference: how it is reached, then a block per mode. `mode_name`
---narrows it to that one mode. Returns nil plus a message when the adapter or
---mode is not registered.
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

    local out = { adapter }
    local reached = _reached_by(def)
    if reached then out[#out + 1] = reached end

    if #names == 0 then
        out[#out + 1] = ""
        out[#out + 1] = "declares no modes"
        return out
    end

    for _, name in ipairs(names) do
        out[#out + 1] = ""
        _mode_block(adapter, name, out)
    end

    -- The star is only worth explaining where one is actually shown.
    for _, line in ipairs(out) do
        if line:match("^    %S+%*") then
            vim.list_extend(out, { "", "* required" })
            break
        end
    end
    return out
end

---Show the adapter reference in a float: every adapter when `adapter` is nil,
---otherwise that adapter's modes and their inputs, narrowed to `mode_name` when
---given. The entry point behind `:Debug adapter_info`.
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
            vim.notify("[ezdap] adapter_info: " .. tostring(err), vim.log.levels.ERROR)
            return
        end
        title = mode_name and (adapter .. " " .. mode_name) or adapter
    end
    require("ezdap.util.floatwin").open(table.concat(lines, "\n"), { title = title })
end

return M
