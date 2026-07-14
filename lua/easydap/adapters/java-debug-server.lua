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
            request = "attach",
            parameters = {
                hostName = "{host:host}",
                port     = "{port:port}",
                timeout  = 30000,
            },
            connect = { host = "{host}", port = "{port}" },
        },
    },
}
