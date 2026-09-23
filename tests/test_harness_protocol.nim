## Tests the strict action protocol of the query loop.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_harness_protocol.nim
## :License: AGPL-3.0
##
## This suite verifies strict action validation, provider-native tool argument
## decoding, and parallel call decoding. Text that is not a strict JSON action
## is an answer. It performs no network or shell operations.

{.experimental: "strictFuncs".}

import std/[json, options, strutils, unittest]

import harness_protocol
import harness_types

## Verifies all provider-independent action decoding paths.
suite "harness action protocol":
  test "native answers preserve code examples and keep explicit actions typed":
    for source in [
      "# Example\n```sh\nrm -rf example\n```",
      "```json\n{\"name\":\"example\"}\n```",
      "```json\n{\"type\":\"object\",\"properties\":{}}\n```",
      "```json\n[1, 2, 3]\n```",
      "```python\n{'name': 'example'}\n```",
      "```sh\nprintf ready\n```"
    ]:
      let value = decodeTextAction(source)
      check value.kind == hakAnswer
      check value.text == source
    let action = decodeTextAction(
      "```json\n{\"type\":\"tool_calls\",\"calls\":[{\"tool\":\"run_shell\",\"command\":\"pwd\"}]}\n```")
    check action.kind == hakToolCalls

  test "parses a structured answer":
    let parsed = parseStructuredAction(
      "{\"type\":\"answer\",\"text\":\"Linux\"}")
    check parsed.isSome
    check parsed.get.kind == hakAnswer
    check parsed.get.text == "Linux"

  test "parses a fenced structured answer":
    let parsed = parseStructuredAction(
      "```json\n{\"type\":\"answer\",\"text\":\"ok\"}\n```")
    check parsed.isSome
    check parsed.get.text == "ok"

  test "ordinary JSON objects are preserved as answer data":
    for source in ["{\"text\":\"56088\"}",
        "{\"text\":\"pwd\",\"command\":\"pwd\"}",
        "{\"type\":\"object\",\"properties\":{}}",
        "{\"rs\":2,\"py\":3,\"nim\":1}"]:
      let action = decodeTextAction(source)
      check action.kind == hakAnswer
      check action.text == source
      check action.calls.len == 0

  test "parses independent parallel calls":
    let action = parseStructuredAction("""
      {
        "type": "tool_calls",
        "calls": [
          {"tool": "run_shell", "arguments": {"command": "uname -a"}},
          {"tool": "read_file", "arguments": {"path": "README.md"}}
        ]
      }
    """).get
    check action.kind == hakToolCalls
    check action.calls.len == 2
    check action.calls[0].command == "uname -a"
    check action.calls[1].invocationKind == tikReadFile

  test "a call without a tool name is rejected":
    expect ValueError:
      discard parseStructuredAction(
        """{"type":"tool_calls","calls":[{"command":"pwd"}]}""")
    expect ValueError:
      discard parseStructuredAction(
        """{"type":"tool_calls","calls":[{"tool":"run_shell","arguments":{"command":"pwd","result_mode":"return_raw"}}]}""")

  test "parses provider-native arguments":
    let call = parseNativeToolCall(
      "call-8",
      "run_shell",
      """{
        "command": "pwd",
        "purpose": "show the current directory"
      }"""
    )
    check call.id == "call-8"
    check call.command == "pwd"
    check call.purpose == "show the current directory"

  test "old Markdown commands and action markers are inert answer text":
    for source in ["```sh\npwd\n```\n<!-- FINAL -->",
        "```sh\npwd\n```\n<!-- CONTINUE -->", "<!-- INTERPRET -->"]:
      let action = decodeTextAction(source)
      check action.kind == hakAnswer
      check action.text == source
      check action.calls.len == 0

  test "textual tool-call markers are answer text":
    for source in [
        "[Tool call] run_shell {command: date +%Y, purpose: get current year}",
        "[tool CALL] run_shell {\"command\":\"pwd\"}",
        "[Tool call] write_file {command: touch x}"]:
      let action = decodeTextAction(source)
      check action.kind == hakAnswer
      check action.text == source

  test "embedded textual marker remains an answer":
    let action = decodeTextAction(
      "The provider may print [Tool call] in documentation.")
    check action.kind == hakAnswer

  test "plain text becomes an answer":
    let action = decodeTextAction("No command is required.")
    check action.kind == hakAnswer
    check action.text == "No command is required."

  test "rejects unknown native tools":
    expect ValueError:
      discard parseNativeToolCall(
        "call-1", "write_file", "{\"command\":\"x\"}")

  test "rejects malformed structured calls":
    expect ValueError:
      discard parseStructuredAction(
        "{\"type\":\"tool_calls\",\"calls\":[]}")
    expect ValueError:
      discard parseStructuredAction(
        "{\"type\":\"tool\",\"arguments\":\"pwd\"," &
        "\"command\":\"pwd\"}")

  test "rejects malformed JSON that claims to be structured":
    expect ValueError:
      discard parseStructuredAction(
        "{\"type\":\"answer\",broken}")

  test "replaces an empty fallback identifier":
    let action = parseStructuredAction(
      "{\"type\":\"tool_calls\",\"calls\":[{" &
      "\"id\":\"\",\"tool\":\"run_shell\",\"command\":\"pwd\"}]}").get
    check action.calls[0].id == "local-1"

  test "non-JSON content is not a structured action":
    check parseStructuredAction("hello").isNone

  test "adds precise model hints for silent finite readers":
    let identical = observationJson(ToolObservation(
      callId: "cmp-1",
      toolName: "run_shell",
      command: "cmp -s ./a ./b",
      output: "",
      exitCode: 0,
      elapsedMs: 1,
      timedOut: false,
      truncated: false,
      policyRejected: false
    ))
    check identical.contains("cmp exit 0 means the compared inputs are identical")

    let noMatch = observationJson(ToolObservation(
      callId: "grep-1",
      toolName: "run_shell",
      command: "/usr/bin/grep needle ./file",
      output: "",
      exitCode: 1,
      elapsedMs: 1,
      timedOut: false,
      truncated: false,
      policyRejected: false
    ))
    check noMatch.contains("Exit 1 means no lines matched")

  test "failed required observations name the exact fact to repair":
    var observation = ToolObservation(callId: "order", toolName: "run_process",
      command: "getconf BYTE_ORDER", exitCode: 2, status: osUnavailable,
      required: true, evidenceKey: "byte_order")
    let hint = parseJson(observationJson(observation))["interpretation_hint"].getStr
    check hint.contains("evidence_key exactly \"byte_order\"")
    observation.evidenceKey = ""
    let fallback = parseJson(observationJson(observation))
    check fallback["evidence_key"].getStr == "order"
    check fallback["interpretation_hint"].getStr.contains("evidence_key exactly \"order\"")
    observation.status = osNoMatch
    observation.exitCode = 1
    check not observationJson(observation).contains("repairs this required fact")
    observation.status = osUnavailable
    observation.required = false
    check not observationJson(observation).contains("repairs this required fact")

## Verifies the default budget.
suite "budget":
  test "the default budget matches the documented caps":
    let budget = defaultRunBudget()
    check budget.maxTurns == DEFAULT_HARNESS_TURNS
    check budget.maxToolCalls == DEFAULT_TOOL_CALLS
    check budget.maxParallel == DEFAULT_PARALLELISM
    check budget.totalTimeoutSec == DEFAULT_QUERY_TIMEOUT
    check budget.commandTimeoutSec == DEFAULT_COMMAND_TIMEOUT
    check budget.maxOutputBytes == DEFAULT_MAX_OUTPUT_BYTES
