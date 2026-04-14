## Unit tests for the get tool infrastructure modules.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-14
## :File: test.nim
## :License: AGPL-3.0
##
## This file exercises the pure-function helpers and infrastructure
## operations exposed by utils, config, cache, sysinfo, exec,
## prompt, logger, and llm.  The LLM connectivity suite is skipped
## unless the environment variables GET_TEST_KEY, GET_TEST_URL, and
## GET_TEST_MODEL are set.

{.experimental: "strictFuncs".}

import std/[os, options, strformat, strutils, times,
            unittest]

import utils
import cache
import config
import exec
import llm
import logger
import prompt
import style
import sysinfo

# ---------------------------------------------------------------------------
# utils tests
# ---------------------------------------------------------------------------

suite "utils":
  ## Tests for maskString, extractCodeBlock, defaultShell, and the
  ## global application-identity constants.

  test "maskString replaces characters with asterisks":
    check maskString("hello") == "*****"
    check maskString("") == ""
    check maskString("x") == "*"
    check maskString("ab") == "**"

  test "APP constants are non-empty":
    check APP_NAME.len > 0
    check APP_VERSION.len > 0
    check APP_VERSION == "1.0.0"
    check APP_INTRO.len > 0
    check APP_LICENSE.len > 0
    check APP_GITHUB.len > 0

  test "defaultShell returns a non-empty string":
    check defaultShell().len > 0

  test "extractCodeBlock extracts sh block":
    let text = "Here:\n```sh\nls -la /etc\n```\ndone"
    let res = extractCodeBlock(text)
    check res.isSome
    check res.get == "ls -la /etc"

  test "extractCodeBlock extracts bare block":
    let text = "```\necho hello\n```"
    let res = extractCodeBlock(text)
    check res.isSome
    check res.get == "echo hello"

  test "extractCodeBlock returns none on no block":
    let text = "no code block here"
    check extractCodeBlock(text).isNone

  test "extractCodeBlock handles unclosed fence":
    let text = "```sh\nls -la"
    let res = extractCodeBlock(text)
    check res.isSome
    check res.get == "ls -la"

  test "extractCodeBlock extracts first block only":
    let text =
      "```sh\nfirst\n```\n```sh\nsecond\n```"
    let res = extractCodeBlock(text)
    check res.isSome
    check res.get == "first"

  test "extractCodeBlock handles multiline command":
    let text = """```sh
ls -la /etc && \
  cat /etc/hostname
```"""
    let res = extractCodeBlock(text)
    check res.isSome
    check res.get.contains("ls -la")
    check res.get.contains("cat")

  test "getBundledBinDir returns a string":
    let d = getBundledBinDir()
    # May be empty in CI environments.
    discard d

  test "DEFAULT_COMMAND_PATTERN is non-empty":
    check DEFAULT_COMMAND_PATTERN.len > 0
    check DEFAULT_COMMAND_PATTERN.contains("rm")

  test "DANGEROUS_COMMAND_NAMES has entries":
    check DANGEROUS_COMMAND_NAMES.len > 0

# ---------------------------------------------------------------------------
# sysinfo tests
# ---------------------------------------------------------------------------

suite "sysinfo":
  ## Tests that system information collection produces sensible
  ## data and environment checks run without error.

  test "collectSysInfo returns non-empty os and arch":
    let info = collectSysInfo(defaultShell())
    check info.os.len > 0
    check info.arch.len > 0
    check info.cwd.len > 0

  test "formatSysInfo produces non-empty output":
    let info = collectSysInfo(defaultShell())
    let formatted = formatSysInfo(info)
    check formatted.len > 0
    check formatted.contains("OS:")

  test "formatSysInfo with minimal SysInfo":
    let info = SysInfo(
      os: "testOS",
      arch: "testArch",
      hostname: "",
      username: "",
      cwd: "/tmp",
      shell: "sh",
      shellVersion: "",
      availableTools: @[],
      bundledTools: @[],
      binDir: ""
    )
    let formatted = formatSysInfo(info)
    check formatted.contains("testOS")
    check formatted.contains("testArch")
    check not formatted.contains("Hostname:")

  test "formatBundledTools with empty list":
    check formatBundledTools(@[]).len == 0

  test "formatBundledTools with entries":
    let tools = @[
      BundledTool(name: "rg",
        description: "fast grep")]
    let s = formatBundledTools(tools)
    check s.contains("rg")
    check s.contains("BUNDLED TOOLS")

  test "checkEnvironment runs without crash":
    let w = checkEnvironment()
    # May or may not return a warning.
    discard w

