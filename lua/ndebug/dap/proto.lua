---@meta
---@brief DAP (Debug Adapter Protocol) specification types.

---https://microsoft.github.io/debug-adapter-protocol/specification
---Transcribed from `debugProtocol.json` in microsoft/debug-adapter-protocol
---(MIT): names and types only, none of the spec's own prose.

-- Primitive aliases

assert(false, "should not require() a meta file")

---@alias ndebug.dap.proto.SteppingGranularity "statement"|"line"|"instruction"
---@alias ndebug.dap.proto.OutputCategory "console"|"important"|"stdout"|"stderr"|"telemetry"|string
---@alias ndebug.dap.proto.ChecksumAlgorithm "MD5"|"SHA1"|"SHA256"|"timestamp"
---@alias ndebug.dap.proto.DataBreakpointAccessType "read"|"write"|"readWrite"
---@alias ndebug.dap.proto.StartMethod "launch"|"attach"|"attachForSuspendedLaunch"
---@alias ndebug.dap.proto.SourcePresentationHint "normal"|"emphasize"|"deemphasize"
---@alias ndebug.dap.proto.StackFramePresentationHint "normal"|"label"|"subtle"
---@alias ndebug.dap.proto.ScopePresentationHint "arguments"|"locals"|"registers"|"returnValue"|string
---@alias ndebug.dap.proto.VariablePresentationHintKind "property"|"method"|"class"|"data"|"event"|"baseClass"|"innerClass"|"interface"|"mostDerivedClass"|"virtual"|"dataBreakpoint"|string
---@alias ndebug.dap.proto.VariablePresentationHintVisibility "public"|"private"|"protected"|"internal"|"final"
---@alias ndebug.dap.proto.DisassembledInstructionPresentationHint "normal"|"invalid"
---@alias ndebug.dap.proto.EvaluateContext "watch"|"repl"|"hover"|"clipboard"|"variables"|string
---@alias ndebug.dap.proto.CompletionItemType "method"|"function"|"constructor"|"field"|"variable"|"class"|"interface"|"module"|"property"|"unit"|"value"|"enum"|"keyword"|"snippet"|"text"|"color"|"file"|"reference"|"customcolor"
---@alias ndebug.dap.proto.InvalidatedAreas "all"|"stacks"|"threads"|"variables"|string
---@alias ndebug.dap.proto.ThreadEventReason "started"|"exited"|string
---@alias ndebug.dap.proto.BreakpointEventReason "changed"|"new"|"removed"|string
---@alias ndebug.dap.proto.ModuleEventReason "new"|"changed"|"removed"
---@alias ndebug.dap.proto.LoadedSourceEventReason "new"|"changed"|"removed"
---@alias ndebug.dap.proto.BreakpointModeApplicability "source"|"exception"|"data"|"instruction"

-- Base data types

---@class ndebug.dap.proto.Checksum
---@field algorithm ndebug.dap.proto.ChecksumAlgorithm
---@field checksum  string

---@class ndebug.dap.proto.Source
---@field name?             string
---@field path?             string
---@field sourceReference?  integer
---@field presentationHint? ndebug.dap.proto.SourcePresentationHint
---@field origin?           string
---@field sources?          ndebug.dap.proto.Source[]
---@field adapterData?      any
---@field checksums?        ndebug.dap.proto.Checksum[]
---@field id?               integer|string  -- adapter extension: used by some adapters for source correlation

---@class ndebug.dap.proto.Thread
---@field id   integer
---@field name string

---@class ndebug.dap.proto.StackFrameFormat
---@field hex?             boolean
---@field parameters?      boolean
---@field parameterTypes?  boolean
---@field parameterNames?  boolean
---@field parameterValues? boolean
---@field line?            boolean
---@field module?          boolean
---@field includeAll?      boolean

---@class ndebug.dap.proto.StackFrame
---@field id                           integer
---@field name                         string
---@field source?                      ndebug.dap.proto.Source
---@field line                         integer
---@field column                       integer
---@field endLine?                     integer
---@field endColumn?                   integer
---@field canRestart?                  boolean
---@field instructionPointerReference? string
---@field moduleId?                    integer|string
---@field presentationHint?            ndebug.dap.proto.StackFramePresentationHint

