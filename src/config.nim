## Configuration management for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-17
## :File: config.nim
## :License: AGPL-3.0
##
## This module owns the Config data type, its default values,
## JSON serialisation, and all persistence logic including
## platform-specific secure key storage (Linux: file permissions
## 0600; Windows: DPAPI).  It exposes high-level operations
## consumed by the CLI dispatcher: load, save, display, reset,
## set-by-name, and readiness checking.

{.experimental: "strictFuncs".}

import std/[json, options, os, strformat, strutils]

when defined(windows):
  import std/base64

import style
import utils

# ---------------------------------------------------------------------------
# Constants — default values
# ---------------------------------------------------------------------------

## Default LLM API endpoint URL.
const DEFAULT_URL* = "https://api.poe.com/v1"

## Default LLM model identifier.
const DEFAULT_MODEL* = "gpt-5.3-codex"

## Default for manual-confirm.
const DEFAULT_MANUAL_CONFIRM* = false

## Default for double-check.
const DEFAULT_DOUBLE_CHECK* = true

## Default for instance mode.
const DEFAULT_INSTANCE* = false

## Default API request timeout in seconds.
const DEFAULT_TIMEOUT* = 300

## Default maximum tokens per request.
const DEFAULT_MAX_TOKEN* = 20480

## Default log-enabled flag.
const DEFAULT_LOG* = true

## Default hide-process flag.
const DEFAULT_HIDE_PROCESS* = false

## Default cache-enabled flag.
const DEFAULT_CACHE* = true

## Default cache expiry in days.
const DEFAULT_CACHE_EXPIRY* = 30

## Default maximum number of cached entries.
const DEFAULT_CACHE_MAX_ENTRIES* = 1000

## Default maximum number of log entries retained.
const DEFAULT_LOG_MAX_ENTRIES* = 1000

## Default vivid mode flag.
const DEFAULT_VIVID* = true

## Default external-display flag.
const DEFAULT_EXTERNAL_DISPLAY* = true

## Default maximum number of agent loop rounds.
const DEFAULT_MAX_ROUNDS* = 3

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Holds every runtime configuration option except the API key,
## which is stored separately for security reasons.  Integer
## options that support the "false" (disabled) state use 0 to
## represent the disabled condition.
type
  Config* = object
    url*: string                     ## API endpoint URL.
    model*: string                   ## LLM model identifier.
    manualConfirm*: bool             ## Prompt before executing.
    doubleCheck*: bool               ## Second model review.
    instance*: bool                  ## Single-call mode.
    timeout*: int                    ## Per-request timeout (s).
    maxToken*: int                   ## Max tokens per request.
    commandPattern*: Option[string]  ## Forbidden-cmd regex.
    systemPrompt*: Option[string]    ## Custom system prompt.
    shell*: string                   ## Shell executable.
    log*: bool                       ## Log requests.
    hideProcess*: bool               ## Hide intermediate output.
    cache*: bool                     ## Enable response cache.
    cacheExpiry*: int                ## Cache expiry in days.
    cacheMaxEntries*: int            ## Max cached entries.
    logMaxEntries*: int              ## Max log entries.
    vivid*: bool                     ## Vivid output mode.
    externalDisplay*: bool           ## Use bat/mdcat.
    maxRounds*: int                  ## Max agent loop rounds.

# ---------------------------------------------------------------------------
# Platform-specific DPAPI bindings (Windows only)
# ---------------------------------------------------------------------------

when defined(windows):
  type
    ## Mirrors the Windows DATA_BLOB structure.
    DataBlob = object
      cbData: uint32  ## Size of the data buffer in bytes.
      pbData: pointer ## Pointer to the data buffer.

  ## Encrypts plaintext using DPAPI.
  proc cryptProtectData(
    pDataIn: ptr DataBlob,
    szDataDescr: pointer,
    pOptionalEntropy: pointer,
    pvReserved: pointer,
    pPromptStruct: pointer,
    dwFlags: uint32,
    pDataOut: ptr DataBlob
  ): int32 {.importc: "CryptProtectData",
    stdcall, dynlib: "crypt32.dll".}

  ## Decrypts ciphertext previously encrypted with DPAPI.
  proc cryptUnprotectData(
    pDataIn: ptr DataBlob,
    ppszDataDescr: pointer,
    pOptionalEntropy: pointer,
    pvReserved: pointer,
    pPromptStruct: pointer,
    dwFlags: uint32,
    pDataOut: ptr DataBlob
  ): int32 {.importc: "CryptUnprotectData",
    stdcall, dynlib: "crypt32.dll".}

  ## Frees memory allocated by the operating system.
  proc localFree(
    hMem: pointer
  ): pointer {.importc: "LocalFree",
    stdcall, dynlib: "kernel32.dll".}

