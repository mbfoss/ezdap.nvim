-- Generic TCP attach — connect to a DAP server already listening on host:port.
-- host/port live at the task level (they set the connection), so the attach body
-- itself stays minimal.
---@type easydap.AdapterDef
return {
    host    = "127.0.0.1",
    port    = 0,
    request = "attach",
    presets = {
        connect = {
            request    = "attach",
            parameters = {},
            connect    = { host = "{host}", port = "{port}" },
        },
    },
}
