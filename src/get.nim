## Entry point and CLI dispatcher for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-14
## :File: get.nim
## :License: AGPL-3.0
##
## This module parses command-line arguments, routes execution to
## the appropriate subcommand handler, and manages top-level error
## reporting.  The query flow supports instance (single-call) and
## non-instance (multi-step) modes, optional double-check safety
## review, manual-confirm gating, command-pattern validation,
## response caching with LLM-driven cache-worthiness checks,
## structured logging, model-strength warnings, progress display,
## and bundled tool integration.

{.experimental: "strictFuncs".}

import std/[os, strformat, strutils, options, times]

import cache
import config
import exec
import llm
import logger
import prompt
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
  get "query" [--no-cache]   retrieve information via natural language
  get set <option> [value]   set configuration (omit value to reset)
  get config [flags]         view or reset configuration
  get cache [flags]          view or manage response cache
  get log [flags]            view or manage execution log
  get get [flags]            display application information
  get version                display version
  get isok                   verify configuration readiness
  get help                   display this help message

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
  command-pattern    regex for command validation
                       (string, default: empty)
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
  get set model gpt-5.3-codex
  get set key sk-your-api-key
  get set url https://api.openai.com/v1
  get set timeout false
  get config --model
  get cache --clean
  get log --clean"""

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
  if args.len == 0:
    displayConfig()
    return
  if args[0] == "--reset":
    resetConfig()
    echo "configuration reset."
    return
  if args[0].startsWith("--"):
    let optName = args[0][2 .. ^1]
    let cfg = loadConfig()
    case optName
    of "key":
      let key = loadKey()
      if key.isSome:
        echo "set (" & maskString(key.get) & ")"
      else:
        echo "not set"
    of "url":
      echo cfg.url
    of "model":
      echo cfg.model
    of "manual-confirm":
      echo cfg.manualConfirm
    of "double-check":
      echo cfg.doubleCheck
    of "instance":
      echo cfg.instance
    of "timeout":
      echo formatIntOrDisable(cfg.timeout)
    of "max-token":
      echo formatIntOrDisable(cfg.maxToken)
    of "command-pattern":
      echo(
        if cfg.commandPattern.isSome:
          cfg.commandPattern.get else: "")
    of "system-prompt":
      echo(
        if cfg.systemPrompt.isSome:
          cfg.systemPrompt.get else: "")
    of "shell":
      echo cfg.shell
    of "log":
      echo cfg.log
    of "hide-process":
      echo cfg.hideProcess
    of "cache":
      echo cfg.cache
    of "cache-expiry":
      echo formatIntOrDisable(cfg.cacheExpiry)
    of "cache-max-entries":
      echo formatIntOrDisable(cfg.cacheMaxEntries)
    of "log-max-entries":
      echo formatIntOrDisable(cfg.logMaxEntries)
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
  if args.len == 0:
    let cfg = loadConfig()
    displayCacheInfo(
      cfg.cache, cfg.cacheExpiry,
      cfg.cacheMaxEntries)
    return
  case args[0]
  of "--clean":
    let removed = cleanCache()
    echo fmt"cache cleared. ({removed} entries removed)"
  of "--unset":
    if args.len < 2:
      implUsageError(
        "missing query text for 'cache --unset'")
    let query = args[1 .. ^1].join(" ")
    let removed = unsetCache(query)
    if removed > 0:
      echo fmt"removed {removed} cache entries" &
        fmt" for ""{query}""."
    else:
      echo fmt"no cache entry found for ""{query}""."
  else:
    implUsageError(
      fmt"unknown argument '{args[0]}' for 'cache'")

## Handles `get log` and `get log --clean`.
##
## :param args: Arguments after "log".
proc implHandleLog(args: seq[string]) =
  if args.len == 0:
    let cfg = loadConfig()
    displayLogInfo(cfg.log, cfg.logMaxEntries)
    return
  case args[0]
  of "--clean":
    let removed = cleanLog()
    echo fmt"log cleared. ({removed} entries removed)"
  else:
    implUsageError(
      fmt"unknown argument '{args[0]}' for 'log'")

## Handles `get get` and its sub-flags.
##
## :param args: Arguments after "get".
proc implHandleGet(args: seq[string]) =
  if args.len == 0:
    echo fmt"version: {APP_VERSION}"
    echo fmt"intro: {APP_INTRO}"
    echo fmt"license: {APP_LICENSE}"
    echo fmt"github: {APP_GITHUB}"
    return
  case args[0]
  of "--intro":
    echo APP_INTRO
  of "--version":
    echo APP_VERSION
  of "--license":
    echo APP_LICENSE
  of "--github":
    echo APP_GITHUB
  else:
    implUsageError(
      fmt"unknown option '{args[0]}' for 'get get'")

## Handles `get isok`.  Checks config readiness then sends a probe
## request to the LLM.
proc implHandleIsOk() =
  let cfgReady = checkReady()
  if not cfgReady:
    quit(1)
  let cfg = loadConfig()
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
    hideProcess = cfg.hideProcess
  )
  let answer = resp.content.strip().toLowerAscii()
  if answer == "ok":
    echo "ok"
  else:
    echo fmt"unexpected response: {resp.content}"
    quit(1)

# ---------------------------------------------------------------------------
# Private helpers — query flow
# ---------------------------------------------------------------------------

## Resolves the effective shell, falling back to the platform
## default when the configured value is empty.
##
## :param cfg: The loaded configuration.
## :returns: A non-empty shell name.
func implEffectiveShell(cfg: Config): string =
  if cfg.shell.len > 0: cfg.shell
  else: defaultShell()

## Sends an LLM request built from the supplied messages and
## returns the response.
##
## :param messages: Conversation messages to send.
## :param cfg: The loaded configuration.
## :param key: The API key.
## :returns: The LLM response.
proc implLlmCall(
  messages: seq[LlmMessage],
  cfg: Config,
  key: string
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
    hideProcess = cfg.hideProcess
  )

## Optionally performs the double-check safety review on a command.
##
## :param command: The command to review.
## :param query: The original user query.
## :param info: System information snapshot.
## :param cfg: The loaded configuration.
## :param key: The API key.
## :returns: The approved (possibly revised) command.
proc implDoubleCheck(
  command: string,
  query: string,
  info: SysInfo,
  cfg: Config,
  key: string
): string =
  if not cfg.hideProcess:
    stderr.writeLine("double-checking command...")
  let msgs = buildDoubleCheckMessages(
    command, query, info)
  let resp = implLlmCall(msgs, cfg, key)
  let stripped = resp.content.strip()
  if toUpperAscii(stripped) == "UNSAFE":
    stderr.writeLine(
      "error: command deemed unsafe by review")
    quit(1)
  let revised = extractCodeBlock(resp.content)
  if revised.isSome:
    result = revised.get
  else:
    result = command

## Asks the LLM whether a query result is worth caching.  Returns
## true when the model answers "CACHE" or when the check fails
## (fail-open so transient errors do not break caching).
##
## :param query: The original user query.
## :param command: The generated command.
## :param output: The full command output.
## :param cfg: The loaded configuration.
## :param key: The API key.
## :returns: true when the result should be cached.
proc implCheckShouldCache(
  query: string,
  command: string,
  output: string,
  cfg: Config,
  key: string
): bool =
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
    result = answer != "NOCACHE"
  except CatchableError:
    # Fail-open: cache on error.
    result = true

## Emits a model-strength warning on stderr when the configured
## model is not recognised as a known high-performance model.
##
## :param model: The configured model name.
proc implWarnIfWeakModel(model: string) =
  if model.len > 0 and
      not isKnownStrongModel(model):
    stderr.writeLine(MODEL_STRENGTH_WARNING)

## Handles a natural-language query.
##
## :param query: The user's natural-language query.
## :param noCache: When true the cache is bypassed for this query.
proc implHandleQuery(query: string, noCache: bool) =
  let cfg = loadConfig()
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

  # Model-strength advisory.
  implWarnIfWeakModel(cfg.model)

  let shell = implEffectiveShell(cfg)
  let cwd = getCurrentDir()

  # ---- Cache lookup ----
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
      if not cfg.hideProcess:
        stderr.writeLine("(cached)")
      echo hit.get.output
      return

  # 1. Collect system information.
  if not cfg.hideProcess:
    stderr.writeLine("collecting system info...")
  let info = collectSysInfo(shell)

  # 2. Build query prompt and call LLM.
  let queryMsgs = buildQueryMessages(
    info, query, shell, cfg.instance,
    cfg.systemPrompt, cfg.commandPattern)
  let genResp = implLlmCall(
    queryMsgs, cfg, key.get)

  # 3. Extract command from the response.
  let maybeCmd = extractCodeBlock(genResp.content)
  if maybeCmd.isNone:
    # Direct text answer (no command generated).
    echo genResp.content
    if useCache:
      var store = loadCache()
      let entry = CacheEntry(
        hash: cacheHash,
        query: query,
        command: "",
        output: genResp.content,
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
    stderr.writeLine(fmt"command: {command}")

  # 4. Double-check (optional, default: enabled).
  if cfg.doubleCheck:
    command = implDoubleCheck(
      command, query, info, cfg, key.get)
    if not cfg.hideProcess:
      stderr.writeLine(
        fmt"approved command: {command}")

  # 5. Command-pattern validation.
  if cfg.commandPattern.isSome:
    if not validateCommandPattern(
        command, cfg.commandPattern.get):
      stderr.writeLine(
        "error: command does not match" &
        " configured pattern")
      if cfg.log:
        logExecution(query, command,
          "rejected by pattern", 1,
          cfg.logMaxEntries)
      quit(1)

  # 6. Manual confirmation (optional).
  if cfg.manualConfirm:
    if not confirmExecution(command):
      stderr.writeLine("aborted.")
      quit(0)

  # 7. Execute the command with bundled bin dir.
  if not cfg.hideProcess:
    stderr.writeLine("executing...")
  let execRes = executeCommand(
    command, shell, info.binDir)

  # 8. Instance vs non-instance output handling.
  var finalOutput = ""
  if cfg.instance:
    finalOutput = execRes.output.strip()
    if finalOutput.len > 0:
      echo finalOutput
  else:
    if execRes.exitCode != 0 and
        execRes.output.strip().len == 0:
      finalOutput =
        fmt"command exited with code " &
        fmt"{execRes.exitCode}"
      stderr.writeLine(finalOutput)
    else:
      let interpretMsgs = buildInterpretMessages(
        query, command, execRes.output)
      let interpretResp = implLlmCall(
        interpretMsgs, cfg, key.get)
      finalOutput = interpretResp.content
      echo finalOutput

  # 9. Cache the result (with LLM cache-worthiness check).
  if useCache and finalOutput.len > 0:
    let shouldCache = implCheckShouldCache(
      query, command, finalOutput, cfg, key.get)
    if shouldCache:
      var store = loadCache()
      let entry = CacheEntry(
        hash: cacheHash,
        query: query,
        command: command,
        output: finalOutput,
        timestamp: getTime().toUnix()
      )
      addCacheEntry(store, entry,
        cfg.cacheMaxEntries, cfg.cacheExpiry)
      saveCache(store)
    else:
      if not cfg.hideProcess:
        stderr.writeLine(
          "(result not cached — volatile)")

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
    echo APP_VERSION
  of "isok":
    implHandleIsOk()
  of "help", "--help", "-h":
    echo HELP_TEXT
  else:
    var queryParts: seq[string] = @[]
    var noCache = false
    for a in args:
      if a == "--no-cache":
        noCache = true
      else:
        queryParts.add(a)
    let query = queryParts.join(" ")
    if query.len == 0:
      implUsageError("no query provided")
    implHandleQuery(query, noCache)

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

when isMainModule:
  try:
    implMain()
  except GetError as e:
    stderr.writeLine(fmt"error: {e.msg}")
    quit(1)
  except CatchableError as e:
    stderr.writeLine(fmt"error: {e.msg}")
    quit(1)