# ---------------------------------------------------------------------------
# Private helpers — DPAPI (Windows only)
# ---------------------------------------------------------------------------

when defined(windows):
  ## Encrypts plaintext with DPAPI, returns base64.
  ##
  ## :param data: The plaintext to encrypt.
  ## :returns: Base64-encoded ciphertext.
  ## :raises: GetError: If the system call fails.
  proc implEncryptDpapi(data: string): string =
    var inputBlob = DataBlob(
      cbData: data.len.uint32,
      pbData: if data.len > 0:
        cast[pointer](unsafeAddr data[0]) else: nil
    )
    var outputBlob: DataBlob
    let ret = cryptProtectData(
      addr inputBlob, nil, nil, nil, nil, 0'u32,
      addr outputBlob)
    if ret == 0:
      raise newException(GetError,
        "DPAPI encryption failed")
    var buf = newString(outputBlob.cbData.int)
    if outputBlob.cbData > 0'u32:
      copyMem(addr buf[0], outputBlob.pbData,
        outputBlob.cbData.int)
    discard localFree(outputBlob.pbData)
    result = encode(buf)

  ## Decrypts base64-encoded DPAPI ciphertext.
  ##
  ## :param encoded: Base64-encoded ciphertext.
  ## :returns: The original plaintext string.
  ## :raises: GetError: If decryption fails.
  proc implDecryptDpapi(encoded: string): string =
    let encrypted = decode(encoded)
    var inputBlob = DataBlob(
      cbData: encrypted.len.uint32,
      pbData: if encrypted.len > 0:
        cast[pointer](unsafeAddr encrypted[0])
        else: nil
    )
    var outputBlob: DataBlob
    let ret = cryptUnprotectData(
      addr inputBlob, nil, nil, nil, nil, 0'u32,
      addr outputBlob)
    if ret == 0:
      raise newException(GetError,
        "DPAPI decryption failed")
    result = newString(outputBlob.cbData.int)
    if outputBlob.cbData > 0'u32:
      copyMem(addr result[0], outputBlob.pbData,
        outputBlob.cbData.int)
    discard localFree(outputBlob.pbData)

# ---------------------------------------------------------------------------
# Private helpers — pure functions
# ---------------------------------------------------------------------------

## Returns the platform default shell name.
##
## :returns: "powershell" on Windows, "bash" elsewhere.
func implDefaultShell(): string =
  result = defaultShell()

## Parses a boolean string.  Empty input returns the default.
##
## :param value: Raw string from the CLI.
## :param optName: Option name, used in error messages.
## :param default: Fallback when value is empty.
## :returns: The parsed boolean.
## :raises: GetError: If value is invalid.
func implParseBool(
  value: string,
  optName: string,
  default: bool
): bool =
  if value.len == 0:
    return default
  case toLowerAscii(value)
  of "true":  result = true
  of "false": result = false
  else:
    raise newException(GetError,
      fmt"invalid value '{value}' for " &
      fmt"'{optName}': expected 'true' or 'false'")

## Parses a positive integer or "false" (mapping to 0).
## Empty input returns the default.
##
## :param value: Raw string from the CLI.
## :param optName: Option name, used in error messages.
## :param default: Fallback when value is empty.
## :returns: The parsed integer, or 0 for "false".
## :raises: GetError: If value is not valid.
func implParseIntOrDisable(
  value: string,
  optName: string,
  default: int
): int =
  if value.len == 0:
    return default
  if toLowerAscii(value) == "false":
    return 0
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(GetError,
      fmt"invalid value '{value}' for " &
      fmt"'{optName}': expected positive " &
      "integer or 'false'")
  if result < 0:
    raise newException(GetError,
      fmt"invalid value '{value}' for " &
      fmt"'{optName}': expected positive " &
      "integer or 'false'")

# ---------------------------------------------------------------------------
# Private helpers — JSON serialisation
# ---------------------------------------------------------------------------

