## Tests the query loop.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-09-23
## :File: test_harness_runtime.nim
## :License: AGPL-3.0
##
## Deterministic model and tool callbacks check the loop's contract without
## network access or real execution: answers stop the loop, tool batches run
## whole and return in call order, and every stop keeps its observations.

{.experimental: "strictFuncs".}

import std/[json, os, strutils, unittest]

import harness_runtime
import harness_types
import llm
import utils
import observations

func fakeObservation(call: ToolCall): ToolObservation =
  ToolObservation(callId: call.id, toolName: call.toolName,
    command: call.command, output: "output:" & call.command, exitCode: 0,
    elapsedMs: 1, status: osCompleted)

func initialMessages(): seq[LlmMessage] =
  @[LlmMessage(role: "system", content: "test"),
    LlmMessage(role: "user", content: "query")]

## A strict JSON action calling run_shell once per command.
func jsonCalls(commands: varargs[string]): LlmResponse =
  var calls = newJArray()
  for index, command in commands:
    calls.add(%*{"id": "c" & $(index + 1), "tool": "run_shell",
      "arguments": {"command": command}})
  LlmResponse(content: $(%*{"type": "tool_calls", "calls": calls}))

## A provider-native response calling run_shell once per command.
func nativeCalls(commands: varargs[string]): LlmResponse =
  var raw = newJArray()
  for index, command in commands:
    let id = "n" & $(index + 1)
    let arguments = $(%*{"command": command})
    result.toolCalls.add(LlmToolCall(id: id, name: "run_shell", arguments: arguments))
    raw.add(%*{"id": id, "type": "function",
      "function": {"name": "run_shell", "arguments": arguments}})
  result.toolCallsJson = $raw
  result.finishReason = "tool_calls"

let succeed: ToolBatchProc = proc(calls: seq[ToolCall],
    maxParallel: int): seq[ToolObservation] =
  for call in calls:
    result.add(fakeObservation(call))

func options(protocol = tpkNative, toolsDisabled = false): HarnessRunOptions =
  HarnessRunOptions(protocol: protocol, budget: defaultRunBudget(),
    toolsDisabled: toolsDisabled)

