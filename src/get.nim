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

import std/[os, strformat, strutils, options, times]

import cache
import command_policy
import config
import exec
import harness_executor
import harness_prompt
import harness_protocol
import harness_runtime
import harness_types
import llm
import logger
import prompt
import style
import sysinfo
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Maximum characters of intermediate output shown to the user
## during continuation turns (when hideProcess is false).
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
  --protocol <kind>            auto, native, or legacy
  --hide-process               suppress intermediate output
  --no-hide-process            show intermediate output
  --system-proxy               prefer OS system proxy settings
  --no-system-proxy            use terminal proxy environment only
  --vivid                      enable vivid output mode
  --no-vivid                   plain text output mode
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
                       (auto/native/legacy, default: auto)
  timeout            request timeout in seconds
                       (integer or false, default: 300)
  max-token          max tokens per request
                       (integer or false, default: 20480)
  max-rounds         hard model-turn limit
                       (positive integer, default: 3)
  max-tool-calls     max tool calls per run
                       (integer, default: 8)
  max-parallel       max concurrent tool calls
                       (integer, default: 4)
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

## Uses deterministic sampling for Qwen tool orchestration.  Qwen-compatible
## serving stacks otherwise commonly default to a non-zero temperature, which
## makes identical local-system queries vary between a valid tool call and a
## fabricated tool name.  Other providers retain their own defaults because
## some reasoning APIs reject an explicit temperature field.
func implSamplingTemperature(model: string): Option[float] =
  if toLowerAscii(model).contains("qwen"):
    result = some(0.0)
  else:
    result = none(float)

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
    maxTokens: cfg.maxToken,
    temperature: implSamplingTemperature(cfg.model)
  )
  result = sendLlmRequest(
    req,
    cfg.url,
    key,
    timeoutSec = cfg.timeout,
    hideProcess = cfg.hideProcess,
    sk = sk,
    preferSystemProxy = cfg.systemProxy
  )

# ---------------------------------------------------------------------------
# Private helpers — shell and pattern resolution
# ---------------------------------------------------------------------------

## Resolves the effective shell.
##
## :param cfg: The loaded configuration.
## :returns: A non-empty shell name.
func implEffectiveShell(cfg: Config): string =
  result =
    if cfg.shell.len > 0: cfg.shell
    else: defaultShell()
  if not isSupportedShell(result):
    raise newException(GetError,
      "configured shell is outside the supported trusted set")

## Resolves the optional supplemental forbidden-command pattern.
##
## :param cfg: The loaded configuration.
## :returns: The pattern string to use.
proc implEffectivePattern(cfg: Config): string =
  if cfg.commandPattern.isSome:
    let pat = cfg.commandPattern.get
    if pat.len == 0:
      return ""
    return pat
  # v3's syntax-aware mandatory policy is authoritative by default. The old
  # whole-command keyword regex confused dangerous executable names with
  # ordinary search text and is now opt-in only.
  result = DEFAULT_COMMAND_PATTERN

# ---------------------------------------------------------------------------
# Private helpers — safety checks
# ---------------------------------------------------------------------------