## Converts a Config object to a JSON node.
##
## :param cfg: The configuration to serialise.
## :returns: A JsonNode representing the configuration.
proc implConfigToJson(cfg: Config): JsonNode =
  result = %*{
    "url":             cfg.url,
    "model":           cfg.model,
    "manualConfirm":   cfg.manualConfirm,
    "doubleCheck":     cfg.doubleCheck,
    "instance":        cfg.instance,
    "timeout":         cfg.timeout,
    "maxToken":        cfg.maxToken,
    "shell":           cfg.shell,
    "log":             cfg.log,
    "hideProcess":     cfg.hideProcess,
    "cache":           cfg.cache,
    "cacheExpiry":     cfg.cacheExpiry,
    "cacheMaxEntries": cfg.cacheMaxEntries,
    "logMaxEntries":   cfg.logMaxEntries,
    "vivid":           cfg.vivid,
    "externalDisplay": cfg.externalDisplay,
    "maxRounds":       cfg.maxRounds
  }
  if cfg.commandPattern.isSome:
    result["commandPattern"] =
      %cfg.commandPattern.get
  if cfg.systemPrompt.isSome:
    result["systemPrompt"] =
      %cfg.systemPrompt.get

## Parses a JSON node into a Config.
##
## :param node: The JSON node to parse.
## :param defaults: Fallback values for absent fields.
## :returns: A populated Config instance.
proc implJsonToConfig(
  node: JsonNode,
  defaults: Config
): Config =
  result = Config(
    url: node{"url"}.getStr(""),
    model: node{"model"}.getStr(""),
    manualConfirm: node{"manualConfirm"}.getBool(
      defaults.manualConfirm),
    doubleCheck: node{"doubleCheck"}.getBool(
      defaults.doubleCheck),
    instance: node{"instance"}.getBool(
      defaults.instance),
    timeout: node{"timeout"}.getInt(
      defaults.timeout),
    maxToken: node{"maxToken"}.getInt(
      defaults.maxToken),
    shell: node{"shell"}.getStr(""),
    log: node{"log"}.getBool(defaults.log),
    hideProcess: node{"hideProcess"}.getBool(
      defaults.hideProcess),
    cache: node{"cache"}.getBool(defaults.cache),
    cacheExpiry: node{"cacheExpiry"}.getInt(
      defaults.cacheExpiry),
    cacheMaxEntries:
      node{"cacheMaxEntries"}.getInt(
        defaults.cacheMaxEntries),
    logMaxEntries: node{"logMaxEntries"}.getInt(
      defaults.logMaxEntries),
    vivid: node{"vivid"}.getBool(defaults.vivid),
    externalDisplay:
      node{"externalDisplay"}.getBool(
        defaults.externalDisplay),
    maxRounds: node{"maxRounds"}.getInt(
      defaults.maxRounds)
  )
  let cmdNode = node{"commandPattern"}
  if not cmdNode.isNil and
      cmdNode.kind == JString and
      cmdNode.getStr().len > 0:
    result.commandPattern = some(cmdNode.getStr())
  else:
    result.commandPattern = none(string)
  let sysNode = node{"systemPrompt"}
  if not sysNode.isNil and
      sysNode.kind == JString and
      sysNode.getStr().len > 0:
    result.systemPrompt = some(sysNode.getStr())
  else:
    result.systemPrompt = none(string)

# ---------------------------------------------------------------------------
# Public API — defaults
# ---------------------------------------------------------------------------

## Creates a Config populated entirely with default values.
##
## :returns: A Config with every field at its default.
##
## .. code-block:: nim
##   runnableExamples:
##     let cfg = defaultConfig()
##     assert cfg.timeout == 300
func defaultConfig*(): Config =
  result = Config(
    url:             DEFAULT_URL,
    model:           DEFAULT_MODEL,
    manualConfirm:   DEFAULT_MANUAL_CONFIRM,
    doubleCheck:     DEFAULT_DOUBLE_CHECK,
    instance:        DEFAULT_INSTANCE,
    timeout:         DEFAULT_TIMEOUT,
    maxToken:        DEFAULT_MAX_TOKEN,
    commandPattern:  none(string),
    systemPrompt:    none(string),
    shell:           implDefaultShell(),
    log:             DEFAULT_LOG,
    hideProcess:     DEFAULT_HIDE_PROCESS,
    cache:           DEFAULT_CACHE,
    cacheExpiry:     DEFAULT_CACHE_EXPIRY,
    cacheMaxEntries: DEFAULT_CACHE_MAX_ENTRIES,
    logMaxEntries:   DEFAULT_LOG_MAX_ENTRIES,
    vivid:           DEFAULT_VIVID,
    externalDisplay: DEFAULT_EXTERNAL_DISPLAY,
    maxRounds:       DEFAULT_MAX_ROUNDS
  )

