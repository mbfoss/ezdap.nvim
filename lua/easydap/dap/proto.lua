---@meta
---@brief DAP (Debug Adapter Protocol) specification types.

---Spec: https://microsoft.github.io/debug-adapter-protocol/specification

-- ── Primitive aliases ──────────────────────────────────────────────────────

assert(false, "should not require() a meta file")

---@alias easydap.dap.proto.SteppingGranularity "statement"|"line"|"instruction"
---@alias easydap.dap.proto.OutputCategory "console"|"important"|"stdout"|"stderr"|"telemetry"|string
---@alias easydap.dap.proto.ChecksumAlgorithm "MD5"|"SHA1"|"SHA256"|"timestamp"
---@alias easydap.dap.proto.DataBreakpointAccessType "read"|"write"|"readWrite"
---@alias easydap.dap.proto.StartMethod "launch"|"attach"|"attachForSuspendedLaunch"
---@alias easydap.dap.proto.SourcePresentationHint "normal"|"emphasize"|"deemphasize"
---@alias easydap.dap.proto.StackFramePresentationHint "normal"|"label"|"subtle"
---@alias easydap.dap.proto.ScopePresentationHint "arguments"|"locals"|"registers"|"returnValue"|string
---@alias easydap.dap.proto.VariablePresentationHintKind "property"|"method"|"class"|"data"|"event"|"baseClass"|"innerClass"|"interface"|"mostDerivedClass"|"virtual"|"dataBreakpoint"|string
---@alias easydap.dap.proto.VariablePresentationHintVisibility "public"|"private"|"protected"|"internal"|"final"
---@alias easydap.dap.proto.DisassembledInstructionPresentationHint "normal"|"invalid"
---@alias easydap.dap.proto.EvaluateContext "watch"|"repl"|"hover"|"clipboard"|"variables"|string
---@alias easydap.dap.proto.CompletionItemType "method"|"function"|"constructor"|"field"|"variable"|"class"|"interface"|"module"|"property"|"unit"|"value"|"enum"|"keyword"|"snippet"|"text"|"color"|"file"|"reference"|"customcolor"
---@alias easydap.dap.proto.InvalidatedAreas "all"|"stacks"|"threads"|"variables"|string
---@alias easydap.dap.proto.ThreadEventReason "started"|"exited"|string
---@alias easydap.dap.proto.BreakpointEventReason "changed"|"new"|"removed"|string
---@alias easydap.dap.proto.ModuleEventReason "new"|"changed"|"removed"
---@alias easydap.dap.proto.LoadedSourceEventReason "new"|"changed"|"removed"
---@alias easydap.dap.proto.BreakpointModeApplicability "source"|"exception"|"data"|"instruction"

-- ── Base data types ────────────────────────────────────────────────────────

---@class easydap.dap.proto.Checksum
---@field algorithm easydap.dap.proto.ChecksumAlgorithm
---@field checksum  string

---@class easydap.dap.proto.Source
---@field name?             string
---@field path?             string
---@field sourceReference?  integer
---@field presentationHint? easydap.dap.proto.SourcePresentationHint
---@field origin?           string
---@field sources?          easydap.dap.proto.Source[]
---@field adapterData?      any
---@field checksums?        easydap.dap.proto.Checksum[]
---@field id?               integer|string  -- adapter extension: used by some adapters for source correlation

---@class easydap.dap.proto.Thread
---@field id   integer
---@field name string

---@class easydap.dap.proto.StackFrameFormat
---@field hex?             boolean
---@field parameters?      boolean
---@field parameterTypes?  boolean
---@field parameterNames?  boolean
---@field parameterValues? boolean
---@field line?            boolean
---@field module?          boolean
---@field includeAll?      boolean

---@class easydap.dap.proto.StackFrame
---@field id                           integer
---@field name                         string
---@field source?                      easydap.dap.proto.Source
---@field line                         integer
---@field column                       integer
---@field endLine?                     integer
---@field endColumn?                   integer
---@field canRestart?                  boolean
---@field instructionPointerReference? string
---@field moduleId?                    integer|string
---@field presentationHint?            easydap.dap.proto.StackFramePresentationHint

---@class easydap.dap.proto.Scope
---@field name               string
---@field presentationHint?  easydap.dap.proto.ScopePresentationHint
---@field variablesReference integer
---@field namedVariables?    integer
---@field indexedVariables?  integer
---@field expensive          boolean
---@field source?            easydap.dap.proto.Source
---@field line?              integer
---@field column?            integer
---@field endLine?           integer
---@field endColumn?         integer

