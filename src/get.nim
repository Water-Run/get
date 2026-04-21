## Entry point and CLI dispatcher for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-21
## :File: get.nim
## :License: AGPL-3.0
##
## This module parses command-line arguments, routes execution to
## the appropriate subcommand handler, and manages top-level error
## reporting.  The query flow supports two modes:
##
##   Instance — single LLM call, one command, direct output.
##
##   Agent    — multi-round loop where the LLM can execute
##              intermediate commands to gather information before
##              producing a final answer.  An urgency counter
##              increases each round to encourage convergence, and
##              a hard cap (max-rounds, default 3) prevents
##              unbounded loops.
##
## Every command — whether intermediate or final — passes through
## all safety layers before execution: forbidden-command pattern,
## double-check LLM review, and optional manual confirmation.
##
## Caching uses a deferred-decision mechanism: the first execution
## of a query merely marks it as "seen"; only on the second
## execution (or when --cache is explicitly passed) does the tool
## invoke the LLM to choose a caching strategy.  When the global
## config option ``cache`` is false, all caching logic — including
## seen tracking — is completely disabled.

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

## Maximum characters of intermediate output shown to the user
## during agent loop rounds (when hideProcess is false).
const INTERMEDIATE_OUTPUT_PREVIEW_LEN = 500

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
  --no-instance                multi-step agent mode
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
  max-rounds         max agent loop rounds (non-instance)
                       (integer or false, default: 3)
  command-pattern    forbidden command regex; omit value to
                       restore the built-in default, use ""
                       to disable filtering entirely
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
  cache-trigger-threshold
                     number of prior executions required
                       before triggering cache decision
                       (integer or false, default: 1)
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
    hideProcess*: Option[bool]   ## Override hide-process.
    vivid*: Option[bool]         ## Override vivid mode.
    model*: Option[string]       ## Override model name.
    timeout*: Option[int]        ## Override timeout seconds.

# ---------------------------------------------------------------------------
# Private helpers — usage errors
# ---------------------------------------------------------------------------

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
# Private helpers — LLM call wrappers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Private helpers — shell and pattern resolution
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
## :param hideProcess: Suppress warnings when true.
## :returns: The pattern string to use.
proc implEffectivePattern(
  cfg: Config,
  sk: StyleKind,
  hideProcess: bool
): string =
  if cfg.commandPattern.isSome:
    let pat = cfg.commandPattern.get
    if pat.len == 0:
      if not hideProcess:
        styleWarning(sk,
          "warning: command-pattern is empty — " &
          "no forbidden command filtering is active")
      return ""
    return pat
  result = DEFAULT_COMMAND_PATTERN

# ---------------------------------------------------------------------------
# Private helpers — safety checks
# ---------------------------------------------------------------------------

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

## Runs all safety layers on a command: forbidden-command
## pattern, double-check review, and manual confirmation.
## Returns the (possibly revised) command.  Quits with a
## non-zero exit code if any check rejects the command, or
## if the user declines manual confirmation.
##
## :param command: The raw command from the LLM.
## :param query: The original user query.
## :param info: System information snapshot.
## :param cfg: The loaded configuration.
## :param key: The API key.
## :param sk: The active output style.
## :param effectivePattern: The active forbidden-command regex.
## :returns: The approved command string.
proc implSafetyCheck(
  command: string,
  query: string,
  info: SysInfo,
  cfg: Config,
  key: string,
  sk: StyleKind,
  effectivePattern: string
): string =
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
  var checked = command
  if cfg.doubleCheck:
    checked = implDoubleCheck(
      command, query, info, cfg, key, sk)
    if checked != command and not cfg.hideProcess:
      styleCommand(sk, "revised command", checked)
  if cfg.manualConfirm:
    let showCmd = cfg.hideProcess
    if not confirmExecution(checked, sk, showCmd):
      styleProgress(sk, "aborted.")
      quit(0)
  result = checked

# ---------------------------------------------------------------------------
# Private helpers — cache decision
# ---------------------------------------------------------------------------