# ---------------------------------------------------------------------------
# Public API — key storage
# ---------------------------------------------------------------------------

## Persists the API key using platform-appropriate secure
## storage.  Passing none deletes any stored key.
##
## :param key: The key value to store, or none to clear.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc saveKey*(key: Option[string]) =
  let path = getKeyFilePath()
  if key.isNone:
    if fileExists(path):
      removeFile(path)
    return
  let value = key.get
  when defined(windows):
    let encrypted = implEncryptDpapi(value)
    writeFile(path, encrypted)
  else:
    writeFile(path, value)
    setFilePermissions(path,
      {fpUserRead, fpUserWrite})

## Loads the API key from platform-specific secure storage.
##
## :returns: The stored key, or none if absent.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc loadKey*(): Option[string] =
  let path = getKeyFilePath()
  if not fileExists(path):
    return none(string)
  let content = readFile(path).strip()
  if content.len == 0:
    return none(string)
  when defined(windows):
    try:
      result = some(implDecryptDpapi(content))
    except GetError:
      stderr.writeLine(
        "warning: cannot decrypt key file," &
        " treating as unset")
      result = none(string)
  else:
    result = some(content)

# ---------------------------------------------------------------------------
# Public API — config persistence
# ---------------------------------------------------------------------------

## Loads the configuration from disk.  Returns defaults when the
## file does not exist or cannot be parsed.
##
## :returns: The current configuration.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc loadConfig*(): Config =
  let path = getConfigFilePath()
  if not fileExists(path):
    return defaultConfig()
  let defaults = defaultConfig()
  try:
    let content = readFile(path)
    let node = parseJson(content)
    result = implJsonToConfig(node, defaults)
  except JsonParsingError:
    stderr.writeLine(
      "warning: config file is corrupted," &
      " using defaults")
    result = defaults
  except IOError:
    stderr.writeLine(
      "warning: cannot read config file," &
      " using defaults")
    result = defaults

## Writes the configuration to disk as pretty-printed JSON.
##
## :param cfg: The configuration to persist.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc saveConfig*(cfg: Config) =
  let path = getConfigFilePath()
  let node = implConfigToJson(cfg)
  writeFile(path, pretty(node, 2) & "\n")

# ---------------------------------------------------------------------------
# Public API — display
# ---------------------------------------------------------------------------

## Prints every configuration option to stdout.  The API key is
## masked with asterisks.
##
## :param sk: The active output style.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc displayConfig*(sk: StyleKind = skSimp) =
  let cfg = loadConfig()
  let key = loadKey()
  let keyDisplay =
    if key.isSome: maskString(key.get) else: ""
  let cmdPat =
    if cfg.commandPattern.isSome:
      cfg.commandPattern.get
    else:
      "(default: built-in)"
  let sysPmt =
    if cfg.systemPrompt.isSome:
      cfg.systemPrompt.get else: ""
  styleKeyValue(sk, "key", keyDisplay)
  styleKeyValue(sk, "url", cfg.url)
  styleKeyValue(sk, "model", cfg.model)
  styleKeyValue(sk, "manual-confirm",
    $cfg.manualConfirm)
  styleKeyValue(sk, "double-check",
    $cfg.doubleCheck)
  styleKeyValue(sk, "instance", $cfg.instance)
  styleKeyValue(sk, "timeout",
    formatIntOrDisable(cfg.timeout))
  styleKeyValue(sk, "max-token",
    formatIntOrDisable(cfg.maxToken))
  styleKeyValue(sk, "max-rounds",
    formatIntOrDisable(cfg.maxRounds))
  styleKeyValue(sk, "command-pattern", cmdPat)
  styleKeyValue(sk, "system-prompt", sysPmt)
  styleKeyValue(sk, "shell", cfg.shell)
  styleKeyValue(sk, "log", $cfg.log)
  styleKeyValue(sk, "hide-process",
    $cfg.hideProcess)
  styleKeyValue(sk, "cache", $cfg.cache)
  styleKeyValue(sk, "cache-expiry",
    formatIntOrDisable(cfg.cacheExpiry))
  styleKeyValue(sk, "cache-max-entries",
    formatIntOrDisable(cfg.cacheMaxEntries))
  styleKeyValue(sk, "log-max-entries",
    formatIntOrDisable(cfg.logMaxEntries))
  styleKeyValue(sk, "vivid", $cfg.vivid)
  styleKeyValue(sk, "external-display",
    $cfg.externalDisplay)

