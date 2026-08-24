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
##       elapsedMs: 1, timedOut: false, truncated: false))
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
    "truncated": observation.truncated
  })
