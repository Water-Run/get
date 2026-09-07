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

import std/[json, options, os, strformat, strutils, unittest]

import llm
import utils

## Runs a test with isolated proxy variables and restores their original values.
##
## :param body: Assertions that may configure proxy environment variables.
template withProxyEnvironment(body: untyped) =
  block:
    let names = [
      "HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy",
      "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"
    ]
    var previous: seq[tuple[exists: bool, value: string]] = @[]
    for name in names:
      previous.add((existsEnv(name), getEnv(name, "")))
    # Snapshot both spellings before deleting either: Windows treats them as
    # the same environment variable.
    for name in names:
      delEnv(name)
    try:
      body
    finally:
      for index, name in names:
        if previous[index].exists:
          putEnv(name, previous[index].value)
        else:
          delEnv(name)

## Verifies routing decisions without connecting to a provider or proxy.
suite "NO_PROXY routing":
  test "restricts explicit ports and resolves HTTP and HTTPS defaults":
    withProxyEnvironment:
      putEnv("ALL_PROXY", "http://proxy.test:8080")
      for (entry, target, bypass) in [
        ("provider.test:443", "https://provider.test/v1", true),
        ("provider.test:443", "https://provider.test:443/v1", true),
        ("provider.test:443", "https://provider.test:8443/v1", false),
        ("provider.test:443", "http://provider.test/v1", false),
        ("provider.test:80", "http://provider.test/v1", true),
        ("provider.test:80", "https://provider.test/v1", false),
        ("provider.test:8443", "https://provider.test:8443/v1", true),
        ("provider.test:8443", "https://provider.test/v1", false),
        ("provider.test:00443", "https://provider.test/v1", true),
        ("provider.test:443", "https://provider.test:00443/v1", true),
        ("provider.test:65535", "https://provider.test:65535/v1", true),
        ("provider.test:443", "https://provider.test:invalid/v1", false)
      ]:
        checkpoint fmt"NO_PROXY={entry}; target={target}"
        putEnv("NO_PROXY", entry)
        check detectSystemProxyForTest(target) ==
          (if bypass: "" else: "http://proxy.test:8080")

  test "preserves domain boundaries and unrestricted host entries":
    withProxyEnvironment:
      putEnv("ALL_PROXY", "http://proxy.test:8080")
      for (entry, target, bypass) in [
        ("provider.test", "https://provider.test:8443/v1", true),
        ("provider.test", "https://api.provider.test:8443/v1", true),
        (".provider.test:443", "https://provider.test/v1", true),
        (".provider.test:443", "https://api.provider.test/v1", true),
        (".provider.test:443", "https://api.provider.test:8443/v1", false),
        ("provider.test:443", "https://notprovider.test/v1", false),
        ("provider.test:443", "https://provider.test.example/v1", false),
        (" PROVIDER.TEST:443 ", "https://API.Provider.Test/v1", true),
        ("other.test:80, provider.test:443", "https://provider.test/v1", true),
        ("*", "https://provider.test:8443/v1", true)
      ]:
        checkpoint fmt"NO_PROXY={entry}; target={target}"
        putEnv("NO_PROXY", entry)
        check detectSystemProxyForTest(target) ==
          (if bypass: "" else: "http://proxy.test:8080")

  test "matches IPv4 addresses exactly with optional ports":
    withProxyEnvironment:
      putEnv("ALL_PROXY", "http://proxy.test:8080")
      for (entry, target, bypass) in [
        ("127.0.0.1:8080", "http://127.0.0.1:8080/v1", true),
        ("127.0.0.1:8080", "http://127.0.0.1:8081/v1", false),
        ("127.0.0.1", "http://127.0.0.1:8081/v1", true),
        ("127.0.0.1", "http://127.0.0.2/v1", false),
        ("127.0.0.1", "http://api.127.0.0.1/v1", false),
        ("0.0.1", "http://127.0.0.1/v1", false)
      ]:
        checkpoint fmt"NO_PROXY={entry}; target={target}"
        putEnv("NO_PROXY", entry)
        check detectSystemProxyForTest(target) ==
          (if bypass: "" else: "http://proxy.test:8080")

  test "distinguishes IPv6 addresses from bracketed address-port pairs":
    withProxyEnvironment:
      putEnv("ALL_PROXY", "http://proxy.test:8080")
      for (entry, target, bypass) in [
        ("::1", "http://[::1]:8080/v1", true),
        ("[::1]", "http://[::1]:8080/v1", true),
        ("[::1]:8080", "http://[::1]:8080/v1", true),
        ("[::1]:8080", "http://[::1]:8081/v1", false),
        ("[::1]:443", "https://[::1]/v1", true),
        ("[::1]:443", "http://[::1]/v1", false),
        ("[::1]:8080", "http://[::2]:8080/v1", false),
        ("2001:db8::1", "https://[2001:0db8:0:0:0:0:0:1]/v1", true),
        ("2001:db8::1:443", "https://[2001:db8::1]/v1", false)
      ]:
        checkpoint fmt"NO_PROXY={entry}; target={target}"
        putEnv("NO_PROXY", entry)
        check detectSystemProxyForTest(target) ==
          (if bypass: "" else: "http://proxy.test:8080")

  test "ignores malformed entries without broadening proxy bypass":
    withProxyEnvironment:
      putEnv("ALL_PROXY", "http://proxy.test:8080")
      for entry in [
        "provider.test:", "provider.test:invalid", "provider.test:0",
        "provider.test:65536", "provider.test:99999999999999999999",
        "provider.test:+443", "provider.test:-443", "provider.test: 443",
        "provider.test:443:8443", "[provider.test]:443", "[::1",
        "[::1]extra", "[::1]:", "[::1]:invalid", "[::1]:65536",
        "[::1]:443:8443", ":443", "*:443", "", ", ,"
      ]:
        putEnv("NO_PROXY", entry)
        for target in ["https://provider.test/v1", "https://[::1]/v1"]:
          checkpoint fmt"NO_PROXY={entry}; target={target}"
          check detectSystemProxyForTest(target) == "http://proxy.test:8080"
      putEnv("NO_PROXY", "provider.test:invalid, provider.test:443")
      check detectSystemProxyForTest("https://provider.test/v1") == ""

  test "honors lowercase no_proxy with the same port restriction":
    withProxyEnvironment:
      putEnv("ALL_PROXY", "http://proxy.test:8080")
      putEnv("no_proxy", "provider.test:443")
      check detectSystemProxyForTest("https://provider.test/v1") == ""
      check detectSystemProxyForTest("https://provider.test:8443/v1") ==
        "http://proxy.test:8080"

