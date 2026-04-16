## Entry point and CLI dispatcher for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-16
## :File: get.nim
## :License: AGPL-3.0
##
## This module parses command-line arguments, routes execution to
## the appropriate subcommand handler, and manages top-level error
## reporting.  The query flow supports instance (single-call) and
## non-instance (multi-step) modes, optional double-check safety
## review, manual-confirm gating, forbidden-command-pattern
## validation, response caching with three-way LLM-driven
## cache-worthiness decisions (RESULT / COMMAND / NOCACHE),
## structured logging, model-strength warnings, progress display,
## external-display rendering (bat/mdcat), and bundled tool
## integration.
##
## The output mode is controlled by a single ``vivid`` boolean
## (default: true).  When vivid is enabled, output uses animated
## spinners, ANSI colours, and optional external rendering.  When
## disabled, plain unformatted text is produced.

{.experimental: "strictFuncs".}

import std/[os, strformat, strutils, options, times]

import cache
import config
import exec
import llm
import logger
import prompt
import style
import sysinfo
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Maximum characters of output included in the cache-worthiness
## check prompt to keep the token cost low.
const CACHE_CHECK_PREVIEW_LEN = 200

## Comprehensive help text displayed by `get help`.
const HELP_TEXT* = """get -- get anything from your computer

usage:
  get "query" [flags]          retrieve information via natural language
  get set <option> [value]     set configuration (omit value to reset)
  get config [flags]           view or reset configuration
  get cache [flags]            view or manage response cache
  get log [flags]              view or manage execution log
  get get [flags]              display application information
  get version                  display version
  get isok                     verify configuration readiness
  get help                     display this help message

query flags (per-invocation overrides):
  --no-cache                   bypass cache for this query
  --cache                      force cache for this query
  --manual-confirm             prompt before executing
  --no-manual-confirm          skip confirmation prompt
  --double-check               enable safety review
  --no-double-check            skip safety review
  --instance                   fast single-call mode
  --no-instance                multi-step mode
  --hide-process               suppress intermediate output
  --no-hide-process            show intermediate output
  --vivid                      enable vivid output mode
  --no-vivid                   plain text output mode
  --model <name>               override LLM model
  --timeout <seconds>          override request timeout

set options:
  key                LLM API key (string, default: empty)
  url                API endpoint URL (string,
                       default: https://api.poe.com/v1)
  model              LLM model name (string,
                       default: gpt-5.3-codex)
  manual-confirm     prompt before executing
                       (true/false, default: false)
  double-check       second model safety review
                       (true/false, default: true)
  instance           faster model replies
                       (true/false, default: false)
  timeout            request timeout in seconds
                       (integer or false, default: 300)
  max-token          max tokens per request
                       (integer or false, default: 20480)
  command-pattern    forbidden command regex
                       (string, default: built-in blocklist)
  system-prompt      custom system prompt
                       (string, default: empty)
  shell              shell executable
                       (string, default: bash / powershell)
  log                log requests and executions
                       (true/false, default: true)
  hide-process       hide intermediate output
                       (true/false, default: false)
  cache              enable response caching
                       (true/false, default: true)
  cache-expiry       cache lifetime in days
                       (integer or false, default: 30)
  cache-max-entries  max cached entries
                       (integer or false, default: 1000)
  log-max-entries    max log entries retained
                       (integer or false, default: 1000)
  vivid              vivid output mode with colours and animation
                       (true/false, default: true)
  external-display   use bat/mdcat for output rendering
                       (true/false, default: true)

  Integer options accept 'false' to disable the limit.

config flags:
  (none)             display all current settings
  --reset            reset all settings to defaults
  --<option>         display one setting (any set option name)

cache flags:
  (none)             display cache status
  --clean            remove all cached entries
  --unset "query"    remove entries matching query

log flags:
  (none)             display log status
  --clean            remove all log entries

get flags:
  (none)             display all application info
  --intro            display introduction
  --version          display version
  --license          display license identifier
  --github           display GitHub URL

examples:
  get "system version"
  get "disk usage" --no-cache
  get "list files" --model gpt-5.3-codex --vivid
  get set model gpt-5.3-codex
  get set key sk-your-api-key
  get set url https://api.openai.com/v1
  get set timeout false
  get set vivid false
  get config --model
  get cache --clean
  get log --clean"""