# ---------------------------------------------------------------------------
# exec tests
# ---------------------------------------------------------------------------

suite "exec":
  ## Tests for forbidden-command-pattern validation and command
  ## execution.

  test "validateCommandPattern allows safe command":
    # Pattern blocks "rm", command is "ls" → allowed.
    check validateCommandPattern(
      "ls -la /etc", "\\brm\\b") == true

  test "validateCommandPattern blocks forbidden":
    # Pattern blocks "rm", command has "rm" → blocked.
    check validateCommandPattern(
      "rm -rf /", "\\brm\\b") == false

  test "validateCommandPattern with default pattern":
    # Default pattern should block "rm".
    check validateCommandPattern(
      "rm -rf /", DEFAULT_COMMAND_PATTERN) == false
    # Default pattern should allow "ls".
    check validateCommandPattern(
      "ls -la", DEFAULT_COMMAND_PATTERN) == true
    # Default pattern should block "kill".
    check validateCommandPattern(
      "kill -9 1234", DEFAULT_COMMAND_PATTERN) == false
    # Default pattern should allow "rg".
    check validateCommandPattern(
      "rg pattern .", DEFAULT_COMMAND_PATTERN) == true

  test "validateCommandPattern complex commands":
    check validateCommandPattern(
      "echo hello", DEFAULT_COMMAND_PATTERN) == true
    check validateCommandPattern(
      "cat /etc/hostname",
      DEFAULT_COMMAND_PATTERN) == true
    check validateCommandPattern(
      "shutdown -h now",
      DEFAULT_COMMAND_PATTERN) == false

  test "invalid regex raises GetError":
    expect GetError:
      discard validateCommandPattern(
        "test", "[invalid")

  test "checkPatternSafety reports uncovered":
    # A very narrow pattern should miss some dangers.
    let warn = checkPatternSafety("\\brm\\b")
    check warn.len > 0
    check warn.contains("warning")

  test "checkPatternSafety with default pattern":
    let warn = checkPatternSafety(
      DEFAULT_COMMAND_PATTERN)
    check warn.len == 0

  test "executeCommand runs echo":
    let shell = defaultShell()
    when defined(windows):
      let res = executeCommand(
        "Write-Output 'hello'", shell)
    else:
      let res = executeCommand(
        "echo hello", shell)
    check res.exitCode == 0
    check res.output.strip() == "hello"

  test "executeCommand captures non-zero exit":
    let shell = defaultShell()
    when defined(windows):
      let res = executeCommand(
        "exit 42", shell)
    else:
      let res = executeCommand(
        "exit 42", shell)
    check res.exitCode == 42

  test "executeCommand with empty binDir works":
    let shell = defaultShell()
    when defined(windows):
      let res = executeCommand(
        "Write-Output 'ok'", shell, "")
    else:
      let res = executeCommand(
        "echo ok", shell, "")
    check res.exitCode == 0
    check res.output.strip() == "ok"

# ---------------------------------------------------------------------------
# style tests
# ---------------------------------------------------------------------------

suite "style":
  ## Tests for style parsing and name conversion.

  test "parseStyle accepts valid styles":
    check parseStyle("simp") == skSimp
    check parseStyle("std") == skStd
    check parseStyle("vivid") == skVivid
    check parseStyle("STD") == skStd
    check parseStyle(" vivid ") == skVivid

  test "parseStyle rejects invalid styles":
    expect GetError:
      discard parseStyle("invalid")

  test "styleName round-trips":
    check styleName(skSimp) == "simp"
    check styleName(skStd) == "std"
    check styleName(skVivid) == "vivid"

# ---------------------------------------------------------------------------
# config — pure helpers via public API
# ---------------------------------------------------------------------------

