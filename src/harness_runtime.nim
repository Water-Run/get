## The query loop.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-09-23
## :File: harness_runtime.nim
## :License: AGPL-3.0
##
## One loop serves every query: ask the model; stop when it answers; otherwise
## authorize and run the whole batch of calls, return the observations in call
## order, and ask again. The model and tool boundaries are injected so the loop
## is independent of terminal rendering and provider transport. Every stop
## keeps the observations collected so far.

{.experimental: "strictFuncs".}

import std/[json, monotimes, strformat, tables, times]

import harness_protocol
import harness_types
import observations
import llm
import tool_registry
import utils

const MAX_MODEL_FEEDBACK_BYTES = 12 * 1024

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Raised when a model violates the typed action contract.
type
  HarnessProtocolError* = object of GetError

## Invokes one model request using the supplied conversation and tool policy.
type
  ModelTurnProc* = proc(
    messages: seq[LlmMessage],
    enableNativeTools: bool,
    allowParallel: bool
  ): LlmResponse {.closure.}

## Authorizes and executes a batch of model-proposed tool calls.
type
  ToolBatchProc* = proc(
    calls: seq[ToolCall],
    maxParallel: int
  ): seq[ToolObservation] {.closure.}

## Configures one run of the query loop.
type
  HarnessRunOptions* = object
    protocol*: ToolProtocolKind    ## Native or strict-JSON tools.
    budget*: RunBudget             ## Hard turn, tool, timeout, and size limits.
    toolsDisabled*: bool           ## Deny native and textual tool actions.
    eventSink*: HarnessEventSink   ## Optional structured event receiver.

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

proc implElapsedMs(started: MonoTime): int64 =
  result = (getMonoTime() - started).inMilliseconds

proc implEmit(options: HarnessRunOptions, event: HarnessEvent) =
  if not options.eventSink.isNil:
    options.eventSink(event)

## Converts a provider response to a typed action.
##
## A native call with invalid arguments keeps its provider ID and an empty
## command. The executor rejects it without running anything, and the model
## sees a matching result it can correct.
proc implDecodeResponse(response: LlmResponse): HarnessAction =
  if response.toolCalls.len > 0:
    var calls: seq[ToolCall] = @[]
    for nativeCall in response.toolCalls:
      try:
        calls.add(parseNativeToolCall(
          nativeCall.id, nativeCall.name, nativeCall.arguments))
      except ValueError:
        calls.add(ToolCall(id: nativeCall.id, toolName: nativeCall.name,
          command: "", purpose: "invalid provider tool call"))
    return HarnessAction(kind: hakToolCalls, text: "", calls: calls)
  try:
    result = decodeTextAction(response.content)
  except ValueError as error:
    raise newException(HarnessProtocolError, error.msg)

## Adds observations to a native or strict-JSON conversation.
proc implAppendFeedback(
  messages: var seq[LlmMessage],
  response: LlmResponse,
  observations: seq[ToolObservation]
) =
  if response.toolCalls.len > 0:
    messages.add(LlmMessage(role: "assistant", content: response.content,
      toolCallsJson: response.toolCallsJson))
    for observation in observations:
      messages.add(LlmMessage(role: "tool", toolCallId: observation.callId,
        content: observationJson(
          compactObservation(observation, MAX_MODEL_FEEDBACK_BYTES))))
  else:
    messages.add(LlmMessage(role: "assistant", content: response.content))
    var values = newJArray()
    for observation in observations:
      values.add(parseJson(observationJson(
        compactObservation(observation, MAX_MODEL_FEEDBACK_BYTES))))
    messages.add(LlmMessage(role: "user",
      content: "Tool observations (JSON): " & $values))

proc implToolCallIds(toolCallsJson: string): seq[string] =
  if toolCallsJson.len == 0:
    return
  try:
    let node = parseJson(toolCallsJson)
    if node.kind != JArray:
      return
    for item in node:
      let idNode = item{"id"}
      if not idNode.isNil and idNode.kind == JString and idNode.getStr.len > 0:
        result.add(idNode.getStr)
  except JsonParsingError:
    discard