suite "query loop":
  test "an answer without tool calls stops after one request":
    var requests = 0
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      check enableNativeTools
      LlmResponse(content: "Linux", tokensUsed: 4)
    let value = runHarness(initialMessages(), options(), model, succeed)
    check requests == 1
    check value.output == "Linux"
    check value.exitCode == 0
    check value.termination == htAnswer
    check value.metrics.inputOutputTokens == 4

  test "text-only requests never offer tools and may answer with code":
    const answer = "# Example\n```sh\nprintf sample\n```"
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      check not enableNativeTools
      LlmResponse(content: answer)
    let forbidden: ToolBatchProc = proc(calls: seq[ToolCall],
        maxParallel: int): seq[ToolObservation] =
      check false
    for protocol in [tpkAuto, tpkNative, tpkJson]:
      let value = runHarness(initialMessages(),
        options(protocol, toolsDisabled = true), model, forbidden)
      check value.output == answer
      check value.metrics.toolCalls == 0

  test "text-only requests reject a tool action":
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      jsonCalls("pwd")
    expect HarnessProtocolError:
      discard runHarness(initialMessages(),
        options(toolsDisabled = true), model, succeed)

  test "native observations return in call order before the next request":
    var requests = 0
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      if requests == 1:
        check allowParallel
        return nativeCalls("uname", "pwd", "id")
      check messages[^4].role == "assistant"
      check messages[^3].toolCallId == "n1"
      check messages[^2].toolCallId == "n2"
      check messages[^1].toolCallId == "n3"
      check messages[^1].content.contains("output:id")
      LlmResponse(content: "done")
    var parallelism = 0
    let tools: ToolBatchProc = proc(calls: seq[ToolCall],
        maxParallel: int): seq[ToolObservation] =
      parallelism = maxParallel
      for call in calls: result.add(fakeObservation(call))
    let value = runHarness(initialMessages(), options(), model, tools)
    check requests == 2
    check parallelism == 3
    check value.output == "done"
    check value.metrics.toolCalls == 3
    check value.observations.len == 3

  test "strict JSON observations go back as one user message":
    var requests = 0
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      if requests == 1:
        check not enableNativeTools
        return jsonCalls("pwd")
      check messages[^1].role == "user"
      check messages[^1].content.startsWith("Tool observations (JSON): ")
      LlmResponse(content: "{\"type\":\"answer\",\"text\":\"/tmp\"}")
    let value = runHarness(initialMessages(), options(tpkJson), model, succeed)
    check value.output == "/tmp"

  test "a denied call leaves an observation and exits 126 without evidence":
    var requests = 0
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      if requests == 1:
        return nativeCalls("printf x > file")
      check messages[^1].content.contains("\"policy_rejected\":true")
      LlmResponse(content: "could not inspect")
    let deny: ToolBatchProc = proc(calls: seq[ToolCall],
        maxParallel: int): seq[ToolObservation] =
      @[ToolObservation(callId: calls[0].id, toolName: calls[0].toolName,
        command: calls[0].command, exitCode: 126, policyRejected: true,
        notExecuted: true, status: osDenied, output: "denied")]
    let value = runHarness(initialMessages(), options(), model, deny)
    check value.termination == htAnswer
    check value.exitCode == 126
    check value.metrics.toolCalls == 0
    check value.metrics.toolRejections == 1

  test "a denied call repaired by another reader succeeds":
    var requests = 0
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      case requests
      of 1: jsonCalls("unknown-reader")
      of 2: jsonCalls("uname")
      else: LlmResponse(content: "Linux")
    let tools: ToolBatchProc = proc(calls: seq[ToolCall],
        maxParallel: int): seq[ToolObservation] =
      result = @[fakeObservation(calls[0])]
      if calls[0].command == "unknown-reader":
        result[0].policyRejected = true
        result[0].notExecuted = true
        result[0].exitCode = 126
        result[0].status = osDenied
    let value = runHarness(initialMessages(), options(), model, tools)
    check value.exitCode == 0
    check value.metrics.toolRejections == 1
    check value.metrics.toolCalls == 1

  test "an unknown native tool gets an inert matching result":
    var requests = 0
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      if requests == 1:
        return LlmResponse(toolCalls: @[LlmToolCall(id: "wrong",
          name: "run_read-files", arguments: "{}")],
          toolCallsJson: """[{"id":"wrong","type":"function","function":{"name":"run_read-files","arguments":"{}"}}]""")
      check messages[^1].toolCallId == "wrong"
      LlmResponse(content: "recovered")
    let tools: ToolBatchProc = proc(calls: seq[ToolCall],
        maxParallel: int): seq[ToolObservation] =
      check calls[0].command.len == 0
      @[ToolObservation(callId: calls[0].id, toolName: calls[0].toolName,
        exitCode: 126, policyRejected: true, notExecuted: true,
        status: osDenied, output: "no command was executed")]
    let value = runHarness(initialMessages(), options(), model, tools)
    check value.output == "recovered"

  test "an invalid textual action is corrected within the turn cap":
    var requests = 0
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      if requests == 1:
        return LlmResponse(content: """{"type":"tool_calls",broken}""")
      check messages[^1].content.contains("nothing was executed")
      LlmResponse(content: "{\"type\":\"answer\",\"text\":\"fixed\"}")
    let value = runHarness(initialMessages(), options(tpkJson), model, succeed)
    check requests == 2
    check value.output == "fixed"
    check value.metrics.modelTurns == 2

  test "the turn cap stops with the observations kept":
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      jsonCalls("probe " & $messages.len)
    var budget = defaultRunBudget()
    budget.maxTurns = 3
    let value = runHarness(initialMessages(), HarnessRunOptions(
      protocol: tpkNative, budget: budget), model, succeed)
    check value.termination == htBudgetExhausted
    check value.exitCode == 1
    check value.observations.len == 3
    check value.output.contains("output:probe")
    check value.reason.contains("model-request limit")

  test "calls past the tool budget get a result but do not run":
    var requests = 0
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      if requests == 1:
        return nativeCalls("a", "b", "c")
      check messages[^1].content.contains("\"exit_code\":125")
      LlmResponse(content: "partial answer")
    var ran = 0
    let tools: ToolBatchProc = proc(calls: seq[ToolCall],
        maxParallel: int): seq[ToolObservation] =
      ran = calls.len
      for call in calls: result.add(fakeObservation(call))
    var budget = defaultRunBudget()
    budget.maxToolCalls = 2
    let value = runHarness(initialMessages(), HarnessRunOptions(
      protocol: tpkNative, budget: budget), model, tools)
    check ran == 2
    check value.observations.len == 3
    check value.metrics.toolCalls == 2
    check value.output == "partial answer"

  test "the same call three turns in a row stops the loop":
    var requests = 0
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      jsonCalls("uptime")
    let value = runHarness(initialMessages(), options(), model, succeed)
    check requests == 3
    check value.termination == htRepeated
    check value.exitCode == 1
    check value.observations.len == 2

  test "a model failure after tools keeps the observations":
    var requests = 0
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      if requests == 1:
        return jsonCalls("uname")
      raise newException(LlmApiError, "API returned HTTP 401: bad key")
    let value = runHarness(initialMessages(), options(), model, succeed)
    check value.termination == htModelFailed
    check value.exitCode == 1
    check value.observations.len == 1
    check value.reason.contains("401")

  test "a model failure before any tool is an error":
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      raise newException(LlmApiError, "API returned HTTP 400: bad request")
    expect LlmApiError:
      discard runHarness(initialMessages(), options(), model, succeed)

  test "the query deadline stops with exit 124":
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      sleep(1100)
      jsonCalls("slow " & $messages.len)
    var budget = defaultRunBudget()
    budget.totalTimeoutSec = 1
    let value = runHarness(initialMessages(), HarnessRunOptions(
      protocol: tpkNative, budget: budget), model, succeed)
    check value.termination == htTimedOut
    check value.exitCode == 124
    check value.observations.len == 1

  test "orphan tool results are dropped before a request":
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      for message in messages:
        check message.toolCallId != "orphan"
      LlmResponse(content: "ok")
    var messages = initialMessages()
    messages.add(LlmMessage(role: "tool", toolCallId: "orphan", content: "{}"))
    check runHarness(messages, options(), model, succeed).output == "ok"

  test "seed observations from a cached plan count as evidence":
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      LlmResponse(content: "from the plan")
    let seed = @[ToolObservation(callId: "cached-1", toolName: "run_shell",
      command: "uname", output: "Linux", status: osCompleted, required: true)]
    let value = runHarness(initialMessages(), options(), model, succeed,
      seedObservations = seed)
    check value.exitCode == 0
    check value.metrics.toolCalls == 1
    check value.observations.len == 1

  test "executor observations must match their proposed calls":
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      jsonCalls("pwd")
    let mismatch: ToolBatchProc = proc(calls: seq[ToolCall],
        maxParallel: int): seq[ToolObservation] =
      result = @[fakeObservation(calls[0])]
      result[0].command = "uname"
    expect GetError:
      discard runHarness(initialMessages(), options(), model, mismatch)
    let reviewed: ToolBatchProc = proc(calls: seq[ToolCall],
        maxParallel: int): seq[ToolObservation] =
      result = @[fakeObservation(calls[0])]
      result[0].proposedCommand = calls[0].command
      result[0].command = "uname"
    var requests = 0
    let answer: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      if requests == 1: jsonCalls("pwd") else: LlmResponse(content: "ok")
    check runHarness(initialMessages(), options(), answer, reviewed).exitCode == 0

  test "duplicate call identifiers are a protocol error":
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      LlmResponse(content: """{"type":"tool_calls","calls":[{"id":"x","tool":"run_shell","arguments":{"command":"pwd"}},{"id":"x","tool":"run_shell","arguments":{"command":"id"}}]}""")
    expect HarnessProtocolError:
      discard runHarness(initialMessages(), options(), model, succeed)

  test "an explicit refusal exits 1":
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      LlmResponse(content: """{"type":"refuse","reason":"not a read"}""")
    let value = runHarness(initialMessages(), options(), model, succeed)
    check value.termination == htRefused
    check value.exitCode == 1
    check value.output == "not a read"

  test "process events carry tool, target, status, and duration":
    var requests = 0
    let model: ModelTurnProc = proc(messages: seq[LlmMessage],
        enableNativeTools, allowParallel: bool): LlmResponse =
      inc requests
      if requests == 1: nativeCalls("uname -a", "rm x") else: LlmResponse(content: "ok")
    let tools: ToolBatchProc = proc(calls: seq[ToolCall],
        maxParallel: int): seq[ToolObservation] =
      result = @[fakeObservation(calls[0]), fakeObservation(calls[1])]
      result[1].policyRejected = true
      result[1].notExecuted = true
      result[1].status = osDenied
    var completed: seq[HarnessEvent] = @[]
    let sink: HarnessEventSink = proc(event: HarnessEvent) =
      if event.kind == hekToolCompleted: completed.add(event)
    discard runHarness(initialMessages(), HarnessRunOptions(protocol: tpkNative,
      budget: defaultRunBudget(), eventSink: sink), model, tools)
    check completed.len == 2
    check completed[0].tool == "run_shell"
    check completed[0].target == "uname -a"
    check completed[0].status == osCompleted
    check completed[0].elapsedMs == 1
    check completed[1].status == osDenied
    check completed[1].elapsedMs == -1

