import std/[json, options, strutils, unittest]

import ../src/config
import ../src/get
import ../src/harness_prompt
import ../src/harness_types
import ../src/llm
import ../src/sysinfo
import ../src/utils

suite "version metadata":
  test "uses release version 3.0.0 consistently":
    const nimbleContent = staticRead("../get.nimble")
    check APP_VERSION == "3.0.0"
    check nimbleContent.contains("version       = \"3.0.0\"")

  test "pins the supported Windows OpenSSL 3 runtime":
    const buildConfig = staticRead("../config.nims")
    const installer = staticRead("../get_ready.py")
    check buildConfig.contains("sslVersion=3")
    check installer.contains("libcrypto-3.dll")
    check installer.contains("libssl-3.dll")
    check installer.contains("zlib1.dll")
    check not installer.contains("libcrypto-1_1-x64.dll")
    check not installer.contains("libssl-1_1-x64.dll")

  when defined(windows):
    test "uses the stable Windows thread memory manager":
      check defined(gcrefc)

suite "response parsing":
  test "strips provider think blocks from chat content":
    let body = $(%*{
      "choices": [
        {
          "message": {
            "content": "<think>internal reasoning</think>\n\nok"
          }
        }
      ],
      "usage": {"total_tokens": 9}
    })
    let resp = parseLlmResponseForTest(body)
    check resp.content == "ok"
    check resp.tokensUsed == 9

  test "strips multiple case-insensitive thinking blocks":
    let body = $(%*{
      "choices": [
        {
          "message": {
            "content": "<THINK>first</THINK>\nanswer\n<thinking>second</thinking>"
          }
        }
      ]
    })
    let resp = parseLlmResponseForTest(body)
    check resp.content == "answer"

suite "model classification":
  test "uses the 2026-06-24 high-performance model rules":
    check DEFAULT_MODEL == "minimax-m3"
    check isKnownStrongModel("minimax-m3")
    check isKnownStrongModel("minimax-m2.7")
    check not isKnownStrongModel("minimax-m2.5")
    check isKnownStrongModel("gpt-5.5-pro")
    check isKnownStrongModel("gpt-5-codex")
    check not isKnownStrongModel("gpt-5.2")
    check not isKnownStrongModel("gpt-5.5-mini")
    check isKnownStrongModel("gemini-3-flash")
    check isKnownStrongModel("gemini-3.5-flash")
    check not isKnownStrongModel("gemini-3.1-flash-lite")
    check isKnownStrongModel("claude-sonnet-4.6")
    check not isKnownStrongModel("claude-haiku-5")
    check isKnownStrongModel("qwen3-235b-a22b")
    check isKnownStrongModel("qwen3.8-27b")
    check not isKnownStrongModel("qwen3.7-flash")
    check not isKnownStrongModel("phi-4")
    check not isKnownStrongModel("gemma-3")

  test "covers each listed provider family with pass and reject examples":
    const passModels = [
      "gpt-5.4", "claude-mythos-5", "gemini-3.1-pro",
      "grok-4.3", "deepseek-v4-pro", "qwen3.7-plus",
      "glm-5.2", "minimax-m3", "mimo-v2.5-pro-ultraspeed",
      "kimi-k2.6", "mistral-large-3", "devstral-2",
      "llama-4-maverick", "command-a-reasoning",
      "ernie-5.0-thinking-preview", "doubao-seed-2-0-code",
      "hunyuan-hy3-preview", "step-3.5-flash",
      "nova-premier", "jamba-1.5-large"
    ]
    for model in passModels:
      checkpoint("pass model: " & model)
      check isKnownStrongModel(model)

    const rejectModels = [
      "gpt-5.5-mini", "claude-haiku-5",
      "gemini-3.1-flash-lite", "grok-4.3-fast",
      "deepseek-v3", "qwen3.7-turbo", "glm-5.2-air",
      "minimax-m2.5", "mimo-v2.5-lite", "moonshot-v1",
      "ministral-8b", "llama-4-70b", "command-r-plus",
      "ernie-4.5", "doubao-seed-1.5-pro",
      "hunyuan-translation", "step-2", "nova-micro",
      "jamba-small", "phi-4-reasoning", "gemma-3n"
    ]
    for model in rejectModels:
      checkpoint("reject model: " & model)
      check not isKnownStrongModel(model)

suite "configuration":
  test "defaults to MiniMax M3 and does not prefer system proxy":
    let cfg = defaultConfig()
    check cfg.model == "minimax-m3"
    check cfg.systemProxy == false

  test "installer defaults match runtime defaults":
    const installerContent = staticRead("../get_ready.py")
    check installerContent.contains(
      "DEFAULT_MODEL: str = \"minimax-m3\"")
    check installerContent.contains(
      "DEFAULT_URL: str = \"https://api.minimaxi.com/v1\"")

  test "system proxy preference overrides terminal proxy only when enabled":
    check chooseProxyForTest(
      "http://terminal:7890",
      "http://system:7890",
      false) == (url: "http://terminal:7890", source: "terminal")
    check chooseProxyForTest(
      "http://terminal:7890",
      "http://system:7890",
      true) == (url: "http://system:7890", source: "system")
    check chooseProxyForTest(
      "",
      "http://system:7890",
      false) == (url: "", source: "")

suite "command aliases":
  test "normalises direct info aliases":
    check normaliseArgsForTest(@["name"]) == @["get", "--name"]
    check normaliseArgsForTest(@["intro"]) == @["get", "--intro"]
    check normaliseArgsForTest(@["author"]) == @["get", "--author"]
    check normaliseArgsForTest(@["license"]) == @["get", "--license"]
    check normaliseArgsForTest(@["github"]) == @["get", "--github"]
    check normaliseArgsForTest(@["get", "--author"]) == @["get", "--author"]

suite "agent response parsing":
  test "bare protocol markers are not treated as user-facing answers":
    let parsed = extractAgentAction("<!-- INTERPRET -->")
    check parsed.action == aaContinue
    check parsed.command.isNone

suite "prompt guidance":
  test "PowerShell prompt strongly prefers executable native commands":
    let info = SysInfo(
      os: "windows",
      arch: "amd64",
      hostname: "host",
      username: "user",
      cwd: "C:\\Work",
      localDate: "2026-08-24",
      shell: "powershell",
      shellVersion: "5.1",
      availableTools: @["rg"]
    )
    let msgs = buildHarnessMessages(
      info, "list files", "powershell", hkAuto,
      defaultRunBudget(hkAuto), none(string), none(string))
    let sys = msgs[0].content
    check sys.contains("Get-ChildItem")
    check sys.contains("without placeholders")
    check sys.contains("emit only runnable commands")
    check sys.contains("Inspect dynamic or machine-local facts")
    check sys.contains("Resolve-Path ~")
    check not sys.contains("[Environment]::")
