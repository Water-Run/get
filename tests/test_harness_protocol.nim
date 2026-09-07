## Tests the structured and legacy get v3 harness action protocols.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_harness_protocol.nim
## :License: AGPL-3.0
##
## This suite verifies strict action validation, provider-native tool argument
## decoding, parallel call decoding, and compatibility with v2 fenced command
## responses.  It performs no network or shell operations.

{.experimental: "strictFuncs".}

import std/[options, strutils, unittest]

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
      let value = decodeTextAction(source, allowBareCodeTools = false)
      check value.kind == hakAnswer
      check value.text == source
    let action = decodeTextAction(
      "```json\n{\"type\":\"tool_calls\",\"calls\":[{\"command\":\"pwd\"}]}\n```",
      allowBareCodeTools = false)
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

  test "parses an exact Qwen bare-text answer object":
    let action = decodeTextAction("{\"text\":\"56088\"}")
    check action.kind == hakAnswer
    check action.text == "56088"

    expect ValueError:
      discard decodeTextAction(
        "{\"text\":\"pwd\",\"command\":\"pwd\"}")

  test "parses independent parallel calls":
    let action = parseStructuredAction("""
      {
        "type": "tool_calls",
        "after": "continue",
        "calls": [
          {"arguments": {"command": "uname -a"}},
          {"arguments": {
            "command": "git branch --show-current",
            "result_mode": "return_raw"
          }}
        ]
      }
    """).get
    check action.kind == hakToolCalls
    check action.calls.len == 2
    check action.calls[0].resultMode == trmContinue
    check action.calls[1].resultMode == trmReturnRaw

  test "parses provider-native arguments":
    let call = parseNativeToolCall(
      "call-8",
      READ_ONLY_SHELL_TOOL,
      """{
        "command": "pwd",
        "purpose": "show the current directory",
        "result_mode": "return_raw"
      }"""
    )
    check call.id == "call-8"
    check call.command == "pwd"
    check call.resultMode == trmReturnRaw

  test "converts legacy final command":
    let action = decodeTextAction(
      "```sh\nuname -a\n```\n<!-- FINAL -->")
    check action.kind == hakToolCalls
    check action.calls.len == 1
    check action.calls[0].command == "uname -a"
    check action.calls[0].resultMode == trmReturnRaw

  test "converts legacy continuation":
    let action = decodeTextAction(
      "```sh\ngit branch --show-current\n```\n<!-- CONTINUE -->")
    check action.calls[0].resultMode == trmContinue

  test "parses a Qwen textual tool call":
    let action = decodeTextAction(
      "[Tool call] run_readonly_shell " &
      "{command: date +%Y, purpose: get current year, " &
      "result_mode: return_raw}")
    check action.kind == hakToolCalls
    check action.calls.len == 1
    check action.calls[0].id == "text-tool-1"
    check action.calls[0].command == "date +%Y"
    check action.calls[0].purpose == "get current year"
    check action.calls[0].resultMode == trmReturnRaw

  test "parses quoted Qwen textual arguments and command commas":
    let quoted = decodeTextAction(
      "[tool CALL] run_readonly_shell " &
      "{command: \"printf '%s,%s' a b\", " &
      "result_mode: \"continue\"}")
    check quoted.calls[0].command == "printf '%s,%s' a b"
    check quoted.calls[0].resultMode == trmContinue

    let unquoted = decodeTextAction(
      "[Tool call] run_readonly_shell " &
      "{command: printf %s,%s a b, result_mode: return_raw}")
    check unquoted.calls[0].command == "printf %s,%s a b"

  test "rejects unsafe textual tool-call ambiguity":
    expect ValueError:
      discard decodeTextAction(
        "[Tool call] write_file {command: touch x}")
    expect ValueError:
      discard decodeTextAction(
        "[Tool call] run_readonly_shell {purpose: no command}")
    expect ValueError:
      discard decodeTextAction(
        "[Tool call] run_readonly_shell " &
        "{command: pwd, unknown: value}")
    expect ValueError:
      discard decodeTextAction(
        "[Tool call] run_readonly_shell " &
        "{\"command\":\"pwd\",\"unknown\":\"value\"}")
    expect ValueError:
      discard decodeTextAction(
        "[Tool call] run_readonly_shell {command: pwd} trailing")

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
      "\"id\":\"\",\"command\":\"pwd\"}]}").get
    check action.calls[0].id == "local-1"

  test "non-JSON content is not a structured action":
    check parseStructuredAction("hello").isNone

  test "rejects a bare legacy protocol marker":
    expect ValueError:
      discard decodeTextAction("<!-- INTERPRET -->")

  test "adds precise model hints for silent finite readers":
    let identical = observationJson(ToolObservation(
      callId: "cmp-1",
      toolName: READ_ONLY_SHELL_TOOL,
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
      toolName: READ_ONLY_SHELL_TOOL,
      command: "/usr/bin/grep needle ./file",
      output: "",
      exitCode: 1,
      elapsedMs: 1,
      timedOut: false,
      truncated: false,
      policyRejected: false
    ))
    check noMatch.contains("Exit 1 means no lines matched")

## Verifies stable harness configuration parsing and budgets.
suite "harness kinds and budgets":
  test "accepts compatibility aliases":
    check parseHarnessKind("instance") == hkDirect
    check parseHarnessKind("agent") == hkLoop
    check parseHarnessKind("batch") == hkParallel

  test "direct budget has one turn and one call":
    let budget = defaultRunBudget(hkDirect)
    check budget.maxTurns == 1
    check budget.maxToolCalls == 1
    check budget.maxParallel == 1

  test "automatic budget permits bounded parallelism":
    let budget = defaultRunBudget(hkAuto)
    check budget.maxTurns == DEFAULT_HARNESS_TURNS
    check budget.maxParallel == DEFAULT_PARALLELISM