# ---------------------------------------------------------------------------
# Types — CLI override structure
# ---------------------------------------------------------------------------

## Holds per-invocation override values extracted from query flags.
type
  QueryOverrides = object
    noCache*: bool               ## Bypass cache.
    forceCache*: Option[bool]    ## Force cache on.
    manualConfirm*: Option[bool] ## Override manual-confirm.
    doubleCheck*: Option[bool]   ## Override double-check.
    instance*: Option[bool]      ## Override instance mode.
    hideProcess*: Option[bool]   ## Override hide-process.
    vivid*: Option[bool]         ## Override vivid mode.
    model*: Option[string]       ## Override model name.
    timeout*: Option[int]        ## Override timeout seconds.

# ---------------------------------------------------------------------------
# Private helpers — usage errors
# ---------------------------------------------------------------------------

## Raises a GetError whose message includes the standard help hint.
##
## :param msg: A concise description of the problem.
proc implUsageError(
  msg: string
) {.noreturn.} =
  raise newException(GetError,
    msg & "\n" & HELP_HINT)

# ---------------------------------------------------------------------------
# Private helpers — override parsing
# ---------------------------------------------------------------------------

## Parses query arguments into a query string and override flags.
##
## :param args: All CLI arguments (after subcommand routing).
## :returns: A tuple of (query string, QueryOverrides).
## :raises: GetError: If a flag that requires a value is missing.
func implParseQueryArgs(
  args: seq[string]
): tuple[query: string, overrides: QueryOverrides] =
  var queryParts: seq[string] = @[]
  var ov = QueryOverrides(
    noCache: false,
    forceCache: none(bool),
    manualConfirm: none(bool),
    doubleCheck: none(bool),
    instance: none(bool),
    hideProcess: none(bool),
    vivid: none(bool),
    model: none(string),
    timeout: none(int)
  )
  var i = 0
  while i < args.len:
    let a = args[i]
    case a
    of "--no-cache":
      ov.noCache = true
    of "--cache":
      ov.forceCache = some(true)
    of "--manual-confirm":
      ov.manualConfirm = some(true)
    of "--no-manual-confirm":
      ov.manualConfirm = some(false)
    of "--double-check":
      ov.doubleCheck = some(true)
    of "--no-double-check":
      ov.doubleCheck = some(false)
    of "--instance":
      ov.instance = some(true)
    of "--no-instance":
      ov.instance = some(false)
    of "--hide-process":
      ov.hideProcess = some(true)
    of "--no-hide-process":
      ov.hideProcess = some(false)
    of "--vivid":
      ov.vivid = some(true)
    of "--no-vivid":
      ov.vivid = some(false)
    of "--model":
      if i + 1 >= args.len:
        raise newException(GetError,
          "--model requires a value")
      i += 1
      ov.model = some(args[i])
    of "--timeout":
      if i + 1 >= args.len:
        raise newException(GetError,
          "--timeout requires a value")
      i += 1
      try:
        ov.timeout = some(parseInt(args[i]))
      except ValueError:
        raise newException(GetError,
          fmt"invalid timeout value: {args[i]}")
    else:
      queryParts.add(a)
    i += 1
  result = (
    query: queryParts.join(" "),
    overrides: ov
  )

## Applies per-invocation overrides to a loaded config.
##
## :param cfg: The base configuration (var, modified in place).
## :param ov: The override values from CLI flags.
proc implApplyOverrides(
  cfg: var Config,
  ov: QueryOverrides
) =
  if ov.forceCache.isSome:
    cfg.cache = ov.forceCache.get
  if ov.manualConfirm.isSome:
    cfg.manualConfirm = ov.manualConfirm.get
  if ov.doubleCheck.isSome:
    cfg.doubleCheck = ov.doubleCheck.get
  if ov.instance.isSome:
    cfg.instance = ov.instance.get
  if ov.hideProcess.isSome:
    cfg.hideProcess = ov.hideProcess.get
  if ov.vivid.isSome:
    cfg.vivid = ov.vivid.get
  if ov.model.isSome:
    cfg.model = ov.model.get
  if ov.timeout.isSome:
    cfg.timeout = ov.timeout.get

# ---------------------------------------------------------------------------
# Private helpers — style loading
# ---------------------------------------------------------------------------