---@class ndebug.dap.proto.Scope
---@field name               string
---@field presentationHint?  ndebug.dap.proto.ScopePresentationHint
---@field variablesReference integer
---@field namedVariables?    integer
---@field indexedVariables?  integer
---@field expensive          boolean
---@field source?            ndebug.dap.proto.Source
---@field line?              integer
---@field column?            integer
---@field endLine?           integer
---@field endColumn?         integer

---@class ndebug.dap.proto.VariablePresentationHint
---@field kind?       ndebug.dap.proto.VariablePresentationHintKind
---@field attributes? string[]
---@field visibility? ndebug.dap.proto.VariablePresentationHintVisibility
---@field lazy?       boolean

---@class ndebug.dap.proto.Variable
---@field name                          string
---@field value                         string
---@field type?                         string
---@field presentationHint?             ndebug.dap.proto.VariablePresentationHint
---@field evaluateName?                 string
---@field variablesReference            integer
---@field namedVariables?               integer
---@field indexedVariables?             integer
---@field memoryReference?              string
---@field declarationLocationReference? integer
---@field valueLocationReference?       integer

---@class ndebug.dap.proto.ValueFormat
---@field hex? boolean

---@class ndebug.dap.proto.Module
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

---@class ndebug.dap.proto.ColumnDescriptor
---@field attributeName  string
---@field label          string
---@field format?        string
---@field type?          "string"|"number"|"boolean"|"unixTimestampUTC"
---@field width?         integer

---@class ndebug.dap.proto.CompletionItem
---@field label          string
---@field text?          string
---@field sortText?      string
---@field detail?        string
---@field type?          ndebug.dap.proto.CompletionItemType
---@field start?         integer
---@field length?        integer
---@field selectionStart? integer
---@field selectionLength? integer

---@class ndebug.dap.proto.ExceptionBreakpointsFilter
---@field filter               string
---@field label                string
---@field description?         string
---@field default?             boolean
---@field supportsCondition?   boolean
---@field conditionDescription? string

---@class ndebug.dap.proto.ExceptionOptions
---@field path?     ndebug.dap.proto.ExceptionPathSegment[]
---@field breakMode ndebug.dap.ExceptionBreakMode

---@class ndebug.dap.proto.ExceptionPathSegment
---@field negate? boolean
---@field names   string[]

---@class ndebug.dap.proto.ExceptionFilterOptions
---@field filterId   string
---@field condition? string

---@class ndebug.dap.proto.ExceptionDetails
---@field message?        string
---@field typeName?       string
---@field fullTypeName?   string
---@field evaluateName?   string
---@field stackTrace?     string
---@field innerException? ndebug.dap.proto.ExceptionDetails[]

---@class ndebug.dap.proto.BreakpointLocation
---@field line        integer
---@field column?     integer
---@field endLine?    integer
---@field endColumn?  integer

---Adapter response for a single breakpoint (e.g. from setBreakpoints).
---@class ndebug.dap.proto.Breakpoint
---@field id?          integer
---@field verified     boolean
---@field message?     string
---@field source?      ndebug.dap.proto.Source
---@field line?        integer
---@field column?      integer
---@field endLine?     integer
---@field endColumn?   integer
---@field instructionReference? string
---@field offset?      integer
---@field reason?      string

---Wire-format breakpoint sent in setBreakpoints.
---@class ndebug.dap.proto.SourceBreakpoint
---@field line          integer
---@field column?       integer
---@field condition?    string
---@field hitCondition? string
---@field logMessage?   string
---@field mode?         string

---Wire-format breakpoint sent in setFunctionBreakpoints.
---@class ndebug.dap.proto.FunctionBreakpoint
---@field name          string
---@field condition?    string
---@field hitCondition? string

---@class ndebug.dap.proto.DataBreakpoint
---@field dataId        string
---@field accessType?   ndebug.dap.proto.DataBreakpointAccessType
---@field condition?    string
---@field hitCondition? string

