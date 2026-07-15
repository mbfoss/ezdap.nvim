-- Generic TCP attach — connect to a DAP server already listening on host:port.
-- host/port live at the task level (they set the connection), so the attach body
-- itself stays minimal.
---@type easydap.AdapterDef
return {
    host    = "127.0.0.1",
    port    = 0,
    request = "attach",
    configurations = {
        connect = {
            description = "attach to a DAP server listening on host:port",
            request    = "attach",
            inputs = {
                host = { type = "host", description = "DAP server host" },
                port = { type = "port", description = "DAP server port" },
            },
            template = {},
            connect = function(inputs)
                return { host = inputs.host, port = inputs.port }
            end,
        },
    },
}
