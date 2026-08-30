---@brief The loaded DAP adapter definitions, `name → ezdap.AdapterDef`.
---
---A plain table, filled as definitions are read: `ezdap.load_adapter` puts one
---here the first time something asks for that adapter by name, and a name absent
---from it is one nothing has reached for yet, not one that does not exist —
---`ezdap.available_adapters()` is the list of what can be loaded. Assigning a
---definition here registers it by hand, no file needed.

-- adapter definition type in adapter_def.lua

---@type table<string, ezdap.AdapterDef>
return {}
