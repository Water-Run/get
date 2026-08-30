## Tests compact prompt construction for the get v3 harness.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_harness_prompt.nim
## :License: AGPL-3.0
##
## This suite guards the direct-first prompt contract and prevents accidental
## reintroduction of the large eager v2 environment/tool inventory.

{.experimental: "strictFuncs".}

import std/[options, strutils, unittest]

import harness_prompt
import harness_protocol
import harness_types
import sysinfo

## Verifies prompt size, strategy guidance, and native tool schema.
suite "compact v3 harness prompt":
  test "automatic prompt stays compact and direct-first":
    let info = SysInfo(
      os: "linux",
      arch: "amd64",
      hostname: "host",
      username: "user",
      cwd: "/workspace",
      localDate: "2026-08-24",
      timeZone: "Asia/Shanghai",
      shell: "bash",
      shellVersion: "",
      availableTools: @[]
    )
    let messages = buildHarnessMessages(
      info,
      "show cwd",
      "bash",
      hkAuto,
      defaultRunBudget(hkAuto),
      none(string),
      none(string)
    )
    check messages.len == 2
    check messages[0].content.len < 2200
    check messages[0].content.contains("Prefer one terminal call")
    check messages[0].content.contains("complete requested answer")
    check messages[0].content.contains("summarize")
    check messages[0].content.contains("local_date=2026-08-24")
    check messages[0].content.contains("timezone=Asia/Shanghai")
    check messages[0].content.contains("never proxy egress")
    check messages[0].content.contains("No scripts, wrappers, inline code")
    check messages[0].content.contains("top -b -n 1 | head -n 15 on Linux")
    check messages[0].content.contains("top -l 1 -n 15 on macOS")
    check messages[0].content.contains("stdout-only sed")
    check messages[0].content.contains("pure AWK field selectors")
    check messages[0].content.contains("short ;/&&/|| sequence")
    check messages[0].content.contains("never find -exec")
    check messages[0].content.contains("Git summaries, first batch")
    check messages[0].content.contains("systemctl --failed --no-pager")
    check messages[0].content.contains("launchctl list | head -n 21")
    check messages[0].content.contains("literal < file needs a data reader")
    check not messages[0].content.contains("Available tools:")
    check not messages[0].content.contains("<!-- CONTINUE -->")

  test "includes only an explicit supplemental regex":
    let info = collectFastSysInfo("bash")
    let messages = buildHarnessMessages(
      info,
      "inspect",
      "bash",
      hkDirect,
      defaultRunBudget(hkDirect),
      none(string),
      some("\\bssh\\b")
    )
    check messages[0].content.contains("\\bssh\\b")
    check messages[0].content.contains("returned verbatim")
    check messages[0].content.contains("otherwise answer directly")

  test "native shell tool has bounded structured arguments":
    let tool = shellToolDefinition()
    check tool.name == "run_readonly_shell"
    check tool.parametersJson.contains("additionalProperties")
    check tool.parametersJson.contains("result_mode")

  test "weather receives an explicit timezone fallback only when relevant":
    var info = collectFastSysInfo("bash")
    info.timeZone = "Asia/Shanghai"
    let weather = buildHarnessMessages(
      info, "今天天气", "bash", hkAuto, defaultRunBudget(hkAuto),
      none(string), none(string))
    check weather[1].content.contains("timezone Asia/Shanghai")
    check weather[1].content.contains("if no place is named")
    check weather[1].content.contains("curl -q -fsSL --max-time 15")
    let ordinary = buildHarnessMessages(
      info, "show cwd", "bash", hkAuto, defaultRunBudget(hkAuto),
      none(string), none(string))
    check ordinary[1].content == "show cwd"

  test "explicit no-tool intent is detected without quoted false positives":
    check explicitlyDisablesTools(
      "Without calling a tool, answer 17 plus 25")
    check explicitlyDisablesTools(
      "General knowledge. Don't use tools: answer yes or no")
    check explicitlyDisablesTools(
      "不要调用工具，直接回答")
    check not explicitlyDisablesTools(
      "Explain the phrase 'without calling a tool'")
    check not explicitlyDisablesTools(
      "Find files containing `不要调用工具`")

  test "text-only prompt omits every tool protocol instruction":
    let info = collectFastSysInfo("bash")
    let messages = buildHarnessMessages(
      info,
      "Without tools, answer 42",
      "bash",
      hkAuto,
      defaultRunBudget(hkAuto),
      none(string),
      none(string),
      toolsDisabled = true
    )
    let system = messages[0].content
    check system.contains("No tools are available")
    check system.contains("text only")
    check not system.contains(READ_ONLY_SHELL_TOOL)
    check not system.contains("tool_calls")
