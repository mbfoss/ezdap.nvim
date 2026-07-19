---@meta
---@brief DAP (Debug Adapter Protocol) specification types.

---https://microsoft.github.io/debug-adapter-protocol/specification

-- Primitive aliases

assert(false, "should not require() a meta file")

---@alias ezdap.dap.proto.SteppingGranularity "statement"|"line"|"instruction"
---@alias ezdap.dap.proto.OutputCategory "console"|"important"|"stdout"|"stderr"|"telemetry"|string
---@alias ezdap.dap.proto.ChecksumAlgorithm "MD5"|"SHA1"|"SHA256"|"timestamp"
---@alias ezdap.dap.proto.DataBreakpointAccessType "read"|"write"|"readWrite"
---@alias ezdap.dap.proto.StartMethod "launch"|"attach"|"attachForSuspendedLaunch"
---@alias ezdap.dap.proto.SourcePresentationHint "normal"|"emphasize"|"deemphasize"
---@alias ezdap.dap.proto.StackFramePresentationHint "normal"|"label"|"subtle"
---@alias ezdap.dap.proto.ScopePresentationHint "arguments"|"locals"|"registers"|"returnValue"|string
---@alias ezdap.dap.proto.VariablePresentationHintKind "property"|"method"|"class"|"data"|"event"|"baseClass"|"innerClass"|"interface"|"mostDerivedClass"|"virtual"|"dataBreakpoint"|string
---@alias ezdap.dap.proto.VariablePresentationHintVisibility "public"|"private"|"protected"|"internal"|"final"
---@alias ezdap.dap.proto.DisassembledInstructionPresentationHint "normal"|"invalid"
---@alias ezdap.dap.proto.EvaluateContext "watch"|"repl"|"hover"|"clipboard"|"variables"|string
---@alias ezdap.dap.proto.CompletionItemType "method"|"function"|"constructor"|"field"|"variable"|"class"|"interface"|"module"|"property"|"unit"|"value"|"enum"|"keyword"|"snippet"|"text"|"color"|"file"|"reference"|"customcolor"
---@alias ezdap.dap.proto.InvalidatedAreas "all"|"stacks"|"threads"|"variables"|string
---@alias ezdap.dap.proto.ThreadEventReason "started"|"exited"|string
---@alias ezdap.dap.proto.BreakpointEventReason "changed"|"new"|"removed"|string
---@alias ezdap.dap.proto.ModuleEventReason "new"|"changed"|"removed"
---@alias ezdap.dap.proto.LoadedSourceEventReason "new"|"changed"|"removed"
---@alias ezdap.dap.proto.BreakpointModeApplicability "source"|"exception"|"data"|"instruction"

-- Base data types

---@class ezdap.dap.proto.Checksum
---@field algorithm ezdap.dap.proto.ChecksumAlgorithm
---@field checksum  string

---@class ezdap.dap.proto.Source
---@field name?             string
---@field path?             string
---@field sourceReference?  integer
---@field presentationHint? ezdap.dap.proto.SourcePresentationHint
---@field origin?           string
---@field sources?          ezdap.dap.proto.Source[]
---@field adapterData?      any
---@field checksums?        ezdap.dap.proto.Checksum[]
---@field id?               integer|string  -- adapter extension: used by some adapters for source correlation

---@class ezdap.dap.proto.Thread
---@field id   integer
---@field name string

---@class ezdap.dap.proto.StackFrameFormat
---@field hex?             boolean
---@field parameters?      boolean
---@field parameterTypes?  boolean
---@field parameterNames?  boolean
---@field parameterValues? boolean
---@field line?            boolean
---@field module?          boolean
---@field includeAll?      boolean

---@class ezdap.dap.proto.StackFrame
---@field id                           integer
---@field name                         string
---@field source?                      ezdap.dap.proto.Source
---@field line                         integer
---@field column                       integer
---@field endLine?                     integer
---@field endColumn?                   integer
---@field canRestart?                  boolean
---@field instructionPointerReference? string
---@field moduleId?                    integer|string
---@field presentationHint?            ezdap.dap.proto.StackFramePresentationHint

