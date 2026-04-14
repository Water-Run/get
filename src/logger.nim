## Simple file-based execution logging for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-14
## :File: logger.nim
## :License: AGPL-3.0
##
## This module appends timestamped entries to the get.log file in
## the application configuration directory.  Each entry records the
## user query, generated command, exit code, and a truncated preview
## of the command output.  Logging failures are silently ignored so
## that they never prevent normal tool operation.
##
## It also provides log management commands: status display,
## cleaning, and entry-count enforcement.  When maxEntries is 0
## (disabled) no trimming is performed.

{.experimental: "strictFuncs".}

import std/[strformat, strutils, times, os]

import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Maximum number of output characters stored in a single log entry.
const MAX_LOG_OUTPUT_LEN* = 4096

## Separator that marks the boundary between log entries.
const LOG_ENTRY_SEPARATOR = "\n\n"

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Counts the number of log entries in the file.
##
## :param content: The full log file content.
## :returns: The number of entries detected.
func implCountEntries(content: string): int =
  result = 0
  for line in content.splitLines():
    if line.contains("] query: "):
      result += 1

## Trims the log content so that at most maxEntries remain.
##
## :param content: The full log file content.
## :param maxEntries: Maximum entries to retain.
## :returns: The trimmed content.
func implTrimEntries(
  content: string,
  maxEntries: int
): string =
  if maxEntries <= 0:
    return content
  let blocks = content.split(LOG_ENTRY_SEPARATOR)
  var entries: seq[string] = @[]
  for b in blocks:
    if b.strip().len > 0:
      entries.add(b)
  if entries.len <= maxEntries:
    return content
  let kept = entries[entries.len - maxEntries .. ^1]
  result = kept.join(LOG_ENTRY_SEPARATOR) & "\n"

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Appends a log entry for a single query execution.  Silently
## ignores all I/O errors.  When maxEntries is positive, enforces
## the cap by trimming oldest entries.  When maxEntries is 0
## (disabled) no trimming is performed.
##
## :param query: The original user query text.
## :param command: The shell command that was executed.
## :param output: The captured output of the command.
## :param exitCode: The process exit code.
## :param maxEntries: Maximum entries to retain (0 = unlimited).
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — writes to filesystem.
##     discard
proc logExecution*(
  query: string,
  command: string,
  output: string,
  exitCode: int,
  maxEntries: int = 0
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
    f.writeLine(fmt"[{ts}] query: {query}")
    f.writeLine(fmt"[{ts}] command: {command}")
    f.writeLine(fmt"[{ts}] exit: {exitCode}")
    if preview.len > 0:
      f.writeLine(fmt"[{ts}] output: {preview}")
    f.writeLine("")
    f.close()
    if maxEntries > 0:
      let content = readFile(path)
      let count = implCountEntries(content)
      if count > maxEntries:
        let trimmed = implTrimEntries(
          content, maxEntries)
        writeFile(path, trimmed)
  except CatchableError:
    discard

## Removes all content from the log file.
##
## :returns: The number of entries that were removed.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — modifies filesystem.
##     discard
proc cleanLog*(): int =
  let path = getLogFilePath()
  if not fileExists(path):
    return 0
  try:
    let content = readFile(path)
    result = implCountEntries(content)
    writeFile(path, "")
  except CatchableError:
    result = 0

## Prints a summary of the log state to stdout.
##
## :param logEnabled: Whether logging is enabled.
## :param maxEntries: Configured max log entries (0 = unlimited).
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — produces console output.
##     discard
proc displayLogInfo*(
  logEnabled: bool,
  maxEntries: int
) =
  let path = getLogFilePath()
  let status =
    if logEnabled: "enabled" else: "disabled"
  echo fmt"log: {status}"
  echo "max entries: " &
    formatIntOrDisable(maxEntries)
  echo fmt"file: {path}"
  if fileExists(path):
    let content = readFile(path)
    let entries = implCountEntries(content)
    echo fmt"entries: {entries}"
    let size = getFileSize(path)
    if size < 1024:
      echo fmt"file size: {size} B"
    elif size < 1024 * 1024:
      let kb = size div 1024
      echo fmt"file size: {kb} KB"
    else:
      let mb = size div (1024 * 1024)
      echo fmt"file size: {mb} MB"
  else:
    echo "entries: 0"
    echo "file size: 0 B"