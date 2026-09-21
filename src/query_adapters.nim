## Bounded native reads used without a shell or executable allowlist.
import std/[algorithm, json, monotimes, os, strutils, times]
when defined(posix):
  import std/posix
import tool_registry
import harness_types
import query_environment
import query_glob

const MAX_FILE_SCAN_BYTES = 8 * 1024 * 1024

type IgnoreRule = object
  base, pattern: string
  negated, directoryOnly, anchored: bool

proc openReader(path: string): File =
  when defined(posix):
    # Never block while opening a FIFO/device. Validate the opened object to
    # avoid a stat/open symlink race; regular procfs files remain readable.
    let descriptor = posix.open(path.cstring, O_RDONLY or O_NONBLOCK or O_NOCTTY)
    if descriptor < 0: raiseOSError(osLastError())
    var info: Stat
    if fstat(descriptor, info) != 0 or not S_ISREG(info.st_mode):
      discard posix.close(descriptor)
      raise newException(IOError, "file query requires a regular file")
    if not open(result, FileHandle(descriptor), fmRead):
      discard posix.close(descriptor)
      raise newException(IOError, "cannot open file for reading")
  else:
    if not fileExists(path):
      raise newException(IOError, "file query requires an existing regular file")
    result = open(path, fmRead)

proc readFilePage(call: ToolCall, budget: RunBudget): ToolObservation =
  let started = getMonoTime()
  let input = openReader(call.path)
  defer: input.close()
  let startLine = max(1, call.startLine)
  let limit = max(1, min(1000, call.limit))
  let cap = if budget.maxOutputBytes > 0: min(budget.maxOutputBytes, 1_048_576)
    else: 1_048_576
  var rows = newJArray()
  var lineNumber = 1
  var line = ""
  var scanned = 0
  var captured = 0
  var more = false
  var done = false
  var buffer: array[8192, char]
  template finishLine() =
    if line.len > 0 and line[^1] == '\r': line.setLen(line.len - 1)
    if lineNumber >= startLine:
      let row = %*{"line": lineNumber, "text": line}
      let encodedSize = ($row).len + 1
      if rows.len >= limit or captured + encodedSize > max(0, cap - absolutePath(call.path).len * 6 - 192):
        more = true
        done = true
      else:
        rows.add(row)
        captured += encodedSize
    line.setLen(0)
    inc lineNumber
  while not done:
    if budget.commandTimeoutSec > 0 and
        (getMonoTime() - started).inSeconds >= budget.commandTimeoutSec:
      result.timedOut = true
      more = true
      break
    let count = input.readBuffer(addr buffer[0], buffer.len)
    if count <= 0:
      if line.len > 0: finishLine()
      break
    for index in 0 ..< count:
      inc scanned
      if scanned > MAX_FILE_SCAN_BYTES:
        more = true
        done = true
        break
      if buffer[index] == '\0':
        raise newException(IOError, "binary data encountered; use a binary inspection tool")
      if buffer[index] == '\n':
        finishLine()
        if done: break
      elif lineNumber >= startLine:
        if line.len >= cap:
          more = true
          done = true
          break
        line.add(buffer[index])
  let nextLine = if rows.len > 0: rows[^1]["line"].getInt + 1 else: startLine
  result.output = $(%*{"path": absolutePath(call.path), "start_line": startLine,
    "lines": rows, "has_more": more, "next_line": nextLine,
    "scanned_bytes": scanned})
  result.moreData = more
  result.source = "host file"
  if result.timedOut: result.status = osTimedOut
  elif more and rows.len == 0:
    result.status = osTruncated
    result.truncated = true
  elif rows.len == 0: result.status = osNoMatch

proc readBoundedQueryFile*(path: string, maximum: int): tuple[text: string, limited: bool] =
  let input = openReader(path)
  defer: input.close()
  var buffer: array[8192, char]
  while true:
    let count = input.readBuffer(addr buffer[0], buffer.len)
    if count <= 0: break
    let available = min(count, maximum - result.text.len)
    for index in 0 ..< available: result.text.add(buffer[index])
    if available < count:
      result.limited = true
      break

proc readIgnoreRules(directory: string, inherited: seq[IgnoreRule]): seq[IgnoreRule] =
  result = inherited
  for name in [".gitignore", ".ignore", ".rgignore"]:
    let path = directory / name
    if not fileExists(path): continue
    let data = readBoundedQueryFile(path, 65536)
    if data.limited: raise newException(IOError, "ignore file exceeds 64 KiB: " & path)
    for raw in data.text.splitLines:
      var pattern = raw.strip(leading = false)
      if pattern.len == 0 or pattern[0] == '#': continue
      var rule = IgnoreRule(base: directory)
      if pattern[0] == '!':
        rule.negated = true
        pattern.delete(0..0)
      if pattern.len == 0: continue
      if pattern[^1] == '/':
        rule.directoryOnly = true
        pattern.setLen(pattern.len - 1)
      if pattern.len > 0 and pattern[0] == '/':
        rule.anchored = true
        pattern.delete(0..0)
      rule.anchored = rule.anchored or '/' in pattern
      rule.pattern = pattern
      result.add(rule)

proc ignored(path: string, directory: bool, rules: seq[IgnoreRule]): bool =
  for rule in rules:
    if rule.directoryOnly and not directory: continue
    let relative = relativePath(path, rule.base).replace('\\', '/')
    let candidate = if rule.anchored: relative else: extractFilename(path)
    if queryGlobMatches(candidate, rule.pattern): result = not rule.negated

