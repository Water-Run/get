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
    check messages[0].content.len < 1800
    check messages[0].content.contains("Prefer one terminal call")
    check messages[0].content.contains("complete requested answer")
    check messages[0].content.contains("summarize")
    check messages[0].content.contains("local_date=2026-08-24")
    check messages[0].content.contains("never use inline interpreter")
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