---@class ndebug.dap.proto.InstructionBreakpoint
---@field instructionReference string
---@field offset?              integer
---@field condition?           string
---@field hitCondition?        string
---@field mode?                string

---@class ndebug.dap.proto.BreakpointMode
---@field mode        string
---@field label       string
---@field description? string
---@field appliesTo?  ndebug.dap.proto.BreakpointModeApplicability[]

---@class ndebug.dap.proto.GotoTarget
---@field id                      integer
---@field label                   string
---@field line                    integer
---@field column?                 integer
---@field endLine?                integer
---@field endColumn?              integer
---@field instructionPointerReference? string

---@class ndebug.dap.proto.StepInTarget
---@field id    integer
---@field label string
---@field line?   integer
---@field column? integer
---@field endLine? integer
---@field endColumn? integer

---@class ndebug.dap.proto.DisassembledInstruction
---@field address           string
---@field instructionBytes? string
---@field instruction       string
---@field symbol?           string
---@field location?         ndebug.dap.proto.Source
---@field line?             integer
---@field column?           integer
---@field endLine?          integer
---@field endColumn?        integer
---@field presentationHint? ndebug.dap.proto.DisassembledInstructionPresentationHint

-- Capabilities

---@class ndebug.dap.proto.Capabilities
---@field supportsConfigurationDoneRequest?      boolean
---@field supportsFunctionBreakpoints?           boolean
---@field supportsConditionalBreakpoints?        boolean
---@field supportsHitConditionalBreakpoints?     boolean
---@field supportsEvaluateForHovers?             boolean
---@field exceptionBreakpointFilters?            ndebug.dap.proto.ExceptionBreakpointsFilter[]
---@field supportsStepBack?                      boolean
---@field supportsSetVariable?                   boolean
---@field supportsRestartFrame?                  boolean
---@field supportsGotoTargetsRequest?            boolean
---@field supportsStepInTargetsRequest?          boolean
---@field supportsCompletionsRequest?            boolean
---@field completionTriggerCharacters?           string[]
---@field supportsModulesRequest?                boolean
---@field additionalModuleColumns?               ndebug.dap.proto.ColumnDescriptor[]
---@field supportedChecksumAlgorithms?           ndebug.dap.proto.ChecksumAlgorithm[]
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
---@field breakpointModes?                       ndebug.dap.proto.BreakpointMode[]
---@field supportsANSIStyling?                   boolean
---@field supportsStartDebuggingRequest?         boolean
---@field supportsArgsCanBeInterpretedByShell?   boolean

-- Event bodies

---@class ndebug.dap.proto.StoppedEventBody
---@field reason             string
---@field description?       string
---@field threadId?          integer
---@field preserveFocusHint? boolean
---@field text?              string
---@field allThreadsStopped? boolean
---@field hitBreakpointIds?  integer[]

---@class ndebug.dap.proto.ContinuedEventBody
---@field threadId             integer
---@field allThreadsContinued? boolean

---@class ndebug.dap.proto.ExitedEventBody
---@field exitCode integer

---@class ndebug.dap.proto.TerminatedEventBody
---@field restart? any

---@class ndebug.dap.proto.ThreadEventBody
---@field threadId integer
---@field reason   ndebug.dap.proto.ThreadEventReason

---@class ndebug.dap.proto.OutputEventBody
---@field category?           ndebug.dap.proto.OutputCategory
---@field output              string
---@field group?              "start"|"startCollapsed"|"end"
---@field variablesReference? integer
---@field source?             ndebug.dap.proto.Source
---@field line?               integer
---@field column?             integer
---@field data?               any

---@class ndebug.dap.proto.BreakpointEventBody
---@field reason     ndebug.dap.proto.BreakpointEventReason
---@field breakpoint ndebug.dap.proto.Breakpoint

---@class ndebug.dap.proto.ModuleEventBody
---@field reason ndebug.dap.proto.ModuleEventReason
---@field module ndebug.dap.proto.Module

