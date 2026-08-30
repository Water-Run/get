## Configuration management for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
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

import harness_types
import style
import utils

# ---------------------------------------------------------------------------
# Constants — default values
# ---------------------------------------------------------------------------

## Default LLM API endpoint URL.
const DEFAULT_URL* = "https://api.minimaxi.com/v1"

## Default LLM model identifier.
const DEFAULT_MODEL* = "minimax-m3"

## Default for manual-confirm.
const DEFAULT_MANUAL_CONFIRM* = false

## Default for double-check.
const DEFAULT_DOUBLE_CHECK* = false

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

## Default prefer-system-proxy flag.
const DEFAULT_SYSTEM_PROXY* = false

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

## Default maximum number of model turns in one harness run.
const DEFAULT_MAX_ROUNDS* = 3

## Current on-disk configuration schema version.
const DEFAULT_SCHEMA_VERSION* = 3

## Default unified harness strategy.
const DEFAULT_HARNESS* = "auto"

## Default provider tool-call protocol.
const DEFAULT_TOOL_PROTOCOL* = "auto"

## Default maximum tool calls per harness run.
const DEFAULT_MAX_TOOL_CALLS* = DEFAULT_TOOL_CALLS

## Default maximum concurrent tool calls.
const DEFAULT_MAX_PARALLEL* = DEFAULT_PARALLELISM

## Default command execution deadline in seconds.
const DEFAULT_COMMAND_TIMEOUT* = harness_types.DEFAULT_COMMAND_TIMEOUT

## Default maximum captured bytes for one command.
const DEFAULT_MAX_OUTPUT_BYTES* = harness_types.DEFAULT_MAX_OUTPUT_BYTES

## Maximum accepted model turns per run.
const MAX_HARNESS_ROUNDS = 32

## Maximum accepted tool calls per run.
const MAX_HARNESS_TOOL_CALLS = 256

## Maximum accepted concurrent tool calls.
const MAX_HARNESS_PARALLEL = 64

## Maximum accepted command deadline in seconds.
const MAX_COMMAND_TIMEOUT = 86_400

## Maximum accepted per-command capture cap in bytes.
const MAX_COMMAND_OUTPUT_BYTES = 100_000_000

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Holds every runtime configuration option except the API key,
## which is stored separately for security reasons.  Integer
## options that support the "false" (disabled) state use 0 to
## represent the disabled condition.
type
  Config* = object
    schemaVersion*: int              ## On-disk configuration schema version.
    url*: string                     ## API endpoint URL.
    model*: string                   ## LLM model identifier.
    manualConfirm*: bool             ## Prompt before executing.
    doubleCheck*: bool               ## Second model review.
    instance*: bool                  ## v2 alias for the direct harness.
    harness*: string                 ## Unified v3 harness strategy.
    toolProtocol*: string            ## Native, legacy, or automatic tools.
    timeout*: int                    ## Per-request timeout (s).
    maxToken*: int                   ## Max tokens per request.
    commandPattern*: Option[string]  ## Forbidden-cmd regex.
    systemPrompt*: Option[string]    ## Custom system prompt.
    shell*: string                   ## Shell executable.
    log*: bool                       ## Log requests.
    hideProcess*: bool               ## Hide intermediate output.
    systemProxy*: bool               ## Prefer system proxy settings.
    cache*: bool                     ## Enable response cache.
    cacheExpiry*: int                ## Cache expiry in days.
    cacheMaxEntries*: int            ## Max cached entries.
    logMaxEntries*: int              ## Max log entries.
    vivid*: bool                     ## Vivid output mode.
    maxRounds*: int                  ## Max model turns per harness run.
    maxToolCalls*: int               ## Max tool calls per harness run.
    maxParallel*: int                ## Max concurrent tool calls.
    commandTimeout*: int             ## Per-command deadline in seconds.
    maxOutputBytes*: int             ## Per-command capture limit.

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