## Loads the style and binDir from the config.
##
## :param cfg: The loaded configuration.
## :returns: A tuple of (StyleKind, binDir string).
proc implLoadStyle(
  cfg: Config
): tuple[sk: StyleKind, binDir: string] =
  result = (
    sk: toStyleKind(cfg.vivid),
    binDir: getBundledBinDir()
  )

# ---------------------------------------------------------------------------
# Private helpers — subcommand handlers
# ---------------------------------------------------------------------------

## Handles `get set <option> [value...]`.
##
## :param args: Arguments after "set".
proc implHandleSet(args: seq[string]) =
  if args.len == 0:
    implUsageError("missing option name for 'set'")
  let optName = args[0]
  let value =
    if args.len > 1: args[1 .. ^1].join(" ") else: ""
  setConfigOption(optName, value)

## Handles `get config`, `get config --reset`, and
## `get config --<option>`.
##
## :param args: Arguments after "config".
proc implHandleConfig(args: seq[string]) =
  let cfg = loadConfig()
  let (sk, _) = implLoadStyle(cfg)
  if args.len == 0:
    displayConfig(sk)
    return
  if args[0] == "--reset":
    resetConfig()
    styleSuccess(sk, "configuration reset.")
    return
  if args[0].startsWith("--"):
    let optName = args[0][2 .. ^1]
    case optName
    of "key":
      let key = loadKey()
      if key.isSome:
        styleKeyValue(sk, "key",
          "set (" & maskString(key.get) & ")")
      else:
        styleKeyValue(sk, "key", "not set")
    of "url":
      styleKeyValue(sk, "url", cfg.url)
    of "model":
      styleKeyValue(sk, "model", cfg.model)
    of "manual-confirm":
      styleKeyValue(sk, "manual-confirm",
        $cfg.manualConfirm)
    of "double-check":
      styleKeyValue(sk, "double-check",
        $cfg.doubleCheck)
    of "instance":
      styleKeyValue(sk, "instance",
        $cfg.instance)
    of "timeout":
      styleKeyValue(sk, "timeout",
        formatIntOrDisable(cfg.timeout))
    of "max-token":
      styleKeyValue(sk, "max-token",
        formatIntOrDisable(cfg.maxToken))
    of "command-pattern":
      let pat =
        if cfg.commandPattern.isSome:
          cfg.commandPattern.get
        else:
          "(default: built-in)"
      styleKeyValue(sk, "command-pattern", pat)
    of "system-prompt":
      let pmt =
        if cfg.systemPrompt.isSome:
          cfg.systemPrompt.get else: ""
      styleKeyValue(sk, "system-prompt", pmt)
    of "shell":
      styleKeyValue(sk, "shell", cfg.shell)
    of "log":
      styleKeyValue(sk, "log", $cfg.log)
    of "hide-process":
      styleKeyValue(sk, "hide-process",
        $cfg.hideProcess)
    of "cache":
      styleKeyValue(sk, "cache", $cfg.cache)
    of "cache-expiry":
      styleKeyValue(sk, "cache-expiry",
        formatIntOrDisable(cfg.cacheExpiry))
    of "cache-max-entries":
      styleKeyValue(sk, "cache-max-entries",
        formatIntOrDisable(cfg.cacheMaxEntries))
    of "log-max-entries":
      styleKeyValue(sk, "log-max-entries",
        formatIntOrDisable(cfg.logMaxEntries))
    of "vivid":
      styleKeyValue(sk, "vivid", $cfg.vivid)
    of "external-display":
      styleKeyValue(sk, "external-display",
        $cfg.externalDisplay)
    else:
      implUsageError(
        fmt"unknown config option '{optName}'")
    return
  implUsageError(
    fmt"unknown argument '{args[0]}' for 'config'")

## Handles `get cache`, `get cache --clean`, and
## `get cache --unset "query"`.
##
## :param args: Arguments after "cache".
proc implHandleCache(args: seq[string]) =
  let cfg = loadConfig()
  let (sk, _) = implLoadStyle(cfg)
  if args.len == 0:
    displayCacheInfo(
      cfg.cache, cfg.cacheExpiry,
      cfg.cacheMaxEntries, sk)
    return
  case args[0]
  of "--clean":
    let removed = cleanCache()
    styleSuccess(sk,
      fmt"cache cleared. ({removed} entries removed)")
  of "--unset":
    if args.len < 2:
      implUsageError(
        "missing query text for 'cache --unset'")
    let query = args[1 .. ^1].join(" ")
    let removed = unsetCache(query)
    if removed > 0:
      styleSuccess(sk,
        fmt"removed {removed} cache entries" &
        fmt" for ""{query}"".")
    else:
      styleInfo(sk,
        fmt"no cache entry found for ""{query}"".")
  else:
    implUsageError(
      fmt"unknown argument '{args[0]}' for 'cache'")