suite "config defaults":
  ## Verifies that defaultConfig returns correct compile-time
  ## defaults.

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
    check cfg.cache == DEFAULT_CACHE
    check cfg.cacheExpiry == DEFAULT_CACHE_EXPIRY
    check cfg.cacheMaxEntries ==
      DEFAULT_CACHE_MAX_ENTRIES
    check cfg.logMaxEntries ==
      DEFAULT_LOG_MAX_ENTRIES
    check cfg.externalDisplay ==
      DEFAULT_EXTERNAL_DISPLAY

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
  ## Verifies that saveConfig and loadConfig faithfully preserve
  ## every field.

  test "save and load preserves values":
    let original = Config(
      url:             "https://example.com/v1",
      model:           "test-model",
      manualConfirm:   true,
      doubleCheck:     true,
      instance:        true,
      timeout:         60,
      maxToken:        1024,
      commandPattern:  some("^ls"),
      systemPrompt:    some("Be concise."),
      shell:           "zsh",
      log:             false,
      hideProcess:     true,
      cache:           false,
      cacheExpiry:     7,
      cacheMaxEntries: 500,
      logMaxEntries:   200,
      style:           "std",
      externalDisplay: false
    )
    saveConfig(original)
    let loaded = loadConfig()
    check loaded.url == original.url
    check loaded.model == original.model
    check loaded.manualConfirm ==
      original.manualConfirm
    check loaded.doubleCheck == original.doubleCheck
    check loaded.instance == original.instance
    check loaded.timeout == original.timeout
    check loaded.maxToken == original.maxToken
    check loaded.commandPattern ==
      original.commandPattern
    check loaded.systemPrompt == original.systemPrompt
    check loaded.shell == original.shell
    check loaded.log == original.log
    check loaded.hideProcess == original.hideProcess
    check loaded.cache == original.cache
    check loaded.cacheExpiry == original.cacheExpiry
    check loaded.cacheMaxEntries ==
      original.cacheMaxEntries
    check loaded.logMaxEntries ==
      original.logMaxEntries
    check loaded.externalDisplay ==
      original.externalDisplay
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
  ## Verifies the set-by-name API.

  test "set and unset url":
    setConfigOption("url", "https://custom.api/v1")
    var cfg = loadConfig()
    check cfg.url == "https://custom.api/v1"
    setConfigOption("url", "")
    cfg = loadConfig()
    check cfg.url == ""
    saveConfig(defaultConfig())

  test "set and unset model":
    setConfigOption("model", "custom-model-x")
    var cfg = loadConfig()
    check cfg.model == "custom-model-x"
    setConfigOption("model", "")
    cfg = loadConfig()
    check cfg.model == ""
    saveConfig(defaultConfig())

  test "set boolean option":
    setConfigOption("manual-confirm", "true")
    var cfg = loadConfig()
    check cfg.manualConfirm == true
    setConfigOption("manual-confirm", "false")
    cfg = loadConfig()
    check cfg.manualConfirm == false
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

  test "config reset restores all defaults":
    setConfigOption("model", "")
    setConfigOption("url", "")
    setConfigOption("timeout", "60")
    resetConfig()
    let cfg = loadConfig()
    check cfg.url == DEFAULT_URL
    check cfg.model == DEFAULT_MODEL
    check cfg.timeout == DEFAULT_TIMEOUT

  test "set cache boolean":
    setConfigOption("cache", "false")
    var cfg = loadConfig()
    check cfg.cache == false
    setConfigOption("cache", "true")
    cfg = loadConfig()
    check cfg.cache == true
    saveConfig(defaultConfig())

  test "set cache-expiry":
    setConfigOption("cache-expiry", "7")
    var cfg = loadConfig()
    check cfg.cacheExpiry == 7
    setConfigOption("cache-expiry", "")
    cfg = loadConfig()
    check cfg.cacheExpiry == DEFAULT_CACHE_EXPIRY
    saveConfig(defaultConfig())

  test "set cache-max-entries":
    setConfigOption("cache-max-entries", "500")
    var cfg = loadConfig()
    check cfg.cacheMaxEntries == 500
    setConfigOption("cache-max-entries", "")
    cfg = loadConfig()
    check cfg.cacheMaxEntries ==
      DEFAULT_CACHE_MAX_ENTRIES
    saveConfig(defaultConfig())

  test "set log-max-entries":
    setConfigOption("log-max-entries", "500")
    var cfg = loadConfig()
    check cfg.logMaxEntries == 500
    setConfigOption("log-max-entries", "")
    cfg = loadConfig()
    check cfg.logMaxEntries ==
      DEFAULT_LOG_MAX_ENTRIES
    saveConfig(defaultConfig())

  test "set external-display":
    setConfigOption("external-display", "false")
    var cfg = loadConfig()
    check cfg.externalDisplay == false
    setConfigOption("external-display", "true")
    cfg = loadConfig()
    check cfg.externalDisplay == true
    saveConfig(defaultConfig())