---@class ezdap.dap.proto.Scope
---@field name               string
---@field presentationHint?  ezdap.dap.proto.ScopePresentationHint
---@field variablesReference integer
---@field namedVariables?    integer
---@field indexedVariables?  integer
---@field expensive          boolean
---@field source?            ezdap.dap.proto.Source
---@field line?              integer
---@field column?            integer
---@field endLine?           integer
---@field endColumn?         integer

---@class ezdap.dap.proto.VariablePresentationHint
---@field kind?       ezdap.dap.proto.VariablePresentationHintKind
---@field attributes? string[]
---@field visibility? ezdap.dap.proto.VariablePresentationHintVisibility
---@field lazy?       boolean

---@class ezdap.dap.proto.Variable
---@field name                          string
---@field value                         string
---@field type?                         string
---@field presentationHint?             ezdap.dap.proto.VariablePresentationHint
---@field evaluateName?                 string
---@field variablesReference            integer
---@field namedVariables?               integer
---@field indexedVariables?             integer
---@field memoryReference?              string
---@field declarationLocationReference? integer
---@field valueLocationReference?       integer

---@class ezdap.dap.proto.ValueFormat
---@field hex? boolean

---@class ezdap.dap.proto.Module
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

---@class ezdap.dap.proto.ColumnDescriptor
---@field attributeName  string
---@field label          string
---@field format?        string
---@field type?          "string"|"number"|"boolean"|"unixTimestampUTC"
---@field width?         integer

---@class ezdap.dap.proto.CompletionItem
---@field label          string
---@field text?          string
---@field sortText?      string
---@field detail?        string
---@field type?          ezdap.dap.proto.CompletionItemType
---@field start?         integer
---@field length?        integer
---@field selectionStart? integer
---@field selectionLength? integer

---@class ezdap.dap.proto.ExceptionBreakpointsFilter
---@field filter               string
---@field label                string
---@field description?         string
---@field default?             boolean
---@field supportsCondition?   boolean
---@field conditionDescription? string

---@class ezdap.dap.proto.ExceptionOptions
---@field path?     ezdap.dap.proto.ExceptionPathSegment[]
---@field breakMode ezdap.dap.ExceptionBreakMode

---@class ezdap.dap.proto.ExceptionPathSegment
---@field negate? boolean
---@field names   string[]

---@class ezdap.dap.proto.ExceptionFilterOptions
---@field filterId   string
---@field condition? string

---@class ezdap.dap.proto.ExceptionDetails
---@field message?        string
---@field typeName?       string
---@field fullTypeName?   string
---@field evaluateName?   string
---@field stackTrace?     string
---@field innerException? ezdap.dap.proto.ExceptionDetails[]

---@class ezdap.dap.proto.BreakpointLocation
---@field line        integer
---@field column?     integer
---@field endLine?    integer
---@field endColumn?  integer

---Adapter response for a single breakpoint (e.g. from setBreakpoints).
---@class ezdap.dap.proto.Breakpoint
---@field id?          integer
---@field verified     boolean
---@field message?     string
---@field source?      ezdap.dap.proto.Source
---@field line?        integer
---@field column?      integer
---@field endLine?     integer
---@field endColumn?   integer
---@field instructionReference? string
---@field offset?      integer
---@field reason?      string

---Wire-format breakpoint sent in setBreakpoints.
---@class ezdap.dap.proto.SourceBreakpoint
---@field line          integer
---@field column?       integer
---@field condition?    string
---@field hitCondition? string
---@field logMessage?   string
---@field mode?         string

---Wire-format breakpoint sent in setFunctionBreakpoints.
---@class ezdap.dap.proto.FunctionBreakpoint
---@field name          string
---@field condition?    string
---@field hitCondition? string

---@class ezdap.dap.proto.DataBreakpoint
---@field dataId        string
---@field accessType?   ezdap.dap.proto.DataBreakpointAccessType
---@field condition?    string
---@field hitCondition? string

