local S = require("easydap.adapters._shared")

-- codelldb (vscode-lldb) — its own key set, distinct from lldb-dap. The command
-- hooks, source remapping and evaluator settings are shared by launch and attach;
-- the field set follows the CodeLLDB MANUAL
-- (https://github.com/vadimcn/codelldb/blob/master/MANUAL.md). codelldb uses
-- `terminal` (not `runInTerminal`) to pick the debuggee's stdio destination.
---@type table<string, easydap.ParamSpec>
local _common = {
    initCommands          = S.lldb_cmds("LLDB commands executed on debugger startup (no target yet)"),
    targetCreateCommands  = S.lldb_cmds("LLDB commands executed to create the debug target"),
    preRunCommands        = S.lldb_cmds("LLDB commands executed just before launch/attach"),
    processCreateCommands = S.lldb_cmds("LLDB commands executed to create/attach the process"),
    postRunCommands       = S.lldb_cmds("LLDB commands executed just after launch/attach"),
    exitCommands          = S.lldb_cmds("LLDB commands executed at the end of the session"),
    expressions           = {
        type = "string",
        kind = "enum",
        enum = { "simple", "python", "native" },
        desc = "default expression evaluator type"
    },
    sourceMap             = { type = "table", desc = "source path re-mappings (dictionary)" },
    relativePathBase      = { type = "string", kind = "dir", desc = "base dir for resolving relative source paths" },
    sourceLanguages       = { type = "list", desc = "source languages used in the program" },
    breakpointMode        = {
        type = "string",
        kind = "enum",
        enum = { "path", "file" },
        desc = "how source breakpoints resolve locations"
    },
}

---@type easydap.AdapterDef
return {
    command       = "codelldb",
    launch_schema = vim.tbl_extend("error", {
        type        = { default = "lldb", fixed = true },
        program     = S.program,
        args        = S.args,
        cwd         = S.cwd,
        env         = S.env,
        envFile     = { type = "string", kind = "file", desc = "file with additional environment variables" },
        stdio       = { type = "list", desc = "stdio redirection targets, in order [stdin, stdout, stderr]" },
        terminal    = {
            type = "string",
            kind = "enum",
            enum = { "console", "integrated", "external" },
            default = "integrated",
            desc = "destination for the debuggee's stdio streams"
        },
        stopOnEntry = { type = "boolean", desc = "stop the debuggee immediately after launch", default = false },
    }, _common),
    attach_schema = vim.tbl_extend("error", {
        type        = { default = "lldb", fixed = true },
        program     = { type = "string", kind = "file", desc = "path to the executable on the host" },
        pid         = { type = "integer", role = "pid", desc = "process id to attach to (omit to locate a running instance)" },
        waitFor     = { type = "boolean", desc = "wait for the process to launch" },
        stopOnEntry = { type = "boolean", desc = "stop the debuggee immediately after attaching" },
    }, _common),
}