## Parses a raw cache decision string into a CacheDecision.
##
## The parser applies a three-tier strategy:
##
##   Tier 1 — Exact match after stripping all non-alphanumeric
##            characters and uppercasing (handles backslash-
##            escaped underscores, Markdown emphasis, quotation
##            marks, and similar formatting noise).
##   Tier 2 — Substring match for the compound token (handles
##            verbose responses that embed the token in a
##            sentence).
##   Tier 3 — Keyword-pair fallback (GLOBAL/CONTEXT +
##            COMMAND/RESULT), applied only to short responses
##            (≤ 30 alphanumeric characters) to avoid false
##            positives in lengthy explanations.
##
## Concrete cache modes are always checked before NOCACHE so
## that a response containing both a mode name and the word
## "nocache" resolves in favour of caching.
##
## :param raw: The raw model output.
## :returns: A parsed CacheDecision value.
func implParseCacheDecision(
  raw: string
): CacheDecision =
  # Strip every non-alphanumeric character and
  # uppercase, so "GLOBAL\_COMMAND", `GLOBAL_COMMAND`,
  # **GLOBAL_COMMAND**, "global-command" all collapse
  # to "GLOBALCOMMAND".
  var clean = newStringOfCap(raw.len)
  for ch in raw:
    if ch in {'A' .. 'Z', 'a' .. 'z',
              '0' .. '9'}:
      clean.add(ch)
  clean = toUpperAscii(clean)
  if clean.len == 0:
    return cdNoCache

  # --- Tier 1: exact match on stripped token ---
  case clean
  of "GLOBALCOMMAND":
    return cdGlobalCommand
  of "GLOBALRESULT":
    return cdGlobalResult
  of "CONTEXTCOMMAND":
    return cdContextCommand
  of "CONTEXTRESULT":
    return cdContextResult
  of "NOCACHE", "NOCACHING":
    return cdNoCache
  else:
    discard

  # --- Tier 2: compound-token substring ---
  # Check CONTEXT before GLOBAL (more specific).
  if clean.contains("CONTEXTRESULT"):
    return cdContextResult
  if clean.contains("CONTEXTCOMMAND"):
    return cdContextCommand
  if clean.contains("GLOBALRESULT"):
    return cdGlobalResult
  if clean.contains("GLOBALCOMMAND"):
    return cdGlobalCommand

  # --- Tier 3: keyword-pair fallback ---
  # Only for short responses to prevent false
  # positives when the model writes a full sentence
  # that coincidentally contains both "context" and
  # "result".
  if clean.len <= 30:
    let hasGlobal = clean.contains("GLOBAL")
    let hasContext = clean.contains("CONTEXT")
    let hasCommand = clean.contains("COMMAND")
    let hasResult = clean.contains("RESULT")
    if hasContext and hasResult:
      return cdContextResult
    if hasContext and hasCommand:
      return cdContextCommand
    if hasGlobal and hasResult:
      return cdGlobalResult
    if hasGlobal and hasCommand:
      return cdGlobalCommand

  # NOCACHE as substring (verbose refusal).
  if clean.contains("NOCACHE"):
    return cdNoCache

  result = cdNoCache

when defined(getTest):
  ## Exposes cache decision parsing for test builds.
  ##
  ## :param raw: The raw model output.
  ## :returns: A parsed CacheDecision value.
  func parseCacheDecisionForTest*(raw: string): CacheDecision =
    result = implParseCacheDecision(raw)

