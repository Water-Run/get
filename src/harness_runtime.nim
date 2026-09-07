## Unified state-machine runtime for all get v3 harness strategies.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: harness_runtime.nim
## :License: AGPL-3.0
##
## This module owns model/action/tool/observation transitions independently
## of terminal rendering and provider transport. Direct, loop, parallel, and
## automatic behavior are policies over the same typed and budgeted loop.

{.experimental: "strictFuncs".}

import std/[json, monotimes, strformat, strutils, times]

import harness_protocol
import harness_types
import llm
import utils

const MAX_MODEL_FEEDBACK_BYTES = 12 * 1024

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Raised when a model violates the typed harness contract.
type
  HarnessProtocolError* = object of GetError

## Invokes one model turn using the supplied conversation and tool policy.
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

## Configures one invocation of the unified harness state machine.
type
  HarnessRunOptions* = object
    kind*: HarnessKind             ## Strategy policy layered on the loop.
    protocol*: ToolProtocolKind    ## Native or structured-text protocol.
    budget*: RunBudget             ## Hard turn, tool, timeout, and size limits.
    toolsDisabled*: bool           ## Deny native and textual tool actions.
    eventSink*: HarnessEventSink   ## Optional structured event receiver.

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Returns milliseconds elapsed since a monotonic start time.
##
## :param started: Monotonic start timestamp.
## :returns: Non-negative elapsed milliseconds.
proc implElapsedMs(started: MonoTime): int64 =
  result = (getMonoTime() - started).inMilliseconds

## Emits an event when a sink was configured.
##
## :param options: Run options containing the optional sink.
## :param event: Structured event to deliver.
proc implEmit(options: HarnessRunOptions, event: HarnessEvent) =
  if not options.eventSink.isNil:
    options.eventSink(event)

## Converts a provider response to the provider-independent action contract.
##
## :param response: Parsed provider response.
## :returns: Validated typed action.
## :raises: HarnessProtocolError: If native arguments or fallback text is invalid.
proc implDecodeResponse(
  response: LlmResponse,
  allowBareCodeTools: bool
): HarnessAction =
  if response.toolCalls.len > 0:
    var calls: seq[ToolCall] = @[]
    for nativeCall in response.toolCalls:
      try:
        calls.add(parseNativeToolCall(
          nativeCall.id,
          nativeCall.name,
          nativeCall.arguments
        ))
      except ValueError:
        # Preserve the provider call ID so the next request can contain the
        # required matching tool response, but leave the command empty.  The
        # executor boundary treats this as a rejected protocol proposal and
        # never sends it to a shell.  This lets a flaky model self-correct
        # without weakening the only registered tool or aborting a long run.
        calls.add(ToolCall(
          id: nativeCall.id,
          toolName: nativeCall.name,
          command: "",
          purpose: "invalid provider tool call",
          resultMode: trmContinue
        ))
    return HarnessAction(
      kind: hakToolCalls,
      text: "",
      calls: calls
    )
  try:
    result = decodeTextAction(response.content, allowBareCodeTools)
  except ValueError as error:
    raise newException(HarnessProtocolError, error.msg)

## Formats terminal observations in stable call order.
##
## :param observations: Tool results to expose to the user.
## :returns: Clean terminal output, with labels for multi-call batches.
func implFormatRawOutput(observations: seq[ToolObservation]): string =
  if observations.len == 1:
    let observation = observations[0]
    let clean = observation.output.strip()
    if clean.len > 0:
      if observation.truncated:
        return clean & "\n[output truncated at configured limit]"
      return clean
    if observation.truncated:
      return "[output truncated at configured limit]"
    if observation.timedOut:
      return "command timed out"
    if observation.exitCode != 0:
      return fmt"command exited with code {observation.exitCode}"
    return "(command completed with no output)"
  var sections: seq[string] = @[]
  for observation in observations:
    var output = observation.output.strip()
    if output.len == 0 and observation.timedOut:
      output = "command timed out"
    elif output.len == 0 and observation.exitCode != 0:
      output = fmt"command exited with code {observation.exitCode}"
    if observation.truncated:
      output.add("\n[output truncated at configured limit]")
    sections.add(fmt"[{observation.callId}] {observation.command}\n{output}")
  result = sections.join("\n\n")

## Returns the process-style exit code for a terminal observation batch.
##
## :param observations: Completed tool observations.
## :returns: First non-zero code, timeout code 124, or zero.
func implBatchExitCode(observations: seq[ToolObservation]): int =
  for observation in observations:
    if observation.timedOut:
      return 124
    if observation.truncated:
      return 1
    if observation.exitCode != 0:
      return observation.exitCode
  result = 0

