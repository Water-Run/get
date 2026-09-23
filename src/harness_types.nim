## Core data types for the get query loop.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: harness_types.nim
## :License: AGPL-3.0
##
## This module defines the provider-independent actions, observations, budgets,
## events, and results used by the query loop.  Keeping these types independent
## from HTTP, prompts, execution, and terminal rendering gives the loop one
## explicit contract.

{.experimental: "strictFuncs".}

import std/[strutils, monotimes]

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Default number of model requests available to one query.
const DEFAULT_HARNESS_TURNS* = 6

## Default maximum number of tool calls available to one query.
const DEFAULT_TOOL_CALLS* = 16

const DEFAULT_QUERY_TIMEOUT* = 120
const MAX_PROPOSALS_PER_TURN* = 16

## A call repeated with identical arguments this many turns in a row stops the loop.
const MAX_IDENTICAL_CALL_REPEATS* = 3

## Default maximum number of independent tool calls executed together.
const DEFAULT_PARALLELISM* = 4

## Default timeout for a single tool call, in seconds.
const DEFAULT_COMMAND_TIMEOUT* = 30

## Default maximum captured output for a single tool call, in bytes.
const DEFAULT_MAX_OUTPUT_BYTES* = 1_048_576

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Selects how model tool calls are encoded on the wire.
type
  ToolProtocolKind* = enum
    tpkAuto    ## Tries native tools, then falls back to structured JSON.
    tpkNative  ## Requires provider-native function tools.
    tpkJson  ## Uses explicit structured JSON actions.

## Identifies the action proposed by a model response.
type
  HarnessActionKind* = enum
    hakAnswer    ## Completes the run with a plain-text answer.
    hakToolCalls ## Executes one or more typed tool calls.
    hakRefuse    ## Completes the run with an explicit refusal.

## Describes one read-only tool invocation proposed by the model.
type
  ToolInvocationKind* = enum
    tikShell, tikProcess, tikEnvironment, tikReadFile, tikSearchFiles

  ToolCall* = object
    id*: string                  ## Provider call identifier or local fallback ID.
    toolName*: string            ## Registered tool name.
    command*: string             ## Exact read-only shell command to execute.
    purpose*: string             ## Short user-facing reason for the invocation.
    invocationKind*: ToolInvocationKind
    argumentsJson*: string      ## Validated arguments for tracing and identity.
    executable*: string
    argv*: seq[string]
    cwd*: string
    shell*: string
    names*: seq[string]
    path*: string
    pattern*: string
    startLine*: int
    limit*: int
    offset*: int
    includeIgnored*: bool
    contentSearch*: bool
    fresh*: bool                ## Request a new sample instead of a cached observation.
    required*: bool             ## Whether this fact is necessary for task completion.
    evidenceKey*: string        ## Same key identifies a repaired essential fact.

## Describes one provider-independent action produced by the model.
type
  HarnessAction* = object
    kind*: HarnessActionKind ## Action discriminator.
    text*: string            ## Answer or refusal text.
    calls*: seq[ToolCall]     ## Tool calls for hakToolCalls.

## Captures the bounded result of one tool invocation.
type
  ObservationStatus* = enum
    osCompleted, osNoMatch, osFinding, osUnavailable, osDenied, osUnsupported,
    osTimedOut, osTruncated, osReused

  ToolObservation* = object
    callId*: string       ## Identifier of the originating tool call.
    toolName*: string     ## Name of the tool that produced the observation.
    command*: string      ## Exact command that was executed.
    argumentsJson*: string
    identity*: string
    proposedCommand*: string ## Original proposal when safety review rewrote it.
    output*: string       ## Captured, size-bounded combined output.
    exitCode*: int        ## Child-process exit code.
    elapsedMs*: int64     ## Tool wall-clock duration in milliseconds.
    timedOut*: bool       ## Whether execution exceeded its timeout.
    truncated*: bool      ## Whether output exceeded its byte budget.
    policyRejected*: bool ## Whether policy denied it before any execution.
    status*: ObservationStatus
    originalStatus*: ObservationStatus ## Semantic status retained when reusing a sample.
    notExecuted*: bool
    required*: bool
    sampledAt*: string
    source*: string
    stdout*: string
    stderr*: string
    moreData*: bool
    evidenceKey*: string
    feedbackCompacted*: bool
    originalOutputBytes*: int

  ## Applies hard resource limits to a complete harness run.
