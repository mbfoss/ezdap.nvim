-- Java — expects an external debug server (e.g. started by nvim-jdtls). Unlike
-- `remote`, this adapter also wants the JVM's JDWP endpoint echoed into the attach
-- body. com.microsoft.java.debug reads `hostName`/`port` (not `host`); the field
-- set follows microsoft/vscode-java-debug's attach configuration.
---@type easydap.AdapterDef
return {
    host          = "127.0.0.1",
    port          = 0,
    request       = "attach",
    attach_schema = {
        hostName    = { type = "string", kind = "host", role = "host", desc = "JVM debug (JDWP) host", default = "localhost" },
        port        = { type = "integer", kind = "port", role = "port", desc = "JVM debug (JDWP) port" },
        timeout     = { type = "integer", desc = "attach timeout in milliseconds", default = 30000 },
        projectName = { type = "string", desc = "project name (helps resolve sources/classpaths)" },
    },
}