---@class easydap.dap.proto.VariablePresentationHint
---@field kind?       easydap.dap.proto.VariablePresentationHintKind
---@field attributes? string[]
---@field visibility? easydap.dap.proto.VariablePresentationHintVisibility
---@field lazy?       boolean

---@class easydap.dap.proto.Variable
---@field name                          string
---@field value                         string
---@field type?                         string
---@field presentationHint?             easydap.dap.proto.VariablePresentationHint
---@field evaluateName?                 string
---@field variablesReference            integer
---@field namedVariables?               integer
---@field indexedVariables?             integer
---@field memoryReference?              string
---@field declarationLocationReference? integer
---@field valueLocationReference?       integer

---@class easydap.dap.proto.ValueFormat
---@field hex? boolean

---@class easydap.dap.proto.Module
---@field id             integer|string
---@field name           string
---@field path?          string
---@field isOptimized?   boolean
---@field isUserCode?    boolean
---@field version?       string
---@field symbolStatus?  string
---@field symbolFilePath? string
---@field dateTimeStamp? string
---@field addressRange?  string

---@class easydap.dap.proto.ColumnDescriptor
---@field attributeName  string
---@field label          string
---@field format?        string
---@field type?          "string"|"number"|"boolean"|"unixTimestampUTC"
---@field width?         integer

---@class easydap.dap.proto.CompletionItem
---@field label          string
---@field text?          string
---@field sortText?      string
---@field detail?        string
---@field type?          easydap.dap.proto.CompletionItemType
---@field start?         integer
---@field length?        integer
---@field selectionStart? integer
---@field selectionLength? integer

---@class easydap.dap.proto.ExceptionBreakpointsFilter
---@field filter               string
---@field label                string
---@field description?         string
---@field default?             boolean
---@field supportsCondition?   boolean
---@field conditionDescription? string

---@class easydap.dap.proto.ExceptionOptions
---@field path?     easydap.dap.proto.ExceptionPathSegment[]
---@field breakMode easydap.dap.ExceptionBreakMode

---@class easydap.dap.proto.ExceptionPathSegment
---@field negate? boolean
---@field names   string[]

---@class easydap.dap.proto.ExceptionFilterOptions
---@field filterId   string
---@field condition? string

---@class easydap.dap.proto.ExceptionDetails
---@field message?        string
---@field typeName?       string
---@field fullTypeName?   string
---@field evaluateName?   string
---@field stackTrace?     string
---@field innerException? easydap.dap.proto.ExceptionDetails[]

---@class easydap.dap.proto.BreakpointLocation
---@field line        integer
---@field column?     integer
---@field endLine?    integer
---@field endColumn?  integer

---Adapter response for a single breakpoint (e.g. from setBreakpoints).
---@class easydap.dap.proto.Breakpoint
---@field id?          integer
---@field verified     boolean
---@field message?     string
---@field source?      easydap.dap.proto.Source
---@field line?        integer
---@field column?      integer
---@field endLine?     integer
---@field endColumn?   integer
---@field instructionReference? string
---@field offset?      integer
---@field reason?      string

---Wire-format breakpoint sent in setBreakpoints.
---@class easydap.dap.proto.SourceBreakpoint
---@field line          integer
---@field column?       integer
---@field condition?    string
---@field hitCondition? string
---@field logMessage?   string
---@field mode?         string

---Wire-format breakpoint sent in setFunctionBreakpoints.
---@class easydap.dap.proto.FunctionBreakpoint
---@field name          string
---@field condition?    string
---@field hitCondition? string

---@class easydap.dap.proto.DataBreakpoint
---@field dataId        string
---@field accessType?   easydap.dap.proto.DataBreakpointAccessType
---@field condition?    string
---@field hitCondition? string

---@class easydap.dap.proto.InstructionBreakpoint
---@field instructionReference string
---@field offset?              integer
---@field condition?           string
---@field hitCondition?        string
---@field mode?                string

---@class easydap.dap.proto.BreakpointMode
---@field mode        string
---@field label       string
---@field description? string
---@field appliesTo?  easydap.dap.proto.BreakpointModeApplicability[]