# ---------------------------------------------------------------------------
# cache tests
# ---------------------------------------------------------------------------

suite "cache":
  ## Tests for hash computation, cache persistence, lookup,
  ## eviction, and management commands.

  test "computeCacheHash is deterministic":
    let h1 = computeCacheHash(
      "test query", "/tmp", "bash", "gpt",
      false, none(string), none(string))
    let h2 = computeCacheHash(
      "test query", "/tmp", "bash", "gpt",
      false, none(string), none(string))
    check h1 == h2
    check h1.len == 32

  test "computeCacheHash differs for queries":
    let h1 = computeCacheHash(
      "query one", "/tmp", "bash", "gpt",
      false, none(string), none(string))
    let h2 = computeCacheHash(
      "query two", "/tmp", "bash", "gpt",
      false, none(string), none(string))
    check h1 != h2

  test "computeCacheHash differs for cwd":
    let h1 = computeCacheHash(
      "test", "/home", "bash", "gpt",
      false, none(string), none(string))
    let h2 = computeCacheHash(
      "test", "/tmp", "bash", "gpt",
      false, none(string), none(string))
    check h1 != h2

  test "computeCacheHash differs for instance":
    let h1 = computeCacheHash(
      "test", "/tmp", "bash", "gpt",
      true, none(string), none(string))
    let h2 = computeCacheHash(
      "test", "/tmp", "bash", "gpt",
      false, none(string), none(string))
    check h1 != h2

  test "computeCacheHash normalises query case":
    let h1 = computeCacheHash(
      "Test Query", "/tmp", "bash", "gpt",
      false, none(string), none(string))
    let h2 = computeCacheHash(
      "test query", "/tmp", "bash", "gpt",
      false, none(string), none(string))
    check h1 == h2

  test "save and load cache round-trip":
    var store = CacheStore(entries: @[])
    let entry = CacheEntry(
      hash: "abc123",
      query: "test query",
      command: "echo hello",
      output: "hello",
      timestamp: getTime().toUnix()
    )
    addCacheEntry(store, entry, 1000, 30)
    saveCache(store)
    let loaded = loadCache()
    check loaded.entries.len >= 1
    var found = false
    for e in loaded.entries:
      if e.hash == "abc123":
        check e.query == "test query"
        check e.command == "echo hello"
        check e.output == "hello"
        found = true
    check found
    discard cleanCache()

  test "lookupCache returns entry when fresh":
    var store = CacheStore(entries: @[
      CacheEntry(
        hash: "fresh1",
        query: "q",
        command: "cmd",
        output: "out",
        timestamp: getTime().toUnix()
      )
    ])
    let hit = lookupCache(store, "fresh1", 30)
    check hit.isSome
    check hit.get.output == "out"

  test "lookupCache returns none when expired":
    let old = getTime().toUnix() - (31 * 86400)
    var store = CacheStore(entries: @[
      CacheEntry(
        hash: "old1",
        query: "q",
        command: "cmd",
        output: "out",
        timestamp: old
      )
    ])
    let hit = lookupCache(store, "old1", 30)
    check hit.isNone

  test "lookupCache returns none for missing hash":
    var store = CacheStore(entries: @[])
    let hit = lookupCache(store, "missing", 30)
    check hit.isNone

  test "addCacheEntry replaces existing hash":
    var store = CacheStore(entries: @[
      CacheEntry(
        hash: "dup",
        query: "old",
        command: "old-cmd",
        output: "old-out",
        timestamp: getTime().toUnix() - 100
      )
    ])
    let entry = CacheEntry(
      hash: "dup",
      query: "new",
      command: "new-cmd",
      output: "new-out",
      timestamp: getTime().toUnix()
    )
    addCacheEntry(store, entry, 1000, 30)
    check store.entries.len == 1
    check store.entries[0].query == "new"

  test "addCacheEntry enforces max entries":
    var store = CacheStore(entries: @[])
    for i in 0 ..< 5:
      let e = CacheEntry(
        hash: fmt"h{i}",
        query: fmt"q{i}",
        command: "",
        output: "",
        timestamp:
          getTime().toUnix() - (5 - i).int64
      )
      addCacheEntry(store, e, 3, 30)
    check store.entries.len <= 3

  test "unsetCacheEntries removes matching query":
    var store = CacheStore(entries: @[
      CacheEntry(
        hash: "a1",
        query: "system version",
        command: "uname -a",
        output: "Linux",
        timestamp: getTime().toUnix()
      ),
      CacheEntry(
        hash: "b2",
        query: "disk usage",
        command: "df -h",
        output: "50G",
        timestamp: getTime().toUnix()
      )
    ])
    let removed = unsetCacheEntries(
      store, "system version")
    check removed == 1
    check store.entries.len == 1
    check store.entries[0].query == "disk usage"

  test "unsetCacheEntries case-insensitive":
    var store = CacheStore(entries: @[
      CacheEntry(
        hash: "ci",
        query: "System Version",
        command: "",
        output: "",
        timestamp: getTime().toUnix()
      )
    ])
    let removed = unsetCacheEntries(
      store, "system version")
    check removed == 1
    check store.entries.len == 0

  test "cleanCache removes all entries":
    var store = CacheStore(entries: @[
      CacheEntry(
        hash: "x",
        query: "q",
        command: "",
        output: "",
        timestamp: getTime().toUnix()
      )
    ])
    saveCache(store)
    let removed = cleanCache()
    check removed == 1
    let loaded = loadCache()
    check loaded.entries.len == 0

