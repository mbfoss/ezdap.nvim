local S = require("easydap.adapters._shared")

-- lldb-dap — the launch/attach parameters mirror the LLVM docs
-- (https://lldb.llvm.org/use/lldbdap.html). `_common` supplies the source
-- remapping / formatting / command-hook fields shared by both requests.
---@type table<string, easydap.ParamSpec>
local _common = {
    sourcePath                    = {
        type = "string",
        kind = "dir",
        desc = "remap './' so relative-source binaries resolve breakpoints"
    },
    sourceMap                     = {
        type = "table",
        desc = "source path re-mappings (array of [from, to] pairs)"
    },
    debuggerRoot                  = {
        type = "string",
        kind = "dir",
        desc = "working directory lldb-dap uses to locate sources/objects"
    },
    commandEscapePrefix           = {
        type = "string",
        desc = "prefix for running LLDB commands in the debug console (default '`')"
    },
    customFrameFormat             = { type = "string", desc = "format string for stack frame labels" },
    customThreadFormat            = { type = "string", desc = "format string for thread labels" },
    displayExtendedBacktrace      = { type = "boolean", desc = "enable language-specific extended backtraces" },
    enableAutoVariableSummaries   = { type = "boolean", desc = "auto-generate variable summaries when none exist" },
    enableSyntheticChildDebugging = { type = "boolean", desc = "show synthetic children alongside raw contents" },
    initCommands                  = S.lldb_cmds("LLDB commands run when the debugger starts"),
    preRunCommands                = S.lldb_cmds("LLDB commands run before launch/attach"),
    stopCommands                  = S.lldb_cmds("LLDB commands run after each stop"),
    exitCommands                  = S.lldb_cmds("LLDB commands run when the program exits"),
    terminateCommands             = S.lldb_cmds("LLDB commands run when the session ends"),
}

---@type easydap.AdapterDef
return {
    command       = "lldb-dap",
    launch_schema = vim.tbl_extend("error", {
        name           = { default = "lldb", fixed = true },
        type           = { default = "lldb-dap", fixed = true },
        program        = S.program,
        args           = S.args,
        cwd            = S.cwd,
        env            = S.env,
        stdio          = { type = "list", desc = "redirection targets for the program's stdio streams" },
        stopOnEntry    = { type = "boolean", desc = "stop at entry", default = false },
        console        = {
            type = "string",
            kind = "enum",
            default = "integratedTerminal",
            enum = { "internalConsole", "integratedTerminal", "externalTerminal" },
            desc = "where to launch the program (supersedes runInTerminal)"
        },
        launchCommands = S.lldb_cmds("LLDB commands run to launch the program (replaces the default launch)"),
    }, _common),
    attach_schema = vim.tbl_extend("error", {
        type                = { default = "lldb", fixed = true },
        program             = { type = "string", kind = "file", desc = "path to the executable (helps locate the binary)" },
        pid                 = { type = "integer", role = "pid", desc = "PID to attach to" },
        waitFor             = { type = "boolean", desc = "wait for the next process matching `program` to launch" },
        attachCommands      = S.lldb_cmds("LLDB commands run to perform the attach (replaces the default attach)"),
        coreFile            = { type = "string", kind = "file", desc = "core file to debug" },
        ["gdb-remote-port"] = { type = "integer", kind = "port", role = "port", desc = "TCP port to attach to on a remote system" },
        ["gdb-remote-host"] = { type = "string", kind = "host", role = "host", desc = "hostname of the remote system (default localhost)" },
    }, _common),
}
