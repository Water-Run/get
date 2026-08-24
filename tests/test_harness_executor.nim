## Tests ordered parallel execution for the get v3 harness.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_harness_executor.nim
## :License: AGPL-3.0
##
## This suite verifies that independent read-only calls run concurrently while
## observations remain in model-provided order and retain bounded metadata.

{.experimental: "strictFuncs".}

import std/[monotimes, unittest, times]

import harness_executor
import harness_protocol
import harness_types

## Verifies stable, actually concurrent batch execution.
suite "harness tool executor":
  when defined(posix):
    test "runs independent calls concurrently in stable order":
      let calls = @[
        ToolCall(
          id: "first",
          toolName: READ_ONLY_SHELL_TOOL,
          command: "sleep 0.6; printf first",
          purpose: "first probe",
          resultMode: trmReturnRaw
        ),
        ToolCall(
          id: "second",
          toolName: READ_ONLY_SHELL_TOOL,
          command: "sleep 0.2; printf second",
          purpose: "second probe",
          resultMode: trmReturnRaw
        ),
        ToolCall(
          id: "third",
          toolName: READ_ONLY_SHELL_TOOL,
          command: "sleep 0.2; printf third",
          purpose: "third probe",
          resultMode: trmReturnRaw
        )
      ]
      let budget = RunBudget(
        maxTurns: 3,
        maxToolCalls: 8,
        maxParallel: 2,
        commandTimeoutSec: 2,
        maxOutputBytes: 1024
      )
      let started = getMonoTime()
      let values = executeToolBatch(calls, "bash", budget, 2)
      let elapsed = (getMonoTime() - started).inMilliseconds
      checkpoint "elapsed=" & $elapsed & " tool=" &
        $values[0].elapsedMs & "," & $values[1].elapsedMs &
        "," & $values[2].elapsedMs
      check values.len == 3
      check values[0].callId == "first"
      check values[0].output == "first"
      check values[1].callId == "second"
      check values[1].output == "second"
      check values[2].callId == "third"
      check values[2].output == "third"
      check elapsed < 750
  else:
    test "empty batch is valid":
      let budget = defaultRunBudget(hkParallel)
      check executeToolBatch(@[], "cmd", budget, 2).len == 0