## Asks the LLM whether and how a query result should be
## cached.  Returns none on any failure so that callers can
## distinguish "decided NOCACHE" from "decision step failed".
## A dedicated spinner label is passed to sendLlmRequest so
## the progress indicator shows context-specific text.
##
## When the LLM call fails, a warning is emitted in normal
## process mode so that the user can diagnose connectivity
## or configuration issues affecting the cache pipeline.
##
## :param query: The original user query.
## :param command: The final command, or empty for plain text.
## :param output: The full output.
## :param cfg: The loaded configuration.
## :param key: The API key.
## :param sk: The active output style.
## :returns: The cache decision, or none on failure.
proc implCacheDecision(
  query: string,
  command: string,
  output: string,
  cfg: Config,
  key: string,
  sk: StyleKind
): Option[CacheDecision] =
  try:
    let preview =
      if output.len > CACHE_CHECK_PREVIEW_LEN:
        output[0 ..< CACHE_CHECK_PREVIEW_LEN] &
          "..."
      else:
        output
    let msgs = buildCacheCheckMessages(
      query, command, preview)
    let req = LlmRequest(
      model: cfg.model,
      messages: msgs,
      maxTokens: cfg.maxToken
    )
    let resp = sendLlmRequest(
      req,
      cfg.url,
      key,
      timeoutSec = (
        if cfg.timeout > 0: min(cfg.timeout, 30)
        else: 30),
      hideProcess = cfg.hideProcess,
      sk = sk,
      spinnerLabel = "checking cache decision"
    )
    result = some(implParseCacheDecision(
      resp.content))
  except CatchableError as e:
    if not cfg.hideProcess:
      styleWarning(sk,
        fmt"warning: cache decision failed: " &
        fmt"{e.msg}")
    result = none(CacheDecision)

# ---------------------------------------------------------------------------
# Private helpers — model strength warning
# ---------------------------------------------------------------------------

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

## Handles the entire post-execution cache pipeline:
##
##   1. When caching is disabled or the context says so, do
##      nothing.
##   2. First-time query -> just mark as seen.
##   3. Previously decided NOCACHE -> print remembered notice,
##      mark seen, skip the LLM decision call entirely.
##   4. Nothing to cache (empty command and output) -> mark seen.
##   5. Run the cache-decision LLM call, print the result,
##      then persist the entry (or the NOCACHE memory).
##
## :param cc: The cache context with hash keys and seen flag.
## :param query: The original user query.
## :param command: The final command, or empty for plain text.
## :param output: The final output text.
## :param cfg: The loaded configuration.
## :param key: The API key.
## :param sk: The active output style.
proc implHandleCacheOutcome(
  cc: CacheContext,
  query: string,
  command: string,
  output: string,
  cfg: Config,
  key: string,
  sk: StyleKind
) =
  if not cc.useCache:
    return
  var store = loadCache()
  # Case 1: first time seeing this query.
  if not cc.wasSeen:
    markSeen(store, cc.queryHash,
      cfg.cacheMaxEntries, cfg.cacheExpiry)
    saveCache(store)
    return
  # Case 2: query was already decided as NOCACHE.
  if isNoCacheDecided(store, cc.queryHash,
      cfg.cacheExpiry):
    if not cfg.hideProcess:
      styleProgress(sk,
        "cache decision: nocache (remembered)")
    markSeen(store, cc.queryHash,
      cfg.cacheMaxEntries, cfg.cacheExpiry)
    saveCache(store)
    return
  # Case 3: nothing worth deciding on.
  if command.len == 0 and output.len == 0:
    markSeen(store, cc.queryHash,
      cfg.cacheMaxEntries, cfg.cacheExpiry)
    saveCache(store)
    return
  # Case 4: invoke the LLM decision.
  let decisionOpt = implCacheDecision(
    query, command, output, cfg, key, sk)
  if decisionOpt.isNone:
    if not cfg.hideProcess:
      styleProgress(sk,
        "cache decision: failed (skipped)")
    markSeen(store, cc.queryHash,
      cfg.cacheMaxEntries, cfg.cacheExpiry)
    saveCache(store)
    return
  let decision = decisionOpt.get
  if not cfg.hideProcess:
    let label = case decision
      of cdGlobalCommand:
        "global-command (command cached)"
      of cdGlobalResult:
        "global-result (output cached)"
      of cdContextCommand:
        "context-command (command cached)"
      of cdContextResult:
        "context-result (output cached)"
      of cdNoCache:
        "nocache (remembered, will skip next time)"
    styleProgress(sk, "cache decision: " & label)
  let ts = getTime().toUnix()
  case decision
  of cdGlobalResult:
    addCacheEntry(store, CacheEntry(
      hash: cc.globalHash, scope: csGlobal,
      cacheMode: cmResult, query: query,
      command: command, output: output,
      timestamp: ts),
      cfg.cacheMaxEntries, cfg.cacheExpiry)
  of cdGlobalCommand:
    addCacheEntry(store, CacheEntry(
      hash: cc.globalHash, scope: csGlobal,
      cacheMode: cmCommand, query: query,
      command: command, output: "",
      timestamp: ts),
      cfg.cacheMaxEntries, cfg.cacheExpiry)
  of cdContextResult:
    addCacheEntry(store, CacheEntry(
      hash: cc.contextHash, scope: csContext,
      cacheMode: cmResult, query: query,
      command: command, output: output,
      timestamp: ts),
      cfg.cacheMaxEntries, cfg.cacheExpiry)
  of cdContextCommand:
    addCacheEntry(store, CacheEntry(
      hash: cc.contextHash, scope: csContext,
      cacheMode: cmCommand, query: query,
      command: command, output: "",
      timestamp: ts),
      cfg.cacheMaxEntries, cfg.cacheExpiry)
  of cdNoCache:
    markNoCacheDecided(store, cc.queryHash,
      cfg.cacheMaxEntries, cfg.cacheExpiry)
  markSeen(store, cc.queryHash,
    cfg.cacheMaxEntries, cfg.cacheExpiry)
  saveCache(store)

