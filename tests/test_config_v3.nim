## Tests configuration defaults and migration.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_config_v3.nim
## :License: AGPL-3.0
##
## This suite validates defaults, the removal of schema-4 keys, and
## normalization of externally edited hard resource limits without disk IO.

{.experimental: "strictFuncs".}

import std/unittest

when defined(windows):
  import std/[options, os, strutils, tempfiles]

import config
when defined(windows):
  import utils

## Verifies configuration defaults and migration behavior.
suite "configuration schema 5":
  test "defaults keep review and confirmation off":
    let value = defaultConfig()
    check value.schemaVersion == 5
    check value.toolProtocol == "auto"
    check not value.doubleCheck
    check not value.manualConfirm
    check value.markdown
    check value.maxRounds == 6
    check value.maxToolCalls == 16
    check value.maxParallel == 4
    check value.commandTimeout == 30
    check value.maxOutputBytes == 1_048_576

  test "Markdown defaults migrate and explicit values are respected":
    check parseConfigForTest("{}").markdown
    check parseConfigForTest("{\"markdown\":true}").markdown
    check not parseConfigForTest("{\"markdown\":false}").markdown
    check parseConfigForTest("{\"markdown\":\"false\"}").markdown

  test "removed keys are dropped and other settings are kept":
    let value = parseConfigForTest("""{
      "schemaVersion":4, "instance":true, "harness":"direct", "vivid":false,
      "commandPattern":"\\brm\\b", "model":"kept-model", "markdown":false
    }""")
    check value.schemaVersion == 5
    check value.model == "kept-model"
    check not value.markdown
    check value.url == DEFAULT_URL
    check value.shell.len > 0

  test "normalizes an invalid protocol and disabled hard limits":
    let value = parseConfigForTest("""{
      "toolProtocol":"unknown",
      "maxRounds":0,
      "maxToolCalls":-1,
      "maxParallel":0,
      "commandTimeout":0,
      "maxOutputBytes":0
    }""")
    check value.toolProtocol == "auto"
    check value.maxRounds == 6
    check value.maxToolCalls == 16
    check value.maxParallel == 4
    check value.commandTimeout == 30
    check value.maxOutputBytes == 1_048_576

  test "accepts only supported shells from trusted paths":
    for shell in [
      "bash", "/bin/bash", "/usr/bin/fish", "/opt/homebrew/bin/zsh",
      "powershell.exe", "C:\\Windows\\System32\\cmd.exe",
      "C:\\Program Files\\PowerShell\\7\\pwsh.exe"
    ]:
      check isSupportedShell(shell)
    for shell in [
      "python", "/tmp/bash", "./bash", "/usr/bin/../../../tmp/bash",
      "C:\\Temp\\powershell.exe", "evilbash"
    ]:
      check not isSupportedShell(shell)
    check parseConfigForTest("{\"shell\":\"/tmp/bash\"}").shell ==
      defaultConfig().shell

  when defined(windows):
    test "stores API keys with a DPAPI round trip":
      let originalAppData = getEnv("APPDATA")
      let root = createTempDir("get_v3_dpapi_", "")
      putEnv("APPDATA", root)
      defer:
        if originalAppData.len > 0:
          putEnv("APPDATA", originalAppData)
        else:
          delEnv("APPDATA")
        removeDir(root)

      const secret = "windows-dpapi-roundtrip-test"
      saveKey(some(secret))
      let stored = readFile(getKeyFilePath())
      check stored.len > 0
      check not stored.contains(secret)
      check loadKey() == some(secret)

      saveKey(none(string))
      check not fileExists(getKeyFilePath())
