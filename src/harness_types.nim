## Core data types for the get v3 harness runtime.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: harness_types.nim
## :License: AGPL-3.0
##
## This module defines the provider-independent actions, observations, budgets,
## events, and results used by every v3 harness strategy.  Keeping these types
## independent from HTTP, prompts, execution, and terminal rendering gives all
## strategies one explicit state-machine contract.

{.experimental: "strictFuncs".}

import std/[strutils]

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Default number of model turns available to an automatic harness run.
const DEFAULT_HARNESS_TURNS* = 3

## Default maximum number of tool calls available to one harness run.
const DEFAULT_TOOL_CALLS* = 8

## Default maximum number of independent tool calls executed together.
const DEFAULT_PARALLELISM* = 4

## Default timeout for a single tool call, in seconds.
const DEFAULT_COMMAND_TIMEOUT* = 30

## Default maximum captured output for a single tool call, in bytes.
const DEFAULT_MAX_OUTPUT_BYTES* = 1_048_576

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Selects the orchestration policy used by the unified harness state machine.
type
  HarnessKind* = enum
    hkAuto      ## Starts direct and escalates only when the model needs it.
    hkDirect    ## Allows one model turn and terminal tool execution.
    hkLoop      ## Feeds observations back to the model until completion.
    hkParallel  ## Allows batches of independent read-only tool calls.

## Selects how model tool calls are encoded on the wire.
type
  ToolProtocolKind* = enum
    tpkAuto    ## Tries native tools, then falls back to structured JSON.
    tpkNative  ## Requires provider-native function tools.
    tpkLegacy  ## Uses structured JSON with Markdown v2 compatibility.

## Selects what the harness does after a tool call finishes.
type
  ToolResultMode* = enum
    trmReturnRaw ## Returns tool output directly without another model call.
    trmContinue  ## Feeds tool output back to the model for another turn.

## Identifies the action proposed by a model response.
type
  HarnessActionKind* = enum
    hakAnswer    ## Completes the run with a plain-text answer.
    hakToolCalls ## Executes one or more typed tool calls.
    hakRefuse    ## Completes the run with an explicit refusal.

## Describes one read-only tool invocation proposed by the model.
type
  ToolCall* = object
    id*: string                  ## Provider call identifier or local fallback ID.
    toolName*: string            ## Registered tool name.
    command*: string             ## Exact read-only shell command to execute.
    purpose*: string             ## Short user-facing reason for the invocation.
    resultMode*: ToolResultMode  ## Terminal or model-feedback behavior.

## Describes one provider-independent action produced by the model.
type
  HarnessAction* = object
    kind*: HarnessActionKind ## Action discriminator.
    text*: string            ## Answer or refusal text.
    calls*: seq[ToolCall]     ## Tool calls for hakToolCalls.

## Captures the bounded result of one tool invocation.
type
  ToolObservation* = object
    callId*: string       ## Identifier of the originating tool call.
    toolName*: string     ## Name of the tool that produced the observation.
    command*: string      ## Exact command that was executed.
    proposedCommand*: string ## Original proposal when safety review rewrote it.
    output*: string       ## Captured, size-bounded combined output.
    exitCode*: int        ## Child-process exit code.
    elapsedMs*: int64     ## Tool wall-clock duration in milliseconds.
    timedOut*: bool       ## Whether execution exceeded its timeout.
    truncated*: bool      ## Whether output exceeded its byte budget.
    policyRejected*: bool ## Whether policy denied it before any execution.

  ## Applies hard resource limits to a complete harness run.
type
  RunBudget* = object
    maxTurns*: int           ## Positive maximum model turns.
    maxToolCalls*: int       ## Positive maximum tool calls.
    maxParallel*: int        ## Maximum calls executed concurrently.
    commandTimeoutSec*: int  ## Per-command timeout; zero means no limit.
    maxOutputBytes*: int     ## Per-command output cap; zero means no limit.

## Identifies an event emitted by the harness state machine.
type
  HarnessEventKind* = enum
    hekRunStarted        ## A query run has started.
    hekModelStarted      ## A model turn has started.
    hekModelCompleted    ## A model turn has completed.
    hekActionProposed    ## A typed action has been decoded.
    hekToolStarted       ## A tool call has started.
    hekToolCompleted     ## A tool call has completed.
    hekRunCompleted      ## The run completed successfully.
    hekRunFailed         ## The run failed or exhausted its budget.

## Identifies why a harness run stopped.
type
  HarnessTermination* = enum
    htAnswer          ## The model returned a final answer.
    htRawToolResult   ## Tool output was returned without another model turn.
    htRefused         ## The model explicitly refused the request.
    htBudgetExhausted ## The run reached a configured hard limit.

## Represents one structured runtime event for rendering and tracing.
type
  HarnessEvent* = object
    kind*: HarnessEventKind ## Event discriminator.
    turn*: int              ## One-based model turn, or zero when not applicable.
    callId*: string         ## Tool call identifier, when applicable.
    message*: string        ## Concise event detail.
    elapsedMs*: int64       ## Elapsed duration associated with the event.

