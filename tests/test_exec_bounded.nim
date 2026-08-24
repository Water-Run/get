## Tests bounded shell execution for get v3.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_exec_bounded.nim
## :License: AGPL-3.0
##
## This suite verifies normal output capture, byte caps, and process deadlines.
## It uses only read-only shell operations and runs independently of an API key.

{.experimental: "strictFuncs".}

import std/[strutils, unittest]

import exec

## Verifies bounded process execution and metadata.
suite "bounded command execution":
  when defined(posix):
    test "captures normal command output":
      let value = executeCommandBounded(
        "printf 'ready'", "bash", 2, 1024)
      check value.output == "ready"
      check value.exitCode == 0
      check not value.timedOut
      check not value.truncated

    test "caps captured output":
      let value = executeCommandBounded(
        "printf '1234567890'", "bash", 2, 5)
      check value.output == "12345"
      check value.truncated
      check not value.timedOut

    test "stops a silent process at its deadline":
      let value = executeCommandBounded(
        "sleep 2", "bash", 1, 1024)
      check value.timedOut
      check value.elapsedMs >= 900
      check value.elapsedMs < 1800
      check value.exitCode != 0
  else:
    test "captures normal command output":
      let value = executeCommandBounded(
        "echo ready", "cmd", 2, 1024)
      check value.output.strip() == "ready"
      check value.exitCode == 0

    test "caps captured output":
      let value = executeCommandBounded(
        "echo 1234567890", "cmd", 2, 5)
      check value.output == "12345"
      check value.truncated
      check not value.timedOut

    test "stops a silent process at its deadline":
      let value = executeCommandBounded(
        "ping -n 3 127.0.0.1 >NUL", "cmd", 1, 1024)
      check value.timedOut
      check value.elapsedMs >= 900
      check value.elapsedMs < 2_000
      check value.exitCode != 0