## Handles `get log` and `get log --clean`.
##
## :param args: Arguments after "log".
proc implHandleLog(args: seq[string]) =
  let cfg = loadConfig()
  let (sk, _) = implLoadStyle(cfg)
  if args.len == 0:
    displayLogInfo(cfg.log, cfg.logMaxEntries, sk)
    return
  case args[0]
  of "--clean":
    let removed = cleanLog()
    styleSuccess(sk,
      fmt"log cleared. ({removed} entries removed)")
  else:
    implUsageError(
      fmt"unknown argument '{args[0]}' for 'log'")

## Handles `get get` and its sub-flags.
##
## :param args: Arguments after "get".
proc implHandleGet(args: seq[string]) =
  let cfg = loadConfig()
  let (sk, _) = implLoadStyle(cfg)
  if args.len == 0:
    styleSeparator(sk, DIV_SECTION)
    styleKeyValue(sk, "name", APP_NAME)
    styleKeyValue(sk, "version", APP_VERSION)
    styleKeyValue(sk, "intro", APP_INTRO)
    styleKeyValue(sk, "license", APP_LICENSE)
    styleKeyValue(sk, "github", APP_GITHUB)
    styleSeparator(sk, DIV_FOOTER)
    return
  case args[0]
  of "--intro":
    styleValue(sk, APP_INTRO)
  of "--version":
    styleValue(sk, APP_VERSION)
  of "--license":
    styleValue(sk, APP_LICENSE)
  of "--github":
    styleValue(sk, APP_GITHUB)
  else:
    implUsageError(
      fmt"unknown option '{args[0]}' for 'get get'")

## Handles `get isok`.
proc implHandleIsOk() =
  let cfg = loadConfig()
  let (sk, _) = implLoadStyle(cfg)
  let cfgReady = checkReady(sk)
  if not cfgReady:
    quit(1)
  let key = loadKey()
  if key.isNone:
    raise newException(GetError,
      "API key is not configured")
  let req = LlmRequest(
    model: cfg.model,
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
    cfg.url,
    key.get,
    timeoutSec = cfg.timeout,
    hideProcess = cfg.hideProcess,
    sk = sk
  )
  let answer = resp.content.strip().toLowerAscii()
  if answer.len == 0:
    styleError(sk,
      "unexpected response: (empty)")
    quit(1)
  elif answer == "ok" or
      (answer.contains("ok") and answer.len < 10):
    styleSuccess(sk, "ok")
  else:
    styleError(sk,
      fmt"unexpected response: {resp.content}")
    quit(1)

# ---------------------------------------------------------------------------
# Private helpers — query flow
# ---------------------------------------------------------------------------

## Resolves the effective shell.
##
## :param cfg: The loaded configuration.
## :returns: A non-empty shell name.
func implEffectiveShell(cfg: Config): string =
  if cfg.shell.len > 0: cfg.shell
  else: defaultShell()

## Resolves the effective forbidden-command pattern.
##
## :param cfg: The loaded configuration.
## :param sk: The active output style (for warnings).
## :returns: The pattern string to use.
proc implEffectivePattern(
  cfg: Config,
  sk: StyleKind
): string =
  if cfg.commandPattern.isSome:
    let pat = cfg.commandPattern.get
    if pat.len == 0:
      styleWarning(sk,
        "warning: command-pattern is empty — " &
        "no forbidden command filtering is active")
      return ""
    return pat
  result = DEFAULT_COMMAND_PATTERN

## Sends an LLM request and returns the response.
##
## :param messages: Conversation messages to send.
## :param cfg: The loaded configuration.
## :param key: The API key.
## :param sk: The active output style.
## :returns: The LLM response.
proc implLlmCall(
  messages: seq[LlmMessage],
  cfg: Config,
  key: string,
  sk: StyleKind = skSimp
): LlmResponse =
  let req = LlmRequest(
    model: cfg.model,
    messages: messages,
    maxTokens: cfg.maxToken
  )
  result = sendLlmRequest(
    req,
    cfg.url,
    key,
    timeoutSec = cfg.timeout,
    hideProcess = cfg.hideProcess,
    sk = sk
  )

