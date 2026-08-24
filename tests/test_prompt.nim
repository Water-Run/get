## Tests the small auxiliary v3 prompts.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_prompt.nim
## :License: AGPL-3.0

{.experimental: "strictFuncs".}

import std/[strutils, unittest]

import prompt
import sysinfo

suite "auxiliary v3 prompts":
  test "connectivity probe is exact and bounded":
    check ISOK_SYSTEM_PROMPT.contains("exactly")
    check ISOK_USER_PROMPT.contains("exactly")
    check ISOK_MAX_TOKENS <= 256

  test "double-check prompt is compact and safety focused":
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
    let messages = buildDoubleCheckMessages(
      "ls -1", "list files", info)
    check messages.len == 2
    check messages[0].content.len < 1200
    check messages[0].content.contains("read-only")
    check messages[0].content.contains("UNSAFE")
    check messages[0].content.contains("list files")
    check messages[0].content.contains("ls -1")
    check not messages[0].content.contains("NOCACHE")
