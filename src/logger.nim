## Simple file-based execution logging for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-21
## :File: logger.nim
## :License: AGPL-3.0
##
## This module appends timestamped entries to the get.log file.
## Each entry records the user query, generated command, exit
## code, and a truncated output preview.  Logging failures are
## silently ignored.

{.experimental: "strictFuncs".}

import std/[deques, json, strformat, strutils, times, os]

import file_lock
import style
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Maximum output characters stored in a single log entry.
const MAX_LOG_OUTPUT_LEN* = 4096

## Separator that marks the boundary between log entries.
const LOG_ENTRY_SEPARATOR = "\n\n"

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Recognizes a timestamped entry header, including the historical format.
func implIsEntryStart(line: string): bool =
  result = line.len >= 29 and line[0] == '[' and
    line[5] == '-' and line[8] == '-' and line[11] == ' ' and
    line[14] == ':' and line[17] == ':' and line[20 .. 28] == "] query: "

proc implCountEntries(path: string): int =
  ## Count incrementally so log inspection and cleaning use bounded memory.
  result = 0
  for line in lines(path):
    if implIsEntryStart(line):
      result += 1

proc implReadTail(path: string, keep: int): string =
  ## Keep only the requested tail while scanning historical multiline logs.
  if keep <= 0 or not fileExists(path):
    return ""
  var entries = initDeque[string]()
  var entry = ""
  for line in lines(path):
    if implIsEntryStart(line) and entry.len > 0:
      entries.addLast(entry.strip(trailing = true, leading = false))
      if entries.len > keep:
        discard entries.popFirst()
      entry = ""
    entry.add(line & "\n")
  if entry.strip().len > 0:
    entries.addLast(entry.strip(trailing = true, leading = false))
    if entries.len > keep:
      discard entries.popFirst()
  for retained in entries:
    result.add(retained & LOG_ENTRY_SEPARATOR)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Appends a log entry for a single query execution.
##
## :param query: The original user query text.
## :param command: The shell command that was executed.
## :param output: The captured output of the command.
## :param exitCode: The process exit code.
## :param maxEntries: Maximum entries to retain (0 = unlimited).
##
## .. code-block:: nim
##   runnableExamples:
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
    let lock = acquireFileLock(path & ".lock")
    defer: releaseFileLock(lock)
    let ts = now().format("yyyy-MM-dd HH:mm:ss")
    let preview =
      if output.len > MAX_LOG_OUTPUT_LEN:
        output[0 ..< MAX_LOG_OUTPUT_LEN] & "..."
      else:
        output
    # Write one complete entry inside the same critical section as retention.
    var entry = fmt"[{ts}] query: " & $(%query) & "\n" &
      fmt"[{ts}] command: " & $(%command) & "\n" &
      fmt"[{ts}] exit: {exitCode}" & "\n"
    if preview.len > 0:
      entry.add(fmt"[{ts}] output: " & $(%preview) & "\n")
    entry.add("\n")
    if maxEntries > 0:
      writePrivateFile(path, implReadTail(path, maxEntries - 1) & entry)
    elif not fileExists(path):
      writePrivateFile(path, entry)
    else:
      var f: File
      if not open(f, path, fmAppend):
        return
      try:
        when defined(posix):
          setFilePermissions(path, {fpUserRead, fpUserWrite})
        f.write(entry)
      finally:
        f.close()
  except CatchableError:
    discard

## Removes all content from the log file.
##
## :returns: The number of entries that were removed.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc cleanLog*(): int =
  let path = getLogFilePath()
  if not fileExists(path):
    return 0
  try:
    let lock = acquireFileLock(path & ".lock")
    defer: releaseFileLock(lock)
    result = implCountEntries(path)
    writePrivateFile(path, "")
  except CatchableError:
    result = 0

## Prints a summary of the log state.
##
## :param logEnabled: Whether logging is enabled.
## :param maxEntries: Configured max log entries.
## :param sk: The active output style.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc displayLogInfo*(
  logEnabled: bool,
  maxEntries: int,
  sk: StyleKind = skSimp
) =
  let path = getLogFilePath()
  let status =
    if logEnabled: "enabled" else: "disabled"
  styleKeyValue(sk, "log", status)
  styleKeyValue(sk, "max-entries",
    formatIntOrDisable(maxEntries))
  styleKeyValue(sk, "file", path)
  if fileExists(path):
    let lock = acquireFileLock(path & ".lock")
    defer: releaseFileLock(lock)
    let entries = implCountEntries(path)
    styleKeyValue(sk, "entries", $entries)
    let size = getFileSize(path)
    let sizeStr =
      if size < 1024:
        fmt"{size} B"
      elif size < 1024 * 1024:
        fmt"{size div 1024} KB"
      else:
        fmt"{size div (1024 * 1024)} MB"
    styleKeyValue(sk, "file-size", sizeStr)
  else:
    styleKeyValue(sk, "entries", "0")
    styleKeyValue(sk, "file-size", "0 B")
