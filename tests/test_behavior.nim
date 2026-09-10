import std/[json, options, strutils, unittest]

import ../src/config
import ../src/get
import ../src/harness_prompt
import ../src/harness_types
import ../src/llm
import ../src/sysinfo
import ../src/utils

suite "version metadata":
  test "uses release version 3.2.0 consistently":
    const nimbleContent = staticRead("../get.nimble")
    check APP_VERSION == "3.2.0"
    check nimbleContent.contains("version       = \"3.2.0\"")

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

suite "model configuration":
  test "opaque nonempty model identifiers have neutral presentation":
    for model in ["flash", "mini", "local/experimental", "arbitrary-alias"]:
      check classifyModel(model) == classifyUrl("https://example.invalid")
    check classifyModel("") == classifyUrl("")

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
    check sys.contains("dynamic/local facts")
    check sys.contains("runnable, placeholder-free commands")
    check sys.contains("Only inspect/retrieve")
    check sys.contains("Resolve-Path ~")
    check not sys.contains("[Environment]::")