## Receives structured runtime events as they occur.
type
  HarnessEventSink* = proc(
    event: HarnessEvent
  ) {.closure.}

## Summarises resource use for one completed harness run.
type
  RunMetrics* = object
    modelTurns*: int       ## Number of completed logical model turns.
    modelRequests*: int    ## Physical provider requests, including retries.
    toolCalls*: int        ## Number of started tool calls.
    inputOutputTokens*: int ## Total tokens reported by providers.
    elapsedMs*: int64      ## Complete run wall-clock duration.

## Represents the final provider-independent harness result.
type
  HarnessResult* = object
    output*: string                     ## Final user-facing output.
    exitCode*: int                      ## Final process-style exit code.
    finalCommand*: string               ## Last executed command, when present.
    observations*: seq[ToolObservation] ## Tool observations in call order.
    metrics*: RunMetrics                ## Resource-use summary.
    termination*: HarnessTermination    ## Stable reason the run stopped.
    refused*: bool                      ## Whether the model explicitly refused.

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Parses a user-facing harness name.
##
## :param value: Case-insensitive harness name.
## :returns: The corresponding HarnessKind.
## :raises: ValueError: If the name is not supported.
##
## .. code-block:: nim
##   runnableExamples:
##     assert parseHarnessKind("auto") == hkAuto
##     assert parseHarnessKind("parallel") == hkParallel
func parseHarnessKind*(value: string): HarnessKind =
  case toLowerAscii(value.strip())
  of "auto": result = hkAuto
  of "direct", "instance": result = hkDirect
  of "loop", "agent": result = hkLoop
  of "parallel", "batch": result = hkParallel
  else:
    raise newException(ValueError,
      "expected auto, direct, loop, or parallel")

## Returns the stable configuration name for a harness kind.
##
## :param kind: Harness kind to format.
## :returns: Stable lowercase configuration value.
##
## .. code-block:: nim
##   runnableExamples:
##     assert harnessName(hkDirect) == "direct"
func harnessName*(kind: HarnessKind): string =
  case kind
  of hkAuto: result = "auto"
  of hkDirect: result = "direct"
  of hkLoop: result = "loop"
  of hkParallel: result = "parallel"

## Parses a user-facing tool protocol name.
##
## :param value: Case-insensitive protocol name.
## :returns: The corresponding ToolProtocolKind.
## :raises: ValueError: If the name is unsupported.
##
## .. code-block:: nim
##   runnableExamples:
##     assert parseToolProtocolKind("native") == tpkNative
func parseToolProtocolKind*(value: string): ToolProtocolKind =
  case toLowerAscii(value.strip())
  of "auto": result = tpkAuto
  of "native", "tools": result = tpkNative
  of "legacy", "json", "text": result = tpkLegacy
  else:
    raise newException(ValueError,
      "expected auto, native, or legacy")

## Returns the stable configuration name for a tool protocol.
##
## :param kind: Tool protocol to format.
## :returns: Stable lowercase configuration value.
##
## .. code-block:: nim
##   runnableExamples:
##     assert toolProtocolName(tpkLegacy) == "legacy"
func toolProtocolName*(kind: ToolProtocolKind): string =
  case kind
  of tpkAuto: result = "auto"
  of tpkNative: result = "native"
  of tpkLegacy: result = "legacy"

## Parses a model-provided result mode.
##
## :param value: Case-insensitive mode name.
## :returns: Terminal raw mode or continuation mode.
## :raises: ValueError: If the mode is unsupported.
##
## .. code-block:: nim
##   runnableExamples:
##     assert parseToolResultMode("return_raw") == trmReturnRaw
##     assert parseToolResultMode("continue") == trmContinue
func parseToolResultMode*(value: string): ToolResultMode =
  case toLowerAscii(value.strip()).replace('-', '_')
  of "return_raw", "raw", "final", "direct":
    result = trmReturnRaw
  of "continue", "interpret", "model":
    result = trmContinue
  else:
    raise newException(ValueError,
      "expected return_raw or continue")

## Returns a default resource budget for a harness kind.
##
## Direct mode is deliberately limited to one turn and one tool call.  Other
## modes share the standard turn and tool-call limits, while loop mode executes
## calls serially and parallel mode uses the configured concurrency default.
##
## :param kind: Harness policy receiving the budget.
## :returns: A fully populated RunBudget.
##
## .. code-block:: nim
##   runnableExamples:
##     assert defaultRunBudget(hkDirect).maxTurns == 1
##     assert defaultRunBudget(hkParallel).maxParallel == 4
func defaultRunBudget*(kind: HarnessKind): RunBudget =
  result = RunBudget(
    maxTurns:
      if kind == hkDirect: 1
      else: DEFAULT_HARNESS_TURNS,
    maxToolCalls:
      if kind == hkDirect: 1
      else: DEFAULT_TOOL_CALLS,
    maxParallel:
      if kind == hkParallel or kind == hkAuto:
        DEFAULT_PARALLELISM
      else:
        1,
    commandTimeoutSec: DEFAULT_COMMAND_TIMEOUT,
    maxOutputBytes: DEFAULT_MAX_OUTPUT_BYTES
  )