# ---------------------------------------------------------------------------
# Private helpers — instance flow
# ---------------------------------------------------------------------------

## Handles a query in instance mode: a single LLM call that
## produces one command (or text answer), executed and displayed
## directly.
##
## :param query: The user query.
## :param cfg: The effective configuration.
## :param key: The API key.
## :param sk: The active output style.
## :param binDir: Bundled bin directory.
## :param extDisplay: External display enabled flag.
## :param shell: The effective shell.
## :param info: System information snapshot.
## :param effectivePattern: Forbidden-command regex.
## :param cc: Cache context with hashes and seen state.
proc implInstanceFlow(
  query: string,
  cfg: Config,
  key: string,
  sk: StyleKind,
  binDir: string,
  extDisplay: bool,
  shell: string,
  info: SysInfo,
  effectivePattern: string,
  cc: CacheContext
) =
  if not cfg.hideProcess:
    styleSeparator(sk, DIV_THIN)
  let patternOpt =
    if effectivePattern.len > 0:
      some(effectivePattern)
    else:
      none(string)
  let msgs = buildInstanceMessages(
    info, query, shell,
    cfg.systemPrompt, patternOpt)
  let resp = implLlmCall(msgs, cfg, key, sk)

  let cmd = extractCodeBlock(resp.content)
  if cmd.isNone:
    if not cfg.hideProcess:
      styleSeparator(sk, DIV_SECTION)
    styleResult(sk, resp.content, binDir,
      extDisplay, false)
    implHandleCacheOutcome(cc, query, "",
      resp.content, cfg, key, sk)
    if cfg.log:
      logExecution(query, "(none)",
        resp.content, 0, cfg.logMaxEntries)
    return

  var command = cmd.get
  if not cfg.hideProcess:
    styleCommand(sk, "command", command)

  command = implSafetyCheck(
    command, query, info, cfg, key, sk,
    effectivePattern)

  if not cfg.hideProcess:
    styleSeparator(sk, DIV_WARN)
    styleProgress(sk, "executing...")
  let execRes = executeCommand(
    command, shell, info.binDir)

  if not cfg.hideProcess:
    styleSeparator(sk, DIV_SECTION)
  var finalOutput = execRes.output.strip()
  if finalOutput.len > 0:
    styleResult(sk, finalOutput, info.binDir,
      extDisplay, false)
  elif execRes.exitCode != 0:
    finalOutput =
      fmt"command exited with code " &
      fmt"{execRes.exitCode}"
    styleError(sk, finalOutput)

  implHandleCacheOutcome(cc, query, command,
    finalOutput, cfg, key, sk)

  if cfg.log:
    logExecution(query, command,
      execRes.output, execRes.exitCode,
      cfg.logMaxEntries)

  if execRes.exitCode != 0:
    quit(execRes.exitCode)