type
  RunBudget* = object
    maxTurns*: int           ## Positive maximum model turns.
    maxToolCalls*: int       ## Positive maximum tool calls.
    maxParallel*: int        ## Maximum calls executed concurrently.
    commandTimeoutSec*: int  ## Per-command timeout; zero means no limit.
    maxOutputBytes*: int     ## Per-command output cap; zero means no limit.
    totalTimeoutSec*: int    ## Whole-query deadline; zero only for embedding/tests.
    executionDeadline*: MonoTime ## Absolute shared deadline for queued tools; zero means unset.

## Identifies an event emitted by the query loop.
type
  HarnessEventKind* = enum
    hekRunStarted        ## A query run has started.
    hekModelStarted      ## A model turn has started.
    hekModelCompleted    ## A model turn has completed.
    hekActionProposed    ## A typed action has been decoded.
    hekToolProposed      ## A tool proposal awaits authorization.
    hekRunSummary        ## Measured counters for one completed run.
    hekToolCompleted     ## A tool call has completed.
    hekRunCompleted      ## The run completed successfully.
    hekRunFailed         ## The run failed or exhausted its budget.

## Identifies why a query stopped.
type
  HarnessTermination* = enum
    htAnswer          ## The model returned a final answer.
    htRefused         ## The model explicitly refused the request.
    htBudgetExhausted ## The run reached a configured hard limit.
    htTimedOut        ## The whole-query deadline passed.
    htRepeated        ## The model repeated an identical call too often.
    htModelFailed     ## A model request failed after tools had run.

## Represents one structured runtime event for rendering and tracing.
type
  HarnessEvent* = object
    kind*: HarnessEventKind ## Event discriminator.
    turn*: int              ## One-based model turn, or zero when not applicable.
    callId*: string         ## Tool call identifier, when applicable.
    message*: string        ## Concise event detail.
    elapsedMs*: int64       ## Elapsed duration associated with the event.
    tool*: string           ## Tool name for tool events.
    target*: string         ## Short description of what the tool read.
    status*: ObservationStatus ## Observation status for hekToolCompleted.

## Receives structured runtime events as they occur.
type
  HarnessEventSink* = proc(
    event: HarnessEvent
  ) {.closure.}

## Summarises resource use for one query.
type
  RunMetrics* = object
    modelTurns*: int       ## Number of completed logical model turns.
    modelRequests*: int    ## Physical provider requests, including retries.
    toolCalls*: int        ## Number of started tool calls.
    toolProposals*: int
    toolRejections*: int
    toolReuses*: int
    inputOutputTokens*: int ## Total tokens reported by providers.
    elapsedMs*: int64      ## Complete run wall-clock duration.

## Represents the provider-independent result of one query.
type
  HarnessResult* = object
    output*: string                     ## Final user-facing output.
    exitCode*: int                      ## Final process-style exit code.
    finalCommand*: string               ## Last executed command, when present.
    observations*: seq[ToolObservation] ## Tool observations in call order.
    metrics*: RunMetrics                ## Resource-use summary.
    termination*: HarnessTermination    ## Stable reason the run stopped.
    refused*: bool                      ## Whether the model explicitly refused.
    partial*: bool                      ## One or more observations remain unavailable.
    reason*: string                     ## Why a run stopped without a clean answer.

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

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
  of "legacy", "json", "text": result = tpkJson
  else:
    raise newException(ValueError,
      "expected auto, native, or json")

## Returns the stable configuration name for a tool protocol.
##
## :param kind: Tool protocol to format.
## :returns: Stable lowercase configuration value.
##
## .. code-block:: nim
##   runnableExamples:
##     assert toolProtocolName(tpkJson) == "json"
func toolProtocolName*(kind: ToolProtocolKind): string =
  case kind
  of tpkAuto: result = "auto"
  of tpkNative: result = "native"
  of tpkJson: result = "json"

## Returns the default resource budget for one query.
##
## .. code-block:: nim
##   runnableExamples:
##     assert defaultRunBudget().maxTurns == 6
##     assert defaultRunBudget().maxParallel == 4
func defaultRunBudget*(): RunBudget =
  result = RunBudget(
    maxTurns: DEFAULT_HARNESS_TURNS,
    maxToolCalls: DEFAULT_TOOL_CALLS,
    maxParallel: DEFAULT_PARALLELISM,
    commandTimeoutSec: DEFAULT_COMMAND_TIMEOUT,
    maxOutputBytes: DEFAULT_MAX_OUTPUT_BYTES,
    totalTimeoutSec: DEFAULT_QUERY_TIMEOUT
  )