## Adds observations to a native or structured-text conversation.
##
## :param messages: Conversation to extend.
## :param response: Assistant response that proposed the calls.
## :param observations: Results to feed back.
proc implAppendFeedback(
  messages: var seq[LlmMessage],
  response: LlmResponse,
  observations: seq[ToolObservation]
) =
  func compactForModel(observation: ToolObservation): ToolObservation =
    result = observation
    if result.output.len <= MAX_MODEL_FEEDBACK_BYTES:
      return
    var prefixBytes = MAX_MODEL_FEEDBACK_BYTES
    while prefixBytes > 0 and prefixBytes < result.output.len and
        (byte(result.output[prefixBytes]) and 0xC0'u8) == 0x80'u8:
      prefixBytes -= 1
    let originalBytes = result.output.len
    result.output = result.output[0 ..< prefixBytes] &
      fmt"\n[model feedback compacted: first {prefixBytes} of " &
      fmt"{originalBytes} bytes]"
    result.truncated = true

  if response.toolCalls.len > 0:
    messages.add(LlmMessage(
      role: "assistant",
      content: response.content,
      toolCallId: "",
      toolCallsJson: response.toolCallsJson
    ))
    for observation in observations:
      let feedbackObservation = compactForModel(observation)
      messages.add(LlmMessage(
        role: "tool",
        content: observationJson(feedbackObservation),
        toolCallId: observation.callId,
        toolCallsJson: ""
      ))
  else:
    messages.add(LlmMessage(
      role: "assistant",
      content: response.content,
      toolCallId: "",
      toolCallsJson: ""
    ))
    var values = newJArray()
    for observation in observations:
      values.add(parseJson(observationJson(compactForModel(observation))))
    messages.add(LlmMessage(
      role: "user",
      content: "Tool observations (JSON): " & $values,
      toolCallId: "",
      toolCallsJson: ""
    ))

## Finalizes elapsed metrics on a result value.
##
## :param value: Result to update and return.
## :param started: Run start timestamp.
## :returns: Result with complete elapsed time.
proc implFinish(value: HarnessResult, started: MonoTime): HarnessResult =
  result = value
  result.metrics.elapsedMs = implElapsedMs(started)

## Some requests inherently need model interpretation after inspection. Models
## occasionally mark a raw listing as terminal even for an explicit summary or
## composition question; this small multilingual intent gate corrects that
## protocol choice without exposing another tool or changing command policy.
func implRequestNeedsInterpretation(messages: seq[LlmMessage]): bool =
  var query = ""
  for index in countdown(messages.high, 0):
    if messages[index].role == "user":
      query = toLowerAscii(messages[index].content)
      break
  for marker in [
    "composition", "breakdown", "summarize", "summary", "compare",
    "comparison", "whether", "determine if", "identical", "different",
    "exists", "existence", "missing", "absent",
    "explain", "analyze", "analyse", "status",
    "clearly say", "as evidence", "interpret the exit", "explicit answer",
    "weather", "forecast", "天气", "天氣", "天気", "날씨",
    "组成", "构成", "汇总", "总结", "概览", "分析", "解释", "说明",
    "比较", "对比", "情况", "状态", "是否", "有没有", "存在", "相同",
    "一致", "缺失", "不存在", "内訳", "要約", "요약", "구성", "분석"
  ]:
    if query.contains(marker):
      return true

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Runs a query through the unified typed harness state machine.
##
## The model and tool boundaries are injected so the state machine can be
## tested deterministically and used with any compatible provider or executor.
##
## :param initialMessages: System and user messages for the first turn.
## :param options: Strategy, protocol, budget, and event configuration.
## :param modelTurn: Model request callback.
## :param runTools: Central policy-and-execution callback.
## :returns: Final output, observations, termination reason, and metrics.
## :raises: HarnessProtocolError: If a response violates the action contract.
## :raises: GetError: If a required callback is absent or returns invalid data.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc runHarness*(
  initialMessages: seq[LlmMessage],
  options: HarnessRunOptions,
  modelTurn: ModelTurnProc,
  runTools: ToolBatchProc
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
  let requestNeedsInterpretation =
    implRequestNeedsInterpretation(initialMessages)
  var observations: seq[ToolObservation] = @[]
  var metrics = RunMetrics(
    modelTurns: 0,
    modelRequests: 0,
    toolCalls: 0,
    inputOutputTokens: 0,
    elapsedMs: 0
  )
  implEmit(options, HarnessEvent(
    kind: hekRunStarted,
    turn: 0,
    callId: "",
    message: "run started",
    elapsedMs: 0
  ))

  for turn in 1 .. options.budget.maxTurns:
    implEmit(options, HarnessEvent(
      kind: hekModelStarted,
      turn: turn,
      callId: "",
      message: "model turn started",
      elapsedMs: implElapsedMs(started)
    ))
    let enableNative =
      not options.toolsDisabled and options.protocol != tpkLegacy
    let allowParallel = options.kind in {hkAuto, hkParallel}
    let response = modelTurn(messages, enableNative, allowParallel)
    metrics.modelTurns += 1
    metrics.modelRequests += max(response.providerRequests, 1)
    metrics.inputOutputTokens += response.tokensUsed
    implEmit(options, HarnessEvent(
      kind: hekModelCompleted,
      turn: turn,
      callId: "",
      message: response.finishReason,
      elapsedMs: implElapsedMs(started)
    ))

    var action: HarnessAction
    try:
      action = implDecodeResponse(response,
        options.protocol == tpkLegacy and not options.toolsDisabled)
    except HarnessProtocolError:
      # A malformed textual action cannot be associated with a native tool
      # response, but it is also inert: no executor has seen it.  Auto/loop/
      # parallel runs use one remaining bounded model turn to repair the wire
      # format instead of failing an otherwise healthy long-running task.
      # Direct mode remains exactly one turn and therefore fails immediately.
      if options.kind == hkDirect or turn >= options.budget.maxTurns:
        raise
      const MAX_INVALID_ACTION_CONTEXT = 4096
      var invalidText = response.content
      if invalidText.len > MAX_INVALID_ACTION_CONTEXT:
        var prefixBytes = MAX_INVALID_ACTION_CONTEXT
        while prefixBytes > 0 and prefixBytes < invalidText.len and
            (byte(invalidText[prefixBytes]) and 0xC0'u8) == 0x80'u8:
          prefixBytes -= 1
        invalidText = invalidText[0 ..< prefixBytes] &
          "\n[invalid action text compacted]"
      messages.add(LlmMessage(
        role: "assistant",
        content: invalidText,
        toolCallId: "",
        toolCallsJson: ""
      ))
      messages.add(LlmMessage(
        role: "user",
        content: "Protocol correction: the previous textual action was " &
          "invalid and nothing was executed. Return exactly one valid action " &
          "using the declared read-only tool, or strict JSON with type " &
          "answer/refuse/tool_calls. Do not include Markdown or commentary.",
        toolCallId: "",
        toolCallsJson: ""
      ))
      implEmit(options, HarnessEvent(
        kind: hekActionProposed,
        turn: turn,
        callId: "",
        message: "invalid textual action; requesting protocol correction",
        elapsedMs: implElapsedMs(started)
      ))
      continue
    implEmit(options, HarnessEvent(
      kind: hekActionProposed,
      turn: turn,
      callId: "",
      message: $action.kind,
      elapsedMs: implElapsedMs(started)
    ))
    case action.kind
    of hakAnswer:
      let value = HarnessResult(
        output: action.text,
        exitCode: 0,
        finalCommand: "",
        observations: observations,
        metrics: metrics,
        termination: htAnswer,
        refused: false
      )
      implEmit(options, HarnessEvent(
        kind: hekRunCompleted,
        turn: turn,
        callId: "",
        message: "answer",
        elapsedMs: implElapsedMs(started)
      ))
      return implFinish(value, started)
    of hakRefuse:
      let value = HarnessResult(
        output: action.text,
        exitCode: 1,
        finalCommand: "",
        observations: observations,
        metrics: metrics,
        termination: htRefused,
        refused: true
      )
      implEmit(options, HarnessEvent(
        kind: hekRunCompleted,
        turn: turn,
        callId: "",
        message: "refused",
        elapsedMs: implElapsedMs(started)
      ))
      return implFinish(value, started)
    of hakToolCalls:
      if options.toolsDisabled:
        raise newException(HarnessProtocolError,
          "tool calls are disabled for this request")
      if action.calls.len == 0:
        raise newException(HarnessProtocolError,
          "tool action contains no calls")
      var callIds: seq[string] = @[]
      for call in action.calls:
        if call.id.len == 0:
          raise newException(HarnessProtocolError,
            "tool call identifier must not be empty")
        if call.id in callIds:
          raise newException(HarnessProtocolError,
            fmt"duplicate tool call identifier '{call.id}'")
        callIds.add(call.id)
      if options.kind == hkDirect and action.calls.len > 1:
        raise newException(HarnessProtocolError,
          "direct harness permits one tool call")
      if metrics.toolCalls + action.calls.len > options.budget.maxToolCalls:
        let value = HarnessResult(
          output: "harness tool-call budget exhausted",
          exitCode: 1,
          finalCommand: "",
          observations: observations,
          metrics: metrics,
          termination: htBudgetExhausted,
          refused: false
        )
        implEmit(options, HarnessEvent(
          kind: hekRunFailed,
          turn: turn,
          callId: "",
          message: "tool-call budget exhausted",
          elapsedMs: implElapsedMs(started)
        ))
        return implFinish(value, started)

      for call in action.calls:
        implEmit(options, HarnessEvent(
          kind: hekToolStarted,
          turn: turn,
          callId: call.id,
          message: call.purpose,
          elapsedMs: implElapsedMs(started)
        ))
      let parallelism =
        if options.kind in {hkAuto, hkParallel}:
          min(options.budget.maxParallel, action.calls.len)
        else:
          1
      let batch = runTools(action.calls, parallelism)
      if batch.len != action.calls.len:
        raise newException(GetError,
          "tool executor returned an incomplete observation batch")
      for index, observation in batch:
        let call = action.calls[index]
        if observation.callId != call.id or
            observation.toolName != call.toolName or
            (if observation.proposedCommand.len > 0:
               observation.proposedCommand != call.command
             else: observation.command != call.command):
          raise newException(GetError,
            "tool executor returned an observation that does not match " &
              "its proposed call")
      metrics.toolCalls += action.calls.len
      for observation in batch:
        observations.add(observation)
        implEmit(options, HarnessEvent(
          kind: hekToolCompleted,
          turn: turn,
          callId: observation.callId,
          message: $observation.exitCode,
          elapsedMs: observation.elapsedMs
        ))

      var needsContinuation = false
      for call in action.calls:
        if call.resultMode == trmContinue:
          needsContinuation = true
      if options.kind != hkDirect and requestNeedsInterpretation:
        needsContinuation = true
      # Auto/loop/parallel strategies recover from policy false positives and
      # ordinary finite reader failures (no matches, missing files/tools).
      # A hard timeout or output cap is returned immediately when the model
      # requested raw output: automatically repeating a resource-limit breach
      # would turn one bounded command into maxTurns expensive attempts.
      if options.kind != hkDirect:
        for observation in batch:
          if observation.policyRejected or (observation.exitCode != 0 and
              not observation.timedOut and not observation.truncated):
            needsContinuation = true
      if options.kind == hkDirect:
        needsContinuation = false
      if not needsContinuation:
        let value = HarnessResult(
          output: implFormatRawOutput(batch),
          exitCode: implBatchExitCode(batch),
          finalCommand: batch[^1].command,
          observations: observations,
          metrics: metrics,
          termination: htRawToolResult,
          refused: false
        )
        implEmit(options, HarnessEvent(
          kind: hekRunCompleted,
          turn: turn,
          callId: "",
          message: "raw tool result",
          elapsedMs: implElapsedMs(started)
        ))
        return implFinish(value, started)
      if turn >= options.budget.maxTurns:
        let batchCode = implBatchExitCode(batch)
        let rawOutput = implFormatRawOutput(batch)
        let budgetOutput =
          if rawOutput.len > 0:
            rawOutput & "\n[harness model-turn budget exhausted]"
          else:
            "harness model-turn budget exhausted"
        let value = HarnessResult(
          output: budgetOutput,
          exitCode:
            if batchCode == 0: 1
            else: batchCode,
          finalCommand: batch[^1].command,
          observations: observations,
          metrics: metrics,
          termination: htBudgetExhausted,
          refused: false
        )
        implEmit(options, HarnessEvent(
          kind: hekRunFailed,
          turn: turn,
          callId: "",
          message: "model-turn budget exhausted; returning observation",
          elapsedMs: implElapsedMs(started)
        ))
        return implFinish(value, started)
      implAppendFeedback(messages, response, batch)

  let value = HarnessResult(
    output: "harness model-turn budget exhausted",
    exitCode: 1,
    finalCommand:
      if observations.len > 0: observations[^1].command
      else: "",
    observations: observations,
    metrics: metrics,
    termination: htBudgetExhausted,
    refused: false
  )
  implEmit(options, HarnessEvent(
    kind: hekRunFailed,
    turn: options.budget.maxTurns,
    callId: "",
    message: "model-turn budget exhausted",
    elapsedMs: implElapsedMs(started)
  ))
  result = implFinish(value, started)