# ---------------------------------------------------------------------------
# logger tests
# ---------------------------------------------------------------------------

suite "logger":
  ## Tests for log cleaning and info display.

  test "cleanLog on empty log returns 0":
    # Ensure clean state.
    let path = getLogFilePath()
    if fileExists(path):
      writeFile(path, "")
    check cleanLog() == 0

  test "logExecution and cleanLog round-trip":
    logExecution("test q", "echo 1", "1", 0, 0)
    let removed = cleanLog()
    check removed >= 1

# ---------------------------------------------------------------------------
# prompt tests
# ---------------------------------------------------------------------------

suite "prompt":
  ## Tests that prompt builders produce well-formed message lists.

  test "buildQueryMessages produces system+user":
    let info = SysInfo(
      os: "linux", arch: "amd64",
      hostname: "dev", username: "user",
      cwd: "/home/user", shell: "bash",
      shellVersion: "5.2",
      availableTools: @["git", "curl"],
      bundledTools: @[
        BundledTool(name: "rg",
          description: "fast grep")],
      binDir: "/opt/bin")
    let msgs = buildQueryMessages(
      info, "disk usage", "bash", true,
      none(string), none(string))
    check msgs.len == 2
    check msgs[0].role == "system"
    check msgs[1].role == "user"
    check msgs[0].content.contains("read-only")
    check msgs[1].content.contains("disk usage")

  test "buildQueryMessages includes bundled tools":
    let info = SysInfo(
      os: "linux", arch: "amd64",
      hostname: "", username: "",
      cwd: "/tmp", shell: "bash",
      shellVersion: "",
      availableTools: @[],
      bundledTools: @[
        BundledTool(name: "rg",
          description: "fast grep"),
        BundledTool(name: "fd",
          description: "fast find")],
      binDir: "/opt/bin")
    let msgs = buildQueryMessages(
      info, "test", "bash", false,
      none(string), none(string))
    check msgs[0].content.contains("BUNDLED TOOLS")
    check msgs[0].content.contains("rg")
    check msgs[0].content.contains("fd")

  test "buildQueryMessages includes bat guidance":
    let info = SysInfo(
      os: "linux", arch: "amd64",
      hostname: "", username: "",
      cwd: "/tmp", shell: "bash",
      shellVersion: "",
      availableTools: @[],
      bundledTools: @[],
      binDir: "")
    let msgs = buildQueryMessages(
      info, "test", "bash", false,
      none(string), none(string))
    check msgs[0].content.contains("bat")
    check msgs[0].content.contains("mdcat")

  test "buildQueryMessages includes system info":
    let info = SysInfo(
      os: "linux", arch: "amd64",
      hostname: "", username: "",
      cwd: "/tmp", shell: "bash",
      shellVersion: "",
      availableTools: @[],
      bundledTools: @[],
      binDir: "")
    let msgs = buildQueryMessages(
      info, "test", "bash", false,
      none(string), none(string))
    check msgs[0].content.contains("linux")

  test "buildQueryMessages includes custom prompt":
    let info = SysInfo(
      os: "linux", arch: "amd64",
      hostname: "", username: "",
      cwd: "/tmp", shell: "bash",
      shellVersion: "",
      availableTools: @[],
      bundledTools: @[],
      binDir: "")
    let msgs = buildQueryMessages(
      info, "test", "bash", false,
      some("Custom rule here"), none(string))
    check msgs[0].content.contains(
      "Custom rule here")

  test "buildQueryMessages includes pattern note":
    let info = SysInfo(
      os: "linux", arch: "amd64",
      hostname: "", username: "",
      cwd: "/tmp", shell: "bash",
      shellVersion: "",
      availableTools: @[],
      bundledTools: @[],
      binDir: "")
    let msgs = buildQueryMessages(
      info, "test", "bash", false,
      none(string), some("\\brm\\b"))
    check msgs[0].content.contains("\\brm\\b")
    check msgs[0].content.contains(
      "MUST NOT match")

  test "buildDoubleCheckMessages produces 2 msgs":
    let info = SysInfo(
      os: "linux", arch: "amd64",
      hostname: "", username: "",
      cwd: "/tmp", shell: "bash",
      shellVersion: "",
      availableTools: @[],
      bundledTools: @[],
      binDir: "")
    let msgs = buildDoubleCheckMessages(
      "ls -la", "list files", info)
    check msgs.len == 2
    check msgs[0].content.contains("ls -la")
    check msgs[0].content.contains("list files")

  test "buildInterpretMessages produces 2 msgs":
    let msgs = buildInterpretMessages(
      "disk usage", "df -h",
      "/dev/sda1 50G 20G 30G 40%")
    check msgs.len == 2
    check msgs[0].content.contains("disk usage")
    check msgs[0].content.contains("df -h")
    check msgs[0].content.contains("50G")

# ---------------------------------------------------------------------------
# llm connectivity (optional)
# ---------------------------------------------------------------------------

suite "llm connectivity":
  ## Sends a minimal probe request.  Skipped when GET_TEST_KEY,
  ## GET_TEST_URL, or GET_TEST_MODEL are absent.

  test "sendLlmRequest returns non-empty response":
    let apiKey   = getEnv("GET_TEST_KEY", "")
    let apiUrl   = getEnv("GET_TEST_URL", "")
    let apiModel = getEnv("GET_TEST_MODEL", "")
    if apiKey.len == 0 or apiUrl.len == 0 or
        apiModel.len == 0:
      skip()
    else:
      let req = LlmRequest(
        model: apiModel,
        messages: @[
          LlmMessage(
            role: "system",
            content: ISOK_SYSTEM_PROMPT),
          LlmMessage(
            role: "user",
            content: ISOK_USER_PROMPT)
        ],
        maxTokens: ISOK_MAX_TOKENS
      )
      let resp = sendLlmRequest(
        req,
        apiUrl,
        apiKey,
        timeoutSec  = 30,
        hideProcess = true
      )
      check resp.content.len > 0
