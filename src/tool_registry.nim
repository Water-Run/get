## Query tools share one schema registry and one argument decoder.
## Shell text remains explicit; structured paths/argv never become shell code.
{.experimental: "strictFuncs".}

import std/[json, strutils]
import harness_types
import llm

const
  LEGACY_SHELL_TOOL* = "run_readonly_shell"
  QUERY_TOOL_NAMES* = ["read_environment", "read_file", "search_files",
    "run_process", "run_shell"]
  TOOL_SCHEMA_REVISION* = "get-v4-query-tools-1"
  MAX_TOOL_ARGUMENT_BYTES* = 32_768

func knownQueryTool*(name: string): bool =
  name == LEGACY_SHELL_TOOL or name in QUERY_TOOL_NAMES

func toolParameters(name: string): JsonNode =
  var properties = %*{
    "purpose": {"type": "string"},
    "result_mode": {"type": "string", "enum": ["return_raw", "continue"]},
    "fresh": {"type": "boolean", "description": "Collect a new time-sensitive sample."},
    "required": {"type": "boolean", "description": "This observation is essential to answering the request."}
  }
  properties["evidence_key"] = %*{"type": "string",
    "description": "Reuse the same key when repairing a query for an essential fact."}
  var required: seq[string] = @[]
  case name
  of "run_shell", LEGACY_SHELL_TOOL:
    properties["command"] = %*{"type": "string", "minLength": 1}
    properties["cwd"] = %*{"type": "string"}
    properties["shell"] = %*{"type": "string"}
    required = @["command"]
  of "run_process":
    properties["executable"] = %*{"type": "string", "minLength": 1}
    properties["args"] = %*{"type": "array", "items": {"type": "string"}, "maxItems": 256}
    properties["cwd"] = %*{"type": "string"}
    required = @["executable", "args"]
  of "read_environment":
    properties["names"] = %*{"type": "array", "items": {"type": "string"},
      "minItems": 1, "maxItems": 128}
    required = @["names"]
  of "read_file":
    properties["path"] = %*{"type": "string", "minLength": 1}
    properties["start_line"] = %*{"type": "integer", "minimum": 1, "maximum": 1000000}
    properties["limit"] = %*{"type": "integer", "minimum": 1, "maximum": 1000}
    required = @["path"]
  of "search_files":
    properties["path"] = %*{"type": "string", "description": "Root directory; defaults to cwd."}
    properties["pattern"] = %*{"type": "string", "description": "Literal text for content search; filename glob otherwise."}
    properties["content"] = %*{"type": "boolean"}
    properties["include_ignored"] = %*{"type": "boolean"}
    properties["offset"] = %*{"type": "integer", "minimum": 0, "maximum": 1000000}
    properties["limit"] = %*{"type": "integer", "minimum": 1, "maximum": 1000}
  else:
    raise newException(ValueError, "unknown query tool: " & name)
  result = %*{"type": "object", "properties": properties,
    "required": required, "additionalProperties": false}

func queryToolDefinitions*(): seq[LlmToolDefinition] =
  const descriptions = [
    "Read named host environment values. Missing names are null; credential values are masked.",
    "Read a page of a local text file with line numbers and a continuation position.",
    "List files by glob or search literal contents, honoring ignore files by default. Supports pagination.",
    "Run a query executable with literal arguments, without shell expansion. Captures bounded output.",
    "Run a bounded observational shell command in the configured dialect. General computation requires an isolated backend."
  ]
  for index, name in QUERY_TOOL_NAMES:
    result.add(LlmToolDefinition(name: name, description: descriptions[index],
      parametersJson: $toolParameters(name), strict: false))

func stringValue(node: JsonNode, key: string, fallback = ""): string =
  let value = node{key}
  if value.isNil: return fallback
  if value.kind != JString or '\0' in value.getStr:
    raise newException(ValueError, key & " must be a string without NUL")
  result = value.getStr

func integerValue(node: JsonNode, key: string, fallback, low, high: int): int =
  let value = node{key}
  if value.isNil: return fallback
  if value.kind != JInt or value.getBiggestInt < low or value.getBiggestInt > high:
    raise newException(ValueError, key & " is outside its integer range")
  result = value.getInt

func boolValue(node: JsonNode, key: string): bool =
  let value = node{key}
  if value.isNil: return false
  if value.kind != JBool:
    raise newException(ValueError, key & " must be boolean")
  result = value.getBool

