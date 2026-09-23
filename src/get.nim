## Entry point and CLI dispatcher for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: get.nim
## :License: AGPL-3.0
##
## This module parses command-line arguments, routes execution to the
## appropriate subcommand handler, and manages top-level error reporting.
## A query runs through one loop: provider-native tool calls are preferred and
## strict JSON actions are the fallback. Every fresh or cached call passes the
## same authorization and a bounded executor before it can run.

{.experimental: "strictFuncs".}

import std/[os, strformat, strutils, options]

import cache
import config
import native_query_worker
import compute_sandbox
import exec
import harness_types
import installer
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
  get config [--<option>]      view settings, or one setting
  get config --reset           reset all settings and remove the key
  get cache [flags]            view or manage the cache
  get log [flags]              view recent queries or clear the log
  get update                   install the latest release
  get uninstall [--purge]      remove get (--purge also removes settings)
  get get [flags]              display application information
  get version, --version, -V   display version
  get isok                     verify configuration readiness
  get help                     display this help message

query flags (this query only):
  --model <name>               use another model
  --timeout <seconds>          request timeout
  --no-cache                   skip the cache
  --cache                      also cache the answer text
  --protocol <kind>            auto, native, or json
  --hide-process               hide process lines
  --no-hide-process            show process lines
  --markdown                   render Markdown in an interactive terminal
  --no-markdown                print Markdown source
  --manual-confirm             ask before each call runs
  --no-manual-confirm          do not ask
  --double-check               second model reviews each call
  --no-double-check            no review
  --system-proxy               prefer the OS proxy settings
  --no-system-proxy            use terminal proxy variables only

set options:
  key                API key (default: empty)
  url                API base URL (default: https://api.deepseek.com)
  model              model name (default: deepseek-flash)
  manual-confirm     ask before each call runs (true/false, default: false)
  double-check       second model reviews each call (true/false, default: false)
  tool-protocol      auto, native, or json (default: auto)
  timeout            request timeout in seconds, or false (default: 300)
  max-token          max tokens per request, or false (default: 20480)
  max-rounds         model requests per query (default: 6)
  max-tool-calls     tool calls per query (default: 16)
  max-parallel       calls run at once (default: 4)
  query-timeout      whole-query deadline in seconds (default: 120)
  command-timeout    per-command deadline in seconds (default: 30)
  max-output-bytes   captured bytes per command (default: 1048576)
  system-prompt      extra instruction for the model (default: empty)
  shell              shell for commands (default: bash / powershell)
  log                log one line per query (true/false, default: true)
  diagnostics        structured events on stderr (true/false, default: false)
  hide-process       hide process lines (true/false, default: false)
  system-proxy       prefer the OS proxy settings (true/false, default: false)
  cache              use the cache (true/false, default: true)
  cache-expiry       cache lifetime in days, or false (default: 30)
  cache-max-entries  cached entries kept, or false (default: 1000)
  log-max-entries    log entries kept, or false (default: 1000)
  markdown           render answers in interactive terminals
                       (true/false, default: true)

cache flags:
  (none)             display cache status
  --clean            remove all cached entries
  --unset "query"    remove entries for a query

log flags:
  (none)             display log status and recent queries
  --clean            remove all log entries

get flags:
  --name, --intro, --version, --author, --license, --github

examples:
  get "system version"
  get "disk usage" --no-cache
  get set model deepseek-flash
  get set key sk-your-api-key
  get config --model
  get log"""

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
    toolProtocol*: Option[string] ## Override provider tool protocol.
    hideProcess*: Option[bool]   ## Override hide-process.
    systemProxy*: Option[bool]   ## Override system-proxy.
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
    toolProtocol: none(string),
    hideProcess: none(bool),
    systemProxy: none(bool),
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
    of "--harness", "--instance", "--no-instance", "--vivid", "--no-vivid":
      raise newException(GetError, fmt"unknown option '{a}'")
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
  if ov.toolProtocol.isSome:
    cfg.toolProtocol = ov.toolProtocol.get
  if ov.hideProcess.isSome:
    cfg.hideProcess = ov.hideProcess.get
  if ov.systemProxy.isSome:
    cfg.systemProxy = ov.systemProxy.get
  if ov.markdown.isSome:
    cfg.markdown = ov.markdown.get
  if ov.model.isSome:
    cfg.model = ov.model.get
  if ov.timeout.isSome:
    cfg.timeout = ov.timeout.get

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
  let sk = detectStyle()
  if args.len == 0:
    displayConfig(sk)
    return
  if args.len > 1:
    implUsageError(fmt"'config {args[0]}' takes no arguments")
  if args[0] == "--reset":
    resetConfig()
    styleSuccess(sk, "configuration reset.")
  elif args[0].startsWith("--"):
    try:
      displayConfig(sk, args[0][2 .. ^1])
    except GetError as error:
      implUsageError(error.msg)
  else:
    implUsageError(fmt"unknown argument '{args[0]}' for 'config'")

## Handles `get cache`, `get cache --clean`, and
## `get cache --unset "query"`.
##
## :param args: Arguments after "cache".
proc implHandleCache(args: seq[string]) =
  let cfg = loadConfig()
  let sk = detectStyle()
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
  let sk = detectStyle()
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
  let sk = detectStyle()
  if args.len == 0:
    styleKeyValue(sk, "name",    APP_NAME)
    styleKeyValue(sk, "version", APP_VERSION)
    styleKeyValue(sk, "author",  APP_AUTHOR)
    styleKeyValue(sk, "intro",   APP_INTRO)
    styleKeyValue(sk, "license", APP_LICENSE)
    styleKeyValue(sk, "github",  APP_GITHUB)
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
  let sk = detectStyle()
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

## Handles `get update`.
proc implHandleUpdate(args: seq[string]) =
  if args.len > 0:
    implUsageError(fmt"unknown argument '{args[0]}' for 'update'")
  let code = updateGet(detectStyle(), loadConfig().systemProxy)
  if code != 0:
    implQuitWithCode(code)

## Handles `get uninstall` and `get uninstall --purge`.
proc implHandleUninstall(args: seq[string]) =
  if args.len > 1 or (args.len == 1 and args[0] != "--purge"):
    implUsageError("usage: get uninstall [--purge]")
  uninstallGet(detectStyle(), purge = args.len == 1)

## Handles a natural-language query.
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
    styleValue(detectStyle(), APP_VERSION)
  of "isok":
    implHandleIsOk()
  of "update":
    implHandleUpdate(args[1 .. ^1])
  of "uninstall":
    implHandleUninstall(args[1 .. ^1])
  of "help", "--help", "-h":
    styleHelp(HELP_TEXT)
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
    stderr.write("\n")
    styleProgress(detectStyle(), "interrupted.")
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
  except CatchableError as e:
    styleError(detectStyle(), fmt"error: {e.msg}")
    quit(1)