## Performs the double-check safety review on a command.
##
## :param command: The command to review.
## :param query: The original user query.
## :param info: System information snapshot.
## :param cfg: The loaded configuration.
## :param key: The API key.
## :param sk: The active output style.
## :returns: The approved (possibly revised) command.
proc implDoubleCheck(
  command: string,
  query: string,
  info: SysInfo,
  cfg: Config,
  key: string,
  sk: StyleKind
): string =
  if not cfg.hideProcess:
    styleProgress(sk, "double-checking command...")
  let msgs = buildDoubleCheckMessages(
    command, query, info)
  let resp = implLlmCall(msgs, cfg, key, sk)
  let stripped = resp.content.strip()
  if toUpperAscii(stripped) == "UNSAFE":
    styleError(sk,
      "error: command deemed unsafe by review")
    quit(1)
  let revised = extractCodeBlock(resp.content)
  if revised.isSome:
    result = revised.get
  else:
    result = command

## Asks the LLM whether a query result should be cached and how.
## Returns cdResult, cdCommand, or cdNoCache.  Defaults to
## cdResult on transient errors (fail-open).
##
## :param query: The original user query.
## :param command: The generated command.
## :param output: The full command output.
## :param cfg: The loaded configuration.
## :param key: The API key.
## :returns: The cache decision.
proc implCheckShouldCache(
  query: string,
  command: string,
  output: string,
  cfg: Config,
  key: string
): CacheDecision =
  try:
    let preview =
      if output.len > CACHE_CHECK_PREVIEW_LEN:
        output[0 ..< CACHE_CHECK_PREVIEW_LEN] & "..."
      else:
        output
    let msgs = buildCacheCheckMessages(
      query, command, preview)
    let req = LlmRequest(
      model: cfg.model,
      messages: msgs,
      maxTokens: CACHE_CHECK_MAX_TOKENS
    )
    let resp = sendLlmRequest(
      req,
      cfg.url,
      key,
      timeoutSec = (
        if cfg.timeout > 0: min(cfg.timeout, 30)
        else: 30),
      hideProcess = true
    )
    let answer = toUpperAscii(
      resp.content.strip())
    if answer.contains("NOCACHE"):
      result = cdNoCache
    elif answer.contains("COMMAND"):
      result = cdCommand
    else:
      result = cdResult
  except CatchableError:
    # Fail-open: cache result on error.
    result = cdResult

## Emits a model-strength warning when the configured model is
## not recognised as a known high-performance model.
##
## :param model: The configured model name.
## :param sk: The active output style.
proc implWarnIfWeakModel(
  model: string,
  sk: StyleKind
) =
  if model.len > 0 and
      not isKnownStrongModel(model):
    styleWarning(sk, MODEL_STRENGTH_WARNING)

