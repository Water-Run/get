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
    truncated: false,
    policyRejected: false
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

  test "successful empty terminal output is explicit":
    let model: ModelTurnProc = proc(
      messages: seq[LlmMessage],
      enableNativeTools: bool,
      allowParallel: bool
    ): LlmResponse =
      discard messages
      discard enableNativeTools
      discard allowParallel
      result = LlmResponse(
        content: "",
        tokensUsed: 1,
        toolCalls: @[
          LlmToolCall(
            id: "empty",
            name: READ_ONLY_SHELL_TOOL,
            arguments: "{\"command\":\"printf ''\"," &
              "\"result_mode\":\"return_raw\"}"
          )
        ],
        toolCallsJson: "[]",
        finishReason: "tool_calls"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      discard maxParallel
      result = @[
        ToolObservation(
          callId: calls[0].id,
          toolName: calls[0].toolName,
          command: calls[0].command,
          output: "",
          exitCode: 0,
          elapsedMs: 1,
          timedOut: false,
          truncated: false,
          policyRejected: false
        )
      ]
    let value = runHarness(
      initialMessages(),
      HarnessRunOptions(
        kind: hkDirect,
        protocol: tpkNative,
        budget: defaultRunBudget(hkDirect),
        eventSink: nil
      ),
      model,
      tools
    )
    check value.exitCode == 0
    check value.output == "(command completed with no output)"
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

  test "auto strategy requests a safe revision after policy rejection":
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
          tokensUsed: 2,
          toolCalls: @[
            LlmToolCall(
              id: "denied",
              name: READ_ONLY_SHELL_TOOL,
              arguments: "{\"command\":\"find . -exec sh -c bad {} \\\\;\"," &
                "\"result_mode\":\"return_raw\"}"
            )
          ],
          toolCallsJson: "[{\"id\":\"denied\",\"type\":\"function\"," &
            "\"function\":{\"name\":\"run_readonly_shell\"," &
            "\"arguments\":\"{}\"}}]",
          finishReason: "tool_calls"
        )
      check messages[^1].role == "tool"
      check messages[^1].content.contains("\"policy_rejected\":true")
      check messages[^1].content.contains("before execution")
      result = LlmResponse(
        content: "safe revision completed",
        tokensUsed: 3,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      discard maxParallel
      result = @[
        ToolObservation(
          callId: calls[0].id,
          toolName: calls[0].toolName,
          command: calls[0].command,
          output: "read-only policy rejected this command before execution",
          exitCode: 126,
          elapsedMs: 0,
          timedOut: false,
          truncated: false,
          policyRejected: true
        )
      ]
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
    check modelCalls == 2
    check value.output == "safe revision completed"
    check value.exitCode == 0
    check value.observations.len == 1
    check value.observations[0].policyRejected
    check value.termination == htAnswer

  test "unknown native tool is fed back without becoming executable":
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
          tokensUsed: 2,
          toolCalls: @[
            LlmToolCall(
              id: "wrong-tool",
              name: "run_read-files",
              arguments: "{\"path\":\"/etc/passwd\"}"
            )
          ],
          toolCallsJson: "[{\"id\":\"wrong-tool\",\"type\":\"function\"," &
            "\"function\":{\"name\":\"run_read-files\"," &
            "\"arguments\":\"{}\"}}]",
          finishReason: "tool_calls"
        )
      check messages[^1].role == "tool"
      check messages[^1].toolCallId == "wrong-tool"
      check messages[^1].content.contains("no command was executed")
      result = LlmResponse(
        content: "Recovered safely.",
        tokensUsed: 2,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      discard maxParallel
      check calls.len == 1
      check calls[0].toolName == "run_read-files"
      check calls[0].command.len == 0
      result = @[
        ToolObservation(
          callId: calls[0].id,
          toolName: calls[0].toolName,
          command: calls[0].command,
          output: "provider proposed an unsupported tool; " &
            "no command was executed.",
          exitCode: 126,
          elapsedMs: 0,
          timedOut: false,
          truncated: false,
          policyRejected: true
        )
      ]
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
    check modelCalls == 2
    check value.output == "Recovered safely."
    check value.observations.len == 1
    check value.observations[0].policyRejected
    check value.termination == htAnswer

  test "auto strategy interprets an ordinary nonzero reader result":
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
          tokensUsed: 2,
          toolCalls: @[
            LlmToolCall(
              id: "no-match",
              name: READ_ONLY_SHELL_TOOL,
              arguments: "{\"command\":\"grep -R TODO ./src\"," &
                "\"result_mode\":\"return_raw\"}"
            )
          ],
          toolCallsJson: "[{\"id\":\"no-match\",\"type\":\"function\"," &
            "\"function\":{\"name\":\"run_readonly_shell\"," &
            "\"arguments\":\"{}\"}}]",
          finishReason: "tool_calls"
        )
      check messages[^1].role == "tool"
      check messages[^1].content.contains("\"exit_code\":1")
      check not messages[^1].content.contains("\"policy_rejected\":true")
      result = LlmResponse(
        content: "No TODO markers were found under src.",
        tokensUsed: 3,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      discard maxParallel
      result = @[
        ToolObservation(
          callId: calls[0].id,
          toolName: calls[0].toolName,
          command: calls[0].command,
          output: "",
          exitCode: 1,
          elapsedMs: 1,
          timedOut: false,
          truncated: false,
          policyRejected: false
        )
      ]
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
    check modelCalls == 2
    check value.output == "No TODO markers were found under src."
    check value.exitCode == 0
    check value.observations.len == 1
    check value.observations[0].exitCode == 1
    check not value.observations[0].policyRejected
    check value.termination == htAnswer

  test "auto strategy does not repeat a raw timeout":
    var modelCalls = 0
    let model: ModelTurnProc = proc(
      messages: seq[LlmMessage],
      enableNativeTools: bool,
      allowParallel: bool
    ): LlmResponse =
      discard messages
      discard enableNativeTools
      discard allowParallel
      modelCalls += 1
      result = LlmResponse(
        content: "",
        tokensUsed: 2,
        toolCalls: @[
          LlmToolCall(
            id: "bounded-timeout",
            name: READ_ONLY_SHELL_TOOL,
            arguments: "{\"command\":\"sleep 10\"," &
              "\"result_mode\":\"return_raw\"}"
          )
        ],
        toolCallsJson: "[]",
        finishReason: "tool_calls"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      discard maxParallel
      result = @[
        ToolObservation(
          callId: calls[0].id,
          toolName: calls[0].toolName,
          command: calls[0].command,
          output: "",
          exitCode: 137,
          elapsedMs: 1_000,
          timedOut: true,
          truncated: false,
          policyRejected: false
        )
      ]
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
    check value.output == "command timed out"
    check value.exitCode == 124
    check value.observations.len == 1
    check value.termination == htRawToolResult

  test "summary intent overrides an accidental raw tool result":
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
          tokensUsed: 2,
          toolCalls: @[
            LlmToolCall(
              id: "composition",
              name: READ_ONLY_SHELL_TOOL,
              arguments: "{\"command\":\"find . -type f\"," &
                "\"result_mode\":\"return_raw\"}"
            )
          ],
          toolCallsJson: "[]",
          finishReason: "tool_calls"
        )
      check messages[^1].role == "tool"
      check messages[^1].content.contains("model feedback compacted")
      check messages[^1].content.len < 14_000
      result = LlmResponse(
        content: "Mostly Nim source with Python tests.",
        tokensUsed: 3,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      discard maxParallel
      var observation = fakeObservation(calls[0])
      observation.output = repeat("A", 20_000) & "最终标记"
      result = @[observation]
    var messages = initialMessages()
    messages[1].content = "总结目录的代码组成"
    let value = runHarness(
      messages,
      HarnessRunOptions(
        kind: hkAuto,
        protocol: tpkNative,
        budget: defaultRunBudget(hkAuto),
        eventSink: nil
      ),
      model,
      tools
    )
    check modelCalls == 2
    check value.output == "Mostly Nim source with Python tests."
    check value.exitCode == 0
    check value.observations[0].output.endsWith("最终标记")
    check value.observations[0].output.len > 20_000
    check value.termination == htAnswer

  test "evidence intent overrides an accidental raw exit-status result":
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
          tokensUsed: 1,
          toolCalls: @[
            LlmToolCall(
              id: "no-match-status",
              name: READ_ONLY_SHELL_TOOL,
              arguments: "{\"command\":\"grep absent file; echo exit=$?\"," &
                "\"result_mode\":\"return_raw\"}"
            )
          ],
          toolCallsJson: "[]",
          finishReason: "tool_calls"
        )
      check messages[^1].role == "tool"
      check messages[^1].content.contains("exit_status=1")
      result = LlmResponse(
        content: "No match exists.",
        tokensUsed: 1,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      discard maxParallel
      var observation = fakeObservation(calls[0])
      observation.output = "exit_status=1"
      result = @[observation]
    var messages = initialMessages()
    messages[1].content =
      "Treat exit 1 as evidence and clearly say that no match exists."
    let value = runHarness(
      messages,
      HarnessRunOptions(
        kind: hkAuto,
        protocol: tpkNative,
        budget: defaultRunBudget(hkAuto),
        eventSink: nil
      ),
      model,
      tools
    )
    check modelCalls == 2
    check value.output == "No match exists."
    check value.exitCode == 0
    check value.termination == htAnswer

  test "identical-file intent interprets a silent cmp success":
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
          tokensUsed: 1,
          toolCalls: @[
            LlmToolCall(
              id: "cmp-identical",
              name: READ_ONLY_SHELL_TOOL,
              arguments: "{\"command\":\"cmp -s ./a ./b\"," &
                "\"result_mode\":\"return_raw\"}"
            )
          ],
          toolCallsJson: "[]",
          finishReason: "tool_calls"
        )
      check messages[^1].role == "tool"
      check messages[^1].content.contains("cmp exit 0 means")
      result = LlmResponse(
        content: "The files are identical.",
        tokensUsed: 1,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      discard maxParallel
      var observation = fakeObservation(calls[0])
      observation.output = ""
      result = @[observation]
    var messages = initialMessages()
    messages[1].content = "Determine whether ./a and ./b are identical."
    let value = runHarness(
      messages,
      HarnessRunOptions(
        kind: hkAuto,
        protocol: tpkNative,
        budget: defaultRunBudget(hkAuto),
        eventSink: nil
      ),
      model,
      tools
    )
    check modelCalls == 2
    check value.output == "The files are identical."
    check value.exitCode == 0
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

  test "executor observations must match their proposed calls":
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
          "\"id\":\"expected\",\"command\":\"pwd\"}]}",
        tokensUsed: 1,
        toolCalls: @[],
        toolCallsJson: "",
        finishReason: "stop"
      )
    let tools: ToolBatchProc = proc(
      calls: seq[ToolCall],
      maxParallel: int
    ): seq[ToolObservation] =
      discard maxParallel
      var mismatched = fakeObservation(calls[0])
      mismatched.callId = "wrong-call"
      result = @[mismatched]
    expect GetError:
      discard runHarness(
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

  test "automatic harness repairs a malformed textual action in-band":
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
          content: "{\"type\":\"tool_calls\",broken}",
          tokensUsed: 2,
          toolCalls: @[],
          toolCallsJson: "",
          finishReason: "stop"
        )
      check messages[^2].role == "assistant"
      check messages[^1].role == "user"
      check messages[^1].content.contains("nothing was executed")
      check messages[^1].content.contains("strict JSON")
      result = LlmResponse(
        content: "{\"type\":\"answer\",\"text\":\"repaired\"}",
        tokensUsed: 2,
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
      check false
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
    check modelCalls == 2
    check value.output == "repaired"
    check value.metrics.modelTurns == 2
    check value.metrics.toolCalls == 0
    check value.termination == htAnswer

  test "direct harness does not exceed one turn to repair malformed text":
    var modelCalls = 0
    let model: ModelTurnProc = proc(
      messages: seq[LlmMessage],
      enableNativeTools: bool,
      allowParallel: bool
    ): LlmResponse =
      discard messages
      discard enableNativeTools
      discard allowParallel
      modelCalls += 1
      result = LlmResponse(
        content: "{\"type\":\"answer\",broken}",
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
    expect HarnessProtocolError:
      discard runHarness(
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
    check modelCalls == 1

  test "text-only requests do not expose native tools":
    var toolRan = false
    let model: ModelTurnProc = proc(
      messages: seq[LlmMessage],
      enableNativeTools: bool,
      allowParallel: bool
    ): LlmResponse =
      discard messages
      discard allowParallel
      check not enableNativeTools
      result = LlmResponse(
        content: "42",
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
      toolRan = true
      result = @[]
    let value = runHarness(
      initialMessages(),
      HarnessRunOptions(
        kind: hkAuto,
        protocol: tpkNative,
        budget: defaultRunBudget(hkAuto),
        toolsDisabled: true,
        eventSink: nil
      ),
      model,
      tools
    )
    check value.output == "42"
    check not toolRan

  test "text-only requests reject textual tool actions":
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
          "\"command\":\"pwd\",\"result_mode\":\"return_raw\"}]}",
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
    expect HarnessProtocolError:
      discard runHarness(
        initialMessages(),
        HarnessRunOptions(
          kind: hkAuto,
          protocol: tpkLegacy,
          budget: defaultRunBudget(hkAuto),
          toolsDisabled: true,
          eventSink: nil
        ),
        model,
        tools
      )
