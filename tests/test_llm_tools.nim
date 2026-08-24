## Tests native tool encoding and decoding in the LLM transport.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_llm_tools.nim
## :License: AGPL-3.0
##
## This suite validates OpenAI-compatible function-tool payloads and response
## parsing without making network requests or exposing credentials.

{.experimental: "strictFuncs".}

import std/[json, os, unittest]

import llm
import utils

## Verifies native request and response payload handling.
suite "LLM native tools":
  test "selects proxy by target scheme and honors NO_PROXY":
    let names = [
      "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy",
      "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"
    ]
    var previous: seq[tuple[exists: bool, value: string]] = @[]
    for name in names:
      previous.add((existsEnv(name), getEnv(name, "")))
      delEnv(name)
    try:
      putEnv("HTTP_PROXY", "http://http-proxy.test:8080")
      putEnv("HTTPS_PROXY", "http://https-proxy.test:8443")
      check detectSystemProxyForTest("http://provider.test/v1") ==
        "http://http-proxy.test:8080"
      check detectSystemProxyForTest("https://provider.test/v1") ==
        "http://https-proxy.test:8443"
      putEnv("NO_PROXY", ".provider.test")
      check detectSystemProxyForTest("https://api.provider.test/v1") == ""
    finally:
      for index, name in names:
        if previous[index].exists:
          putEnv(name, previous[index].value)
        else:
          delEnv(name)

  test "encodes tools and tool feedback messages":
    let request = LlmRequest(
      model: "test-model",
      messages: @[
        LlmMessage(
          role: "assistant",
          content: "",
          toolCallId: "",
          toolCallsJson: "[{\"id\":\"c1\",\"type\":\"function\"," &
            "\"function\":{\"name\":\"probe\",\"arguments\":\"{}\"}}]"
        ),
        LlmMessage(
          role: "tool",
          content: "{\"output\":\"ok\"}",
          toolCallId: "c1",
          toolCallsJson: ""
        )
      ],
      maxTokens: 100,
      tools: @[
        LlmToolDefinition(
          name: "probe",
          description: "Inspect",
          parametersJson: "{\"type\":\"object\",\"properties\":{}}",
          strict: false
        )
      ],
      parallelToolCalls: true
    )
    let body = buildLlmRequestBodyForTest(request)
    check body{"tools"}.kind == JArray
    check body{"parallel_tool_calls"}.getBool()
    check body{"messages"}[0]{"content"}.kind == JNull
    check body{"messages"}[1]{"tool_call_id"}.getStr() == "c1"
    var serialRequest = request
    serialRequest.parallelToolCalls = false
    let serialBody = buildLlmRequestBodyForTest(serialRequest)
    check serialBody{"parallel_tool_calls"}.isNil

  test "parses a native tool response with null content":
    let raw = """{
      "choices":[{
        "finish_reason":"tool_calls",
        "message":{
          "content":null,
          "tool_calls":[{
            "id":"call-7",
            "type":"function",
            "function":{
              "name":"run_readonly_shell",
              "arguments":"{\"command\":\"pwd\"}"
            }
          }]
        }
      }],
      "usage":{"total_tokens":17}
    }"""
    let value = parseLlmResponseForTest(raw)
    check value.content == ""
    check value.toolCalls.len == 1
    check value.toolCalls[0].id == "call-7"
    check value.toolCalls[0].name == "run_readonly_shell"
    check value.finishReason == "tool_calls"
    check value.tokensUsed == 17
    check value.providerRequests == 1

  test "accepts null tool calls on a text response":
    let raw = """{
      "choices":[{
        "finish_reason":"stop",
        "message":{
          "content":"Qwen text",
          "tool_calls":null,
          "reasoning_content":"provider-specific field"
        }
      }],
      "usage":{"total_tokens":9}
    }"""
    let value = parseLlmResponseForTest(raw)
    check value.content == "Qwen text"
    check value.toolCalls.len == 0
    check value.finishReason == "stop"
    check value.tokensUsed == 9

  test "strips provider-visible thinking blocks":
    let raw = """{
      "choices":[{"message":{"content":
        "<THINK>private</THINK> answer <thinking>hidden</thinking>"}}],
      "usage":{"total_tokens":5}
    }"""
    let value = parseLlmResponseForTest(raw)
    check value.content == "answer"
    check value.tokensUsed == 5

  test "rejects malformed provider envelopes":
    for raw in [
      "{",
      "{}",
      "{\"choices\":[]}",
      "{\"choices\":[{\"message\":{\"content\":null," &
        "\"tool_calls\":{}}}]}"
    ]:
      expect LlmApiError:
        discard parseLlmResponseForTest(raw)

  test "rejects incomplete native calls":
    let raw = """{
      "choices":[{"message":{"content":null,"tool_calls":[{
        "id":"","function":{"name":"probe","arguments":"{}"}
      }]}}]
    }"""
    expect LlmApiError:
      discard parseLlmResponseForTest(raw)