## Drops tool results that no longer answer an assistant tool call. Providers
## reject such orphans, so the conversation is cleaned before each request.
proc implStripOrphanToolResults(messages: seq[LlmMessage]): seq[LlmMessage] =
  var pending: seq[string] = @[]
  for message in messages:
    if message.role == "assistant":
      pending = implToolCallIds(message.toolCallsJson)
      result.add(message)
    elif message.role == "tool":
      let index = pending.find(message.toolCallId)
      if index >= 0:
        pending.delete(index)
        result.add(message)
    else:
      pending.setLen(0)
      result.add(message)

## Lists the observations collected before a stop, for the user.
func implIncompleteOutput(observations: seq[ToolObservation]): string =
  if observations.len == 0:
    return "No observations were collected."
  result = "Observations collected before stopping:"
  for observation in observations:
    if result.len >= MAX_MODEL_FEEDBACK_BYTES:
      break
    var section = "\n\n" & observation.command & "\n"
    var preview = observation.output
    if preview.len > 2048:
      var ending = 2048
      while ending > 0 and (byte(preview[ending]) and 0xC0'u8) == 0x80'u8:
        ending -= 1
      preview = preview[0 ..< ending] & "\n[observation shortened]"
    section.add(if preview.len > 0: preview else: "exit " & $observation.exitCode)
    if observation.truncated:
      section.add("\n[output truncated at the configured limit]")
    elif observation.timedOut:
      section.add("\n[stopped at the command deadline]")
    var remaining = min(section.len, MAX_MODEL_FEEDBACK_BYTES - result.len)
    while remaining > 0 and remaining < section.len and
        (byte(section[remaining]) and 0xC0'u8) == 0x80'u8:
      remaining -= 1
    result.add(section[0 ..< remaining])

## Builds a stopped result that keeps every observation.
proc implStopped(
  observations: seq[ToolObservation],
  metrics: RunMetrics,
  termination: HarnessTermination,
  exitCode: int,
  reason: string,
  started: MonoTime
): HarnessResult =
  result = HarnessResult(output: implIncompleteOutput(observations),
    exitCode: exitCode, observations: observations, metrics: metrics,
    termination: termination, partial: true, reason: reason)
  result.metrics.elapsedMs = implElapsedMs(started)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Runs one query through the loop.
##
## :param initialMessages: System and user messages for the first request.
## :param options: Protocol, budget, and event configuration.
## :param modelTurn: Model request callback.
## :param runTools: Authorization-and-execution callback for one batch.
## :returns: Final output, observations, termination reason, and metrics.
## :raises: HarnessProtocolError: If a response violates the action contract.
## :raises: GetError: If the first model request fails, or a callback misbehaves.
proc runHarness*(
  initialMessages: seq[LlmMessage],
  options: HarnessRunOptions,
  modelTurn: ModelTurnProc,
  runTools: ToolBatchProc,
  seedObservations: seq[ToolObservation] = @[]
): HarnessResult =
  if modelTurn.isNil or runTools.isNil:
    raise newException(GetError, "harness callbacks must be configured")
  if initialMessages.len == 0:
    raise newException(GetError, "harness requires initial messages")
  if options.budget.maxTurns <= 0:
    raise newException(GetError, "harness max turns must be positive")
  if options.budget.maxToolCalls <= 0:
    raise newException(GetError, "harness max tool calls must be positive")
  if options.budget.maxParallel <= 0:
    raise newException(GetError, "harness max parallelism must be positive")
  if options.budget.commandTimeoutSec < 0:
    raise newException(GetError, "command timeout must not be negative")
  if options.budget.maxOutputBytes < 0:
    raise newException(GetError, "command output limit must not be negative")

  let started = getMonoTime()
  var messages = initialMessages
  # Observations from a re-executed cached plan are already in the messages.
  var observations = seedObservations
  var metrics = RunMetrics()
  for observation in seedObservations:
    if not observation.notExecuted: metrics.toolCalls += 1
    if observation.policyRejected: metrics.toolRejections += 1
  # identity -> consecutive turns in which the same call was proposed
  var streaks = initTable[string, int]()
  implEmit(options, HarnessEvent(kind: hekRunStarted, message: "run started"))

  for turn in 1 .. options.budget.maxTurns:
    if options.budget.totalTimeoutSec > 0 and
        implElapsedMs(started) >= int64(options.budget.totalTimeoutSec) * 1000:
      implEmit(options, HarnessEvent(kind: hekRunFailed, turn: turn,
        message: "query deadline reached", elapsedMs: implElapsedMs(started)))
      return implStopped(observations, metrics, htTimedOut, 124,
        fmt"query deadline reached ({options.budget.totalTimeoutSec}s)", started)
    messages = implStripOrphanToolResults(messages)
    implEmit(options, HarnessEvent(kind: hekModelStarted, turn: turn,
      message: "model turn started", elapsedMs: implElapsedMs(started)))
    let enableNative = not options.toolsDisabled and options.protocol != tpkJson
    let allowParallel = options.budget.maxParallel > 1 and
      options.budget.maxToolCalls - metrics.toolCalls > 1
    var response: LlmResponse
    try:
      response = modelTurn(messages, enableNative, allowParallel)
    except GetError as error:
      if observations.len == 0:
        raise
      let timedOut = options.budget.totalTimeoutSec > 0 and
        implElapsedMs(started) >= int64(options.budget.totalTimeoutSec) * 1000
      return implStopped(observations, metrics,
        (if timedOut: htTimedOut else: htModelFailed),
        (if timedOut: 124 else: 1), error.msg, started)
    metrics.modelTurns += 1
    metrics.modelRequests += max(response.providerRequests, 1)
    metrics.inputOutputTokens += response.tokensUsed
    implEmit(options, HarnessEvent(kind: hekModelCompleted, turn: turn,
      message: response.finishReason, elapsedMs: implElapsedMs(started)))

    var action: HarnessAction
    try:
      action = implDecodeResponse(response)
    except HarnessProtocolError:
      # A bad textual action executed nothing. Correct it within the same
      # turn cap; there is no separate repair mode.
      const MAX_INVALID_ACTION_CONTEXT = 4096
      var invalidText = response.content
      if invalidText.len > MAX_INVALID_ACTION_CONTEXT:
        var prefixBytes = MAX_INVALID_ACTION_CONTEXT
        while prefixBytes > 0 and
            (byte(invalidText[prefixBytes]) and 0xC0'u8) == 0x80'u8:
          prefixBytes -= 1
        invalidText = invalidText[0 ..< prefixBytes] &
          "\n[invalid action text compacted]"
      messages.add(LlmMessage(role: "assistant", content: invalidText))
      messages.add(LlmMessage(role: "user", content:
        "The previous response was not a final answer or strict JSON " &
        "tool action, and nothing was executed. Reply with the answer, or " &
        "with strict JSON type answer, refuse, or tool_calls."))
      implEmit(options, HarnessEvent(kind: hekActionProposed, turn: turn,
        message: "invalid textual action", elapsedMs: implElapsedMs(started)))
      continue
    implEmit(options, HarnessEvent(kind: hekActionProposed, turn: turn,
      message: $action.kind, elapsedMs: implElapsedMs(started)))

    case action.kind
    of hakAnswer:
      let evidence = answerEvidenceStatus(observations)
      implEmit(options, HarnessEvent(kind: hekRunCompleted, turn: turn,
        message: "answer", elapsedMs: implElapsedMs(started)))
      result = HarnessResult(output: action.text, exitCode: evidence.code,
        partial: evidence.partial, observations: observations,
        metrics: metrics, termination: htAnswer)
      if evidence.code != 0:
        result.reason = "required evidence was not collected"
      result.metrics.elapsedMs = implElapsedMs(started)
      return
    of hakRefuse:
      implEmit(options, HarnessEvent(kind: hekRunCompleted, turn: turn,
        message: "refused", elapsedMs: implElapsedMs(started)))
      result = HarnessResult(output: action.text, exitCode: 1,
        observations: observations, metrics: metrics, termination: htRefused,
        refused: true)
      result.metrics.elapsedMs = implElapsedMs(started)
      return
    of hakToolCalls:
      if options.toolsDisabled:
        raise newException(HarnessProtocolError,
          "tool calls are disabled for this request")
      if action.calls.len == 0:
        raise newException(HarnessProtocolError, "tool action contains no calls")
      var callIds: seq[string] = @[]
      for call in action.calls:
        if call.id.len == 0:
          raise newException(HarnessProtocolError,
            "tool call identifier must not be empty")
        if call.id in callIds:
          raise newException(HarnessProtocolError,
            fmt"duplicate tool call identifier '{call.id}'")
        callIds.add(call.id)
      let remainingCalls = options.budget.maxToolCalls - metrics.toolCalls
      if remainingCalls <= 0:
        return implStopped(observations, metrics, htBudgetExhausted, 1,
          fmt"tool-call limit reached ({options.budget.maxToolCalls})", started)

      var nextStreaks = initTable[string, int]()
      for call in action.calls:
        let identity = queryIdentity(call)
        nextStreaks[identity] = streaks.getOrDefault(identity) + 1
        if nextStreaks[identity] >= MAX_IDENTICAL_CALL_REPEATS:
          return implStopped(observations, metrics, htRepeated, 1,
            fmt"the same {call.toolName} call was repeated " &
              fmt"{MAX_IDENTICAL_CALL_REPEATS} times", started)
      streaks = nextStreaks

      metrics.toolProposals += action.calls.len
      let selectedCalls = action.calls[0 ..< min(action.calls.len,
        min(remainingCalls, MAX_PROPOSALS_PER_TURN))]
      for call in selectedCalls:
        implEmit(options, HarnessEvent(kind: hekToolProposed, turn: turn,
          callId: call.id, message: call.purpose, tool: call.toolName,
          target: callTarget(call), elapsedMs: implElapsedMs(started)))
      var batch = runTools(selectedCalls,
        min(options.budget.maxParallel, selectedCalls.len))
      if batch.len != selectedCalls.len:
        raise newException(GetError,
          "tool executor returned an incomplete observation batch")
      for index, observation in batch:
        let call = selectedCalls[index]
        if observation.callId != call.id or
            observation.toolName != call.toolName or
            (if observation.proposedCommand.len > 0:
               observation.proposedCommand != call.command
             else: observation.command != call.command):
          raise newException(GetError,
            "tool executor returned an observation that does not match " &
              "its proposed call")
      for index, observation in batch:
        if observation.policyRejected:
          metrics.toolRejections += 1
        elif observation.status == osReused:
          metrics.toolReuses += 1
        elif not observation.notExecuted:
          metrics.toolCalls += 1
        implEmit(options, HarnessEvent(kind: hekToolCompleted, turn: turn,
          callId: observation.callId, tool: observation.toolName,
          target: callTarget(selectedCalls[index]), status: observation.status,
          message: $observation.status,
          elapsedMs: (if observation.notExecuted or observation.policyRejected: -1
            else: observation.elapsedMs)))
      # Every proposal gets a result, even past the budget, so the history
      # stays well formed. Those extra calls do not run.
      for index in selectedCalls.len ..< action.calls.len:
        let call = action.calls[index]
        batch.add(ToolObservation(callId: call.id, toolName: call.toolName,
          command: call.command, output:
            "Tool budget reached: this proposal was not executed. Answer from " &
            "the available observations.", exitCode: 125, notExecuted: true,
          status: osUnsupported, required: call.required,
          evidenceKey: call.evidenceKey))
      for observation in batch:
        observations.add(observation)
      implAppendFeedback(messages, response, batch)

  implEmit(options, HarnessEvent(kind: hekRunFailed, turn: options.budget.maxTurns,
    message: "model-turn budget exhausted", elapsedMs: implElapsedMs(started)))
  result = implStopped(observations, metrics, htBudgetExhausted, 1,
    fmt"model-request limit reached ({options.budget.maxTurns})", started)
