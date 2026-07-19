-- Java — expects an external debug server (e.g. started by nvim-jdtls). Unlike
-- `remote`, this adapter also wants the JVM's JDWP endpoint echoed into the attach
-- body. com.microsoft.java.debug reads `hostName`/`port` (not `host`); the field
-- set follows microsoft/vscode-java-debug's attach configuration.
---@type ezdap.AdapterDef
return {
    host    = "127.0.0.1",
    port    = 0,
    request = "attach",
    profiles       = {
        -- `host`/`port` fill both the JDWP body fields (hostName/port) and the
        -- task-level connection (this adapter's own def carries host/port, so
        -- it connects to the java-debug server over TCP too).
        attach_server = {
            description = "attach to an external java-debug server (e.g. via nvim-jdtls)",
            request = "attach",
            inputs = {
                host = { type = "string", format = "host", description = "JDWP host of the debug server" },
                port = { type = "integer", format = "port", description = "JDWP port of the debug server" },
            },
            build = function(params, connect, inputs)
                params.hostName = inputs.host
                params.port     = inputs.port
                params.timeout  = 30000
                connect.host = inputs.host
                connect.port = inputs.port
            end,
        },
    },
}