---@class ndebug.dap.proto.LoadedSourceEventBody
---@field reason ndebug.dap.proto.LoadedSourceEventReason
---@field source ndebug.dap.proto.Source

---@class ndebug.dap.proto.ProcessEventBody
---@field name             string
---@field systemProcessId? integer
---@field isLocalProcess?  boolean
---@field startMethod?     ndebug.dap.proto.StartMethod
---@field pointerSize?     integer

---@class ndebug.dap.proto.CapabilitiesEventBody
---@field capabilities ndebug.dap.proto.Capabilities

---@class ndebug.dap.proto.ProgressStartEventBody
---@field progressId  string
---@field title       string
---@field requestId?  integer
---@field cancellable? boolean
---@field message?    string
---@field percentage? number

---@class ndebug.dap.proto.ProgressUpdateEventBody
---@field progressId string
---@field message?   string
---@field percentage? number

---@class ndebug.dap.proto.ProgressEndEventBody
---@field progressId string
---@field message?   string

---@class ndebug.dap.proto.InvalidatedEventBody
---@field areas?    ndebug.dap.proto.InvalidatedAreas[]
---@field threadId? integer
---@field stackFrameId? integer

---@class ndebug.dap.proto.MemoryEventBody
---@field memoryReference string
---@field offset          integer
---@field count           integer

-- Request arguments

---@class ndebug.dap.proto.InitializeRequestArguments
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

---@class ndebug.dap.proto.ConfigurationDoneArguments

---@class ndebug.dap.proto.LaunchRequestArguments
---@field noDebug?  boolean
---@field restart?  any
---[any adapter-specific keys]

---@class ndebug.dap.proto.AttachRequestArguments
---@field restart?  any
---[any adapter-specific keys]

---@class ndebug.dap.proto.RestartArguments
---@field arguments? ndebug.dap.proto.LaunchRequestArguments|ndebug.dap.proto.AttachRequestArguments

---@class ndebug.dap.proto.DisconnectArguments
---@field restart?           boolean
---@field terminateDebuggee? boolean
---@field suspendDebuggee?   boolean

---@class ndebug.dap.proto.TerminateArguments
---@field restart? boolean

---@class ndebug.dap.proto.BreakpointLocationsArguments
---@field source    ndebug.dap.proto.Source
---@field line      integer
---@field column?   integer
---@field endLine?  integer
---@field endColumn? integer

---@class ndebug.dap.proto.SetBreakpointsArguments
---@field source          ndebug.dap.proto.Source
---@field breakpoints?    ndebug.dap.proto.SourceBreakpoint[]
---@field lines?          integer[]
---@field sourceModified? boolean

---@class ndebug.dap.proto.SetFunctionBreakpointsArguments
---@field breakpoints ndebug.dap.proto.FunctionBreakpoint[]

---@class ndebug.dap.proto.SetExceptionBreakpointsArguments
---@field filters          string[]
---@field filterOptions?   ndebug.dap.proto.ExceptionFilterOptions[]
---@field exceptionOptions? ndebug.dap.proto.ExceptionOptions[]

---@class ndebug.dap.proto.DataBreakpointInfoArguments
---@field variablesReference? integer
---@field name                string
---@field frameId?            integer
---@field bytes?              integer
---@field asAddress?          boolean
---@field mode?               string

---@class ndebug.dap.proto.SetDataBreakpointsArguments
---@field breakpoints ndebug.dap.proto.DataBreakpoint[]

---@class ndebug.dap.proto.SetInstructionBreakpointsArguments
---@field breakpoints ndebug.dap.proto.InstructionBreakpoint[]

-- For the execution-control requests below, `threadId` is required on the wire
-- but optional here: the ndebug Session methods fill it from the active thread
-- when omitted (see session.lua).

---@class ndebug.dap.proto.ContinueArguments
---@field threadId?     integer
---@field singleThread? boolean

---@class ndebug.dap.proto.NextArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field granularity?  ndebug.dap.proto.SteppingGranularity

---@class ndebug.dap.proto.StepInArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field targetId?     integer
---@field granularity?  ndebug.dap.proto.SteppingGranularity