func stringArray(node: JsonNode, key: string, minimum, maximum: int): seq[string] =
  let value = node{key}
  if value.isNil or value.kind != JArray or value.len < minimum or value.len > maximum:
    raise newException(ValueError, key & " must be a bounded array of strings")
  for item in value:
    if item.kind != JString or '\0' in item.getStr:
      raise newException(ValueError, key & " contains an invalid string")
    result.add(item.getStr)

func parseQueryArguments*(name, id: string, node: JsonNode,
    defaultMode = trmContinue): ToolCall =
  if not knownQueryTool(name):
    raise newException(ValueError, "unsupported tool '" & name & "'")
  if node.kind != JObject or ($node).len > MAX_TOOL_ARGUMENT_BYTES:
    raise newException(ValueError, "tool arguments must be a bounded JSON object")
  let schema = toolParameters(name)
  for key, unused in node:
    discard unused
    if not schema["properties"].hasKey(key):
      raise newException(ValueError, "unsupported tool argument '" & key & "'")
  for field in schema["required"]:
    if not node.hasKey(field.getStr):
      raise newException(ValueError, "missing tool argument '" & field.getStr & "'")
  result = ToolCall(id: id, toolName: name, argumentsJson: $node,
    purpose: stringValue(node, "purpose"), resultMode: defaultMode,
    fresh: boolValue(node, "fresh"), required: boolValue(node, "required"))
  result.evidenceKey = stringValue(node, "evidence_key")
  let mode = stringValue(node, "result_mode")
  if mode.len > 0: result.resultMode = parseToolResultMode(mode)
  result.cwd = stringValue(node, "cwd")
  case name
  of "run_shell", LEGACY_SHELL_TOOL:
    result.invocationKind = tikShell
    result.command = stringValue(node, "command").strip()
    result.shell = stringValue(node, "shell")
    if result.command.len == 0:
      raise newException(ValueError, "tool command must not be empty")
  of "run_process":
    result.invocationKind = tikProcess
    result.executable = stringValue(node, "executable")
    result.argv = stringArray(node, "args", 0, 256)
    if result.executable.strip.len == 0:
      raise newException(ValueError, "tool executable must not be empty")
  of "read_environment":
    result.invocationKind = tikEnvironment
    result.names = stringArray(node, "names", 1, 128)
    for value in result.names:
      if value.len == 0 or value[0] notin {'a'..'z', 'A'..'Z', '_'}:
        raise newException(ValueError, "invalid environment name")
      for c in value:
        if c notin {'a'..'z', 'A'..'Z', '0'..'9', '_'}:
          raise newException(ValueError, "invalid environment name")
  of "read_file":
    result.invocationKind = tikReadFile
    result.path = stringValue(node, "path")
    if result.path.len == 0: raise newException(ValueError, "path must not be empty")
    result.startLine = integerValue(node, "start_line", 1, 1, 1000000)
    result.limit = integerValue(node, "limit", 200, 1, 1000)
  of "search_files":
    result.invocationKind = tikSearchFiles
    result.path = stringValue(node, "path", ".")
    result.pattern = stringValue(node, "pattern")
    result.contentSearch = boolValue(node, "content")
    result.includeIgnored = boolValue(node, "include_ignored")
    result.offset = integerValue(node, "offset", 0, 0, 1000000)
    result.limit = integerValue(node, "limit", 200, 1, 1000)
  else: discard
  if result.invocationKind != tikShell:
    result.command = name & " " & $node


func queryIdentity*(call: ToolCall): string =
  ## Sampling intent and user-facing descriptions do not alter the query.
  $(%*{"tool": call.toolName, "kind": $call.invocationKind,
    "command": (if call.invocationKind == tikShell: call.command else: ""),
    "cwd": call.cwd, "shell": call.shell, "executable": call.executable,
    "argv": call.argv, "names": call.names, "path": call.path,
    "pattern": call.pattern, "start_line": call.startLine, "limit": call.limit,
    "offset": call.offset, "include_ignored": call.includeIgnored,
    "content": call.contentSearch})

proc cachedQueryPlan*(observation: ToolObservation): string =
  var arguments = if observation.argumentsJson.len > 0:
    parseJson(observation.argumentsJson) else: newJObject()
  if observation.toolName in [LEGACY_SHELL_TOOL, "run_shell"]:
    arguments["command"] = %observation.command
  $(%*{"tool": observation.toolName, "arguments": arguments})

proc decodeCachedQueryPlan*(content: string): ToolCall =
  let node = parseJson(content)
  if node.kind != JObject or node{"tool"}.isNil or node{"arguments"}.isNil:
    raise newException(ValueError, "invalid cached query plan")
  parseQueryArguments(node["tool"].getStr, "cached-1", node["arguments"], trmReturnRaw)