## Accepts only supported shell basenames or absolute paths rooted in standard
## administrator-controlled executable directories. This prevents the shell
## setting itself from becoming a policy bypass.
func isSupportedShell*(shell: string): bool =
  var path = toLowerAscii(shell.strip()).replace('\\', '/')
  if path.len == 0:
    return false
  if path.contains('/'):
    if path.endsWith('/'):
      return false
    for segment in path.split('/'):
      if segment in [".", ".."]:
        return false
    let trustedPosix =
      path.startsWith("/bin/") or path.startsWith("/usr/bin/") or
      path.startsWith("/usr/local/bin/") or
      path.startsWith("/opt/homebrew/bin/")
    let trustedWindows = path.len > 3 and path[0] in {'a' .. 'z'} and
      path[1] == ':' and (
        path[2 .. ^1].startsWith("/windows/system32/") or
        path[2 .. ^1].startsWith("/program files/powershell/")
      )
    if not trustedPosix and not trustedWindows:
      return false
    path = path[path.rfind('/') + 1 .. ^1]
  if path.endsWith(".exe"):
    path.setLen(path.len - 4)
  result = path in KNOWN_SHELLS

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
  if isSupportedShell(shell): vsGood else: vsWarn

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

## Builds the display text, semantic state, and optional highlighted trailer
## for command-pattern. The default is the mandatory semantic policy alone;
## an explicitly cleared supplemental pattern has the same effective policy,
## while a custom organization policy is shown in emphatic red.
##
## :param pattern: The configured command-pattern option.
## :returns: A tuple of (display text, state, trailer).
func classifyCommandPattern*(
  pattern: Option[string]
): tuple[text: string, state: ValueState,
         trailer: string] =
  if pattern.isNone:
    result = (
      text: "(semantic policy only)",
      state: vsMuted,
      trailer: "(default)")
  elif pattern.get.len == 0:
    result = (
      text: "(semantic policy only)",
      state: vsMuted,
      trailer: "(supplemental regex cleared)")
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

## Validates and normalizes a harness configuration value.
##
## :param value: Raw harness name.
## :param fallback: Value used when the input is empty or invalid.
## :returns: Stable harness name.
func implHarnessOrDefault(value: string, fallback: string): string =
  if value.len == 0:
    return fallback
  try:
    result = harnessName(parseHarnessKind(value))
  except ValueError:
    result = fallback

## Validates and normalizes a tool-protocol configuration value.
##
## :param value: Raw protocol name.
## :param fallback: Value used when the input is empty or invalid.
## :returns: Stable protocol name.
func implProtocolOrDefault(value: string, fallback: string): string =
  if value.len == 0:
    return fallback
  try:
    result = toolProtocolName(parseToolProtocolKind(value))
  except ValueError:
    result = fallback

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
  if result <= 0:
    raise newException(GetError,
      fmt"invalid value '{value}' for " &
      fmt"'{optName}': expected positive " &
      "integer or 'false'")

## Parses a strictly positive integer and rejects disabled hard limits.
##
## :param value: Raw CLI value; empty resets to the default.
## :param optName: Option name for diagnostics.
## :param default: Positive reset value.
## :returns: Parsed positive integer.
## :raises: GetError: If the value is not a positive integer.
func implParsePositiveInt(
  value: string,
  optName: string,
  default: int,
  maximum: int
): int =
  if value.len == 0:
    return default
  try:
    result = parseInt(value)
  except ValueError:
    raise newException(GetError,
      fmt"invalid value '{value}' for '{optName}': " &
      "expected positive integer")
  if result <= 0:
    raise newException(GetError,
      fmt"invalid value '{value}' for '{optName}': " &
      "expected positive integer")
  if result > maximum:
    raise newException(GetError,
      fmt"invalid value '{value}' for '{optName}': " &
      fmt"maximum is {maximum}")

# ---------------------------------------------------------------------------
# Private helpers — JSON serialisation
# ---------------------------------------------------------------------------

