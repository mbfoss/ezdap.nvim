-- Java — expects an external java-debug server (e.g. started by nvim-jdtls).
-- Two distinct endpoints are in play: the DAP connection to that server, and the
-- debuggee JVM's JDWP address, which com.microsoft.java.debug reads from the
-- attach body as `hostName`/`port` (not `host`).

---@type ezdap.AdapterDef
return {
    host     = "127.0.0.1",
    port     = 0,
    profiles = {
        attach_server = {
            description = "attach to an external java-debug server (e.g. via nvim-jdtls)",
            request = "attach",
            inputs = {
                jdwp_host    = { type = "string", format = "host", description = "JDWP host of the debuggee JVM" },
                jdwp_port    = { type = "integer", format = "port", required = true, description = "JDWP port of the debuggee JVM" },
                server_host  = { type = "string", format = "host", description = "host of the java-debug server (default 127.0.0.1)" },
                server_port  = { type = "integer", format = "port", required = true, description = "port the java-debug server listens on" },
                project_name = { type = "string", description = "project name used to resolve sources" },
                source_paths = { type = "table", format = "list", description = "extra source lookup paths" },
                timeout      = { type = "integer", description = "attach timeout in milliseconds" },
            },
            build = function(params, connect, inputs)
                params.hostName    = inputs.jdwp_host or "127.0.0.1"
                params.port        = inputs.jdwp_port
                params.projectName = inputs.project_name
                params.sourcePaths = inputs.source_paths
                params.timeout     = inputs.timeout or 30000
                connect.host = inputs.server_host or "127.0.0.1"
                connect.port = inputs.server_port
            end,
        },
    },
}
