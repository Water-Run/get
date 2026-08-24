## Tests the unified get v3 harness state machine.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_harness_runtime.nim
## :License: AGPL-3.0
##
## This suite injects deterministic model and tool callbacks to verify direct,
## continuation, parallel, legacy, refusal, and budget transitions without
## network access or real shell execution.

{.experimental: "strictFuncs".}

import std/[strutils, unittest]

import harness_protocol
import harness_runtime
import harness_types
import llm
import utils

## Builds one successful observation for a proposed call.
##
## :param call: Proposed read-only shell call.
## :returns: Deterministic successful observation.
func fakeObservation(call: ToolCall): ToolObservation =
  result = ToolObservation(
    callId: call.id,
    toolName: call.toolName,
    command: call.command,
    output: "output:" & call.command,
    exitCode: 0,
    elapsedMs: 1,
    timedOut: false,
    truncated: false
  )

## Returns minimal initial messages for state-machine tests.
##
## :returns: One system and one user message.
func initialMessages(): seq[LlmMessage] =
  result = @[
    LlmMessage(
      role: "system", content: "test",
      toolCallId: "", toolCallsJson: ""),
    LlmMessage(
      role: "user", content: "query",
      toolCallId: "", toolCallsJson: "")
  ]

## Verifies all strategy transitions over injected boundaries.
suite "unified harness runtime":
  test "native terminal call completes in one model turn":
    var modelCalls = 0
    let model: ModelTurnProc = proc(
      messages: seq[LlmMessage],
      enableNativeTools: bool,
      allowParallel: bool
    ): LlmResponse =
      modelCalls += 1
      check messages.len == 2
      check enableNativeTools
      check allowParallel
      result = LlmResponse(
        content: "",
        tokensUsed: 11,
        toolCalls: @[
          LlmToolCall(
            id: "call-1",
            name: READ_ONLY_SHELL_TOOL,
            arguments: "{\"command\":\"pwd\",\"result_mode\":\"return_raw\"}"
          )
        ],
        toolCallsJson: "[{\"id\":\"call-1\",\"type\":\"function\",\"function\":{" &
          "\"name\":\"run_readonly_shell\",\"arguments\":\"{}\"}}]",
        finishReason: "tool_calls"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      check maxParallel == 1
      result = @[fakeObservation(calls[0])]
    let value = runHarness(
      initialMessages(),
      HarnessRunOptions(
        kind: hkAuto,
        protocol: tpkNative,
        budget: defaultRunBudget(hkAuto),
        eventSink: nil
      ),
      model,
      tools
    )
    check modelCalls == 1
    check value.output == "output:pwd"
    check value.metrics.modelTurns == 1
    check value.metrics.modelRequests == 1
    check value.metrics.inputOutputTokens == 11
    check value.termination == htRawToolResult

  test "continuation feeds native observations into a second turn":
    var modelCalls = 0
    let model: ModelTurnProc = proc(
      messages: seq[LlmMessage],
      enableNativeTools: bool,
      allowParallel: bool
    ): LlmResponse =
      discard enableNativeTools
      discard allowParallel
      modelCalls += 1
      if modelCalls == 1:
        return LlmResponse(
          content: "",
          tokensUsed: 3,
          toolCalls: @[
            LlmToolCall(
              id: "inspect",
              name: READ_ONLY_SHELL_TOOL,
              arguments: "{\"command\":\"uname\",\"result_mode\":\"continue\"}"
            )
          ],
          toolCallsJson: "[{\"id\":\"inspect\",\"type\":\"function\"," &
            "\"function\":{\"name\":\"run_readonly_shell\",\"arguments\":\"{}\"}}]",
          finishReason: "tool_calls"
        )
      check messages[^1].role == "tool"
      check messages[^1].toolCallId == "inspect"
      result = LlmResponse(
        content: "Linux",
        tokensUsed: 5,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      discard maxParallel
      result = @[fakeObservation(calls[0])]
    let value = runHarness(
      initialMessages(),
      HarnessRunOptions(
        kind: hkLoop,
        protocol: tpkNative,
        budget: defaultRunBudget(hkLoop),
        eventSink: nil
      ),
      model,
      tools
    )
    check modelCalls == 2
    check value.output == "Linux"
    check value.observations.len == 1
    check value.metrics.inputOutputTokens == 8
    check value.termination == htAnswer

  test "direct strategy forces a continuation request to return raw":
    let model: ModelTurnProc = proc(
      messages: seq[LlmMessage],
      enableNativeTools: bool,
      allowParallel: bool
    ): LlmResponse =
      discard messages
      discard enableNativeTools
      check not allowParallel
      result = LlmResponse(
        content: "{\"type\":\"tool_calls\",\"calls\":[{" &
          "\"command\":\"date\",\"result_mode\":\"continue\"}]}",
        tokensUsed: 1,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      check maxParallel == 1
      result = @[fakeObservation(calls[0])]
    let value = runHarness(
      initialMessages(),
      HarnessRunOptions(
        kind: hkDirect,
        protocol: tpkLegacy,
        budget: defaultRunBudget(hkDirect),
        eventSink: nil
      ),
      model,
      tools
    )
    check value.metrics.modelTurns == 1
    check value.output == "output:date"
    check value.termination == htRawToolResult

  test "loop budget exhaustion preserves evidence and fails":
    let model: ModelTurnProc = proc(
      messages: seq[LlmMessage],
      enableNativeTools: bool,
      allowParallel: bool
    ): LlmResponse =
      discard messages
      discard enableNativeTools
      discard allowParallel
      result = LlmResponse(
        content: "{\"type\":\"tool_calls\",\"calls\":[{" &
          "\"command\":\"date\",\"result_mode\":\"continue\"}]}",
        tokensUsed: 1,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      check maxParallel == 1
      result = @[fakeObservation(calls[0])]
    var budget = defaultRunBudget(hkLoop)
    budget.maxTurns = 1
    let value = runHarness(
      initialMessages(),
      HarnessRunOptions(
        kind: hkLoop,
        protocol: tpkLegacy,
        budget: budget,
        eventSink: nil
      ),
      model,
      tools
    )
    check value.exitCode == 1
    check value.output.contains("output:date")
    check value.termination == htBudgetExhausted

  test "parallel strategy passes its concurrency allowance":
    let model: ModelTurnProc = proc(
      messages: seq[LlmMessage],
      enableNativeTools: bool,
      allowParallel: bool
    ): LlmResponse =
      discard messages
      discard enableNativeTools
      check allowParallel
      result = LlmResponse(
        content: "{\"type\":\"tool_calls\",\"calls\":[" &
          "{\"id\":\"a\",\"command\":\"pwd\"}," &
          "{\"id\":\"b\",\"command\":\"uname\"}]}",
        tokensUsed: 1,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      check calls.len == 2
      check maxParallel == 2
      result = @[
        fakeObservation(calls[0]),
        fakeObservation(calls[1])
      ]
    let value = runHarness(
      initialMessages(),
      HarnessRunOptions(
        kind: hkParallel,
        protocol: tpkLegacy,
        budget: defaultRunBudget(hkParallel),
        eventSink: nil
      ),
      model,
      tools
    )
    check value.observations.len == 2
    check value.output.contains("[a] pwd")
    check value.output.contains("[b] uname")

  test "explicit refusal has a typed termination reason":
    let model: ModelTurnProc = proc(
      messages: seq[LlmMessage],
      enableNativeTools: bool,
      allowParallel: bool
    ): LlmResponse =
      discard messages
      discard enableNativeTools
      discard allowParallel
      result = LlmResponse(
        content: "{\"type\":\"refuse\",\"reason\":\"unsafe\"}",
        tokensUsed: 1,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      discard calls
      discard maxParallel
      result = @[]
    let value = runHarness(
      initialMessages(),
      HarnessRunOptions(
        kind: hkAuto,
        protocol: tpkLegacy,
        budget: defaultRunBudget(hkAuto),
        eventSink: nil
      ),
      model,
      tools
    )
    check value.refused
    check value.exitCode == 1
    check value.termination == htRefused