suite "evidence":
  test "required failures cannot be hidden by optional successful observations":
    let values = @[ToolObservation(callId: "required", required: true,
      exitCode: 1), ToolObservation(callId: "optional", exitCode: 0)]
    check answerEvidenceStatus(values) == (1, true)

  test "a required fact lost only to denial exits 126":
    let values = @[ToolObservation(callId: "required", required: true,
      exitCode: 126, policyRejected: true, notExecuted: true, status: osDenied),
      ToolObservation(callId: "optional", exitCode: 0)]
    check answerEvidenceStatus(values) == (126, true)

  test "failed corroboration cannot erase evidence for the same required fact":
    let proven = ToolObservation(callId: "direct", evidenceKey: "cpu_count",
      required: true, status: osCompleted, exitCode: 0)
    let failed = ToolObservation(callId: "corroboration", evidenceKey: "cpu_count",
      required: true, status: osUnavailable, exitCode: 1)
    check answerEvidenceStatus(@[proven, failed]) == (0, true)
    check answerEvidenceStatus(@[failed, proven]) == (0, false)
    var optionalProof = proven
    optionalProof.required = false
    check answerEvidenceStatus(@[optionalProof, failed]) == (0, true)

  test "a reused no-match remains a successful required observation":
    let value = ToolObservation(callId: "negative", toolName: "run_process",
      command: "literal process query", exitCode: 1, status: osReused,
      originalStatus: osNoMatch, notExecuted: true, required: true)
    check answerEvidenceStatus(@[value]) == (0, false)

  test "feedback preserves final totals and does not invent execution truncation":
    let value = compactObservation(ToolObservation(output:
      "first\n" & repeat("中间", 4000) & "\nTOTAL=45", exitCode: 0), 1024)
    check value.output.startsWith("first")
    check value.output.endsWith("TOTAL=45")
    check value.feedbackCompacted
    check not value.truncated
    check observationSucceeded(value)

  test "stderr feedback does not split a UTF-8 code point":
    let value = compactObservation(ToolObservation(output: "ok",
      stderr: repeat("错", 1000)), 1024)
    check value.stderr == repeat("错", 85) & "\n[stderr feedback compacted]"
    check value.feedbackCompacted
    check not value.truncated