## Enforces mandatory and user-configured command policy layers.
##
## :param command: Model-proposed, revised, or cached command.
## :param query: Original query used for rejection logging.
## :param cfg: Effective runtime configuration.
## :param sk: Active terminal style.
## :param effectivePattern: Optional supplemental forbidden regex.
proc implEnforceCommandPolicy(
  command: string,
  query: string,
  cfg: Config,
  sk: StyleKind,
  effectivePattern: string
) =
  let baseline = checkReadOnlyCommand(
    command, implEffectiveShell(cfg))
  if not baseline.allowed:
    styleError(sk,
      "error: read-only policy rejected command — " &
      baseline.reason)
    if cfg.log:
      logExecution(
        query,
        command,
        "rejected by mandatory read-only policy: " &
          baseline.reason,
        1,
        cfg.logMaxEntries
      )
    quit(1)
  if effectivePattern.len > 0 and
      not validateCommandPattern(command, effectivePattern):
    styleError(sk,
      "error: command matches forbidden " &
      "pattern — rejected")
    if cfg.log:
      logExecution(query, command,
        "rejected by forbidden pattern", 1,
        cfg.logMaxEntries)
    quit(1)

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
  let verdictWords = stripped.splitWhitespace(maxsplit = 1)
  let verdict = if verdictWords.len > 0:
      verdictWords[0].strip(
        chars = {'`', '*', '_', '.', ',', ':', ';', '!', '?'})
    else:
      ""
  if cmpIgnoreCase(verdict, "UNSAFE") == 0:
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
  implEnforceCommandPolicy(
    command, query, cfg, sk, effectivePattern)
  var checked = command
  if cfg.doubleCheck:
    checked = implDoubleCheck(
      command, query, info, cfg, key, sk)
    if checked != command and not cfg.hideProcess:
      styleCommand(sk, "revised command", checked)
    implEnforceCommandPolicy(
      checked, query, cfg, sk, effectivePattern)
  if cfg.manualConfirm:
    let showCmd = cfg.hideProcess
    if not confirmExecution(checked, sk, showCmd):
      styleProgress(sk, "aborted.")
      quit(0)
  result = checked

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

# ---------------------------------------------------------------------------
# Private helpers — v3 unified harness flow
# ---------------------------------------------------------------------------

## Builds enforced run limits from v3 configuration.
##
## :param cfg: Effective runtime configuration.
## :param kind: Selected harness strategy.
## :returns: A positive turn/tool/parallel budget and command bounds.
func implHarnessBudget(cfg: Config, kind: HarnessKind): RunBudget =
  let defaults = defaultRunBudget(kind)
  result = RunBudget(
    maxTurns:
      if kind == hkDirect: 1
      elif cfg.maxRounds > 0: cfg.maxRounds
      else: defaults.maxTurns,
    maxToolCalls:
      if kind == hkDirect: 1
      elif cfg.maxToolCalls > 0: cfg.maxToolCalls
      else: defaults.maxToolCalls,
    maxParallel:
      if kind in {hkDirect, hkLoop}: 1
      elif cfg.maxParallel > 0: cfg.maxParallel
      else: defaults.maxParallel,
    commandTimeoutSec: max(cfg.commandTimeout, 0),
    maxOutputBytes: max(cfg.maxOutputBytes, 0)
  )

## Detects provider errors that specifically indicate unsupported tool fields.
##
## :param message: Sanitized LLM API error message.
## :returns: True only for compatible client errors mentioning tool features.
func implCanFallbackTools(message: string): bool =
  let lower = toLowerAscii(message)
  let isClientError =
    lower.contains("http 400") or
    lower.contains("http 404") or
    lower.contains("http 422")
  let namesToolField =
    lower.contains("tool") or
    lower.contains("function")
  result = isClientError and namesToolField

## Stores a deterministic v3 cache entry without another model request.
##
## Successful single-command raw results cache the context-specific command so
## future hits re-run it through the safety gate. Explicit ``--cache`` also
## permits a final text result to be stored. Multi-step runs are not guessed.
##
## :param context: Precomputed versioned cache hashes.
## :param query: Original user query.
## :param value: Completed harness result.
## :param forceResult: Whether the user explicitly requested caching.
## :param cfg: Effective cache limits.
## :param sk: Active terminal style.
proc implStoreHarnessCache(
  context: CacheContext,
  query: string,
  value: HarnessResult,
  forceResult: bool,
  cfg: Config,
  sk: StyleKind
) =
  if not context.useCache or value.exitCode != 0:
    return
  var entry = CacheEntry()
  var shouldStore = false
  if value.termination == htRawToolResult and
      value.observations.len == 1 and
      not value.observations[0].timedOut and
      not value.observations[0].truncated:
    entry = CacheEntry(
      hash: context.contextHash,
      scope: csContext,
      cacheMode: cmCommand,
      query: query,
      command: value.observations[0].command,
      output: "",
      timestamp: epochTime().int64
    )
    shouldStore = true
  elif forceResult and value.output.len > 0:
    entry = CacheEntry(
      hash: context.contextHash,
      scope: csContext,
      cacheMode: cmResult,
      query: query,
      command: "",
      output: value.output,
      timestamp: epochTime().int64
    )
    shouldStore = true
  if not shouldStore:
    return
  try:
    putCacheEntry(
      entry,
      cfg.cacheMaxEntries,
      cfg.cacheExpiry
    )
  except CacheError as error:
    if not cfg.hideProcess:
      styleWarning(sk,
        "warning: cache write skipped — " & error.msg)
    return
  if not cfg.hideProcess:
    let label =
      if entry.cacheMode == cmCommand:
        "cache: context command stored"
      else:
        "cache: context result stored"
    styleProgress(sk, label)