# ---------------------------------------------------------------------------
# Private helpers — agent loop flow
# ---------------------------------------------------------------------------

## Handles a query in agent (non-instance) mode: a multi-round
## loop where the LLM can execute intermediate commands before
## producing a final answer.
##
## :param query: The user query.
## :param cfg: The effective configuration.
## :param key: The API key.
## :param sk: The active output style.
## :param binDir: Bundled bin directory.
## :param extDisplay: External display enabled flag.
## :param shell: The effective shell.
## :param info: System information snapshot.
## :param effectivePattern: Forbidden-command regex.
## :param cc: Cache context with hashes and seen state.
proc implAgentFlow(
  query: string,
  cfg: Config,
  key: string,
  sk: StyleKind,
  binDir: string,
  extDisplay: bool,
  shell: string,
  info: SysInfo,
  effectivePattern: string,
  cc: CacheContext
) =
  let maxRounds =
    if cfg.maxRounds > 0: cfg.maxRounds
    else: high(int)

  let patternOpt =
    if effectivePattern.len > 0:
      some(effectivePattern)
    else:
      none(string)

  var messages = buildAgentInitMessages(
    info, query, shell, cfg.systemPrompt,
    patternOpt, cfg.maxRounds)

  var finalOutput = ""
  var lastCommand = ""
  var lastExitCode = 0
  var roundsUsed = 0
  var terminated = false

  for round in 1 .. maxRounds:
    roundsUsed = round
    if not cfg.hideProcess:
      styleSeparator(sk, DIV_THIN)
      styleRound(sk, round, cfg.maxRounds)

    let resp = implLlmCall(
      messages, cfg, key, sk)
    var parsed = extractAgentAction(resp.content)

    if parsed.action == aaContinue and
        round >= maxRounds:
      parsed = (action: aaFinal,
                command: parsed.command)

    case parsed.action
    of aaContinue:
      let rawCmd = parsed.command.get
      if not cfg.hideProcess:
        styleCommand(sk, "command", rawCmd)

      let checkedCmd = implSafetyCheck(
        rawCmd, query, info, cfg, key, sk,
        effectivePattern)

      if not cfg.hideProcess:
        styleProgress(sk, "executing...")
      let execRes = executeCommand(
        checkedCmd, shell, info.binDir)

      if not cfg.hideProcess:
        let preview =
          if execRes.output.len >
              INTERMEDIATE_OUTPUT_PREVIEW_LEN:
            execRes.output[
              0 ..< INTERMEDIATE_OUTPUT_PREVIEW_LEN
            ] & "..."
          else:
            execRes.output
        if preview.strip().len > 0:
          styleProgress(sk, preview.strip())

      if cfg.log:
        logExecution(
          fmt"{query} (round {round})",
          checkedCmd, execRes.output,
          execRes.exitCode, cfg.logMaxEntries)

      messages = buildAgentContinueMessages(
        messages, resp.content, checkedCmd,
        execRes.output, execRes.exitCode,
        round + 1, cfg.maxRounds)
      lastCommand = checkedCmd
      lastExitCode = execRes.exitCode

    of aaFinal:
      let rawCmd = parsed.command.get
      if not cfg.hideProcess:
        styleCommand(sk, "command", rawCmd)

      let checkedCmd = implSafetyCheck(
        rawCmd, query, info, cfg, key, sk,
        effectivePattern)

      if not cfg.hideProcess:
        styleSeparator(sk, DIV_WARN)
        styleProgress(sk, "executing...")
      let execRes = executeCommand(
        checkedCmd, shell, info.binDir)

      lastCommand = checkedCmd
      lastExitCode = execRes.exitCode
      finalOutput = execRes.output.strip()

      if not cfg.hideProcess:
        styleSeparator(sk, DIV_SECTION)
      if finalOutput.len > 0:
        styleResult(sk, finalOutput, info.binDir,
          extDisplay, false)
      elif execRes.exitCode != 0:
        finalOutput =
          fmt"command exited with code " &
          fmt"{execRes.exitCode}"
        styleError(sk, finalOutput)

      if cfg.log:
        logExecution(query, checkedCmd,
          execRes.output, execRes.exitCode,
          cfg.logMaxEntries)

      terminated = true
      break

    of aaInterpret:
      let rawCmd = parsed.command.get
      if not cfg.hideProcess:
        styleCommand(sk, "command", rawCmd)

      let checkedCmd = implSafetyCheck(
        rawCmd, query, info, cfg, key, sk,
        effectivePattern)

      if not cfg.hideProcess:
        styleSeparator(sk, DIV_WARN)
        styleProgress(sk, "executing...")
      let execRes = executeCommand(
        checkedCmd, shell, info.binDir)

      lastCommand = checkedCmd
      lastExitCode = execRes.exitCode

      if execRes.exitCode != 0 and
          execRes.output.strip().len == 0:
        finalOutput =
          fmt"command exited with code " &
          fmt"{execRes.exitCode}"
        if not cfg.hideProcess:
          styleSeparator(sk, DIV_SECTION)
        styleError(sk, finalOutput)
      else:
        if not cfg.hideProcess:
          styleProgress(sk, "interpreting...")
        let interpretMsgs = buildInterpretMessages(
          query, checkedCmd, execRes.output)
        let interpretResp = implLlmCall(
          interpretMsgs, cfg, key, sk)
        finalOutput = interpretResp.content
        if not cfg.hideProcess:
          styleSeparator(sk, DIV_SECTION)
        styleResult(sk, finalOutput, info.binDir,
          extDisplay, true)

      if cfg.log:
        logExecution(query, checkedCmd,
          execRes.output, execRes.exitCode,
          cfg.logMaxEntries)

      terminated = true
      break

    of aaAnswer:
      finalOutput = resp.content.strip()
      lastCommand = ""
      lastExitCode = 0

      if not cfg.hideProcess:
        styleSeparator(sk, DIV_SECTION)
      styleResult(sk, finalOutput, info.binDir,
        extDisplay, false)

      if cfg.log:
        logExecution(query, "(none)",
          finalOutput, 0, cfg.logMaxEntries)

      terminated = true
      break

  if not terminated:
    if finalOutput.len == 0:
      finalOutput = "(no result after " &
        fmt"{roundsUsed} rounds)"
      styleError(sk, finalOutput)

  # Cache decision (deferred).
  implHandleCacheOutcome(cc, query, lastCommand,
    finalOutput, cfg, key, sk)

  if lastExitCode != 0:
    quit(lastExitCode)

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
  let (sk, _) = implLoadStyle(cfg)
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
        styleKeyValue(sk, "key",
          "set (encrypted storage, " &
          "value cannot be retrieved)")
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
    of "max-rounds":
      styleKeyValue(sk, "max-rounds",
        formatIntOrDisable(cfg.maxRounds))
    of "command-pattern":
      let pat =
        if cfg.commandPattern.isNone:
          DEFAULT_COMMAND_PATTERN &
            " (default: built-in)"
        elif cfg.commandPattern.get.len == 0:
          "(disabled)"
        else:
          cfg.commandPattern.get
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
    of "cache-trigger-threshold":
      styleKeyValue(sk,
        "cache-trigger-threshold",
        formatIntOrDisable(cfg.cacheTriggerThreshold))
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
    styleKeyValue(sk, "name",    APP_NAME)
    styleKeyValue(sk, "version", APP_VERSION)
    styleKeyValue(sk, "author",  APP_AUTHOR)
    styleKeyValue(sk, "intro",   APP_INTRO)
    styleKeyValue(sk, "license", APP_LICENSE)
    styleKeyValue(sk, "github",  APP_GITHUB)
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
      fmt"unknown option '{args[0]}' " &
      "for 'get get'")

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

