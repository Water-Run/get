## Simple file-based execution logging for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-13
## :File: logger.nim
## :License: AGPL-3.0
##
## This module appends timestamped entries to the get.log file in
## the application configuration directory.  Each entry records the
## user query, generated command, exit code, and a truncated preview
## of the command output.  Logging failures are silently ignored so
## that they never prevent normal tool operation.

{.experimental: "strictFuncs".}

import std/[strformat, strutils, times, os]

import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Maximum number of output characters stored in a single log entry.
## Longer output is truncated with a trailing ellipsis.
const MAX_LOG_OUTPUT_LEN* = 4096

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Appends a log entry for a single query execution.  Silently
## ignores all I/O errors so that logging never interrupts the user.
##
## :param query: The original user query text.
## :param command: The shell command that was executed.
## :param output: The captured output of the command.
## :param exitCode: The process exit code.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — writes to filesystem.
##     discard
proc logExecution*(
  query: string,
  command: string,
  output: string,
  exitCode: int
) =
  try:
    let path = getLogFilePath()
    let ts = now().format("yyyy-MM-dd HH:mm:ss")
    let preview =
      if output.len > MAX_LOG_OUTPUT_LEN:
        output[0 ..< MAX_LOG_OUTPUT_LEN] & "..."
      else:
        output
    var f: File
    if not open(f, path, fmAppend):
      return
    defer: f.close()
    f.writeLine(fmt"[{ts}] query: {query}")
    f.writeLine(fmt"[{ts}] command: {command}")
    f.writeLine(fmt"[{ts}] exit: {exitCode}")
    if preview.len > 0:
      f.writeLine(fmt"[{ts}] output: {preview}")
    f.writeLine("")
  except CatchableError:
    # Logging must never crash the tool.
    discard