## Handles a natural-language query.
##
## :param query: The user's natural-language query.
## :param ov: Per-invocation override flags.
proc implHandleQuery(
  query: string,
  ov: QueryOverrides
) =
  var cfg = loadConfig()
  implApplyOverrides(cfg, ov)

  let key = loadKey()
  if key.isNone:
    raise newException(GetError,
      "API key is not configured." &
      " Run: get set key <your-key>")
  if cfg.url.len == 0:
    raise newException(GetError,
      "API URL is not configured." &
      " Run: get set url <url>")
  if cfg.model.len == 0:
    raise newException(GetError,
      "model is not configured." &
      " Run: get set model <model>")

  let sk = toStyleKind(cfg.vivid)
  let binDir = getBundledBinDir()
  let extDisplay = cfg.externalDisplay

  # External display checks and warnings.
  styleExternalDisplayCheck(sk, extDisplay, binDir)

  # Model-strength advisory.
  implWarnIfWeakModel(cfg.model, sk)

  let shell = implEffectiveShell(cfg)
  let cwd = getCurrentDir()

  # Resolve effective forbidden pattern.
  let effectivePattern = implEffectivePattern(
    cfg, sk)

  # ---- Cache lookup ----
  let noCache = ov.noCache
  let useCache = cfg.cache and (not noCache)
  var cacheHash = ""
  if useCache:
    cacheHash = computeCacheHash(
      query, cwd, shell, cfg.model,
      cfg.instance, cfg.systemPrompt,
      cfg.commandPattern)
    let store = loadCache()
    let hit = lookupCache(
      store, cacheHash, cfg.cacheExpiry)
    if hit.isSome:
      case hit.get.cacheMode
      of cmResult:
        # Direct output reuse — no API call, no
        # execution.
        if not cfg.hideProcess:
          styleProgress(sk, "(cached result)")
        styleResult(sk, hit.get.output,
          binDir, extDisplay)
        return
      of cmCommand:
        # Re-execute the cached command for fresh
        # output.
        if not cfg.hideProcess:
          styleProgress(sk, "(cached command)")
          styleCommand(sk, "command",
            hit.get.command)
        let execRes = executeCommand(
          hit.get.command, shell, binDir)
        let output = execRes.output.strip()
        if output.len > 0:
          styleResult(sk, output, binDir,
            extDisplay, false)
        elif execRes.exitCode != 0:
          styleError(sk,
            fmt"command exited with code " &
            fmt"{execRes.exitCode}")
        if cfg.log:
          logExecution(query, hit.get.command,
            execRes.output, execRes.exitCode,
            cfg.logMaxEntries)
        if execRes.exitCode != 0:
          quit(execRes.exitCode)
        return

  # 1. Collect system information.
  if not cfg.hideProcess:
    styleProgress(sk, "collecting system info...")
  let info = collectSysInfo(shell)

  # 2. Build query prompt and call LLM.
  styleSeparator(sk, DIV_THIN)
  let patternOpt =
    if effectivePattern.len > 0:
      some(effectivePattern)
    else:
      none(string)
  let queryMsgs = buildQueryMessages(
    info, query, shell, cfg.instance,
    cfg.systemPrompt, patternOpt)
  let genResp = implLlmCall(
    queryMsgs, cfg, key.get, sk)

  # 3. Extract command and output-mode marker.
  let maybeCmd = extractCodeBlock(genResp.content)
  let outputMode = extractOutputMode(
    genResp.content)

  if maybeCmd.isNone:
    # Direct text answer (no command generated).
    let isMarkdown = outputMode == "INTERPRET"
    styleResult(sk, genResp.content, binDir,
      extDisplay, isMarkdown)
    if useCache:
      let decision = implCheckShouldCache(
        query, "", genResp.content, cfg, key.get)
      if decision == cdResult:
        var store = loadCache()
        let entry = CacheEntry(
          hash: cacheHash,
          query: query,
          command: "",
          output: genResp.content,
          cacheMode: cmResult,
          timestamp: getTime().toUnix()
        )
        addCacheEntry(store, entry,
          cfg.cacheMaxEntries, cfg.cacheExpiry)
        saveCache(store)
    if cfg.log:
      logExecution(query, "(none)",
        genResp.content, 0, cfg.logMaxEntries)
    return

  var command = maybeCmd.get
  if not cfg.hideProcess:
    styleCommand(sk, "command", command)

  # 4. Forbidden-command pattern check.
  if effectivePattern.len > 0:
    if not validateCommandPattern(
        command, effectivePattern):
      styleError(sk,
        "error: command matches forbidden " &
        "pattern — rejected")
      if cfg.log:
        logExecution(query, command,
          "rejected by forbidden pattern", 1,
          cfg.logMaxEntries)
      quit(1)

  # 5. Double-check (optional, default: enabled).
  if cfg.doubleCheck:
    let reviewedCommand = implDoubleCheck(
      command, query, info, cfg, key.get, sk)
    let commandChanged = reviewedCommand != command
    command = reviewedCommand
    if not cfg.hideProcess and commandChanged:
      styleCommand(sk,
        "approved command", command)

  # 6. Manual confirmation (optional).
  if cfg.manualConfirm:
    let showCommandInPrompt = cfg.hideProcess
    if not confirmExecution(
        command, sk, showCommandInPrompt):
      styleProgress(sk, "aborted.")
      quit(0)

  # 7. Execute the command with bundled bin dir.
  if not cfg.hideProcess:
    styleSeparator(sk, DIV_WARN)
    styleProgress(sk, "executing...")
  let execRes = executeCommand(
    command, shell, info.binDir)

  # 8. Output handling (instance / DIRECT /
  #    INTERPRET).
  styleSeparator(sk, DIV_SECTION)
  var finalOutput = ""
  if cfg.instance or outputMode == "DIRECT":
    finalOutput = execRes.output.strip()
    if finalOutput.len > 0:
      styleResult(sk, finalOutput, info.binDir,
        extDisplay, false)
    elif execRes.exitCode != 0:
      finalOutput =
        fmt"command exited with code " &
        fmt"{execRes.exitCode}"
      styleError(sk, finalOutput)
  else:
    if execRes.exitCode != 0 and
        execRes.output.strip().len == 0:
      finalOutput =
        fmt"command exited with code " &
        fmt"{execRes.exitCode}"
      styleError(sk, finalOutput)
    else:
      let interpretMsgs = buildInterpretMessages(
        query, command, execRes.output)
      let interpretResp = implLlmCall(
        interpretMsgs, cfg, key.get, sk)
      finalOutput = interpretResp.content
      styleResult(sk, finalOutput, info.binDir,
        extDisplay, true)

  # 9. Cache decision (three-way: RESULT / COMMAND
  #    / NOCACHE).
  if useCache and
      (finalOutput.len > 0 or command.len > 0):
    let decision = implCheckShouldCache(
      query, command, finalOutput, cfg, key.get)
    case decision
    of cdResult:
      var store = loadCache()
      let entry = CacheEntry(
        hash: cacheHash,
        query: query,
        command: command,
        output: finalOutput,
        cacheMode: cmResult,
        timestamp: getTime().toUnix()
      )
      addCacheEntry(store, entry,
        cfg.cacheMaxEntries, cfg.cacheExpiry)
      saveCache(store)
    of cdCommand:
      var store = loadCache()
      let entry = CacheEntry(
        hash: cacheHash,
        query: query,
        command: command,
        output: "",
        cacheMode: cmCommand,
        timestamp: getTime().toUnix()
      )
      addCacheEntry(store, entry,
        cfg.cacheMaxEntries, cfg.cacheExpiry)
      saveCache(store)
    of cdNoCache:
      if not cfg.hideProcess:
        styleProgress(sk,
          "(result not cached)")

  # 10. Log.
  if cfg.log:
    logExecution(query, command,
      execRes.output, execRes.exitCode,
      cfg.logMaxEntries)

  # 11. Propagate non-zero exit code.
  if execRes.exitCode != 0:
    quit(execRes.exitCode)

