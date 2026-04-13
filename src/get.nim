## Entry point and CLI dispatcher for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-13
## :File: get.nim
## :License: AGPL-3.0
##
## This module parses command-line arguments, routes execution to
## the appropriate subcommand handler, and manages top-level error
## reporting.  The query flow supports instance (single-call) and
## non-instance (multi-step) modes, optional double-check safety
## review, manual-confirm gating, command-pattern validation,
## response caching, structured logging, and progress display.

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

## Comprehensive help text displayed by `get help`.  Lists every
## subcommand, all set option keys with types and defaults, and
## flag details for config, cache, and get subcommands.
const HELP_TEXT* = """get -- get anything from your computer

usage:
  get "query" [--no-cache]   retrieve information via natural language
  get set <option> [value]   set configuration (omit value to reset)
  get config [flags]         view or reset configuration
  get cache [flags]          view or manage response cache
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
  double-check       second model review
                       (true/false, default: false)
  instance           faster model replies
                       (true/false, default: false)
  timeout            request timeout in seconds
                       (integer, default: 300)
  max-token          max tokens per request
                       (integer, default: 20480)
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
                       (integer, default: 30)
  cache-max-entries  max cached entries
                       (integer, default: 1000)

config flags:
  (none)             display all current settings
  --reset            reset all settings to defaults
  --<option>         display one setting
                       (any set option except key)

cache flags:
  (none)             display cache status
  --clean            remove all cached entries
  --unset "query"    remove entries matching query

get flags:
  (none)             display all application info
  --intro            display introduction
  --version          display version
  --license          display license identifier
  --github           display GitHub URL

examples:
  get "system version"
  get "disk usage" --no-cache
  get set model gpt-4o
  get set key sk-your-api-key
  get set url https://api.openai.com/v1
  get config --model
  get cache --clean"""

# ---------------------------------------------------------------------------
# Private helpers — usage errors
# ---------------------------------------------------------------------------

## Raises a GetError whose message includes the standard help hint.
## Called for user-facing errors caused by incorrect CLI usage so
## the user knows where to find detailed documentation.
##
## :param msg: A concise description of the problem.
proc implUsageError(
  msg: string
) {.noreturn.} =  # Always raises; never returns normally.
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
      echo cfg.timeout
    of "max-token":
      echo cfg.maxToken
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
      echo cfg.cacheExpiry
    of "cache-max-entries":
      echo cfg.cacheMaxEntries
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
    echo fmt"cache cleared. (removed {removed} entries)"
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
  echo resp.content

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
## returns the response.  This is a thin convenience wrapper that
## reads the key and timeout from the config.
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
## Returns the (possibly revised) command string, or raises / quits
## when the command is deemed unsafe.
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
    # Reviewer did not wrap in a code block — keep
    # original.
    result = command

## Handles a natural-language query.  Implements the full pipeline:
## cache lookup, system-info collection, prompt construction, LLM
## command generation, optional double-check, optional manual-
## confirm, command-pattern validation, execution, optional output
## interpretation (non-instance mode), cache storage, and logging.
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
    # The model answered directly without a command.
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
        genResp.content, 0)
    return

  var command = maybeCmd.get
  if not cfg.hideProcess:
    stderr.writeLine(fmt"command: {command}")

  # 4. Double-check (optional).
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
          "rejected by pattern", 1)
      quit(1)

  # 6. Manual confirmation (optional).
  if cfg.manualConfirm:
    if not confirmExecution(command):
      stderr.writeLine("aborted.")
      quit(0)

  # 7. Execute the command.
  if not cfg.hideProcess:
    stderr.writeLine("executing...")
  let execRes = executeCommand(command, shell)

  # 8. Instance vs non-instance output handling.
  var finalOutput = ""
  if cfg.instance:
    # Instance mode: show raw output directly.
    finalOutput = execRes.output.strip()
    if finalOutput.len > 0:
      echo finalOutput
  else:
    # Non-instance mode: ask LLM to interpret output.
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

  # 9. Cache the result.
  if useCache and finalOutput.len > 0:
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

  # 10. Log.
  if cfg.log:
    logExecution(query, command,
      execRes.output, execRes.exitCode)

  # 11. Propagate non-zero exit code.
  if execRes.exitCode != 0:
    quit(execRes.exitCode)

# ---------------------------------------------------------------------------
# Private helpers — top-level dispatcher
# ---------------------------------------------------------------------------

## Top-level CLI dispatcher.  Routes the first positional argument
## to the corresponding subcommand handler, or falls through to
## natural-language query processing.
proc implMain() =
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
  of "get":
    implHandleGet(args[1 .. ^1])
  of "version":
    echo APP_VERSION
  of "isok":
    implHandleIsOk()
  of "help", "--help", "-h":
    echo HELP_TEXT
  else:
    # Parse --no-cache flag from query arguments.
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