---@class ezdap.dap.proto.InstructionBreakpoint
---@field instructionReference string
---@field offset?              integer
---@field condition?           string
---@field hitCondition?        string
---@field mode?                string

---@class ezdap.dap.proto.BreakpointMode
---@field mode        string
---@field label       string
---@field description? string
---@field appliesTo?  ezdap.dap.proto.BreakpointModeApplicability[]

---@class ezdap.dap.proto.GotoTarget
---@field id                      integer
---@field label                   string
---@field line                    integer
---@field column?                 integer
---@field endLine?                integer
---@field endColumn?              integer
---@field instructionPointerReference? string

---@class ezdap.dap.proto.StepInTarget
---@field id    integer
---@field label string
---@field line?   integer
---@field column? integer
---@field endLine? integer
---@field endColumn? integer

---@class ezdap.dap.proto.DisassembledInstruction
---@field address           string
---@field instructionBytes? string
---@field instruction       string
---@field symbol?           string
---@field location?         ezdap.dap.proto.Source
---@field line?             integer
---@field column?           integer
---@field endLine?          integer
---@field endColumn?        integer
---@field presentationHint? ezdap.dap.proto.DisassembledInstructionPresentationHint

-- Capabilities

---@class ezdap.dap.proto.Capabilities
---@field supportsConfigurationDoneRequest?      boolean
---@field supportsFunctionBreakpoints?           boolean
---@field supportsConditionalBreakpoints?        boolean
---@field supportsHitConditionalBreakpoints?     boolean
---@field supportsEvaluateForHovers?             boolean
---@field exceptionBreakpointFilters?            ezdap.dap.proto.ExceptionBreakpointsFilter[]
---@field supportsStepBack?                      boolean
---@field supportsSetVariable?                   boolean
---@field supportsRestartFrame?                  boolean
---@field supportsGotoTargetsRequest?            boolean
---@field supportsStepInTargetsRequest?          boolean
---@field supportsCompletionsRequest?            boolean
---@field completionTriggerCharacters?           string[]
---@field supportsModulesRequest?                boolean
---@field additionalModuleColumns?               ezdap.dap.proto.ColumnDescriptor[]
---@field supportedChecksumAlgorithms?           ezdap.dap.proto.ChecksumAlgorithm[]
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
---@field breakpointModes?                       ezdap.dap.proto.BreakpointMode[]
---@field supportsANSIStyling?                   boolean
---@field supportsStartDebuggingRequest?         boolean
---@field supportsArgsCanBeInterpretedByShell?   boolean

-- Event bodies

---@class ezdap.dap.proto.StoppedEventBody
---@field reason             string
---@field description?       string
---@field threadId?          integer
---@field preserveFocusHint? boolean
---@field text?              string
---@field allThreadsStopped? boolean
---@field hitBreakpointIds?  integer[]

---@class ezdap.dap.proto.ContinuedEventBody
---@field threadId             integer
---@field allThreadsContinued? boolean

---@class ezdap.dap.proto.ExitedEventBody
---@field exitCode integer

---@class ezdap.dap.proto.TerminatedEventBody
---@field restart? any

---@class ezdap.dap.proto.ThreadEventBody
---@field threadId integer
---@field reason   ezdap.dap.proto.ThreadEventReason

---@class ezdap.dap.proto.OutputEventBody
---@field category?           ezdap.dap.proto.OutputCategory
---@field output              string
---@field group?              "start"|"startCollapsed"|"end"
---@field variablesReference? integer
---@field source?             ezdap.dap.proto.Source
---@field line?               integer
---@field column?             integer
---@field data?               any

---@class ezdap.dap.proto.BreakpointEventBody
---@field reason     ezdap.dap.proto.BreakpointEventReason
---@field breakpoint ezdap.dap.proto.Breakpoint

---@class ezdap.dap.proto.ModuleEventBody
---@field reason ezdap.dap.proto.ModuleEventReason
---@field module ezdap.dap.proto.Module

---@class ezdap.dap.proto.LoadedSourceEventBody
---@field reason ezdap.dap.proto.LoadedSourceEventReason
---@field source ezdap.dap.proto.Source

