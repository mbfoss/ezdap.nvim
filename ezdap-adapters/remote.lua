-- Generic TCP attach — connect to a DAP server already listening on host:port.
-- host/port live at the task level (they set the connection), so the attach body
-- itself stays minimal. The one adapter ezdap ships.

---@type ezdap.AdapterDef
return {
    host  = "127.0.0.1",
    port  = 0,
    modes = {
        connect = {
            description = "attach to a DAP server listening on host:port",
            request     = "attach",
            inputs      = {
                host = {
                    type = "string", description = "DAP server host",
                    choices = { "localhost", "127.0.0.1", "::1", "::" },
                },
                port = { type = "integer", format = "port", description = "DAP server port" },
            },
            build = function(inputs)
                return {}, { host = inputs.host, port = inputs.port }
            end,
        },
    },
}