---@class ndebug.dap.proto.StepOutArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field granularity?  ndebug.dap.proto.SteppingGranularity

---@class ndebug.dap.proto.StepBackArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field granularity?  ndebug.dap.proto.SteppingGranularity

---@class ndebug.dap.proto.ReverseContinueArguments
---@field threadId?     integer
---@field singleThread? boolean

---@class ndebug.dap.proto.GotoArguments
---@field threadId? integer
---@field targetId  integer

---@class ndebug.dap.proto.RestartFrameArguments
---@field frameId integer

---@class ndebug.dap.proto.PauseArguments
---@field threadId? integer

---@class ndebug.dap.proto.StackTraceArguments
---@field threadId    integer
---@field startFrame? integer
---@field levels?     integer
---@field format?     ndebug.dap.proto.StackFrameFormat

---@class ndebug.dap.proto.ScopesArguments
---@field frameId integer

---@class ndebug.dap.proto.VariablesArguments
---@field variablesReference integer
---@field filter?            "indexed"|"named"
---@field start?             integer
---@field count?             integer
---@field format?            ndebug.dap.proto.ValueFormat

---@class ndebug.dap.proto.SetVariableArguments
---@field variablesReference integer
---@field name               string
---@field value              string
---@field format?            ndebug.dap.proto.ValueFormat

---@class ndebug.dap.proto.SourceArguments
---@field source?          ndebug.dap.proto.Source
---@field sourceReference  integer

---@class ndebug.dap.proto.TerminateThreadsArguments
---@field threadIds? integer[]

---@class ndebug.dap.proto.ModulesArguments
---@field startModule? integer
---@field moduleCount? integer

---@class ndebug.dap.proto.EvaluateArguments
---@field expression string
---@field frameId?   integer
---@field context?   ndebug.dap.proto.EvaluateContext
---@field format?    ndebug.dap.proto.ValueFormat

---@class ndebug.dap.proto.SetExpressionArguments
---@field expression string
---@field value      string
---@field frameId?   integer
---@field format?    ndebug.dap.proto.ValueFormat

---@class ndebug.dap.proto.StepInTargetsArguments
---@field frameId integer

---@class ndebug.dap.proto.GotoTargetsArguments
---@field source  ndebug.dap.proto.Source
---@field line    integer
---@field column? integer

---@class ndebug.dap.proto.CompletionsArguments
---@field frameId? integer
---@field text     string
---@field column   integer
---@field line?    integer

---@class ndebug.dap.proto.ExceptionInfoArguments
---@field threadId? integer  -- required on the wire; ndebug defaults it to the active thread

---@class ndebug.dap.proto.ReadMemoryArguments
---@field memoryReference string
---@field offset?         integer
---@field count           integer

---@class ndebug.dap.proto.WriteMemoryArguments
---@field memoryReference string
---@field offset?         integer
---@field allowPartial?   boolean
---@field data            string

---@class ndebug.dap.proto.DisassembleArguments
---@field memoryReference       string
---@field offset?               integer
---@field instructionOffset?    integer
---@field instructionCount      integer
---@field resolveSymbols?       boolean

---@class ndebug.dap.proto.CancelArguments
---@field requestId?  integer
---@field progressId? string

-- Response bodies

---@class ndebug.dap.proto.BreakpointLocationsResponseBody
---@field breakpoints ndebug.dap.proto.BreakpointLocation[]

---@class ndebug.dap.proto.SetBreakpointsResponseBody
---@field breakpoints ndebug.dap.proto.Breakpoint[]

---@class ndebug.dap.proto.SetFunctionBreakpointsResponseBody
---@field breakpoints ndebug.dap.proto.Breakpoint[]

---@class ndebug.dap.proto.SetExceptionBreakpointsResponseBody
---@field breakpoints? ndebug.dap.proto.Breakpoint[]

---@class ndebug.dap.proto.DataBreakpointInfoResponseBody
---@field dataId      string|nil
---@field description string
---@field accessTypes? ndebug.dap.proto.DataBreakpointAccessType[]
---@field canPersist?  boolean

