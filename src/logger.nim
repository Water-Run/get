## Query log for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-09-23
## :File: logger.nim
## :License: AGPL-3.0
##
## Each query appends one JSON line to get.log: time, a query preview,
## model rounds, tool calls, denials, cache hit, exit code, and duration.
## Tool output and file contents are not logged. The file is appended to and
## compacted to the newest entries once it passes the configured limit.
## Older multi-line text logs are not parsed; the first new record replaces
## them. A failed write prints a warning and never fails the query.

{.experimental: "strictFuncs".}

import std/[json, strformat, strutils, times, os, unicode]

import file_lock
import style
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Characters of the query kept in one record.
const MAX_LOG_QUERY_CHARS* = 200

## Entries `get log` lists by default.
const DEFAULT_LOG_TAIL* = 10

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## What a query did, as one log record.
type
  QueryRecord* = object
    query*: string
    rounds*: int        ## Model requests.
    toolCalls*: int     ## Tool calls that ran.
    denied*: int        ## Tool calls authorization refused.
    cacheHit*: string   ## "none", "plan", or "result".
    exitCode*: int
    elapsedMs*: int64

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func implPreview(text: string): string =
  if text.runeLen <= MAX_LOG_QUERY_CHARS:
    return text
  result = text.runeSubStr(0, MAX_LOG_QUERY_CHARS) & "..."

proc implRecords(path: string): seq[string] =
  if not fileExists(path):
    return
  for line in lines(path):
    if line.len > 0 and line[0] == '{':
      result.add(line)

## True when the file holds anything other than JSON lines.
proc implIsLegacy(path: string): bool =
  if not fileExists(path):
    return false
  for line in lines(path):
    if line.strip().len > 0:
      return line[0] != '{'

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Appends one record for a finished query.
##
## :param record: What the query did.
## :param maxEntries: Entries to keep (0 = unlimited).
proc logQuery*(record: QueryRecord, maxEntries: int = 0) =
  try:
    let path = getLogFilePath()
    let lock = acquireFileLock(path & ".lock")
    defer: releaseFileLock(lock)
    let line = $(%*{
      "time": now().format("yyyy-MM-dd'T'HH:mm:sszzz"),
      "query": implPreview(record.query),
      "rounds": record.rounds,
      "tool_calls": record.toolCalls,
      "denied": record.denied,
      "cache_hit": record.cacheHit,
      "exit_code": record.exitCode,
      "elapsed_ms": record.elapsedMs
    })
    if not fileExists(path) or implIsLegacy(path):
      writePrivateFile(path, line & "\n")
      return
    var file: File
    if not open(file, path, fmAppend):
      raise newException(IOError, "cannot open " & path)
    try:
      file.write(line & "\n")
    finally:
      file.close()
    if maxEntries > 0:
      let records = implRecords(path)
      if records.len > maxEntries:
        writePrivateFile(path, records[^maxEntries .. ^1].join("\n") & "\n")
  except CatchableError as error:
    stderr.writeLine("warning: log write failed: " & error.msg)

## Removes all content from the log file.
##
## :returns: The number of entries that were removed.
proc cleanLog*(): int =
  let path = getLogFilePath()
  if not fileExists(path):
    return 0
  try:
    let lock = acquireFileLock(path & ".lock")
    defer: releaseFileLock(lock)
    result = implRecords(path).len
    writePrivateFile(path, "")
  except CatchableError:
    result = 0

## Formats one stored record for `get log`.
proc implFormatRecord(line: string): string =
  try:
    let node = parseJson(line)
    let time = node{"time"}.getStr("").replace('T', ' ')
    let seconds = float(node{"elapsed_ms"}.getBiggestInt(0)) / 1000.0
    let exitCode = node{"exit_code"}.getInt(0)
    let rounds = node{"rounds"}.getInt(0)
    let tools = node{"tool_calls"}.getInt(0)
    let denied = node{"denied"}.getInt(0)
    result = time[0 ..< min(16, time.len)] &
      fmt"  exit {exitCode:<3}  {rounds} rounds  {tools} tools  " &
      fmt"{denied} denied  {seconds:.1f}s  cache " &
      node{"cache_hit"}.getStr("none") & "  " & node{"query"}.getStr("")
  except CatchableError:
    result = "(unreadable entry)"

## Prints the log settings and the most recent entries.
##
## :param logEnabled: Whether logging is enabled.
## :param maxEntries: Configured max log entries.
## :param sk: The active output style.
## :param tail: Recent entries to list.
proc displayLogInfo*(
  logEnabled: bool,
  maxEntries: int,
  sk: StyleKind = skSimp,
  tail: int = DEFAULT_LOG_TAIL
) =
  let path = getLogFilePath()
  styleKeyValue(sk, "log", if logEnabled: "enabled" else: "disabled")
  styleKeyValue(sk, "max-entries", formatIntOrDisable(maxEntries))
  styleKeyValue(sk, "file", path)
  var records: seq[string] = @[]
  if fileExists(path):
    let lock = acquireFileLock(path & ".lock")
    defer: releaseFileLock(lock)
    records = implRecords(path)
  styleKeyValue(sk, "entries", $records.len)
  if records.len > 0 and tail > 0:
    echo ""
    for line in records[max(0, records.len - tail) .. ^1]:
      echo implFormatRecord(line)
