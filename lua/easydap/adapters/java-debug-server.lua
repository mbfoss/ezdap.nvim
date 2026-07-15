-- Java — expects an external debug server (e.g. started by nvim-jdtls). Unlike
-- `remote`, this adapter also wants the JVM's JDWP endpoint echoed into the attach
-- body. com.microsoft.java.debug reads `hostName`/`port` (not `host`); the field
-- set follows microsoft/vscode-java-debug's attach configuration.
---@type easydap.AdapterDef
return {
    host    = "127.0.0.1",
    port    = 0,
    request = "attach",
    configurations = {
        -- `host`/`port` fill both the JDWP body fields (hostName/port) and the
        -- task-level connection (this adapter's own def carries host/port, so
        -- it connects to the java-debug server over TCP too).
        attach = {
            description = "attach to an external java-debug server (e.g. via nvim-jdtls)",
            request = "attach",
            inputs = {
                host = { type = "host", description = "JDWP host of the debug server" },
                port = { type = "port", description = "JDWP port of the debug server" },
            },
            template = {
                hostName = "127.0.0.1",
                port     = 5005,
                timeout  = 30000,
            },
            fill = function(params, inputs)
                params.hostName = inputs.host
                params.port     = inputs.port
                params.timeout  = 30000
            end,
            connect = function(inputs)
                return { host = inputs.host, port = inputs.port }
            end,
        },
    },
}
