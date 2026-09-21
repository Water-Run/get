## Evidence status and bounded feedback are shared by the runtime and renderer.
import std/[strutils, tables, os]
import command_policy
import harness_types

func queryResultStatus*(call: ToolCall, code: int, shell = "bash"): ObservationStatus =
  if code == 0: return osCompleted
  let words = if call.invocationKind == tikProcess: @[call.executable] & call.argv
    else: literalQueryWords(call.command, shell)
  if words.len == 0: return osUnavailable
  var name = extractFilename(words[0]).toLowerAscii()
  if name.endsWith(".exe"): name.setLen(name.len - 4)
  if code == 1:
    if name in ["grep", "egrep", "fgrep", "rg", "test", "[", "pgrep", "which", "printenv"]:
      return osNoMatch
    if name in ["cmp", "diff"]: return osFinding
    if name == "command" and words.len > 1 and words[1] == "-v": return osNoMatch
  if name == "git" and "diff" in words:
    if code == 1 and ("--exit-code" in words or "--quiet" in words): return osFinding
    if code == 2 and "--check" in words: return osFinding
  osUnavailable

func observationSucceeded*(value: ToolObservation): bool =
  if value.policyRejected or value.timedOut or value.truncated: return false
  let status = if value.status == osReused: value.originalStatus else: value.status
  if status in {osNoMatch, osFinding}: return true
  if value.exitCode == 0: return true
  # Compatibility observations lack argv/status metadata. Interpret only a
  # single literal command, never the first stage of a compound expression.
  if value.toolName in ["", "run_readonly_shell", "run_shell"]:
    return queryResultStatus(ToolCall(command: value.command), value.exitCode) in
      {osNoMatch, osFinding}

func answerEvidenceStatus*(values: seq[ToolObservation]): tuple[code: int, partial: bool] =
  if values.len == 0: return (0, false)
  var anyEvidence = false
  var required = initTable[string, bool]()
  var latest = initTable[string, bool]()
  var proven = initTable[string, bool]()
  for value in values:
    let success = observationSucceeded(value)
    anyEvidence = anyEvidence or success
    let key = if value.evidenceKey.len > 0: value.evidenceKey else: value.callId
    latest[key] = success
    # Several readers may establish the same fact. A failed corroboration must
    # not erase successful sibling evidence, regardless of batch result order.
    proven[key] = proven.getOrDefault(key) or success
    if value.required or required.hasKey(key): required[key] = proven[key]
  for success in latest.values:
    result.partial = result.partial or not success
  if not anyEvidence: result.code = 1
  for success in required.values:
    if not success: result.code = 1

func compactObservation*(value: ToolObservation, maximum: int): ToolObservation =
  result = value
  result.originalOutputBytes = value.output.len
  if result.stderr.len > maximum div 4:
    var boundary = maximum div 4
    while boundary > 0 and (byte(result.stderr[boundary]) and 0xC0'u8) == 0x80'u8:
      dec boundary
    result.stderr = result.stderr[0 ..< boundary] & "\n[stderr feedback compacted]"
    result.feedbackCompacted = true
  if value.output.len <= maximum: return
  # Keep the end as well as the beginning: many tools put totals/errors last.
  var head = max(0, maximum * 2 div 3 - 100)
  var tail = value.output.len - max(0, maximum div 3 - 100)
  while head > 0 and (byte(value.output[head]) and 0xC0'u8) == 0x80'u8: dec head
  while tail < value.output.len and (byte(value.output[tail]) and 0xC0'u8) == 0x80'u8: inc tail
  result.output = value.output[0 ..< head] &
    "\n[feedback excerpt: middle omitted; original " & $value.output.len & " bytes]\n" &
    value.output[tail ..< value.output.len]
  result.feedbackCompacted = true
