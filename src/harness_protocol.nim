## Structured action protocol for the get v3 harness runtime.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: harness_protocol.nim
## :License: AGPL-3.0
##
## This module validates provider-native tool arguments and structured JSON
## actions before they enter the harness state machine.  It also contains the
## isolated v2 Markdown compatibility decoder, allowing the runtime itself to
## operate exclusively on typed actions.

{.experimental: "strictFuncs".}

import std/[json, options, strformat, strutils]

import harness_types
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Stable name of the built-in read-only shell tool exposed to models.
const READ_ONLY_SHELL_TOOL* = "run_readonly_shell"

## Maximum command characters accepted from one model tool call.
const MAX_COMMAND_CHARS* = 32_768

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Removes a single surrounding Markdown fence from structured JSON content.
##
## :param content: Raw model response content.
## :returns: Trimmed content with an optional fence removed.
func implStripJsonFence(content: string): string =
  let trimmed = content.strip()
  if not trimmed.startsWith("```"):
    return trimmed
  let firstLineEnd = trimmed.find('\n')
  if firstLineEnd < 0:
    return trimmed
  let closing = trimmed.rfind("```")
  if closing <= firstLineEnd:
    return trimmed
  result = trimmed[firstLineEnd + 1 ..< closing].strip()

## Reads a required, non-empty string from a JSON object.
##
## :param node: Object containing the field.
## :param fieldName: Field to retrieve.
## :returns: The validated string.
## :raises: ValueError: If the field is absent, non-string, or empty.
func implRequiredString(
  node: JsonNode,
  fieldName: string
): string =
  let value = node{fieldName}
  if value.isNil or value.kind != JString or
      value.getStr().strip().len == 0:
    raise newException(ValueError,
      fmt"missing non-empty string '{fieldName}'")
  result = value.getStr().strip()

## Reads an optional string from a JSON object.
##
## :param node: Object containing the field.
## :param fieldName: Field to retrieve.
## :param fallback: Value returned when the field is absent.
## :returns: The field value or fallback.
## :raises: ValueError: If a present field is not a string.
func implOptionalString(
  node: JsonNode,
  fieldName: string,
  fallback: string = ""
): string =
  let value = node{fieldName}
  if value.isNil:
    return fallback
  if value.kind != JString:
    raise newException(ValueError,
      fmt"field '{fieldName}' must be a string")
  result = value.getStr().strip()

## Validates the exact command field used by the shell tool.
##
## :param command: Raw model-provided command.
## :returns: Trimmed command.
## :raises: ValueError: If the command is empty or too large.
func implValidateCommand(command: string): string =
  result = command.strip()
  if result.len == 0:
    raise newException(ValueError,
      "tool command must not be empty")
  if result.len > MAX_COMMAND_CHARS:
    raise newException(ValueError,
      fmt"tool command exceeds {MAX_COMMAND_CHARS} characters")

## Enforces the provider-advertised `additionalProperties: false` schema even
## when a provider returns hand-written or textual JSON.
func implValidateArgumentFields(node: JsonNode) =
  for fieldName, unused in node:
    discard unused
    if fieldName notin ["command", "purpose", "result_mode"]:
      raise newException(ValueError,
        fmt"unsupported tool argument '{fieldName}'")