# ---------------------------------------------------------------------------
# Public API — reset
# ---------------------------------------------------------------------------

## Resets all configuration to defaults and clears the stored
## key.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc resetConfig*() =
  saveConfig(defaultConfig())
  saveKey(none(string))

# ---------------------------------------------------------------------------
# Public API — set by name
# ---------------------------------------------------------------------------

## Sets a single configuration option by its CLI kebab-case
## name.
##
## :param name: The kebab-case option name.
## :param value: The new value, or empty to unset/reset.
## :raises: GetError: If the name is unknown or value invalid.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc setConfigOption*(name: string, value: string) =
  if name == "key":
    if value.len == 0:
      saveKey(none(string))
    else:
      saveKey(some(value))
    return

  var cfg = loadConfig()
  case name
  of "url":
    cfg.url = value
  of "model":
    cfg.model = value
  of "manual-confirm":
    cfg.manualConfirm = implParseBool(
      value, name, DEFAULT_MANUAL_CONFIRM)
  of "double-check":
    cfg.doubleCheck = implParseBool(
      value, name, DEFAULT_DOUBLE_CHECK)
  of "instance":
    cfg.instance = implParseBool(
      value, name, DEFAULT_INSTANCE)
  of "timeout":
    cfg.timeout = implParseIntOrDisable(
      value, name, DEFAULT_TIMEOUT)
  of "max-token":
    cfg.maxToken = implParseIntOrDisable(
      value, name, DEFAULT_MAX_TOKEN)
  of "command-pattern":
    if value.len > 0:
      cfg.commandPattern = some(value)
      let safetyWarn = checkPatternSafety(value)
      if safetyWarn.len > 0:
        stderr.writeLine(safetyWarn)
    else:
      cfg.commandPattern = none(string)
  of "system-prompt":
    if value.len > 0:
      cfg.systemPrompt = some(value)
    else:
      cfg.systemPrompt = none(string)
  of "shell":
    cfg.shell = value
  of "log":
    cfg.log = implParseBool(
      value, name, DEFAULT_LOG)
  of "hide-process":
    cfg.hideProcess = implParseBool(
      value, name, DEFAULT_HIDE_PROCESS)
  of "cache":
    cfg.cache = implParseBool(
      value, name, DEFAULT_CACHE)
  of "cache-expiry":
    cfg.cacheExpiry = implParseIntOrDisable(
      value, name, DEFAULT_CACHE_EXPIRY)
  of "cache-max-entries":
    cfg.cacheMaxEntries = implParseIntOrDisable(
      value, name, DEFAULT_CACHE_MAX_ENTRIES)
  of "log-max-entries":
    cfg.logMaxEntries = implParseIntOrDisable(
      value, name, DEFAULT_LOG_MAX_ENTRIES)
  of "vivid":
    cfg.vivid = implParseBool(
      value, name, DEFAULT_VIVID)
  of "external-display":
    cfg.externalDisplay = implParseBool(
      value, name, DEFAULT_EXTERNAL_DISPLAY)
  of "max-rounds":
    cfg.maxRounds = implParseIntOrDisable(
      value, name, DEFAULT_MAX_ROUNDS)
  else:
    raise newException(GetError,
      fmt"unknown option '{name}'")
  saveConfig(cfg)

# ---------------------------------------------------------------------------
# Public API — readiness check
# ---------------------------------------------------------------------------

## Checks whether key, url, and model are all configured.
##
## :param sk: The active output style.
## :returns: true when all three are present.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc checkReady*(sk: StyleKind = skSimp): bool =
  let cfg = loadConfig()
  let key = loadKey()
  var allOk = true
  if key.isNone:
    styleKeyValue(sk, "key", "not set")
    allOk = false
  if cfg.url.len == 0:
    styleKeyValue(sk, "url", "not set")
    allOk = false
  if cfg.model.len == 0:
    styleKeyValue(sk, "model", "not set")
    allOk = false
  if not allOk:
    styleError(sk, "not ready.")
  result = allOk