---@class ezdap.dap.proto.ProcessEventBody
---@field name             string
---@field systemProcessId? integer
---@field isLocalProcess?  boolean
---@field startMethod?     ezdap.dap.proto.StartMethod
---@field pointerSize?     integer

---@class ezdap.dap.proto.CapabilitiesEventBody
---@field capabilities ezdap.dap.proto.Capabilities

---@class ezdap.dap.proto.ProgressStartEventBody
---@field progressId  string
---@field title       string
---@field requestId?  integer
---@field cancellable? boolean
---@field message?    string
---@field percentage? number

---@class ezdap.dap.proto.ProgressUpdateEventBody
---@field progressId string
---@field message?   string
---@field percentage? number

---@class ezdap.dap.proto.ProgressEndEventBody
---@field progressId string
---@field message?   string

---@class ezdap.dap.proto.InvalidatedEventBody
---@field areas?    ezdap.dap.proto.InvalidatedAreas[]
---@field threadId? integer
---@field stackFrameId? integer

---@class ezdap.dap.proto.MemoryEventBody
---@field memoryReference string
---@field offset          integer
---@field count           integer

-- Request arguments

---@class ezdap.dap.proto.InitializeRequestArguments
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

---@class ezdap.dap.proto.ConfigurationDoneArguments

---@class ezdap.dap.proto.LaunchRequestArguments
---@field noDebug?  boolean
---@field restart?  any
---[any adapter-specific keys]

---@class ezdap.dap.proto.AttachRequestArguments
---@field restart?  any
---[any adapter-specific keys]

---@class ezdap.dap.proto.RestartArguments
---@field arguments? ezdap.dap.proto.LaunchRequestArguments|ezdap.dap.proto.AttachRequestArguments

---@class ezdap.dap.proto.DisconnectArguments
---@field restart?           boolean
---@field terminateDebuggee? boolean
---@field suspendDebuggee?   boolean

---@class ezdap.dap.proto.TerminateArguments
---@field restart? boolean

---@class ezdap.dap.proto.BreakpointLocationsArguments
---@field source    ezdap.dap.proto.Source
---@field line      integer
---@field column?   integer
---@field endLine?  integer
---@field endColumn? integer

---@class ezdap.dap.proto.SetBreakpointsArguments
---@field source          ezdap.dap.proto.Source
---@field breakpoints?    ezdap.dap.proto.SourceBreakpoint[]
---@field lines?          integer[]
---@field sourceModified? boolean

---@class ezdap.dap.proto.SetFunctionBreakpointsArguments
---@field breakpoints ezdap.dap.proto.FunctionBreakpoint[]

---@class ezdap.dap.proto.SetExceptionBreakpointsArguments
---@field filters          string[]
---@field filterOptions?   ezdap.dap.proto.ExceptionFilterOptions[]
---@field exceptionOptions? ezdap.dap.proto.ExceptionOptions[]

---@class ezdap.dap.proto.DataBreakpointInfoArguments
---@field variablesReference? integer
---@field name                string
---@field frameId?            integer
---@field bytes?              integer
---@field asAddress?          boolean
---@field mode?               string

---@class ezdap.dap.proto.SetDataBreakpointsArguments
---@field breakpoints ezdap.dap.proto.DataBreakpoint[]

---@class ezdap.dap.proto.SetInstructionBreakpointsArguments
---@field breakpoints ezdap.dap.proto.InstructionBreakpoint[]

-- For the execution-control requests below, `threadId` is required on the wire
-- but optional here: the ezdap Session methods fill it from the active thread
-- when omitted (see session.lua).

---@class ezdap.dap.proto.ContinueArguments
---@field threadId?     integer
---@field singleThread? boolean

---@class ezdap.dap.proto.NextArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field granularity?  ezdap.dap.proto.SteppingGranularity

---@class ezdap.dap.proto.StepInArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field targetId?     integer
---@field granularity?  ezdap.dap.proto.SteppingGranularity

---@class ezdap.dap.proto.StepOutArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field granularity?  ezdap.dap.proto.SteppingGranularity

