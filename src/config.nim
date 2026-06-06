## Configuration management for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-06-06
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
const DEFAULT_URL* = "https://api.xiaomimimo.com/v1"

## Default LLM model identifier.
const DEFAULT_MODEL* = "mimo-v2.5-pro"

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

## Default number of prior executions required before running
## cache-decision classification.
const DEFAULT_CACHE_TRIGGER_THRESHOLD* = 1

## Default maximum number of log entries retained.
const DEFAULT_LOG_MAX_ENTRIES* = 1000

## Default vivid mode flag.
const DEFAULT_VIVID* = true

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
    cacheTriggerThreshold*: int      ## Prior-run threshold before decision.
    logMaxEntries*: int              ## Max log entries.
    vivid*: bool                     ## Vivid output mode.
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

## Shell names recognised as well-supported by the prompt
## builder; anything outside this set is flagged in vivid mode.
const KNOWN_SHELLS = [
  "bash", "zsh", "fish", "sh",
  "powershell", "pwsh", "cmd"]

# ---------------------------------------------------------------------------
# Private helpers — semantic value classification (vivid mode)
# ---------------------------------------------------------------------------

## Classifies a boolean value for vivid colouring: true is
## treated as the positive (green) state and false as the muted
## (grey) state, applied uniformly to every boolean option.
##
## :param value: The boolean option value.
## :returns: vsGood for true, vsBad for false.
func classifyBool*(value: bool): ValueState =
  if value: vsGood else: vsBad

## Classifies an integer option against a recommended inclusive
## range.  A disabled value (0 or negative) is muted; a value
## inside the range is good; anything outside is flagged.
##
## :param value: The integer option value.
## :param lo: Inclusive lower bound of the recommended range.
## :param hi: Inclusive upper bound of the recommended range.
## :returns: The semantic state for the value.
func classifyInt*(value: int, lo: int, hi: int): ValueState =
  if value <= 0:
    return vsMuted
  if value >= lo and value <= hi:
    return vsGood
  result = vsWarn

## Classifies a shell name: recognised shells are good, others
## are flagged so the user notices an unsupported configuration.
##
## :param shell: The configured shell name.
## :returns: vsGood when recognised, vsWarn otherwise.
func classifyShell*(shell: string): ValueState =
  let lower = toLowerAscii(shell)
  for known in KNOWN_SHELLS:
    if lower == known or lower.contains(known):
      return vsGood
  result = vsWarn

## Classifies a model name using the strong-model heuristic so
## that recognised high-performance models appear green and
## unknown / weak models appear amber.
##
## :param model: The configured model name.
## :returns: vsGood when strong, vsWarn otherwise.
func classifyModel*(model: string): ValueState =
  if isKnownStrongModel(model): vsGood else: vsWarn

## Classifies a URL value: a non-empty value is neutral, an
## empty value is flagged as it prevents requests.
##
## :param url: The configured endpoint URL.
## :returns: vsNeutral when set, vsWarn when empty.
func classifyUrl*(url: string): ValueState =
  if url.len > 0: vsNeutral else: vsWarn