# ---------------------------------------------------------------------------
# Private helpers — top-level dispatcher
# ---------------------------------------------------------------------------

## Top-level CLI dispatcher.
proc implMain() =
  initAnsi()

  let envWarning = checkEnvironment()
  if envWarning.len > 0:
    stderr.writeLine(envWarning)

  let args = commandLineParams()
  if args.len == 0:
    implUsageError(
      "no command or query provided")
  case args[0]
  of "set":
    implHandleSet(args[1 .. ^1])
  of "config":
    implHandleConfig(args[1 .. ^1])
  of "cache":
    implHandleCache(args[1 .. ^1])
  of "log":
    implHandleLog(args[1 .. ^1])
  of "get":
    implHandleGet(args[1 .. ^1])
  of "version":
    let cfg = loadConfig()
    let sk = toStyleKind(cfg.vivid)
    styleValue(sk, APP_VERSION)
  of "isok":
    implHandleIsOk()
  of "help", "--help", "-h":
    let cfg = loadConfig()
    let (sk, binDir) = implLoadStyle(cfg)
    styleHelp(sk, HELP_TEXT, binDir,
      cfg.externalDisplay)
  else:
    let (query, ov) = implParseQueryArgs(args)
    if query.len == 0:
      implUsageError("no query provided")
    implHandleQuery(query, ov)

# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------

## Ctrl+C handler that exits gracefully.
proc implCtrlCHandler() {.noconv.} =
  stderr.write("\ninterrupted.\n")
  quit(130)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

when isMainModule:
  setControlCHook(implCtrlCHandler)
  try:
    implMain()
  except GetError as e:
    stderr.writeLine(fmt"error: {e.msg}")
    quit(1)
  except CatchableError as e:
    stderr.writeLine(fmt"error: {e.msg}")
    quit(1)