-- PHP — listens for an Xdebug connection; there is no program to launch. Listen-mode
-- settings follow xdebug/vscode-php-debug's launch.json reference.
---@type easydap.AdapterDef
return {
    command = "php-debug-adapter",
    configurations = {
        listen = {
            description = "listen for an incoming Xdebug connection",
            request = "launch",
            parameters = {
                type = "php",
                name = "Listen for Xdebug",
                cwd  = "{cwd:cwd}",
                port = 9003,
            },
        },
    },
}