## Runs one query through the unified v3 harness.
##
## :param query: Original natural-language request.
## :param cfg: Effective configuration after CLI overrides.
## :param key: API bearer token.
## :param sk: Active terminal style.
## :param shell: Effective shell executable.
## :param info: Fast local environment snapshot.
## :param effectivePattern: Active forbidden-command regex.
## :param cacheContext: Versioned cache state for deterministic storage.
## :param forceCache: Whether the user explicitly requested result caching.
## :param toolsDisabled: Whether this request explicitly forbids tool use.
proc implHarnessFlow(
  query: string,
  cfg: Config,
  key: string,
  sk: StyleKind,
  shell: string,
  info: SysInfo,
  effectivePattern: string,
  cacheContext: CacheContext,
  forceCache: bool,
  toolsDisabled: bool
) =
  let kind = parseHarnessKind(cfg.harness)
  let protocol = parseToolProtocolKind(cfg.toolProtocol)
  let budget = implHarnessBudget(cfg, kind)
  let initialMessages = buildHarnessMessages(
    info,
    query,
    shell,
    kind,
    budget,
    cfg.systemPrompt,
    cfg.commandPattern,
    toolsDisabled
  )
  let session = newLlmSession(
    cfg.url,
    key,
    timeoutSec = cfg.timeout,
    hideProcess = cfg.hideProcess,
    sk = sk,
    preferSystemProxy = cfg.systemProxy
  )
  defer:
    closeLlmSession(session)

  var nativeUnavailable = protocol == tpkLegacy
  let modelTurn: ModelTurnProc = proc(
    messages: seq[LlmMessage],
    enableNativeTools: bool,
    allowParallel: bool
  ): LlmResponse =
    let useNative =
      enableNativeTools and not nativeUnavailable
    var request = LlmRequest(
      model: cfg.model,
      messages: messages,
      maxTokens: cfg.maxToken,
      temperature: implSamplingTemperature(cfg.model),
      tools:
        if useNative: @[shellToolDefinition()]
        else: @[],
      parallelToolCalls: useNative and allowParallel
    )
    try:
      return sendLlmRequest(
        session,
        request,
        spinnerLabel = "requesting"
      )
    except LlmApiError as error:
      if protocol != tpkAuto or not useNative or
          not implCanFallbackTools(error.msg):
        raise
      nativeUnavailable = true
      if not cfg.hideProcess:
        styleWarning(sk,
          "warning: provider rejected native tools; " &
          "using structured JSON compatibility")
      request.tools = @[]
      request.parallelToolCalls = false
      result = sendLlmRequest(
        session,
        request,
        spinnerLabel = "retrying without native tools"
      )
      result.providerRequests += 1

  var priorToolObservations: seq[ToolObservation] = @[]
  let runTools: ToolBatchProc = proc(
    calls: seq[ToolCall],
    maxParallel: int
  ): seq[ToolObservation] =
    result = newSeq[ToolObservation](calls.len)
    var authorized: seq[ToolCall] = @[]
    var authorizedIndexes: seq[int] = @[]
    var rejectedCount = 0
    for index, call in calls:
      if call.toolName != READ_ONLY_SHELL_TOOL or call.command.strip().len == 0:
        rejectedCount += 1
        let detail =
          if call.toolName != READ_ONLY_SHELL_TOOL:
            "provider proposed an unsupported tool; no command was executed. " &
              "Use run_readonly_shell with one read-only command."
          else:
            "provider proposed invalid tool arguments; no command was " &
              "executed. Use run_readonly_shell with a non-empty command."
        result[index] = ToolObservation(
          callId: call.id,
          toolName: call.toolName,
          command: call.command,
          output: detail,
          exitCode: 126,
          elapsedMs: 0,
          timedOut: false,
          truncated: false,
          policyRejected: true
        )
        if cfg.log:
          logExecution(
            query,
            call.command,
            detail,
            126,
            cfg.logMaxEntries
          )
        continue
      var reused = false
      for previous in priorToolObservations:
        if previous.toolName == call.toolName and
            previous.command.strip() == call.command.strip():
          result[index] = previous
          result[index].callId = call.id
          result[index].elapsedMs = 0
          result[index].output =
            if previous.policyRejected:
              "duplicate rejected proposal skipped; no command was executed. " &
                "Use a different supported read-only reader. Earlier " &
                "rejection: " & previous.output
            elif previous.timedOut or previous.truncated:
              "duplicate resource-limited reader skipped; no command was " &
                "executed. Answer from existing evidence or use one cheaper " &
                "reader."
            else:
              "duplicate reader skipped; no command was executed. Use the " &
                "earlier observation for this exact command and answer now."
          reused = true
          break
      if reused:
        continue
      if not cfg.hideProcess:
        styleCommand(sk, "command", call.command)
      let baseline = checkReadOnlyCommand(
        call.command, shell)
      if not baseline.allowed:
        rejectedCount += 1
        let detail =
          "read-only policy rejected this command before execution: " &
            baseline.reason &
            ". Propose a simpler allowlisted read-only command."
        result[index] = ToolObservation(
          callId: call.id,
          toolName: call.toolName,
          command: call.command,
          output: detail,
          exitCode: 126,
          elapsedMs: 0,
          timedOut: false,
          truncated: false,
          policyRejected: true
        )
        if cfg.log:
          logExecution(
            query,
            call.command,
            detail,
            126,
            cfg.logMaxEntries
          )
      else:
        var checked = call
        checked.command = implSafetyCheck(
          checked.command,
          query,
          info,
          cfg,
          key,
          sk,
          effectivePattern
        )
        authorizedIndexes.add(index)
        authorized.add(checked)
    if rejectedCount > 0 and not cfg.hideProcess:
      if authorized.len == 0:
        styleWarning(sk,
          "warning: read-only policy rejected the proposed tool batch; " &
            "requesting a safe revision")
      else:
        styleWarning(sk,
          fmt"warning: read-only policy rejected {rejectedCount} unsafe " &
            fmt"call(s); executing {authorized.len} approved call(s)")
    if authorized.len == 0:
      for observation in result:
        priorToolObservations.add(observation)
      return
    if not cfg.hideProcess:
      styleProgress(sk,
        if authorized.len == 1:
          "executing..."
        else:
          fmt"executing {authorized.len} calls " &
            fmt"(parallelism {maxParallel})...")
    let executed = executeToolBatch(
      authorized,
      shell,
      budget,
      maxParallel
    )
    for position, observation in executed:
      result[authorizedIndexes[position]] = observation
      if cfg.log:
        logExecution(
          query,
          observation.command,
          observation.output,
          observation.exitCode,
          cfg.logMaxEntries
        )
      if not cfg.hideProcess and
          authorized[position].resultMode == trmContinue:
        let preview =
          if observation.output.len > INTERMEDIATE_OUTPUT_PREVIEW_LEN:
            observation.output[0 ..< INTERMEDIATE_OUTPUT_PREVIEW_LEN] & "..."
          else:
            observation.output
        if preview.strip().len > 0:
          styleProgress(sk, preview.strip())
    for observation in result:
      priorToolObservations.add(observation)

  if not cfg.hideProcess:
    styleSeparator(sk, DIV_THIN)
  let value = runHarness(
    initialMessages,
    HarnessRunOptions(
      kind: kind,
      protocol: protocol,
      budget: budget,
      toolsDisabled: toolsDisabled,
      eventSink: nil
    ),
    modelTurn,
    runTools
  )
  if not cfg.hideProcess:
    styleSeparator(sk, DIV_SECTION)
  if value.output.len > 0:
    if value.exitCode == 0:
      styleResult(sk, value.output)
    else:
      styleError(sk, value.output)
  if cfg.log and value.observations.len == 0:
    logExecution(
      query,
      "(none)",
      value.output,
      value.exitCode,
      cfg.logMaxEntries
    )
  implStoreHarnessCache(
    cacheContext,
    query,
    value,
    forceCache,
    cfg,
    sk
  )
  if value.exitCode != 0:
    implQuitWithCode(value.exitCode)

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
    temperature: implSamplingTemperature(cfg.model)
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

