---@brief A bounded stack of undo entries.
---An entry is a group of callbacks that together revert one user action;
---undoing runs them in reverse registration order.

---@class ezdap.util.UndoStack
---@field private _entries fun()[][]
---@field private _limit   integer
---@field private _open    fun()[]?  group currently collecting pushes
local UndoStack = {}
UndoStack.__index = UndoStack

---@param limit integer?  max entries kept, oldest dropped first (default 50)
---@return ezdap.util.UndoStack
function UndoStack.new(limit)
    return setmetatable({ _entries = {}, _limit = limit or 50 }, UndoStack)
end

---Register an undo callback. Joins the open group if `group()` is running,
---otherwise becomes an entry of its own.
---@param undo fun()
function UndoStack:push(undo)
    if self._open then
        self._open[#self._open + 1] = undo
        return
    end
    self:_add({ undo })
end

---Run `fn` with a group open, so every `push()` it makes undoes as one action.
---Nothing is recorded if `fn` pushes nothing. Groups don't nest: a `group()`
---inside a `group()` keeps collecting into the outer one.
---@param fn fun()
function UndoStack:group(fn)
    if self._open then return fn() end
    local entry = {}
    self._open = entry
    local ok, err = pcall(fn)
    self._open = nil
    if #entry > 0 then self:_add(entry) end
    if not ok then error(err, 0) end
end

---Revert the most recent entry.
---@return boolean  false if the stack was empty
function UndoStack:undo()
    local entry = table.remove(self._entries)
    if not entry then return false end
    for i = #entry, 1, -1 do
        entry[i]()
    end
    return true
end

function UndoStack:clear()
    self._entries = {}
    self._open = nil
end

---@return boolean
function UndoStack:is_empty()
    return #self._entries == 0
end

---@private
---@param entry fun()[]
function UndoStack:_add(entry)
    self._entries[#self._entries + 1] = entry
    if #self._entries > self._limit then table.remove(self._entries, 1) end
end

return UndoStack