proc searchFiles(call: ToolCall, budget: RunBudget): ToolObservation =
  let started = getMonoTime()
  let root = absolutePath(if call.path.len > 0: call.path else: ".")
  if not dirExists(root): raise newException(IOError, "search root is not a directory: " & root)
  let limit = max(1, min(1000, call.limit))
  let outputCap = if budget.maxOutputBytes > 0: budget.maxOutputBytes else: 1_048_576
  var matches = newJArray()
  var errors = newJArray()
  var count, visited, outputBytes, readBytes: int
  var incomplete = false
  var pageFull = false
  type Pending = tuple[path: string, rules: seq[IgnoreRule], depth: int]
  var pending: seq[Pending] = @[(root, newSeq[IgnoreRule](), 0)]
  template record(value: JsonNode) =
    if count >= call.offset and matches.len < limit and not pageFull:
      let encodedSize = ($value).len
      if outputBytes + encodedSize < max(0, outputCap - 1024):
        matches.add(value)
        outputBytes += encodedSize
      else:
        pageFull = true
    inc count
  while pending.len > 0:
    if visited >= 50000 or readBytes >= 32 * 1024 * 1024 or
        (budget.commandTimeoutSec > 0 and
         (getMonoTime() - started).inSeconds >= budget.commandTimeoutSec):
      incomplete = true
      break
    let current = pending.pop()
    if current.depth > 64:
      incomplete = true
      continue
    try:
      let rules = if call.includeIgnored: current.rules
        else: readIgnoreRules(current.path, current.rules)
      var entries: seq[tuple[kind: PathComponent, path: string]]
      for kind, path in walkDir(current.path, checkDir = true):
        inc visited
        if visited > 50000:
          incomplete = true
          break
        entries.add((kind, path))
      entries.sort(proc(a, b: tuple[kind: PathComponent, path: string]): int = cmp(a.path, b.path))
      for entry in entries:
        if readBytes >= 32 * 1024 * 1024 or (budget.commandTimeoutSec > 0 and
            (getMonoTime() - started).inSeconds >= budget.commandTimeoutSec):
          incomplete = true
          break
        let directory = entry.kind == pcDir
        if entry.kind notin {pcDir, pcFile, pcLinkToFile}: continue
        if not call.includeIgnored and (
            (directory and extractFilename(entry.path) in [".git", ".ci", "build",
             "dist", "target", "node_modules", ".venv", "venv", "__pycache__", "_deps"]) or
            ignored(entry.path, directory, rules)):
          continue
        if directory:
          pending.add((entry.path, rules, current.depth + 1))
          continue
        let relative = relativePath(entry.path, root).replace('\\', '/')
        if not call.contentSearch:
          let candidate = if '/' in call.pattern: relative else: extractFilename(entry.path)
          if call.pattern.len == 0 or queryGlobMatches(candidate, call.pattern):
            record(%*{"path": relative})
        else:
          try:
            let data = readBoundedQueryFile(entry.path, 1_048_576)
            readBytes += data.text.len
            if '\0' in data.text: continue
            if data.limited: incomplete = true
            var lineNumber = 0
            for line in data.text.splitLines:
              inc lineNumber
              if call.pattern in line:
                record(%*{"path": relative, "line": lineNumber, "text": line})
          except CatchableError as error:
            incomplete = true
            if errors.len < 20: errors.add(%*{"path": relative, "error": error.msg})
    except CatchableError as error:
      incomplete = true
      if errors.len < 20: errors.add(%*{"path": current.path, "error": error.msg})
  if pageFull and matches.len == 0: incomplete = true
  result.moreData = count > call.offset + matches.len
  result.output = $(%*{"root": root, "matches": matches,
    "observed_matches": count, "complete": not incomplete,
    "offset": call.offset, "next_offset": call.offset + matches.len,
    "has_more": result.moreData, "errors": errors})
  result.source = "host filesystem"
  if incomplete:
    result.truncated = true
    result.status = osTruncated
  elif count == 0: result.status = osNoMatch

proc executeBuiltinQuery*(call: ToolCall, budget: RunBudget): ToolObservation =
  let started = getMonoTime()
  result = ToolObservation(callId: call.id, toolName: call.toolName,
    command: call.command, argumentsJson: call.argumentsJson, identity: queryIdentity(call), required: call.required,
    evidenceKey: call.evidenceKey,
    sampledAt: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"))
  try:
    case call.invocationKind
    of tikEnvironment:
      result.output = environmentObservation(call.names)
      result.source = "host environment"
    of tikReadFile:
      let value = readFilePage(call, budget)
      result.output = value.output
      result.moreData = value.moreData
      result.status = value.status
      result.timedOut = value.timedOut
      result.truncated = value.truncated
      result.source = value.source
    of tikSearchFiles:
      let value = searchFiles(call, budget)
      result.output = value.output
      result.moreData = value.moreData
      result.status = value.status
      result.truncated = value.truncated
      result.source = value.source
    else:
      result.status = osUnsupported
      result.notExecuted = true
      result.exitCode = 125
      result.output = "This query adapter is not available."
  except CatchableError as error:
    result.exitCode = 1
    result.status = osUnavailable
    result.output = error.msg
  result.output = redactEnvironmentSecrets(result.output)
  if budget.maxOutputBytes > 0 and result.output.len > budget.maxOutputBytes:
    var boundary = budget.maxOutputBytes
    while boundary > 0 and (byte(result.output[boundary]) and 0xC0'u8) == 0x80'u8:
      dec boundary
    result.output.setLen(boundary)
    result.truncated = true
    result.status = osTruncated
  result.stdout = result.output
  result.elapsedMs = (getMonoTime() - started).inMilliseconds