## Converts a Config object to a JSON node.
##
## :param cfg: The configuration to serialise.
## :returns: A JsonNode representing the configuration.
proc implConfigToJson(cfg: Config): JsonNode =
  result = %*{
    "schemaVersion":   cfg.schemaVersion,
    "url":             cfg.url,
    "model":           cfg.model,
    "manualConfirm":   cfg.manualConfirm,
    "doubleCheck":     cfg.doubleCheck,
    "instance":        cfg.instance,
    "harness":         cfg.harness,
    "toolProtocol":    cfg.toolProtocol,
    "timeout":         cfg.timeout,
    "maxToken":        cfg.maxToken,
    "shell":           cfg.shell,
    "log":             cfg.log,
    "hideProcess":     cfg.hideProcess,
    "systemProxy":      cfg.systemProxy,
    "cache":           cfg.cache,
    "cacheExpiry":     cfg.cacheExpiry,
    "cacheMaxEntries": cfg.cacheMaxEntries,
    "logMaxEntries":   cfg.logMaxEntries,
    "vivid":           cfg.vivid,
    "maxRounds":       cfg.maxRounds,
    "maxToolCalls":    cfg.maxToolCalls,
    "maxParallel":     cfg.maxParallel,
    "commandTimeout":  cfg.commandTimeout,
    "maxOutputBytes":  cfg.maxOutputBytes
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
  let legacyInstance = node{"instance"}.getBool(
    defaults.instance)
  let migratedHarness =
    if not node{"harness"}.isNil:
      implHarnessOrDefault(
        node{"harness"}.getStr(""),
        defaults.harness
      )
    elif legacyInstance:
      "direct"
    else:
      defaults.harness
  let storedMaxRounds = node{"maxRounds"}.getInt(
    defaults.maxRounds)
  let storedMaxToolCalls = node{"maxToolCalls"}.getInt(
    defaults.maxToolCalls)
  let storedMaxParallel = node{"maxParallel"}.getInt(
    defaults.maxParallel)
  let storedCommandTimeout = node{"commandTimeout"}.getInt(
    defaults.commandTimeout)
  let storedMaxOutputBytes = node{"maxOutputBytes"}.getInt(
    defaults.maxOutputBytes)
  let rawShell = node{"shell"}.getStr(defaults.shell)
  let storedShell =
    if isSupportedShell(rawShell): rawShell
    else: defaults.shell
  result = Config(
    schemaVersion: defaults.schemaVersion,
    url: node{"url"}.getStr(defaults.url),
    model: node{"model"}.getStr(defaults.model),
    manualConfirm: node{"manualConfirm"}.getBool(
      defaults.manualConfirm),
    doubleCheck: node{"doubleCheck"}.getBool(
      defaults.doubleCheck),
    instance: migratedHarness == "direct",
    harness: migratedHarness,
    toolProtocol: implProtocolOrDefault(
      node{"toolProtocol"}.getStr(""),
      defaults.toolProtocol),
    timeout: node{"timeout"}.getInt(
      defaults.timeout),
    maxToken: node{"maxToken"}.getInt(
      defaults.maxToken),
    shell: storedShell,
    log: node{"log"}.getBool(defaults.log),
    hideProcess: node{"hideProcess"}.getBool(
      defaults.hideProcess),
    systemProxy: node{"systemProxy"}.getBool(
      defaults.systemProxy),
    cache: node{"cache"}.getBool(defaults.cache),
    cacheExpiry: node{"cacheExpiry"}.getInt(
      defaults.cacheExpiry),
    cacheMaxEntries:
      node{"cacheMaxEntries"}.getInt(
        defaults.cacheMaxEntries),
    logMaxEntries: node{"logMaxEntries"}.getInt(
      defaults.logMaxEntries),
    vivid: node{"vivid"}.getBool(defaults.vivid),
    maxRounds:
      if storedMaxRounds in 1 .. MAX_HARNESS_ROUNDS:
        storedMaxRounds
      else: defaults.maxRounds,
    maxToolCalls:
      if storedMaxToolCalls in 1 .. MAX_HARNESS_TOOL_CALLS:
        storedMaxToolCalls
      else: defaults.maxToolCalls,
    maxParallel:
      if storedMaxParallel in 1 .. MAX_HARNESS_PARALLEL:
        storedMaxParallel
      else: defaults.maxParallel,
    commandTimeout:
      if storedCommandTimeout in 1 .. MAX_COMMAND_TIMEOUT:
        storedCommandTimeout
      else: defaults.commandTimeout,
    maxOutputBytes:
      if storedMaxOutputBytes in 1 .. MAX_COMMAND_OUTPUT_BYTES:
        storedMaxOutputBytes
      else: defaults.maxOutputBytes
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
    schemaVersion:    DEFAULT_SCHEMA_VERSION,
    url:             DEFAULT_URL,
    model:           DEFAULT_MODEL,
    manualConfirm:   DEFAULT_MANUAL_CONFIRM,
    doubleCheck:     DEFAULT_DOUBLE_CHECK,
    instance:        DEFAULT_INSTANCE,
    harness:         DEFAULT_HARNESS,
    toolProtocol:    DEFAULT_TOOL_PROTOCOL,
    timeout:         DEFAULT_TIMEOUT,
    maxToken:        DEFAULT_MAX_TOKEN,
    commandPattern:  none(string),
    systemPrompt:    none(string),
    shell:           implDefaultShell(),
    log:             DEFAULT_LOG,
    hideProcess:     DEFAULT_HIDE_PROCESS,
    systemProxy:      DEFAULT_SYSTEM_PROXY,
    cache:           DEFAULT_CACHE,
    cacheExpiry:     DEFAULT_CACHE_EXPIRY,
    cacheMaxEntries: DEFAULT_CACHE_MAX_ENTRIES,
    logMaxEntries:   DEFAULT_LOG_MAX_ENTRIES,
    vivid:           DEFAULT_VIVID,
    maxRounds:       DEFAULT_MAX_ROUNDS,
    maxToolCalls:    DEFAULT_MAX_TOOL_CALLS,
    maxParallel:     DEFAULT_MAX_PARALLEL,
    commandTimeout:  DEFAULT_COMMAND_TIMEOUT,
    maxOutputBytes:  DEFAULT_MAX_OUTPUT_BYTES
  )

when defined(getTest):
  ## Parses configuration JSON without filesystem access in test builds.
  ##
  ## :param content: Raw JSON object text.
  ## :returns: Migrated and normalized Config value.
  ## :raises: JsonParsingError: If the input is not valid JSON.
  ##
  ## .. code-block:: nim
  ##   runnableExamples:
  ##     discard
  proc parseConfigForTest*(content: string): Config =
    result = implJsonToConfig(
      parseJson(content),
      defaultConfig()
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
## set. When ``command-pattern`` is ``none`` (the default), the display says
## that only the mandatory semantic policy is active. When it is explicitly
## set to an empty string, the display says that the supplemental regex was
## cleared while the same mandatory semantic policy remains active.
##
## In vivid mode each value is colourised according to its
## meaning via ``styleConfigValue``: the key placeholder is
## dimmed, booleans use a consistent green/grey pair, the
## semantic-policy-only default is dimmed with a highlighted
## ``(default)`` trailer while a custom pattern is
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
  styleConfigValue(sk, "harness", cfg.harness,
    vsGood)
  styleConfigValue(sk, "tool-protocol",
    cfg.toolProtocol, vsGood)
  styleConfigValue(sk, "timeout",
    formatIntOrDisable(cfg.timeout),
    classifyInt(cfg.timeout, 1, 3600))
  styleConfigValue(sk, "max-token",
    formatIntOrDisable(cfg.maxToken),
    classifyInt(cfg.maxToken, 1024, 1_000_000))
  styleConfigValue(sk, "max-rounds",
    formatIntOrDisable(cfg.maxRounds),
    classifyInt(cfg.maxRounds, 1, 10))
  styleConfigValue(sk, "max-tool-calls",
    formatIntOrDisable(cfg.maxToolCalls),
    classifyInt(cfg.maxToolCalls, 1, 64))
  styleConfigValue(sk, "max-parallel",
    formatIntOrDisable(cfg.maxParallel),
    classifyInt(cfg.maxParallel, 1, 16))
  styleConfigValue(sk, "command-timeout",
    formatIntOrDisable(cfg.commandTimeout),
    classifyInt(cfg.commandTimeout, 1, 3600))
  styleConfigValue(sk, "max-output-bytes",
    formatIntOrDisable(cfg.maxOutputBytes),
    classifyInt(cfg.maxOutputBytes, 1024, 100_000_000))
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
  styleConfigValue(sk, "system-proxy",
    $cfg.systemProxy, classifyBool(cfg.systemProxy))
  styleConfigValue(sk, "cache", $cfg.cache,
    classifyBool(cfg.cache))
  styleConfigValue(sk, "cache-expiry",
    formatIntOrDisable(cfg.cacheExpiry),
    classifyInt(cfg.cacheExpiry, 1, 365))
  styleConfigValue(sk, "cache-max-entries",
    formatIntOrDisable(cfg.cacheMaxEntries),
    classifyInt(cfg.cacheMaxEntries, 1, 100_000))
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
##   (supplemental regex cleared; triggered by
##   ``get set command-pattern ""``).
## - ``value`` empty, ``explicit = false`` -> set to
##   ``none(string)`` (restore the semantic-policy-only default; triggered by
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
    cfg.harness =
      if cfg.instance: "direct"
      else: DEFAULT_HARNESS
  of "harness":
    try:
      cfg.harness = harnessName(parseHarnessKind(
        if value.len > 0: value else: DEFAULT_HARNESS))
    except ValueError as error:
      raise newException(GetError,
        fmt"invalid value '{value}' for '{name}': {error.msg}")
    cfg.instance = cfg.harness == "direct"
  of "tool-protocol":
    try:
      cfg.toolProtocol = toolProtocolName(parseToolProtocolKind(
        if value.len > 0: value else: DEFAULT_TOOL_PROTOCOL))
    except ValueError as error:
      raise newException(GetError,
        fmt"invalid value '{value}' for '{name}': {error.msg}")
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
      # Disable only the supplemental user regex. The mandatory
      # read-only policy remains active in the query dispatcher.
      cfg.commandPattern = some("")
      styleWarning(toStyleKind(cfg.vivid),
        "warning: command-pattern cleared - " &
        "mandatory read-only policy remains active")
    else:
      # ``get set command-pattern`` (no value) - restore default.
      cfg.commandPattern = none(string)
  of "system-prompt":
    if value.len > 0:
      cfg.systemPrompt = some(value)
    else:
      cfg.systemPrompt = none(string)
  of "shell":
    let candidate = if value.len > 0: value else: implDefaultShell()
    if not isSupportedShell(candidate):
      raise newException(GetError,
        fmt"invalid value '{value}' for '{name}': unsupported shell")
    cfg.shell = candidate
  of "log":
    cfg.log = implParseBool(
      value, name, DEFAULT_LOG)
  of "hide-process":
    cfg.hideProcess = implParseBool(
      value, name, DEFAULT_HIDE_PROCESS)
  of "system-proxy":
    cfg.systemProxy = implParseBool(
      value, name, DEFAULT_SYSTEM_PROXY)
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
  of "max-rounds":
    cfg.maxRounds = implParsePositiveInt(
      value, name, DEFAULT_MAX_ROUNDS,
      MAX_HARNESS_ROUNDS)
  of "max-tool-calls":
    cfg.maxToolCalls = implParsePositiveInt(
      value, name, DEFAULT_MAX_TOOL_CALLS,
      MAX_HARNESS_TOOL_CALLS)
  of "max-parallel":
    cfg.maxParallel = implParsePositiveInt(
      value, name, DEFAULT_MAX_PARALLEL,
      MAX_HARNESS_PARALLEL)
  of "command-timeout":
    cfg.commandTimeout = implParsePositiveInt(
      value, name, DEFAULT_COMMAND_TIMEOUT,
      MAX_COMMAND_TIMEOUT)
  of "max-output-bytes":
    cfg.maxOutputBytes = implParsePositiveInt(
      value, name, DEFAULT_MAX_OUTPUT_BYTES,
      MAX_COMMAND_OUTPUT_BYTES)
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
