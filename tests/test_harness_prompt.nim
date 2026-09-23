## Tests compact prompt construction for the query loop.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-09-23
## :File: test_harness_prompt.nim
## :License: AGPL-3.0
##
## This suite keeps the prompt short, free of removed strategies and special
## cases, and prevents reintroducing an eager environment/tool inventory.

{.experimental: "strictFuncs".}

import std/[options, strutils, unittest]

import harness_prompt
import harness_types
import sysinfo

suite "query prompt":
  test "the prompt stays compact and describes one loop":
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
    let messages = buildHarnessMessages(info, "show cwd", "bash",
      defaultRunBudget(), none(string))
    let system = messages[0].content
    check messages.len == 2
    check messages[1].content == "show cwd"
    check system.len < 3500
    check system.contains("local_date=2026-08-24")
    check system.contains("timezone=Asia/Shanghai")
    check system.contains(".venv")
    check system.contains("6 model turns")
    check not system.contains("Available tools:")
    check not system.contains("<!-- CONTINUE -->")
    check not system.contains("answer turn")
    check not system.contains("return_raw")
    check not system.contains("run_readonly_shell")

  test "weather has no special case":
    var info = collectFastSysInfo("bash")
    info.timeZone = "Asia/Shanghai"
    let weather = buildHarnessMessages(info, "今天天气", "bash",
      defaultRunBudget(), none(string))
    check weather[1].content == "今天天气"
    check not weather[0].content.toLowerAscii.contains("weather")

  test "a configured system prompt is appended":
    let messages = buildHarnessMessages(collectFastSysInfo("bash"), "inspect",
      "bash", defaultRunBudget(), some("Prefer metric units."))
    check messages[0].content.contains("Prefer metric units.")

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
    let messages = buildHarnessMessages(collectFastSysInfo("bash"),
      "Without tools, answer 42", "bash", defaultRunBudget(), none(string),
      toolsDisabled = true)
    let system = messages[0].content
    check system.contains("No tools are available")
    check system.contains("text only")
    check not system.contains("run_shell")
    check not system.contains("tool_calls")