## Handles a natural-language query through the configured unified harness.
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

  if not cfg.hideProcess:
    implWarnIfWeakModel(cfg.model, sk)

  let shell = implEffectiveShell(cfg)
  let cwd = getCurrentDir()
  let info = collectFastSysInfo(shell)
  let effectivePattern = implEffectivePattern(cfg)
  let toolsDisabled = explicitlyDisablesTools(query)

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
    globalHash: "",
    contextHash: "")

  if useCache:
    cc.globalHash = computeGlobalHashV3(
      query, shell, cfg.model, cfg.url, cfg.harness,
      cfg.toolProtocol,
      cfg.systemPrompt, cfg.commandPattern)
    cc.contextHash = computeContextHashV3(
      query, cwd, shell, cfg.model,
      cfg.url, cfg.harness, cfg.toolProtocol,
      cfg.systemPrompt,
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
        styleResult(sk, hit.get.output)
        return
      of cmCommand:
        # Commands written by an older prompt cannot bypass an explicit
        # text-only request. Ignore that hit and ask without tool access.
        if not toolsDisabled:
          if not cfg.hideProcess:
            let label =
              if hit.get.scope == csGlobal:
                "(cached: global command)"
              else:
                "(cached: context command)"
            styleProgress(sk, label)
            styleCommand(sk, "command",
              hit.get.command)
          let checkedCommand = implSafetyCheck(
            hit.get.command,
            query,
            info,
            cfg,
            key.get,
            sk,
            effectivePattern
          )
          let execRes = executeCommandBounded(
            checkedCommand,
            shell,
            max(cfg.commandTimeout, 0),
            max(cfg.maxOutputBytes, 0),
            readOnlySandbox = true
          )
          let output = execRes.output.strip()
          if output.len > 0:
            styleResult(sk, output)
          if execRes.timedOut:
            styleError(sk, "command timed out")
          elif execRes.truncated:
            styleError(sk,
              "output truncated at configured limit")
          elif execRes.exitCode != 0:
            styleError(sk,
              fmt"command exited with code " &
              fmt"{execRes.exitCode}")
          if cfg.log:
            logExecution(query, checkedCommand,
              execRes.output, execRes.exitCode,
              cfg.logMaxEntries)
          if execRes.timedOut:
            quit(124)
          elif execRes.truncated:
            quit(1)
          elif execRes.exitCode != 0:
            implQuitWithCode(execRes.exitCode)
          return

  implHarnessFlow(
    query,
    cfg,
    key.get,
    sk,
    shell,
    info,
    effectivePattern,
    cc,
    forceCache,
    toolsDisabled
  )

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