## Handles a natural-language query by dispatching to instance
## or agent flow based on configuration.
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

  if not cfg.hideProcess:
    styleExternalDisplayCheck(
      sk, extDisplay, binDir)
    implWarnIfWeakModel(cfg.model, sk)

  let shell = implEffectiveShell(cfg)
  let cwd = getCurrentDir()
  let effectivePattern = implEffectivePattern(
    cfg, sk, cfg.hideProcess)

  # Build cache context.  When cache is disabled, all fields
  # remain at zero/false and no cache logic is executed.
  let noCache = ov.noCache
  let useCache = cfg.cache and (not noCache)
  let forceCache =
    ov.forceCache.isSome and ov.forceCache.get
  if (not cfg.cache) and (not cfg.hideProcess):
    styleWarning(sk,
      "warning: cache is disabled in config; " &
      "all cache logic is bypassed")
  var cc = CacheContext(
    useCache: useCache,
    wasSeen: false,
    queryHash: "",
    globalHash: "",
    contextHash: "")

  if useCache:
    cc.queryHash = computeQueryHash(query)
    cc.globalHash = computeGlobalHash(
      query, shell, cfg.model, cfg.instance,
      cfg.systemPrompt, cfg.commandPattern)
    cc.contextHash = computeContextHash(
      query, cwd, shell, cfg.model,
      cfg.instance, cfg.systemPrompt,
      cfg.commandPattern)

    let store = loadCache()
    let hit = lookupCache(
      store, cc.globalHash, cc.contextHash,
      cfg.cacheExpiry)
    if hit.isSome:
      case hit.get.cacheMode
      of cmResult:
        if not cfg.hideProcess:
          let label =
            if hit.get.scope == csGlobal:
              "(cached: global result)"
            else:
              "(cached: context result)"
          styleProgress(sk, label)
        styleResult(sk, hit.get.output,
          binDir, extDisplay)
        return
      of cmCommand:
        if not cfg.hideProcess:
          let label =
            if hit.get.scope == csGlobal:
              "(cached: global command)"
            else:
              "(cached: context command)"
          styleProgress(sk, label)
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

    # Determine whether cache decision should trigger.
    # Decision runs when:
    #   - --cache is present, or
    #   - threshold is disabled (<= 0), or
    #   - seen count has reached the configured threshold.
    let seenCount = getSeenCount(
      store, cc.queryHash, cfg.cacheExpiry)
    let threshold = cfg.cacheTriggerThreshold
    cc.wasSeen =
      forceCache or
      threshold <= 0 or
      seenCount >= threshold

  # Collect system information.
  if not cfg.hideProcess:
    styleProgress(sk,
      "collecting system info...")
  let info = collectSysInfo(shell)

  if cfg.instance:
    implInstanceFlow(query, cfg, key.get, sk,
      binDir, extDisplay, shell, info,
      effectivePattern, cc)
  else:
    implAgentFlow(query, cfg, key.get, sk,
      binDir, extDisplay, shell, info,
      effectivePattern, cc)

# ---------------------------------------------------------------------------
# Private helpers — top-level dispatcher
# ---------------------------------------------------------------------------

## Top-level CLI dispatcher.
proc implMain() =
  initAnsi()

  let cfgForWarn = loadConfig()

  let envWarning = checkEnvironment()
  if envWarning.len > 0 and
      not cfgForWarn.hideProcess:
    styleWarning(
      toStyleKind(cfgForWarn.vivid), envWarning)

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
  try:
    let cfg = loadConfig()
    let sk = toStyleKind(cfg.vivid)
    stderr.write("\n")
    styleProgress(sk, "interrupted.")
  except CatchableError:
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