---@class easydap.dap.proto.GotoTarget
---@field id                      integer
---@field label                   string
---@field line                    integer
---@field column?                 integer
---@field endLine?                integer
---@field endColumn?              integer
---@field instructionPointerReference? string

---@class easydap.dap.proto.StepInTarget
---@field id    integer
---@field label string
---@field line?   integer
---@field column? integer
---@field endLine? integer
---@field endColumn? integer

---@class easydap.dap.proto.DisassembledInstruction
---@field address           string
---@field instructionBytes? string
---@field instruction       string
---@field symbol?           string
---@field location?         easydap.dap.proto.Source
---@field line?             integer
---@field column?           integer
---@field endLine?          integer
---@field endColumn?        integer
---@field presentationHint? easydap.dap.proto.DisassembledInstructionPresentationHint

-- ── Capabilities ───────────────────────────────────────────────────────────

---@class easydap.dap.proto.Capabilities
---@field supportsConfigurationDoneRequest?      boolean
---@field supportsFunctionBreakpoints?           boolean
---@field supportsConditionalBreakpoints?        boolean
---@field supportsHitConditionalBreakpoints?     boolean
---@field supportsEvaluateForHovers?             boolean
---@field exceptionBreakpointFilters?            easydap.dap.proto.ExceptionBreakpointsFilter[]
---@field supportsStepBack?                      boolean
---@field supportsSetVariable?                   boolean
---@field supportsRestartFrame?                  boolean
---@field supportsGotoTargetsRequest?            boolean
---@field supportsStepInTargetsRequest?          boolean
---@field supportsCompletionsRequest?            boolean
---@field completionTriggerCharacters?           string[]
---@field supportsModulesRequest?                boolean
---@field additionalModuleColumns?               easydap.dap.proto.ColumnDescriptor[]
---@field supportedChecksumAlgorithms?           easydap.dap.proto.ChecksumAlgorithm[]
---@field supportsRestartRequest?                boolean
---@field supportsExceptionOptions?              boolean
---@field supportsValueFormattingOptions?        boolean
---@field supportsExceptionInfoRequest?          boolean
---@field supportTerminateDebuggee?              boolean
---@field supportSuspendDebuggee?                boolean
---@field supportsDelayedStackTraceLoading?      boolean
---@field supportsLoadedSourcesRequest?          boolean
---@field supportsLogPoints?                     boolean
---@field supportsTerminateThreadsRequest?       boolean
---@field supportsSetExpression?                 boolean
---@field supportsTerminateRequest?              boolean
---@field supportsDataBreakpoints?               boolean
---@field supportsReadMemoryRequest?             boolean
---@field supportsWriteMemoryRequest?            boolean
---@field supportsDisassembleRequest?            boolean
---@field supportsCancelRequest?                 boolean
---@field supportsBreakpointLocationsRequest?    boolean
---@field supportsClipboardContext?              boolean
---@field supportsSteppingGranularity?           boolean
---@field supportsInstructionBreakpoints?        boolean
---@field supportsExceptionFilterOptions?        boolean
---@field supportsSingleThreadExecutionRequests? boolean
---@field supportsDataBreakpointBytes?           boolean
---@field breakpointModes?                       easydap.dap.proto.BreakpointMode[]
---@field supportsANSIStyling?                   boolean
---@field supportsStartDebuggingRequest?         boolean
---@field supportsArgsCanBeInterpretedByShell?   boolean

-- ── Event bodies ───────────────────────────────────────────────────────────

---@class easydap.dap.proto.StoppedEventBody
---@field reason             string
---@field description?       string
---@field threadId?          integer
---@field preserveFocusHint? boolean
---@field text?              string
---@field allThreadsStopped? boolean
---@field hitBreakpointIds?  integer[]

---@class easydap.dap.proto.ContinuedEventBody
---@field threadId             integer
---@field allThreadsContinued? boolean

---@class easydap.dap.proto.ExitedEventBody
---@field exitCode integer

---@class easydap.dap.proto.TerminatedEventBody
---@field restart? any

---@class easydap.dap.proto.ThreadEventBody
---@field threadId integer
---@field reason   easydap.dap.proto.ThreadEventReason

---@class easydap.dap.proto.OutputEventBody
---@field category?           easydap.dap.proto.OutputCategory
---@field output              string
---@field group?              "start"|"startCollapsed"|"end"
---@field variablesReference? integer
---@field source?             easydap.dap.proto.Source
---@field line?               integer
---@field column?             integer
---@field data?               any

