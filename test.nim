## Unit tests for the get tool infrastructure modules.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-13
## :File: test.nim
## :License: AGPL-3.0
##
## This file exercises the pure-function helpers and basic config
## operations exposed by the utils and config modules.

{.experimental: "strictFuncs".}

import std/[unittest, options]

import utils
import config

# ---------------------------------------------------------------------------
# utils tests
# ---------------------------------------------------------------------------

suite "utils":
  test "maskString replaces characters with asterisks":
    check maskString("hello") == "*****"
    check maskString("") == ""
    check maskString("x") == "*"
    check maskString("ab") == "**"

  test "APP constants are non-empty":
    check APP_NAME.len > 0
    check APP_VERSION.len > 0
    check APP_INTRO.len > 0
    check APP_LICENSE.len > 0
    check APP_GITHUB.len > 0

# ---------------------------------------------------------------------------
# config — pure helpers via public API
# ---------------------------------------------------------------------------

suite "config defaults":
  test "defaultConfig has expected values":
    let cfg = defaultConfig()
    check cfg.url == DEFAULT_URL
    check cfg.model == DEFAULT_MODEL
    check cfg.manualConfirm == DEFAULT_MANUAL_CONFIRM
    check cfg.doubleCheck == DEFAULT_DOUBLE_CHECK
    check cfg.instance == DEFAULT_INSTANCE
    check cfg.timeout == DEFAULT_TIMEOUT
    check cfg.maxToken == DEFAULT_MAX_TOKEN
    check cfg.commandPattern.isNone
    check cfg.systemPrompt.isNone
    check cfg.log == DEFAULT_LOG
    check cfg.hideProcess == DEFAULT_HIDE_PROCESS

  test "defaultConfig shell matches platform":
    let cfg = defaultConfig()
    when defined(windows):
      check cfg.shell == "powershell"
    else:
      check cfg.shell == "bash"

# ---------------------------------------------------------------------------
# config — set / load round-trip
# ---------------------------------------------------------------------------

suite "config persistence round-trip":
  test "save and load preserves values":
    let original = Config(
      url: "https://example.com/v1",
      model: "test-model",
      manualConfirm: true,
      doubleCheck: true,
      instance: true,
      timeout: 60,
      maxToken: 1024,
      commandPattern: some("^ls"),
      systemPrompt: some("Be concise."),
      shell: "zsh",
      log: false,
      hideProcess: true
    )
    saveConfig(original)
    let loaded = loadConfig()
    check loaded.url == original.url
    check loaded.model == original.model
    check loaded.manualConfirm == original.manualConfirm
    check loaded.doubleCheck == original.doubleCheck
    check loaded.instance == original.instance
    check loaded.timeout == original.timeout
    check loaded.maxToken == original.maxToken
    check loaded.commandPattern == original.commandPattern
    check loaded.systemPrompt == original.systemPrompt
    check loaded.shell == original.shell
    check loaded.log == original.log
    check loaded.hideProcess == original.hideProcess
    # Restore defaults so other tests are not affected
    saveConfig(defaultConfig())

  test "save and load with none options":
    var cfg = defaultConfig()
    cfg.commandPattern = none(string)
    cfg.systemPrompt = none(string)
    saveConfig(cfg)
    let loaded = loadConfig()
    check loaded.commandPattern.isNone
    check loaded.systemPrompt.isNone
    saveConfig(defaultConfig())

# ---------------------------------------------------------------------------
# config — setConfigOption validation
# ---------------------------------------------------------------------------

suite "setConfigOption":
  test "set and reset url":
    setConfigOption("url", "https://custom.api/v1")
    var cfg = loadConfig()
    check cfg.url == "https://custom.api/v1"
    # Reset by providing empty value
    setConfigOption("url", "")
    cfg = loadConfig()
    check cfg.url == DEFAULT_URL

  test "set boolean option":
    setConfigOption("manual-confirm", "true")
    var cfg = loadConfig()
    check cfg.manualConfirm == true
    setConfigOption("manual-confirm", "false")
    cfg = loadConfig()
    check cfg.manualConfirm == false
    # Reset
    setConfigOption("manual-confirm", "")
    cfg = loadConfig()
    check cfg.manualConfirm == DEFAULT_MANUAL_CONFIRM

  test "set integer option":
    setConfigOption("timeout", "120")
    var cfg = loadConfig()
    check cfg.timeout == 120
    setConfigOption("timeout", "")
    cfg = loadConfig()
    check cfg.timeout == DEFAULT_TIMEOUT

  test "invalid boolean raises GetError":
    expect GetError:
      setConfigOption("log", "yes")

  test "invalid integer raises GetError":
    expect GetError:
      setConfigOption("timeout", "abc")

  test "negative integer raises GetError":
    expect GetError:
      setConfigOption("max-token", "-5")

  test "unknown option raises GetError":
    expect GetError:
      setConfigOption("nonexistent", "value")