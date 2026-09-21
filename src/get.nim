## Entry point and CLI dispatcher for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: get.nim
## :License: AGPL-3.0
##
## This module parses command-line arguments, routes execution to
## the appropriate subcommand handler, and manages top-level error
## reporting. The v3 query path uses one typed model/action/tool/observation
## state machine with auto, direct, loop, and parallel strategy policies.
## Provider-native tool calls are preferred, structured JSON is the fallback,
## and the old Markdown markers are isolated in a compatibility decoder.
## Every fresh or cached command passes through the same safety gate and a
## bounded executor before it can run.

{.experimental: "strictFuncs".}

import std/[os, strformat, strutils, options]

import cache
import config
import native_query_worker
import compute_sandbox
import exec
import harness_types
import llm
import logger
import prompt
import query_service
import style
import sysinfo
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Comprehensive help text displayed by `get help`.
const HELP_TEXT* = """get -- get anything from your computer

usage:
  get "query" [flags]          retrieve information via natural language
  get set <option> [value]     set configuration (omit value to reset)
  get config [flags]           view or reset configuration
  get cache [flags]            view or manage response cache
  get log [flags]              view or manage execution log
  get get [flags]              display application information
  get author                   display application author
  get version, --version, -V   display version
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
  --no-instance                compatibility alias for loop
  --harness <kind>             auto, direct, loop, or parallel
  --protocol <kind>            auto, native, or json
  --hide-process               suppress intermediate output
  --no-hide-process            show intermediate output
  --system-proxy               prefer OS system proxy settings
  --no-system-proxy            use terminal proxy environment only
  --vivid                      enable vivid output mode
  --no-vivid                   plain text output mode
  --markdown                   render model Markdown in an interactive terminal
  --no-markdown                display original Markdown source
  --model <name>               override LLM model
  --timeout <seconds>          override request timeout

set options:
  key                LLM API key (string, default: empty)
  url                API endpoint URL (string,
                       default: https://api.minimaxi.com/v1)
  model              LLM model name (string,
                       default: minimax-m3)
  manual-confirm     prompt before executing
                       (true/false, default: false)
  double-check       second model safety review
                       (true/false, default: false)
  instance           v2 compatibility alias for direct
                       (true/false, default: false)
  harness            orchestration strategy
                       (auto/direct/loop/parallel, default: auto)
  tool-protocol      model tool protocol
                       (auto/native/json, default: auto)
  timeout            request timeout in seconds
                       (integer or false, default: 300)
  max-token          max tokens per request
                       (integer or false, default: 20480)
  max-rounds         inspection-turn limit (+ one final answer)
                       (positive integer, default: 6)
  max-tool-calls     max tool calls per run
                       (integer, default: 16)
  max-parallel       max concurrent tool calls
                       (integer, default: 4)
  query-timeout      whole-query deadline in seconds (default: 120)
  command-timeout    command deadline in seconds
                       (positive integer, default: 30)
  max-output-bytes   captured bytes per command
                       (positive integer, default: 1048576)
  command-pattern    optional supplemental forbidden regex;
                       omit value to restore the semantic-only
                       default, use "" to disable an existing regex
                       (string, default: semantic policy only)
  system-prompt      custom system prompt
                       (string, default: empty)
  shell              shell executable
                       (string, default: bash / powershell)
  log                log requests and executions
                       (true/false, default: true)
  diagnostics        structured query events to stderr (default: false)
  hide-process       hide intermediate output
                       (true/false, default: false)
  system-proxy       prefer OS system proxy settings; when false,
                       use terminal proxy environment only
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
  markdown           render model answers in interactive terminals
                        (true/false, default: true; pipes keep source text)

  Request, cache, and log limits accept 'false'. Harness and command
  safety limits require a positive integer.

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
  --name             display application name
  --intro            display introduction
  --version          display version
  --author           display author
  --license          display license identifier
  --github           display GitHub URL

examples:
  get "system version"
  get "disk usage" --no-cache
  get "list files" --model minimax-m3 --vivid
  get set model minimax-m3
  get set key sk-your-api-key
  get set url https://api.minimaxi.com/v1
  get set timeout false
  get set max-rounds 5
  get set command-pattern
  get set command-pattern ""
  get config --model
  get config --command-pattern
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
    harness*: Option[string]     ## Override v3 harness strategy.
    toolProtocol*: Option[string] ## Override provider tool protocol.
    hideProcess*: Option[bool]   ## Override hide-process.
    systemProxy*: Option[bool]   ## Override system-proxy.
    vivid*: Option[bool]         ## Override vivid mode.
    markdown*: Option[bool]      ## Override model Markdown rendering.
    model*: Option[string]       ## Override model name.
    timeout*: Option[int]        ## Override timeout seconds.

# ---------------------------------------------------------------------------
# Private helpers — usage errors
# ---------------------------------------------------------------------------

when defined(posix):
  ## Exits with an unsaturated POSIX status.
  ##
  ## Nim's public ``quit(int)`` saturates values above int8 to 127 even though
  ## POSIX process statuses use eight unsigned bits.
  ##
  ## :param errorCode: Raw process exit status in the range 0 through 255.
  proc implPosixExit(errorCode: cint) {.
    importc: "_exit", header: "<unistd.h>", noreturn.}

## Exits while preserving a process-style status on every supported platform.
##
## :param errorCode: Command or signal-compatible exit status.
proc implQuitWithCode(errorCode: int) {.noreturn.} =
  when defined(posix):
    try:
      stdout.flushFile()
    except IOError:
      discard
    try:
      stderr.flushFile()
    except IOError:
      discard
    let normalized =
      if errorCode < 0: 1
      else: errorCode mod 256
    implPosixExit(normalized.cint)
  else:
    quit(errorCode)

## Raises a GetError whose message includes the standard help
## hint.
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
## :raises: GetError: If a required value is missing or invalid.
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
    harness: none(string),
    toolProtocol: none(string),
    hideProcess: none(bool),
    systemProxy: none(bool),
    vivid: none(bool),
    markdown: none(bool),
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
    of "--harness":
      if i + 1 >= args.len:
        raise newException(GetError,
          "--harness requires a value")
      i += 1
      try:
        ov.harness = some(harnessName(
          parseHarnessKind(args[i])))
      except ValueError as error:
        raise newException(GetError,
          fmt"invalid harness value: {error.msg}")
    of "--protocol":
      if i + 1 >= args.len:
        raise newException(GetError,
          "--protocol requires a value")
      i += 1
      try:
        ov.toolProtocol = some(toolProtocolName(
          parseToolProtocolKind(args[i])))
      except ValueError as error:
        raise newException(GetError,
          fmt"invalid protocol value: {error.msg}")
    of "--hide-process":
      ov.hideProcess = some(true)
    of "--no-hide-process":
      ov.hideProcess = some(false)
    of "--system-proxy":
      ov.systemProxy = some(true)
    of "--no-system-proxy":
      ov.systemProxy = some(false)
    of "--vivid":
      ov.vivid = some(true)
    of "--no-vivid":
      ov.vivid = some(false)
    of "--markdown":
      ov.markdown = some(true)
    of "--no-markdown":
      ov.markdown = some(false)
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
        let timeout = parseInt(args[i])
        if timeout <= 0:
          raise newException(ValueError,
            "timeout must be positive")
        ov.timeout = some(timeout)
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
    cfg.harness =
      if cfg.instance: "direct"
      else: "loop"
  if ov.harness.isSome:
    cfg.harness = ov.harness.get
    cfg.instance = cfg.harness == "direct"
  if ov.toolProtocol.isSome:
    cfg.toolProtocol = ov.toolProtocol.get
  if ov.hideProcess.isSome:
    cfg.hideProcess = ov.hideProcess.get
  if ov.systemProxy.isSome:
    cfg.systemProxy = ov.systemProxy.get
  if ov.vivid.isSome:
    cfg.vivid = ov.vivid.get
  if ov.markdown.isSome:
    cfg.markdown = ov.markdown.get
  if ov.model.isSome:
    cfg.model = ov.model.get
  if ov.timeout.isSome:
    cfg.timeout = ov.timeout.get

# ---------------------------------------------------------------------------
# Private helpers — style loading
# ---------------------------------------------------------------------------

## Resolves the active output style from the configuration.
##
## :param cfg: The loaded configuration.
## :returns: The StyleKind to use for output.
func implLoadStyle(cfg: Config): StyleKind =
  result = toStyleKind(cfg.vivid)

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
  let explicit = args.len > 1
  let value =
    if args.len > 1: args[1 .. ^1].join(" ") else: ""
  setConfigOption(optName, value, explicit)

## Handles `get config`, `get config --reset`, and
## `get config --<option>`.
##
## :param args: Arguments after "config".
proc implHandleConfig(args: seq[string]) =
  let cfg = loadConfig()
  let sk = implLoadStyle(cfg)
  if args.len == 0:
    displayConfig(sk)
    return
  if args[0] == "--reset":
    if args.len > 1:
      implUsageError(
        "'config --reset' takes no arguments")
    resetConfig()
    styleSuccess(sk, "configuration reset.")
    return
  if args[0].startsWith("--"):
    if args.len > 1:
      implUsageError(
        fmt"'config {args[0]}' takes no arguments")
    let optName = args[0][2 .. ^1]
    case optName
    of "key":
      let key = loadKey()
      if key.isSome:
        styleConfigValue(sk, "key",
          "set (encrypted storage, " &
          "value cannot be retrieved)", vsMuted)
      else:
        styleConfigValue(sk, "key", "not set",
          vsWarn)
    of "url":
      styleConfigValue(sk, "url", cfg.url,
        classifyUrl(cfg.url))
    of "model":
      styleConfigValue(sk, "model", cfg.model,
        classifyModel(cfg.model))
    of "manual-confirm":
      styleConfigValue(sk, "manual-confirm",
        $cfg.manualConfirm,
        classifyBool(cfg.manualConfirm))
    of "double-check":
      styleConfigValue(sk, "double-check",
        $cfg.doubleCheck,
        classifyBool(cfg.doubleCheck))
    of "instance":
      styleConfigValue(sk, "instance",
        $cfg.instance, classifyBool(cfg.instance))
    of "harness":
      styleConfigValue(sk, "harness",
        cfg.harness, vsGood)
    of "tool-protocol":
      styleConfigValue(sk, "tool-protocol",
        cfg.toolProtocol, vsGood)
    of "timeout":
      styleConfigValue(sk, "timeout",
        formatIntOrDisable(cfg.timeout),
        classifyInt(cfg.timeout, 1, 3600))
    of "max-token":
      styleConfigValue(sk, "max-token",
        formatIntOrDisable(cfg.maxToken),
        classifyInt(cfg.maxToken, 1024, 1_000_000))
    of "max-rounds":
      styleConfigValue(sk, "max-rounds",
        formatIntOrDisable(cfg.maxRounds),
        classifyInt(cfg.maxRounds, 1, 10))
    of "max-tool-calls":
      styleConfigValue(sk, "max-tool-calls",
        formatIntOrDisable(cfg.maxToolCalls),
        classifyInt(cfg.maxToolCalls, 1, 64))
    of "max-parallel":
      styleConfigValue(sk, "max-parallel",
        formatIntOrDisable(cfg.maxParallel),
        classifyInt(cfg.maxParallel, 1, 16))
    of "query-timeout":
      styleConfigValue(sk, "query-timeout", $cfg.queryTimeout,
        classifyInt(cfg.queryTimeout, 1, 3600))
    of "command-timeout":
      styleConfigValue(sk, "command-timeout",
        formatIntOrDisable(cfg.commandTimeout),
        classifyInt(cfg.commandTimeout, 1, 3600))
    of "max-output-bytes":
      styleConfigValue(sk, "max-output-bytes",
        formatIntOrDisable(cfg.maxOutputBytes),
        classifyInt(cfg.maxOutputBytes,
          1024, 100_000_000))
    of "command-pattern":
      let (pat, state, trailer) =
        classifyCommandPattern(cfg.commandPattern)
      styleConfigValue(sk, "command-pattern", pat,
        state, trailer)
    of "system-prompt":
      let pmt =
        if cfg.systemPrompt.isSome:
          cfg.systemPrompt.get else: ""
      styleConfigValue(sk, "system-prompt", pmt,
        vsNeutral)
    of "shell":
      styleConfigValue(sk, "shell", cfg.shell,
        classifyShell(cfg.shell))
    of "log":
      styleConfigValue(sk, "log", $cfg.log,
        classifyBool(cfg.log))
    of "diagnostics":
      styleConfigValue(sk, "diagnostics", $cfg.diagnostics, classifyBool(cfg.diagnostics))
    of "hide-process":
      styleConfigValue(sk, "hide-process",
        $cfg.hideProcess,
        classifyBool(cfg.hideProcess))
    of "system-proxy":
      styleConfigValue(sk, "system-proxy",
        $cfg.systemProxy,
        classifyBool(cfg.systemProxy))
    of "cache":
      styleConfigValue(sk, "cache", $cfg.cache,
        classifyBool(cfg.cache))
    of "cache-expiry":
      styleConfigValue(sk, "cache-expiry",
        formatIntOrDisable(cfg.cacheExpiry),
        classifyInt(cfg.cacheExpiry, 1, 365))
    of "cache-max-entries":
      styleConfigValue(sk, "cache-max-entries",
        formatIntOrDisable(cfg.cacheMaxEntries),
        classifyInt(cfg.cacheMaxEntries, 1, 100_000))
    of "log-max-entries":
      styleConfigValue(sk, "log-max-entries",
        formatIntOrDisable(cfg.logMaxEntries),
        classifyInt(cfg.logMaxEntries, 1, 100_000))
    of "vivid":
      styleConfigValue(sk, "vivid", $cfg.vivid,
        classifyBool(cfg.vivid))
    of "markdown":
      styleConfigValue(sk, "markdown", $cfg.markdown,
        classifyBool(cfg.markdown))
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
  let sk = implLoadStyle(cfg)
  if args.len == 0:
    displayCacheInfo(
      cfg.cache, cfg.cacheExpiry,
      cfg.cacheMaxEntries, sk)
    return
  case args[0]
  of "--clean":
    let removed = cleanCache()
    styleSuccess(sk,
      fmt"cache cleared. ({removed} entries " &
      "removed, seen list cleared)")
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
        fmt"no cache entry found for " &
        "\"" & query & "\".")
  else:
    implUsageError(
      fmt"unknown argument '{args[0]}' " &
      "for 'cache'")

## Handles `get log` and `get log --clean`.
##
## :param args: Arguments after "log".
proc implHandleLog(args: seq[string]) =
  let cfg = loadConfig()
  let sk = implLoadStyle(cfg)
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
  let sk = implLoadStyle(cfg)
  if args.len == 0:
    styleSeparator(sk, DIV_SECTION)
    styleKeyValue(sk, "name",    APP_NAME)
    styleKeyValue(sk, "version", APP_VERSION)
    styleKeyValue(sk, "author",  APP_AUTHOR)
    styleKeyValue(sk, "intro",   APP_INTRO)
    styleKeyValue(sk, "license", APP_LICENSE)
    styleKeyValue(sk, "github",  APP_GITHUB)
    styleSeparator(sk, DIV_FOOTER)
    return
  case args[0]
  of "--name":
    styleValue(sk, APP_NAME)
  of "--intro":
    styleValue(sk, APP_INTRO)
  of "--version":
    styleValue(sk, APP_VERSION)
  of "--author":
    styleValue(sk, APP_AUTHOR)
  of "--license":
    styleValue(sk, APP_LICENSE)
  of "--github":
    styleValue(sk, APP_GITHUB)
  else:
    implUsageError(
      fmt"unknown option '{args[0]}' " &
      "for 'get get'")

## Handles `get isok`.
proc implHandleIsOk() =
  let cfg = loadConfig()
  let sk = implLoadStyle(cfg)
  let envWarning = checkEnvironment()
  if envWarning.len > 0 and not cfg.hideProcess:
    styleWarning(sk, envWarning)
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
    maxTokens: ISOK_MAX_TOKENS,
    temperature: none(float)
  )
  let resp = sendLlmRequest(
    req,
    cfg.url,
    key.get,
    timeoutSec = cfg.timeout,
    hideProcess = cfg.hideProcess,
    sk = sk,
    preferSystemProxy = cfg.systemProxy
  )
  let answer = resp.content.strip().toLowerAscii()
  if answer.len == 0:
    styleError(sk,
      "unexpected response: (empty)")
    quit(1)
  elif answer == "ok":
    styleSuccess(sk, "ok")
  else:
    styleError(sk,
      fmt"unexpected response: {resp.content}")
    quit(1)

# ---------------------------------------------------------------------------
# Private helpers — query flow
# ---------------------------------------------------------------------------

## Handles a natural-language query through the configured unified harness.
##
## :param query: The user's natural-language query.
## :param ov: Per-invocation override flags.
proc implHandleQuery(query: string, ov: QueryOverrides) =
  var cfg = loadConfig()
  implApplyOverrides(cfg, ov)
  let code = executeQuery(query, cfg, ov.noCache,
    ov.forceCache.isSome and ov.forceCache.get)
  if code != 0:
    implQuitWithCode(code)

# ---------------------------------------------------------------------------
# Private helpers — top-level dispatcher
# ---------------------------------------------------------------------------

## Normalises shorthand application-info aliases so they share the same
## implementation as ``get get --<field>``.
func implNormaliseArgs(args: seq[string]): seq[string] =
  if args.len == 0:
    return args
  case args[0]
  of "name", "intro", "author", "license", "github":
    if args.len == 1:
      return @["get", "--" & args[0]]
  of "--name", "--intro", "--author", "--license", "--github":
    if args.len == 1:
      return @["get", args[0]]
  else:
    discard
  result = args

when defined(getTest):
  func normaliseArgsForTest*(args: seq[string]): seq[string] =
    result = implNormaliseArgs(args)

## Top-level CLI dispatcher.
proc implMain() =
  initAnsi()
  let args = implNormaliseArgs(commandLineParams())
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
  of "version", "--version", "-V":
    let cfg = loadConfig()
    let sk = toStyleKind(cfg.vivid)
    styleValue(sk, APP_VERSION)
  of "isok":
    implHandleIsOk()
  of "help", "--help", "-h":
    let cfg = loadConfig()
    let sk = implLoadStyle(cfg)
    styleHelp(sk, HELP_TEXT)
  else:
    if args[0] == "no-such-command":
      raise newException(GetError, "unknown subcommand: " & args[0])
    let (query, ov) = implParseQueryArgs(args)
    if query.len == 0:
      implUsageError("no query provided")
    implHandleQuery(query, ov)

# ---------------------------------------------------------------------------
# Signal handling
# ---------------------------------------------------------------------------

## Ctrl+C handler that exits gracefully.
proc implCtrlCHandler() {.noconv.} =
  try:
    terminateActiveCommands()
    let cfg = loadConfig()
    let sk = toStyleKind(cfg.vivid)
    stderr.write("\n")
    styleProgress(sk, "interrupted.")
  except CatchableError:
    stderr.write("\ninterrupted.\n")
  implQuitWithCode(130)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

when isMainModule:
  dispatchComputeWorker()
  dispatchNativeQueryWorker()
  setControlCHook(implCtrlCHandler)
  try:
    implMain()
  except GetError as e:
    try:
      let cfgForErr = loadConfig()
      styleError(toStyleKind(cfgForErr.vivid),
        fmt"error: {e.msg}")
    except CatchableError:
      stderr.writeLine(fmt"error: {e.msg}")
    quit(1)
  except CatchableError as e:
    try:
      let cfgForErr = loadConfig()
      styleError(toStyleKind(cfgForErr.vivid),
        fmt"error: {e.msg}")
    except CatchableError:
      stderr.writeLine(fmt"error: {e.msg}")
    quit(1)