---@class easydap.dap.proto.BreakpointEventBody
---@field reason     easydap.dap.proto.BreakpointEventReason
---@field breakpoint easydap.dap.proto.Breakpoint

---@class easydap.dap.proto.ModuleEventBody
---@field reason easydap.dap.proto.ModuleEventReason
---@field module easydap.dap.proto.Module

---@class easydap.dap.proto.LoadedSourceEventBody
---@field reason easydap.dap.proto.LoadedSourceEventReason
---@field source easydap.dap.proto.Source

---@class easydap.dap.proto.ProcessEventBody
---@field name             string
---@field systemProcessId? integer
---@field isLocalProcess?  boolean
---@field startMethod?     easydap.dap.proto.StartMethod
---@field pointerSize?     integer

---@class easydap.dap.proto.CapabilitiesEventBody
---@field capabilities easydap.dap.proto.Capabilities

---@class easydap.dap.proto.ProgressStartEventBody
---@field progressId  string
---@field title       string
---@field requestId?  integer
---@field cancellable? boolean
---@field message?    string
---@field percentage? number

---@class easydap.dap.proto.ProgressUpdateEventBody
---@field progressId string
---@field message?   string
---@field percentage? number

---@class easydap.dap.proto.ProgressEndEventBody
---@field progressId string
---@field message?   string

---@class easydap.dap.proto.InvalidatedEventBody
---@field areas?    easydap.dap.proto.InvalidatedAreas[]
---@field threadId? integer
---@field stackFrameId? integer

---@class easydap.dap.proto.MemoryEventBody
---@field memoryReference string
---@field offset          integer
---@field count           integer

-- ── Request arguments ──────────────────────────────────────────────────────

---@class easydap.dap.proto.InitializeRequestArguments
---@field clientID?                            string
---@field clientName?                          string
---@field adapterID                            string
---@field locale?                              string
---@field linesStartAt1?                       boolean
---@field columnsStartAt1?                     boolean
---@field pathFormat?                          "path"|"uri"|string
---@field supportsVariableType?                boolean
---@field supportsVariablePaging?              boolean
---@field supportsRunInTerminalRequest?        boolean
---@field supportsMemoryReferences?            boolean
---@field supportsProgressReporting?           boolean
---@field supportsInvalidatedEvent?            boolean
---@field supportsMemoryEvent?                 boolean
---@field supportsArgsCanBeInterpretedByShell? boolean
---@field supportsStartDebuggingRequest?       boolean
---@field supportsANSIStyling?                 boolean

---@class easydap.dap.proto.ConfigurationDoneArguments

---@class easydap.dap.proto.LaunchRequestArguments
---@field noDebug?  boolean
---@field restart?  any
---[any adapter-specific keys]

---@class easydap.dap.proto.AttachRequestArguments
---@field restart?  any
---[any adapter-specific keys]

---@class easydap.dap.proto.RestartArguments
---@field arguments? easydap.dap.proto.LaunchRequestArguments|easydap.dap.proto.AttachRequestArguments

---@class easydap.dap.proto.DisconnectArguments
---@field restart?           boolean
---@field terminateDebuggee? boolean
---@field suspendDebuggee?   boolean

---@class easydap.dap.proto.TerminateArguments
---@field restart? boolean

---@class easydap.dap.proto.BreakpointLocationsArguments
---@field source    easydap.dap.proto.Source
---@field line      integer
---@field column?   integer
---@field endLine?  integer
---@field endColumn? integer

---@class easydap.dap.proto.SetBreakpointsArguments
---@field source          easydap.dap.proto.Source
---@field breakpoints?    easydap.dap.proto.SourceBreakpoint[]
---@field lines?          integer[]
---@field sourceModified? boolean

---@class easydap.dap.proto.SetFunctionBreakpointsArguments
---@field breakpoints easydap.dap.proto.FunctionBreakpoint[]

---@class easydap.dap.proto.SetExceptionBreakpointsArguments
---@field filters          string[]
---@field filterOptions?   easydap.dap.proto.ExceptionFilterOptions[]
---@field exceptionOptions? easydap.dap.proto.ExceptionOptions[]

---@class easydap.dap.proto.DataBreakpointInfoArguments
---@field variablesReference? integer
---@field name                string
---@field frameId?            integer
---@field bytes?              integer
---@field asAddress?          boolean
---@field mode?               string