---@class ezdap.dap.proto.StepBackArguments
---@field threadId?     integer
---@field singleThread? boolean
---@field granularity?  ezdap.dap.proto.SteppingGranularity

---@class ezdap.dap.proto.ReverseContinueArguments
---@field threadId?     integer
---@field singleThread? boolean

---@class ezdap.dap.proto.GotoArguments
---@field threadId? integer
---@field targetId  integer

---@class ezdap.dap.proto.RestartFrameArguments
---@field frameId integer

---@class ezdap.dap.proto.PauseArguments
---@field threadId? integer

---@class ezdap.dap.proto.StackTraceArguments
---@field threadId    integer
---@field startFrame? integer
---@field levels?     integer
---@field format?     ezdap.dap.proto.StackFrameFormat

---@class ezdap.dap.proto.ScopesArguments
---@field frameId integer

---@class ezdap.dap.proto.VariablesArguments
---@field variablesReference integer
---@field filter?            "indexed"|"named"
---@field start?             integer
---@field count?             integer
---@field format?            ezdap.dap.proto.ValueFormat

---@class ezdap.dap.proto.SetVariableArguments
---@field variablesReference integer
---@field name               string
---@field value              string
---@field format?            ezdap.dap.proto.ValueFormat

---@class ezdap.dap.proto.SourceArguments
---@field source?          ezdap.dap.proto.Source
---@field sourceReference  integer

---@class ezdap.dap.proto.TerminateThreadsArguments
---@field threadIds? integer[]

---@class ezdap.dap.proto.ModulesArguments
---@field startModule? integer
---@field moduleCount? integer

---@class ezdap.dap.proto.EvaluateArguments
---@field expression string
---@field frameId?   integer
---@field context?   ezdap.dap.proto.EvaluateContext
---@field format?    ezdap.dap.proto.ValueFormat

---@class ezdap.dap.proto.SetExpressionArguments
---@field expression string
---@field value      string
---@field frameId?   integer
---@field format?    ezdap.dap.proto.ValueFormat

---@class ezdap.dap.proto.StepInTargetsArguments
---@field frameId integer

---@class ezdap.dap.proto.GotoTargetsArguments
---@field source  ezdap.dap.proto.Source
---@field line    integer
---@field column? integer

---@class ezdap.dap.proto.CompletionsArguments
---@field frameId? integer
---@field text     string
---@field column   integer
---@field line?    integer

---@class ezdap.dap.proto.ExceptionInfoArguments
---@field threadId? integer  -- required on the wire; ezdap defaults it to the active thread

---@class ezdap.dap.proto.ReadMemoryArguments
---@field memoryReference string
---@field offset?         integer
---@field count           integer

---@class ezdap.dap.proto.WriteMemoryArguments
---@field memoryReference string
---@field offset?         integer
---@field allowPartial?   boolean
---@field data            string

---@class ezdap.dap.proto.DisassembleArguments
---@field memoryReference       string
---@field offset?               integer
---@field instructionOffset?    integer
---@field instructionCount      integer
---@field resolveSymbols?       boolean

---@class ezdap.dap.proto.CancelArguments
---@field requestId?  integer
---@field progressId? string

-- Response bodies

---@class ezdap.dap.proto.BreakpointLocationsResponseBody
---@field breakpoints ezdap.dap.proto.BreakpointLocation[]

---@class ezdap.dap.proto.SetBreakpointsResponseBody
---@field breakpoints ezdap.dap.proto.Breakpoint[]

---@class ezdap.dap.proto.SetFunctionBreakpointsResponseBody
---@field breakpoints ezdap.dap.proto.Breakpoint[]

---@class ezdap.dap.proto.SetExceptionBreakpointsResponseBody
---@field breakpoints? ezdap.dap.proto.Breakpoint[]

---@class ezdap.dap.proto.DataBreakpointInfoResponseBody
---@field dataId      string|nil
---@field description string
---@field accessTypes? ezdap.dap.proto.DataBreakpointAccessType[]
---@field canPersist?  boolean

