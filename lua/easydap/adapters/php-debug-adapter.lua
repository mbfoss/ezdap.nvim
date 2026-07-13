-- PHP — listens for an Xdebug connection; there is no program to launch. Listen-mode
-- settings follow xdebug/vscode-php-debug's launch.json reference.
---@type easydap.AdapterDef
return {
    command       = "php-debug-adapter",
    launch_schema = {
        type           = { default = "php", fixed = true },
        name           = { default = "Listen for Xdebug", fixed = true },
        cwd            = {
            type = "string",
            kind = "dir",
            role = "cwd",
            desc = "working directory",
            default = function()
                return vim.fn.getcwd()
            end
        },
        port           = { type = "integer", kind = "port", desc = "port to listen for Xdebug", default = 9003 },
        hostname       = { type = "string", kind = "host", desc = "address to bind when listening" },
        stopOnEntry    = { type = "boolean", desc = "break at the beginning of the script", default = false },
        pathMappings   = { type = "table", desc = "server<->local source path maps" },
        log            = { type = "boolean", desc = "log adapter<->client communication to the debug console" },
        maxConnections = { type = "integer", desc = "max parallel debugging sessions to accept" },
        ignore         = { type = "list", desc = "glob patterns of files to ignore errors from" },
        skipFiles      = { type = "list", desc = "glob patterns to skip while stepping" },
    },
}