---@class easydap.dap.proto.SetDataBreakpointsArguments
---@field breakpoints easydap.dap.proto.DataBreakpoint[]

---@class easydap.dap.proto.SetInstructionBreakpointsArguments
---@field breakpoints easydap.dap.proto.InstructionBreakpoint[]

---@class easydap.dap.proto.ContinueArguments
---@field threadId      integer
---@field singleThread? boolean

---@class easydap.dap.proto.NextArguments
---@field threadId      integer
---@field singleThread? boolean
---@field granularity?  easydap.dap.proto.SteppingGranularity

---@class easydap.dap.proto.StepInArguments
---@field threadId      integer
---@field singleThread? boolean
---@field targetId?     integer
---@field granularity?  easydap.dap.proto.SteppingGranularity

---@class easydap.dap.proto.StepOutArguments
---@field threadId      integer
---@field singleThread? boolean
---@field granularity?  easydap.dap.proto.SteppingGranularity

---@class easydap.dap.proto.StepBackArguments
---@field threadId      integer
---@field singleThread? boolean
---@field granularity?  easydap.dap.proto.SteppingGranularity

---@class easydap.dap.proto.ReverseContinueArguments
---@field threadId      integer
---@field singleThread? boolean

---@class easydap.dap.proto.GotoArguments
---@field threadId integer
---@field targetId integer

---@class easydap.dap.proto.PauseArguments
---@field threadId integer

---@class easydap.dap.proto.StackTraceArguments
---@field threadId    integer
---@field startFrame? integer
---@field levels?     integer
---@field format?     easydap.dap.proto.StackFrameFormat

---@class easydap.dap.proto.ScopesArguments
---@field frameId integer

---@class easydap.dap.proto.VariablesArguments
---@field variablesReference integer
---@field filter?            "indexed"|"named"
---@field start?             integer
---@field count?             integer
---@field format?            easydap.dap.proto.ValueFormat

---@class easydap.dap.proto.SetVariableArguments
---@field variablesReference integer
---@field name               string
---@field value              string
---@field format?            easydap.dap.proto.ValueFormat

---@class easydap.dap.proto.SourceArguments
---@field source?          easydap.dap.proto.Source
---@field sourceReference  integer

---@class easydap.dap.proto.TerminateThreadsArguments
---@field threadIds? integer[]

---@class easydap.dap.proto.ModulesArguments
---@field startModule? integer
---@field moduleCount? integer

---@class easydap.dap.proto.EvaluateArguments
---@field expression string
---@field frameId?   integer
---@field context?   easydap.dap.proto.EvaluateContext
---@field format?    easydap.dap.proto.ValueFormat

---@class easydap.dap.proto.SetExpressionArguments
---@field expression string
---@field value      string
---@field frameId?   integer
---@field format?    easydap.dap.proto.ValueFormat

---@class easydap.dap.proto.StepInTargetsArguments
---@field frameId integer

---@class easydap.dap.proto.GotoTargetsArguments
---@field source  easydap.dap.proto.Source
---@field line    integer
---@field column? integer

---@class easydap.dap.proto.CompletionsArguments
---@field frameId? integer
---@field text     string
---@field column   integer
---@field line?    integer

---@class easydap.dap.proto.ExceptionInfoArguments
---@field threadId integer

---@class easydap.dap.proto.ReadMemoryArguments
---@field memoryReference string
---@field offset?         integer
---@field count           integer

---@class easydap.dap.proto.WriteMemoryArguments
---@field memoryReference string
---@field offset?         integer
---@field allowPartial?   boolean
---@field data            string

---@class easydap.dap.proto.DisassembleArguments
---@field memoryReference       string
---@field offset?               integer
---@field instructionOffset?    integer
---@field instructionCount      integer
---@field resolveSymbols?       boolean

---@class easydap.dap.proto.CancelArguments
---@field requestId?  integer
---@field progressId? string

-- ── Response bodies ────────────────────────────────────────────────────────

---@class easydap.dap.proto.BreakpointLocationsResponseBody
---@field breakpoints easydap.dap.proto.BreakpointLocation[]

---@class easydap.dap.proto.SetBreakpointsResponseBody
---@field breakpoints easydap.dap.proto.Breakpoint[]

---@class easydap.dap.proto.SetFunctionBreakpointsResponseBody
---@field breakpoints easydap.dap.proto.Breakpoint[]