## Returns whether a character can appear in a relaxed tool-call field name.
func implIsFieldChar(value: char): bool =
  result = value in {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_', '-'}

## Decodes one string value from a narrowly scoped relaxed object.
##
## Qwen-compatible servers can occasionally render a provider tool call as
## assistant text with unquoted keys and values.  Quoted values still use JSON
## escaping; single-quoted values are accepted without escape interpretation.
proc implDecodeRelaxedValue(
  rawValue: string,
  fieldName: string
): string =
  let value = rawValue.strip()
  if value.len == 0:
    raise newException(ValueError,
      fmt"empty relaxed tool-call field '{fieldName}'")
  if value[0] == '"':
    var decoded: JsonNode
    try:
      decoded = parseJson(value)
    except JsonParsingError:
      raise newException(ValueError,
        fmt"invalid quoted value for relaxed tool-call field '{fieldName}'")
    if decoded.kind != JString:
      raise newException(ValueError,
        fmt"relaxed tool-call field '{fieldName}' must be a string")
    return decoded.getStr()
  if value[0] == '\'':
    if value.len < 2 or value[^1] != '\'':
      raise newException(ValueError,
        fmt"unterminated value for relaxed tool-call field '{fieldName}'")
    return value[1 ..< value.len - 1]
  result = value

## Parses the object payload used by Qwen's textual ``[Tool call]`` rendering.
##
## Field boundaries are recognised only at top-level commas followed by another
## ``name:`` pair.  This preserves ordinary commas in shell commands while
## keeping the accepted compatibility grammar deliberately small.
proc implParseRelaxedCallObject(payload: string): JsonNode =
  if payload.len < 2 or payload[0] != '{' or payload[^1] != '}':
    raise newException(ValueError,
      "relaxed tool call must contain one braced object")
  let body = payload[1 ..< payload.len - 1]
  result = newJObject()
  var cursor = 0
  while cursor < body.len:
    while cursor < body.len and body[cursor].isSpaceAscii:
      inc cursor
    if cursor >= body.len:
      break

    let keyStart = cursor
    while cursor < body.len and implIsFieldChar(body[cursor]):
      inc cursor
    if cursor == keyStart:
      raise newException(ValueError,
        "relaxed tool-call field name is invalid")
    let fieldName = body[keyStart ..< cursor]
    while cursor < body.len and body[cursor].isSpaceAscii:
      inc cursor
    if cursor >= body.len or body[cursor] != ':':
      raise newException(ValueError,
        fmt"relaxed tool-call field '{fieldName}' is missing ':'")
    inc cursor

    let valueStart = cursor
    var valueEnd = body.len
    var quote = '\0'
    var escaped = false
    var nesting = 0
    while cursor < body.len:
      let current = body[cursor]
      if quote != '\0':
        if escaped:
          escaped = false
        elif current == '\\':
          escaped = true
        elif current == quote:
          quote = '\0'
        inc cursor
        continue
      if current in {'"', '\''}:
        quote = current
      elif current in {'(', '[', '{'}:
        inc nesting
      elif current in {')', ']', '}'}:
        if nesting == 0:
          raise newException(ValueError,
            "unbalanced relaxed tool-call value")
        dec nesting
      elif current == ',' and nesting == 0:
        var lookahead = cursor + 1
        while lookahead < body.len and body[lookahead].isSpaceAscii:
          inc lookahead
        let nextKeyStart = lookahead
        while lookahead < body.len and implIsFieldChar(body[lookahead]):
          inc lookahead
        let hasNextKey = lookahead > nextKeyStart
        while lookahead < body.len and body[lookahead].isSpaceAscii:
          inc lookahead
        if hasNextKey and lookahead < body.len and body[lookahead] == ':':
          valueEnd = cursor
          break
      inc cursor

    if quote != '\0' or nesting != 0:
      raise newException(ValueError,
        "unterminated relaxed tool-call value")
    if fieldName notin ["command", "purpose", "result_mode"]:
      raise newException(ValueError,
        fmt"unsupported relaxed tool-call field '{fieldName}'")
    if result.hasKey(fieldName):
      raise newException(ValueError,
        fmt"duplicate relaxed tool-call field '{fieldName}'")
    result[fieldName] = %implDecodeRelaxedValue(
      body[valueStart ..< valueEnd], fieldName)

    if valueEnd < body.len:
      cursor = valueEnd + 1
    else:
      cursor = body.len

func implParseCallNode(
  node: JsonNode,
  index: int,
  defaultMode: ToolResultMode
): ToolCall

## Decodes a Qwen-style textual tool call when it occupies the whole response.
##
## The compatibility path is intentionally constrained to the built-in
## read-only shell tool.  All decoded commands still pass through the mandatory
## command policy before execution.
proc implParseBracketToolAction(
  content: string
): Option[HarnessAction] =
  const Marker = "[tool call]"
  let candidate = content.strip()
  if not candidate.toLowerAscii().startsWith(Marker):
    return none(HarnessAction)

  let remainder = candidate[Marker.len .. ^1].strip()
  var nameEnd = 0
  while nameEnd < remainder.len and
      implIsFieldChar(remainder[nameEnd]):
    inc nameEnd
  if nameEnd == 0:
    raise newException(ValueError,
      "textual tool call is missing a tool name")
  let toolName = remainder[0 ..< nameEnd]
  if toolName != READ_ONLY_SHELL_TOOL:
    raise newException(ValueError,
      fmt"unsupported tool '{toolName}'")
  let payload = remainder[nameEnd .. ^1].strip()
  if payload.len < 2 or payload[0] != '{' or payload[^1] != '}':
    raise newException(ValueError,
      "textual tool call must end with one braced object")

  var arguments: JsonNode
  try:
    arguments = parseJson(payload)
  except JsonParsingError:
    arguments = implParseRelaxedCallObject(payload)
  if arguments.kind != JObject:
    raise newException(ValueError,
      "textual tool-call arguments must be an object")

  let call = implParseCallNode(
    %*{
      "id": "text-tool-1",
      "tool": toolName,
      "arguments": arguments
    },
    0,
    trmReturnRaw
  )
  result = some(HarnessAction(
    kind: hakToolCalls,
    text: "",
    calls: @[call]
  ))

## Decodes one tool-call object from the structured action format.
##
## :param node: JSON object describing the call.
## :param index: Zero-based index used for a fallback call identifier.
## :param defaultMode: Result mode inherited from the enclosing action.
## :returns: A validated ToolCall.
## :raises: ValueError: If the call is malformed or names an unknown tool.
func implParseCallNode(
  node: JsonNode,
  index: int,
  defaultMode: ToolResultMode
): ToolCall =
  if node.kind != JObject:
    raise newException(ValueError,
      "each tool call must be a JSON object")
  let toolName = implOptionalString(
    node, "tool", READ_ONLY_SHELL_TOOL)
  if toolName != READ_ONLY_SHELL_TOOL:
    raise newException(ValueError,
      fmt"unsupported tool '{toolName}'")
  let argsNode = node{"arguments"}
  if not argsNode.isNil and argsNode.kind != JObject:
    raise newException(ValueError,
      "field 'arguments' must be a JSON object")
  if not argsNode.isNil:
    implValidateArgumentFields(argsNode)
  let source =
    if not argsNode.isNil: argsNode
    else: node
  let command = implValidateCommand(
    implRequiredString(source, "command"))
  let modeText = implOptionalString(
    source, "result_mode", "")
  let mode =
    if modeText.len > 0:
      parseToolResultMode(modeText)
    else:
      defaultMode
  let rawId = implOptionalString(
    node, "id", fmt"local-{index + 1}")
  let idValue =
    if rawId.len > 0: rawId
    else: fmt"local-{index + 1}"
  result = ToolCall(
    id: idValue,
    toolName: toolName,
    command: command,
    purpose: implOptionalString(source, "purpose", ""),
    resultMode: mode
  )

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Parses arguments from a provider-native shell tool call.
##
## :param callId: Provider-generated tool-call identifier.
## :param toolName: Provider-returned function name.
## :param arguments: Raw JSON argument string.
## :returns: A validated ToolCall.
## :raises: ValueError: If the tool name or arguments are invalid.
##
## .. code-block:: nim
##   runnableExamples:
##     let call = parseNativeToolCall(
##       "call-1", "run_readonly_shell",
##       "{\"command\":\"uname -a\",\"result_mode\":\"return_raw\"}")
##     assert call.command == "uname -a"
proc parseNativeToolCall*(
  callId: string,
  toolName: string,
  arguments: string
): ToolCall =
  if toolName != READ_ONLY_SHELL_TOOL:
    raise newException(ValueError,
      fmt"unsupported tool '{toolName}'")
  var node: JsonNode
  try:
    node = parseJson(arguments)
  except JsonParsingError:
    raise newException(ValueError,
      "tool arguments are not valid JSON")
  if node.kind != JObject:
    raise newException(ValueError,
      "tool arguments must be a JSON object")
  result = implParseCallNode(
    %*{
      "id": callId,
      "tool": toolName,
      "arguments": node
    },
    0,
    trmReturnRaw
  )

## Parses a strict JSON action returned as assistant text.
##
## Unknown non-JSON text returns none so the caller can use the isolated legacy
## decoder.  JSON that claims to be an action but violates the schema raises an
## error instead of silently falling through to shell-text parsing.
##
## :param content: Raw assistant content.
## :returns: A typed action, or none when content is not JSON.
## :raises: ValueError: If a JSON action is malformed.
##
## .. code-block:: nim
##   runnableExamples:
##     import std/options
##     let parsed = parseStructuredAction(
##       "{\"type\":\"answer\",\"text\":\"Linux\"}")
##     assert parsed.isSome
##     assert parsed.get.kind == hakAnswer
proc parseStructuredAction*(
  content: string
): Option[HarnessAction] =
  let candidate = implStripJsonFence(content)
  if candidate.len == 0 or candidate[0] != '{':
    return none(HarnessAction)
  var node: JsonNode
  try:
    node = parseJson(candidate)
  except JsonParsingError:
    raise newException(ValueError,
      "structured action is not valid JSON")
  if node.kind != JObject:
    raise newException(ValueError,
      "structured action must be a JSON object")
  # Some Qwen-compatible templates omit the discriminator for a direct
  # answer and emit only {"text":"..."}.  Accept that single-field shape as
  # an answer; keeping the object exact prevents an omitted `type` from
  # weakening validation of tool-like payloads.
  if node{"type"}.isNil and node.len == 1 and
      not node{"text"}.isNil:
    return some(HarnessAction(
      kind: hakAnswer,
      text: implRequiredString(node, "text"),
      calls: @[]
    ))
  let actionType = toLowerAscii(
    implRequiredString(node, "type"))
  case actionType
  of "answer":
    let answer =
      if not node{"text"}.isNil:
        implRequiredString(node, "text")
      else:
        implRequiredString(node, "answer")
    result = some(HarnessAction(
      kind: hakAnswer,
      text: answer,
      calls: @[]
    ))
  of "refuse", "refusal":
    let reason =
      if not node{"reason"}.isNil:
        implRequiredString(node, "reason")
      else:
        implRequiredString(node, "text")
    result = some(HarnessAction(
      kind: hakRefuse,
      text: reason,
      calls: @[]
    ))
  of "tool", "tool_calls":
    let globalModeText = implOptionalString(
      node, "after", "return_raw")
    let globalMode = parseToolResultMode(globalModeText)
    var calls: seq[ToolCall] = @[]
    let callsNode = node{"calls"}
    if not callsNode.isNil:
      if callsNode.kind != JArray or callsNode.len == 0:
        raise newException(ValueError,
          "'calls' must be a non-empty array")
      for index in 0 ..< callsNode.len:
        calls.add(implParseCallNode(
          callsNode[index], index, globalMode))
    else:
      calls.add(implParseCallNode(node, 0, globalMode))
    result = some(HarnessAction(
      kind: hakToolCalls,
      text: "",
      calls: calls
    ))
  else:
    raise newException(ValueError,
      fmt"unsupported structured action type '{actionType}'")

## Decodes assistant text into a typed action with v2 compatibility.
##
## Structured JSON is preferred.  When absent, the function converts the old
## fenced-command protocol into the same ToolCall representation, keeping all
## Markdown compatibility outside the runtime state machine.
##
## :param content: Raw assistant response content.
## :returns: A provider-independent HarnessAction.
## :raises: ValueError: If a structured action is malformed.
##
## .. code-block:: nim
##   runnableExamples:
##     let action = decodeTextAction(
##       "```sh\nuname -a\n```\n<!-- FINAL -->")
##     assert action.kind == hakToolCalls
##     assert action.calls[0].resultMode == trmReturnRaw
proc decodeTextAction*(content: string): HarnessAction =
  let structured = parseStructuredAction(content)
  if structured.isSome:
    return structured.get
  let bracketCall = implParseBracketToolAction(content)
  if bracketCall.isSome:
    return bracketCall.get
  let legacy = extractAgentAction(content)
  case legacy.action
  of aaAnswer:
    result = HarnessAction(
      kind: hakAnswer,
      text: content.strip(),
      calls: @[]
    )
  of aaContinue, aaInterpret, aaFinal:
    if legacy.command.isNone:
      raise newException(ValueError,
        "legacy protocol marker is missing a command")
    let mode =
      if legacy.action in {aaContinue, aaInterpret}:
        trmContinue
      else:
        trmReturnRaw
    result = HarnessAction(
      kind: hakToolCalls,
      text: "",
      calls: @[
        ToolCall(
          id: "legacy-1",
          toolName: READ_ONLY_SHELL_TOOL,
          command: implValidateCommand(legacy.command.get),
          purpose: "",
          resultMode: mode
        )
      ]
    )

## Serialises a tool observation for model feedback.
##
## :param observation: Bounded result of one tool call.
## :returns: Compact JSON containing the stable observation fields.
##
## .. code-block:: nim
##   runnableExamples:
##     let value = observationJson(ToolObservation(
##       callId: "c", toolName: "run_readonly_shell",
##       command: "pwd", output: "/tmp", exitCode: 0,
##       elapsedMs: 1, timedOut: false, truncated: false,
##       policyRejected: false))
##     assert value.contains("\"exit_code\":0")
func observationJson*(observation: ToolObservation): string =
  result = $(%*{
    "call_id": observation.callId,
    "tool": observation.toolName,
    "command": observation.command,
    "output": observation.output,
    "exit_code": observation.exitCode,
    "elapsed_ms": observation.elapsedMs,
    "timed_out": observation.timedOut,
    "truncated": observation.truncated,
    "policy_rejected": observation.policyRejected
  })
