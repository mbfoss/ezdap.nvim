-- PHP — listens for an Xdebug connection; there is no program to launch. Listen-mode
-- settings follow xdebug/vscode-php-debug's launch.json reference.
---@type ezdap.AdapterDef
return {
    command = "php-debug-adapter",
    profiles       = {
        listen = {
            description = "listen for an incoming Xdebug connection",
            request = "launch",
            inputs = {
                cwd = { type = "string", format = "cwd", description = "working directory" },
            },
            build = function(params, _, inputs)
                params.type = "php"
                params.name = "Listen for Xdebug"
                params.cwd  = inputs.cwd
                params.port = 9003
            end,
        },
    },
}