---@class easydap.dap.proto.SetExceptionBreakpointsResponseBody
---@field breakpoints? easydap.dap.proto.Breakpoint[]

---@class easydap.dap.proto.DataBreakpointInfoResponseBody
---@field dataId      string|nil
---@field description string
---@field accessTypes? easydap.dap.proto.DataBreakpointAccessType[]
---@field canPersist?  boolean

---@class easydap.dap.proto.SetDataBreakpointsResponseBody
---@field breakpoints easydap.dap.proto.Breakpoint[]

---@class easydap.dap.proto.SetInstructionBreakpointsResponseBody
---@field breakpoints easydap.dap.proto.Breakpoint[]

---@class easydap.dap.proto.ContinueResponseBody
---@field allThreadsContinued? boolean

---@class easydap.dap.proto.StackTraceResponseBody
---@field stackFrames  easydap.dap.proto.StackFrame[]
---@field totalFrames? integer

---@class easydap.dap.proto.ScopesResponseBody
---@field scopes easydap.dap.proto.Scope[]

---@class easydap.dap.proto.VariablesResponseBody
---@field variables easydap.dap.proto.Variable[]

---@class easydap.dap.proto.SetVariableResponseBody
---@field value               string
---@field type?               string
---@field variablesReference? integer
---@field namedVariables?     integer
---@field indexedVariables?   integer
---@field memoryReference?    string
---@field valueLocationReference? integer

---@class easydap.dap.proto.SourceResponseBody
---@field content  string
---@field mimeType? string

---@class easydap.dap.proto.ThreadsResponseBody
---@field threads easydap.dap.proto.Thread[]

---@class easydap.dap.proto.TerminateThreadsResponseBody

---@class easydap.dap.proto.ModulesResponseBody
---@field modules       easydap.dap.proto.Module[]
---@field totalModules? integer

---@class easydap.dap.proto.LoadedSourcesResponseBody
---@field sources easydap.dap.proto.Source[]

---@class easydap.dap.proto.EvaluateResponseBody
---@field result                        string
---@field type?                         string
---@field presentationHint?             easydap.dap.proto.VariablePresentationHint
---@field variablesReference            integer
---@field namedVariables?               integer
---@field indexedVariables?             integer
---@field memoryReference?              string
---@field valueLocationReference?       integer
---@field declarationLocationReference? integer

---@class easydap.dap.proto.SetExpressionResponseBody
---@field value               string
---@field type?               string
---@field presentationHint?   easydap.dap.proto.VariablePresentationHint
---@field variablesReference? integer
---@field namedVariables?     integer
---@field indexedVariables?   integer
---@field memoryReference?    string
---@field valueLocationReference? integer

---@class easydap.dap.proto.StepInTargetsResponseBody
---@field targets easydap.dap.proto.StepInTarget[]

---@class easydap.dap.proto.GotoTargetsResponseBody
---@field targets easydap.dap.proto.GotoTarget[]

---@class easydap.dap.proto.CompletionsResponseBody
---@field targets easydap.dap.proto.CompletionItem[]

---@class easydap.dap.proto.ExceptionInfoResponseBody
---@field exceptionId  string
---@field description? string
---@field breakMode    easydap.dap.ExceptionBreakMode
---@field details?     easydap.dap.proto.ExceptionDetails

---@class easydap.dap.proto.ReadMemoryResponseBody
---@field address          string
---@field unreadableBytes? integer
---@field data?            string

---@class easydap.dap.proto.WriteMemoryResponseBody
---@field offset?         integer
---@field bytesWritten?   integer

---@class easydap.dap.proto.DisassembleResponseBody
---@field instructions easydap.dap.proto.DisassembledInstruction[]

-- ── Adapter-initiated request args / response bodies ──────────────────────

---@class easydap.dap.proto.RunInTerminalRequestArguments
---@field kind?   "integrated"|"external"
---@field title?  string
---@field cwd     string
---@field args    string[]
---@field env?    table<string, string>  -- spec allows string|null (null = unset), but we only support string values
---@field argsCanBeInterpretedByShell? boolean

---@class easydap.dap.proto.RunInTerminalResponseBody
---@field processId?      integer
---@field shellProcessId? integer

---@class easydap.dap.proto.StartDebuggingRequestArguments
---@field configuration table<string, any>
---@field request       "launch"|"attach"

return {}