---@class ezdap.dap.proto.SetDataBreakpointsResponseBody
---@field breakpoints ezdap.dap.proto.Breakpoint[]

---@class ezdap.dap.proto.SetInstructionBreakpointsResponseBody
---@field breakpoints ezdap.dap.proto.Breakpoint[]

---@class ezdap.dap.proto.ContinueResponseBody
---@field allThreadsContinued? boolean

---@class ezdap.dap.proto.StackTraceResponseBody
---@field stackFrames  ezdap.dap.proto.StackFrame[]
---@field totalFrames? integer

---@class ezdap.dap.proto.ScopesResponseBody
---@field scopes ezdap.dap.proto.Scope[]

---@class ezdap.dap.proto.VariablesResponseBody
---@field variables ezdap.dap.proto.Variable[]

---@class ezdap.dap.proto.SetVariableResponseBody
---@field value               string
---@field type?               string
---@field variablesReference? integer
---@field namedVariables?     integer
---@field indexedVariables?   integer
---@field memoryReference?    string
---@field valueLocationReference? integer

---@class ezdap.dap.proto.SourceResponseBody
---@field content  string
---@field mimeType? string

---@class ezdap.dap.proto.ThreadsResponseBody
---@field threads ezdap.dap.proto.Thread[]

---@class ezdap.dap.proto.TerminateThreadsResponseBody

---@class ezdap.dap.proto.ModulesResponseBody
---@field modules       ezdap.dap.proto.Module[]
---@field totalModules? integer

---@class ezdap.dap.proto.LoadedSourcesResponseBody
---@field sources ezdap.dap.proto.Source[]

---@class ezdap.dap.proto.EvaluateResponseBody
---@field result                        string
---@field type?                         string
---@field presentationHint?             ezdap.dap.proto.VariablePresentationHint
---@field variablesReference            integer
---@field namedVariables?               integer
---@field indexedVariables?             integer
---@field memoryReference?              string
---@field valueLocationReference?       integer
---@field declarationLocationReference? integer

---@class ezdap.dap.proto.SetExpressionResponseBody
---@field value               string
---@field type?               string
---@field presentationHint?   ezdap.dap.proto.VariablePresentationHint
---@field variablesReference? integer
---@field namedVariables?     integer
---@field indexedVariables?   integer
---@field memoryReference?    string
---@field valueLocationReference? integer

---@class ezdap.dap.proto.StepInTargetsResponseBody
---@field targets ezdap.dap.proto.StepInTarget[]

---@class ezdap.dap.proto.GotoTargetsResponseBody
---@field targets ezdap.dap.proto.GotoTarget[]

---@class ezdap.dap.proto.CompletionsResponseBody
---@field targets ezdap.dap.proto.CompletionItem[]

---@class ezdap.dap.proto.ExceptionInfoResponseBody
---@field exceptionId  string
---@field description? string
---@field breakMode    ezdap.dap.ExceptionBreakMode
---@field details?     ezdap.dap.proto.ExceptionDetails

---@class ezdap.dap.proto.ReadMemoryResponseBody
---@field address          string
---@field unreadableBytes? integer
---@field data?            string

---@class ezdap.dap.proto.WriteMemoryResponseBody
---@field offset?         integer
---@field bytesWritten?   integer

---@class ezdap.dap.proto.DisassembleResponseBody
---@field instructions ezdap.dap.proto.DisassembledInstruction[]

-- Adapter-initiated request args / response bodies

---@class ezdap.dap.proto.RunInTerminalRequestArguments
---@field kind?   "integrated"|"external"
---@field title?  string
---@field cwd     string
---@field args    string[]
---@field env?    table<string, string>  -- spec allows string|null (null = unset), but we only support string values
---@field argsCanBeInterpretedByShell? boolean

---@class ezdap.dap.proto.RunInTerminalResponseBody
---@field processId?      integer
---@field shellProcessId? integer

---@class ezdap.dap.proto.StartDebuggingRequestArguments
---@field configuration table<string, any>
---@field request       "launch"|"attach"

return {}
