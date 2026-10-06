-- Generic TCP attach: connect to a DAP server already listening on host:port.
-- host/port live at the task level (they set the connection), so the attach body
-- itself stays minimal. The one adapter ndebug ships.

local shared = require("ndebug.shared")

---@type ndebug.AdapterDef
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
                    completion = { "localhost", "127.0.0.1", "::1", "::" },
                },
                port = { type = "integer", description = "DAP server port" },
            },
            build = function(parameters)
                local port, err = shared.resolve_port(parameters.port)
                if err then return nil, err end
                return {}, { host = parameters.host, port = port }
            end,
        },
    },
}