## Builds the display text, semantic state, and optional
## highlighted trailer for the command-pattern value.  The
## default built-in pattern is dimmed with a highlighted
## ``(default: built-in)`` trailer; a disabled pattern is
## flagged amber; a custom pattern is shown in emphatic red.
##
## :param pattern: The configured command-pattern option.
## :returns: A tuple of (display text, state, trailer).
func classifyCommandPattern*(
  pattern: Option[string]
): tuple[text: string, state: ValueState,
         trailer: string] =
  if pattern.isNone:
    result = (
      text: DEFAULT_COMMAND_PATTERN,
      state: vsMuted,
      trailer: "(default: built-in)")
  elif pattern.get.len == 0:
    result = (
      text: "(disabled)",
      state: vsWarn,
      trailer: "")
  else:
    result = (
      text: pattern.get,
      state: vsDanger,
      trailer: "(custom)")

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
    "cacheTriggerThreshold": cfg.cacheTriggerThreshold,
    "logMaxEntries":   cfg.logMaxEntries,
    "vivid":           cfg.vivid,
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
    cacheTriggerThreshold:
      node{"cacheTriggerThreshold"}.getInt(
        defaults.cacheTriggerThreshold),
    logMaxEntries: node{"logMaxEntries"}.getInt(
      defaults.logMaxEntries),
    vivid: node{"vivid"}.getBool(defaults.vivid),
    maxRounds: node{"maxRounds"}.getInt(
      defaults.maxRounds)
  )
  let cmdNode = node{"commandPattern"}
  if not cmdNode.isNil and
      cmdNode.kind == JString:
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
    cacheTriggerThreshold:
      DEFAULT_CACHE_TRIGGER_THRESHOLD,
    logMaxEntries:   DEFAULT_LOG_MAX_ENTRIES,
    vivid:           DEFAULT_VIVID,
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
      styleWarning(toStyleKind(DEFAULT_VIVID),
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
    styleWarning(toStyleKind(defaults.vivid),
      "warning: config file is corrupted," &
      " using defaults")
    result = defaults
  except IOError:
    styleWarning(toStyleKind(defaults.vivid),
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
## stored with platform-specific encryption and cannot be
## retrieved; the display therefore only shows whether a key is
## set.  When ``command-pattern`` is ``none`` (the default), the
## full built-in regex is printed followed by "(default: built-in)"
## so the user can see exactly what is active.  When it is set to
## an empty string (disabled), "(disabled)" is shown.
##
## In vivid mode each value is colourised according to its
## meaning via ``styleConfigValue``: the key placeholder is
## dimmed, booleans use a consistent green/grey pair, the
## default command-pattern regex is dimmed with a highlighted
## ``(default: built-in)`` trailer while a custom pattern is
## shown in emphatic red, and recognised values (known shells,
## strong models, in-range integers) are green with
## questionable ones in amber.
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
    if key.isSome:
      "set (encrypted storage, value cannot be retrieved)"
    else:
      "not set"
  styleConfigValue(sk, "key", keyDisplay,
    (if key.isSome: vsMuted else: vsWarn))
  styleConfigValue(sk, "url", cfg.url,
    classifyUrl(cfg.url))
  styleConfigValue(sk, "model", cfg.model,
    classifyModel(cfg.model))
  styleConfigValue(sk, "manual-confirm",
    $cfg.manualConfirm, classifyBool(cfg.manualConfirm))
  styleConfigValue(sk, "double-check",
    $cfg.doubleCheck, classifyBool(cfg.doubleCheck))
  styleConfigValue(sk, "instance", $cfg.instance,
    classifyBool(cfg.instance))
  styleConfigValue(sk, "timeout",
    formatIntOrDisable(cfg.timeout),
    classifyInt(cfg.timeout, 1, 3600))
  styleConfigValue(sk, "max-token",
    formatIntOrDisable(cfg.maxToken),
    classifyInt(cfg.maxToken, 1024, 1_000_000))
  styleConfigValue(sk, "max-rounds",
    formatIntOrDisable(cfg.maxRounds),
    classifyInt(cfg.maxRounds, 1, 10))
  let (cmdPat, cmdState, cmdTrailer) =
    classifyCommandPattern(cfg.commandPattern)
  styleConfigValue(sk, "command-pattern", cmdPat,
    cmdState, cmdTrailer)
  let sysPmt =
    if cfg.systemPrompt.isSome:
      cfg.systemPrompt.get else: ""
  styleConfigValue(sk, "system-prompt", sysPmt,
    vsNeutral)
  styleConfigValue(sk, "shell", cfg.shell,
    classifyShell(cfg.shell))
  styleConfigValue(sk, "log", $cfg.log,
    classifyBool(cfg.log))
  styleConfigValue(sk, "hide-process",
    $cfg.hideProcess, classifyBool(cfg.hideProcess))
  styleConfigValue(sk, "cache", $cfg.cache,
    classifyBool(cfg.cache))
  styleConfigValue(sk, "cache-expiry",
    formatIntOrDisable(cfg.cacheExpiry),
    classifyInt(cfg.cacheExpiry, 1, 365))
  styleConfigValue(sk, "cache-max-entries",
    formatIntOrDisable(cfg.cacheMaxEntries),
    classifyInt(cfg.cacheMaxEntries, 1, 100_000))
  styleConfigValue(sk, "cache-trigger-threshold",
    formatIntOrDisable(cfg.cacheTriggerThreshold),
    classifyInt(cfg.cacheTriggerThreshold, 0, 100))
  styleConfigValue(sk, "log-max-entries",
    formatIntOrDisable(cfg.logMaxEntries),
    classifyInt(cfg.logMaxEntries, 1, 100_000))
  styleConfigValue(sk, "vivid", $cfg.vivid,
    classifyBool(cfg.vivid))

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
## For ``command-pattern`` specifically, behaviour depends on
## both ``value`` and ``explicit``:
##
## - ``value`` non-empty -> set to that value (custom pattern).
## - ``value`` empty, ``explicit = true`` -> set to ``some("")``
##   (filtering disabled; triggered by
##   ``get set command-pattern ""``).
## - ``value`` empty, ``explicit = false`` -> set to
##   ``none(string)`` (restore built-in default; triggered by
##   ``get set command-pattern``).
##
## :param name: The kebab-case option name.
## :param value: The new value, or empty to unset/reset.
## :param explicit: When true, an empty value is treated as an
##                  explicit clear rather than a reset signal.
## :raises: GetError: If the name is unknown or value invalid.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc setConfigOption*(
  name: string,
  value: string,
  explicit: bool = false
) =
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
        styleWarning(toStyleKind(cfg.vivid),
          safetyWarn)
    elif explicit:
      # ``get set command-pattern ""`` - disable filtering.
      cfg.commandPattern = some("")
      styleWarning(toStyleKind(cfg.vivid),
        "warning: command-pattern cleared - " &
        "no forbidden command filtering is active")
    else:
      # ``get set command-pattern`` (no value) - restore default.
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
  of "cache-trigger-threshold":
    cfg.cacheTriggerThreshold =
      implParseIntOrDisable(value, name,
        DEFAULT_CACHE_TRIGGER_THRESHOLD)
  of "log-max-entries":
    cfg.logMaxEntries = implParseIntOrDisable(
      value, name, DEFAULT_LOG_MAX_ENTRIES)
  of "vivid":
    cfg.vivid = implParseBool(
      value, name, DEFAULT_VIVID)
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
