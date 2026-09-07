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

import std/[strutils, unittest]

when defined(posix):
  import std/[json, monotimes, os]

import harness_executor
import harness_protocol
import harness_types

when defined(posix):
  # The approved child only reads the monotonic clock, sleeps, and writes stdout.
  # Record the interval inside the subprocess, excluding shell/sandbox startup.
  if paramCount() == 3 and paramStr(1) == "--executor-probe":
    let started = getMonoTime().ticks
    sleep(parseInt(paramStr(3)))
    stdout.writeLine($(%*{
      "label": paramStr(2), "started": started, "finished": getMonoTime().ticks
    }))
    quit(0)

## Verifies stable, actually concurrent batch execution.
suite "harness tool executor":
  when defined(posix):
    test "runs independent calls concurrently in stable order":
      let probe = quoteShell(getAppFilename()) & " --executor-probe "
      let calls = @[
        ToolCall(
          id: "first",
          toolName: READ_ONLY_SHELL_TOOL,
          command: probe & "first 1000",
          purpose: "first probe",
          resultMode: trmReturnRaw
        ),
        ToolCall(
          id: "second",
          toolName: READ_ONLY_SHELL_TOOL,
          command: probe & "second 200",
          purpose: "second probe",
          resultMode: trmReturnRaw
        ),
        ToolCall(
          id: "third",
          toolName: READ_ONLY_SHELL_TOOL,
          command: probe & "third 200",
          purpose: "third probe",
          resultMode: trmReturnRaw
        )
      ]
      let budget = RunBudget(
        maxTurns: 3,
        maxToolCalls: 8,
        maxParallel: 2,
        commandTimeoutSec: 5,
        maxOutputBytes: 1024
      )
      let values = executeToolBatch(calls, "bash", budget, 2)
      require values.len == 3
      var intervals: seq[tuple[started, finished: int64]] = @[]
      for index, value in values:
        checkpoint value.output
        require value.exitCode == 0
        check not value.timedOut
        let record = parseJson(value.output)
        check record["label"].getStr() == calls[index].id
        intervals.add((record["started"].getBiggestInt(),
                       record["finished"].getBiggestInt()))
      check values[0].callId == "first"
      check values[1].callId == "second"
      check values[2].callId == "third"
      # Both short calls must overlap the long call. A serial executor or a
      # batch barrier before the third call fails without a host-speed cutoff.
      for index in 1..2:
        check intervals[index].started < intervals[0].finished
        check intervals[0].started < intervals[index].finished
  else:
    test "runs independent cmd calls in stable order":
      let calls = @[
        ToolCall(
          id: "first",
          toolName: READ_ONLY_SHELL_TOOL,
          command: "echo first",
          purpose: "first probe",
          resultMode: trmReturnRaw
        ),
        ToolCall(
          id: "second",
          toolName: READ_ONLY_SHELL_TOOL,
          command: "echo second",
          purpose: "second probe",
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
      let values = executeToolBatch(calls, "cmd", budget, 2)
      check values.len == 2
      check values[0].callId == "first"
      check values[0].output.strip() == "first"
      check values[1].callId == "second"
      check values[1].output.strip() == "second"