---@class ndebug.dap.proto.SetDataBreakpointsResponseBody
---@field breakpoints ndebug.dap.proto.Breakpoint[]

---@class ndebug.dap.proto.SetInstructionBreakpointsResponseBody
---@field breakpoints ndebug.dap.proto.Breakpoint[]

---@class ndebug.dap.proto.ContinueResponseBody
---@field allThreadsContinued? boolean

---@class ndebug.dap.proto.StackTraceResponseBody
---@field stackFrames  ndebug.dap.proto.StackFrame[]
---@field totalFrames? integer

---@class ndebug.dap.proto.ScopesResponseBody
---@field scopes ndebug.dap.proto.Scope[]

---@class ndebug.dap.proto.VariablesResponseBody
---@field variables ndebug.dap.proto.Variable[]

---@class ndebug.dap.proto.SetVariableResponseBody
---@field value               string
---@field type?               string
---@field variablesReference? integer
---@field namedVariables?     integer
---@field indexedVariables?   integer
---@field memoryReference?    string
---@field valueLocationReference? integer

---@class ndebug.dap.proto.SourceResponseBody
---@field content  string
---@field mimeType? string

---@class ndebug.dap.proto.ThreadsResponseBody
---@field threads ndebug.dap.proto.Thread[]

---@class ndebug.dap.proto.TerminateThreadsResponseBody

---@class ndebug.dap.proto.ModulesResponseBody
---@field modules       ndebug.dap.proto.Module[]
---@field totalModules? integer

---@class ndebug.dap.proto.LoadedSourcesResponseBody
---@field sources ndebug.dap.proto.Source[]

---@class ndebug.dap.proto.EvaluateResponseBody
---@field result                        string
---@field type?                         string
---@field presentationHint?             ndebug.dap.proto.VariablePresentationHint
---@field variablesReference            integer
---@field namedVariables?               integer
---@field indexedVariables?             integer
---@field memoryReference?              string
---@field valueLocationReference?       integer
---@field declarationLocationReference? integer

---@class ndebug.dap.proto.SetExpressionResponseBody
---@field value               string
---@field type?               string
---@field presentationHint?   ndebug.dap.proto.VariablePresentationHint
---@field variablesReference? integer
---@field namedVariables?     integer
---@field indexedVariables?   integer
---@field memoryReference?    string
---@field valueLocationReference? integer

---@class ndebug.dap.proto.StepInTargetsResponseBody
---@field targets ndebug.dap.proto.StepInTarget[]

---@class ndebug.dap.proto.GotoTargetsResponseBody
---@field targets ndebug.dap.proto.GotoTarget[]

---@class ndebug.dap.proto.CompletionsResponseBody
---@field targets ndebug.dap.proto.CompletionItem[]

---@class ndebug.dap.proto.ExceptionInfoResponseBody
---@field exceptionId  string
---@field description? string
---@field breakMode    ndebug.dap.ExceptionBreakMode
---@field details?     ndebug.dap.proto.ExceptionDetails

---@class ndebug.dap.proto.ReadMemoryResponseBody
---@field address          string
---@field unreadableBytes? integer
---@field data?            string

---@class ndebug.dap.proto.WriteMemoryResponseBody
---@field offset?         integer
---@field bytesWritten?   integer

---@class ndebug.dap.proto.DisassembleResponseBody
---@field instructions ndebug.dap.proto.DisassembledInstruction[]

-- Adapter-initiated request args / response bodies

---@class ndebug.dap.proto.RunInTerminalRequestArguments
---@field kind?   "integrated"|"external"
---@field title?  string
---@field cwd     string
---@field args    string[]
---@field env?    table<string, string>  -- spec allows string|null (null = unset), but we only support string values
---@field argsCanBeInterpretedByShell? boolean

---@class ndebug.dap.proto.RunInTerminalResponseBody
---@field processId?      integer
---@field shellProcessId? integer

---@class ndebug.dap.proto.StartDebuggingRequestArguments
---@field configuration table<string, any>
---@field request       "launch"|"attach"

return {}