## Verifies native request and response payload handling.
suite "LLM native tools":
  test "selects proxy by target scheme and honors NO_PROXY":
    withProxyEnvironment:
      putEnv("HTTP_PROXY", "http://http-proxy.test:8080")
      putEnv("HTTPS_PROXY", "http://https-proxy.test:8443")
      check detectSystemProxyForTest("http://provider.test/v1") ==
        "http://http-proxy.test:8080"
      check detectSystemProxyForTest("https://provider.test/v1") ==
        "http://https-proxy.test:8443"
      putEnv("NO_PROXY", ".provider.test")
      check detectSystemProxyForTest("https://api.provider.test/v1") == ""

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
    check serialBody{"temperature"}.isNil

    var deterministicRequest = serialRequest
    deterministicRequest.temperature = some(0.0)
    let deterministicBody = buildLlmRequestBodyForTest(deterministicRequest)
    check deterministicBody{"temperature"}.getFloat() == 0.0

    deterministicRequest.temperature = some(2.1)
    expect LlmApiError:
      discard buildLlmRequestBodyForTest(deterministicRequest)

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

  test "strips orphan Qwen template closing tags":
    let raw = $(%*{
      "choices": [{
        "message": {
          "content": "{\"type\":\"answer\",\"text\":\"ok\"}" &
            "\n</parameter>\n</THINK>"
        }
      }]
    })
    let value = parseLlmResponseForTest(raw)
    check value.content ==
      "{\"type\":\"answer\",\"text\":\"ok\"}"

  test "strips Qwen tool-template closures from a bare answer":
    let raw = $(%*{
      "choices": [{
        "message": {
          "content": "{\"text\":\"56088\"}\n</invoke>\n" &
            "</parameter>\n</function>\n</tool_call>"
        }
      }]
    })
    let value = parseLlmResponseForTest(raw)
    check value.content == "{\"text\":\"56088\"}"

  test "removes embedded orphan template tags without dropping text":
    let raw = $(%*{
      "choices": [{
        "message": {
          "content": "before\n</final_comment>\n</thinking>\nafter"
        }
      }]
    })
    let value = parseLlmResponseForTest(raw)
    check value.content.contains("before")
    check value.content.contains("after")
    check not value.content.contains("</")

  test "normalizes many provider template tags without quadratic rebuilding":
    let content = repeat("x</parameter></THINK>", 4096) & "done"
    let raw = $(%*{
      "choices": [{"message": {"content": content}}]
    })
    let value = parseLlmResponseForTest(raw)
    check value.content == repeat("x", 4096) & "done"

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
