## Tests get v3 defaults and configuration migration.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: test_config_v3.nim
## :License: AGPL-3.0
##
## This suite validates latency-oriented defaults, v2 instance migration, and
## normalization of externally edited hard resource limits without disk IO.

{.experimental: "strictFuncs".}

import std/unittest

when defined(windows):
  import std/[options, os, strutils, tempfiles]

import config
when defined(windows):
  import utils

## Verifies v3 configuration defaults and migration behavior.
suite "v3 configuration":
  test "defaults to automatic one-pass behavior":
    let value = defaultConfig()
    check value.schemaVersion == 3
    check value.harness == "auto"
    check value.toolProtocol == "auto"
    check not value.doubleCheck
    check value.maxRounds == 3
    check value.maxToolCalls == 8
    check value.maxParallel == 4
    check value.commandTimeout == 30
    check value.maxOutputBytes == 1_048_576

  test "migrates an enabled v2 instance flag to direct":
    let value = parseConfigForTest(
      "{\"instance\":true}")
    check value.harness == "direct"
    check value.instance

  test "migrates a disabled v2 instance flag to auto":
    let value = parseConfigForTest(
      "{\"instance\":false}")
    check value.harness == "auto"
    check not value.instance
    check value.schemaVersion == 3
    check value.url == DEFAULT_URL
    check value.model == DEFAULT_MODEL
    check value.shell.len > 0

  test "normalizes invalid strategies and disabled hard limits":
    let value = parseConfigForTest("""{
      "harness":"unknown",
      "toolProtocol":"unknown",
      "maxRounds":0,
      "maxToolCalls":-1,
      "maxParallel":0,
      "commandTimeout":0,
      "maxOutputBytes":0
    }""")
    check value.harness == "auto"
    check value.toolProtocol == "auto"
    check value.maxRounds == 3
    check value.maxToolCalls == 8
    check value.maxParallel == 4
    check value.commandTimeout == 30
    check value.maxOutputBytes == 1_048_576

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
