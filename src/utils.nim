## Shared constants, path helpers, types, and utility functions for
## the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-06-06
## :File: utils.nim
## :License: AGPL-3.0
##
## This module provides application-wide constants such as version,
## license, and GitHub URL; path resolution for configuration
## directories and files; shared domain types (GetError,
## LlmMessage, AgentAction); forbidden-command-pattern
## validation and safety checking; model strength verification;
## and general-purpose string utilities consumed by every other
## module.

{.experimental: "strictFuncs".}

import std/[os, options, strformat, strutils]

import regex

# ---------------------------------------------------------------------------
# Constants — application identity
# ---------------------------------------------------------------------------

## The name of the application.
const APP_NAME* = "get"

## The version string, kept in sync with get.nimble.
const APP_VERSION* = "2.0"

## The author of the application.
const APP_AUTHOR* = "WaterRun"

## One-line introduction shown by ``get get --intro``.
const APP_INTRO* = "get anything from your computer"

## SPDX license identifier.
const APP_LICENSE* = "AGPL-3.0"

## Canonical GitHub repository URL.
const APP_GITHUB* = "https://github.com/Water-Run/get"

# ---------------------------------------------------------------------------
# Constants — file names and paths
# ---------------------------------------------------------------------------

## Name of the configuration JSON file.
const CONFIG_FILE_NAME* = "config.json"

## Name of the key storage file.
const KEY_FILE_NAME* = "key"

## Name of the append-only log file.
const LOG_FILE_NAME* = "get.log"

## Name of the cache JSON file.
const CACHE_FILE_NAME* = "cache.json"

# ---------------------------------------------------------------------------
# Constants — user-facing messages
# ---------------------------------------------------------------------------

## Hint displayed after usage errors to direct users to the help
## command for detailed information.
const HELP_HINT* = "Run 'get help' for usage information."

## Warning text emitted when the configured model is not
## recognised as a known high-performance model.
const MODEL_STRENGTH_WARNING* =
  "warning: model is not recognized as a known " &
  "high-performance model.\n" &
  "For operations that execute commands on your " &
  "device, a sufficiently capable model is the " &
  "foundation of safety.\n" &
  "Consider using a known strong model (e.g. " &
  "GPT-5+, Claude Opus 4.5+/Sonnet 4.6+, " &
  "Gemini 3+, Qwen 3.6+, MiniMax M2.7+, " &
  "MiMo v2+, Kimi K2.5+, GLM-5+, DeepSeek V4+, " &
  "Grok 4.2+)."

# ---------------------------------------------------------------------------
# Constants — safety
# ---------------------------------------------------------------------------

## Default forbidden command pattern regex.  Commands matching
## this pattern are rejected before execution.  The pattern uses
## ``\b`` word boundaries to avoid false positives in paths or
## arguments.
##
## ``md`` and ``rd`` are intentionally omitted: they are aliases
## of ``mkdir``/``rmdir`` (already covered), but ``\bmd\b`` and
## ``\brd\b`` produce false positives on file extensions such as
## ``README.md``.  ``format`` is omitted because ``\bformat\b``
## matches the ubiquitous ``--format`` flag used by many tools.
##
## Users may override this via ``get set command-pattern``.
## Pass an empty string (``get set command-pattern ""``) to
## disable the pattern entirely, or omit the value
## (``get set command-pattern``) to restore this default.
const DEFAULT_COMMAND_PATTERN* =
  "\\b(rm|rmdir|del|erase" &
  "|mv|move|cp|copy" &
  "|mkdir|touch" &
  "|chmod|chown|chgrp" &
  "|mkfs|dd|fdisk" &
  "|kill|killall|pkill" &
  "|shutdown|reboot|halt|poweroff" &
  "|passwd|useradd|userdel|usermod" &
  "|groupadd|groupdel" &
  "|Set-Content|New-Item|Remove-Item" &
  "|Move-Item|Rename-Item" &
  "|Clear-Content|Add-Content)\\b"

## Core dangerous command names used to validate whether a custom
## command-pattern adequately covers common destructive
## operations.  When a user sets a custom pattern that fails to
## match any of these names, a safety warning is emitted.
const DANGEROUS_COMMAND_NAMES* = [
  "rm", "rmdir", "del", "mv", "cp",
  "chmod", "mkfs", "dd", "kill",
  "shutdown", "reboot", "Remove-Item"]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Base exception type for all recoverable errors in the get
## tool.  Every domain-specific error should inherit from this
## type so that the top-level CLI dispatcher can catch and
## display them uniformly.
type
  GetError* = object of CatchableError

## Represents a single message in an LLM conversation.  This
## type is defined here rather than in the llm module so that
## both the prompt builder and the LLM client can reference it
## without circular imports.
type
  LlmMessage* = object
    role*: string     ## "system", "user", or "assistant".
    content*: string  ## Message content text.

## Describes the action the LLM chose in the agent loop
## protocol.  Used by the prompt parser and the main dispatcher
## to determine the next step in the multi-round agent flow.
type
  AgentAction* = enum
    aaContinue  ## Intermediate cmd — execute and return output.
    aaFinal     ## Terminal cmd — execute and show directly.
    aaInterpret ## Terminal cmd — execute then summarise.
    aaAnswer    ## Direct text answer, no command to execute.

# ---------------------------------------------------------------------------
# Public API — path helpers
# ---------------------------------------------------------------------------

## Returns the absolute path to the application configuration
## directory and creates it if it does not yet exist.
##
## :returns: Absolute path to the configuration directory.
##
## .. code-block:: nim
##   runnableExamples:
##     let d = getAppConfigDir()
##     assert d.len > 0
proc getAppConfigDir*(): string =
  result = getConfigDir() / APP_NAME
  if not dirExists(result):
    createDir(result)

## Returns the absolute path to the configuration JSON file.
##
## :returns: Absolute path ending with the config file name.
##
## .. code-block:: nim
##   runnableExamples:
##     let p = getConfigFilePath()
##     assert p.endsWith("config.json")
proc getConfigFilePath*(): string =
  result = getAppConfigDir() / CONFIG_FILE_NAME

## Returns the absolute path to the key storage file.
##
## :returns: Absolute path ending with the key file name.
##
## .. code-block:: nim
##   runnableExamples:
##     let p = getKeyFilePath()
##     assert p.endsWith("key")
proc getKeyFilePath*(): string =
  result = getAppConfigDir() / KEY_FILE_NAME

## Returns the absolute path to the append-only log file.
##
## :returns: Absolute path ending with the log file name.
##
## .. code-block:: nim
##   runnableExamples:
##     let p = getLogFilePath()
##     assert p.endsWith("get.log")
proc getLogFilePath*(): string =
  result = getAppConfigDir() / LOG_FILE_NAME

## Returns the absolute path to the cache JSON file.
##
## :returns: Absolute path ending with the cache file name.
##
## .. code-block:: nim
##   runnableExamples:
##     let p = getCacheFilePath()
##     assert p.endsWith("cache.json")
proc getCacheFilePath*(): string =
  result = getAppConfigDir() / CACHE_FILE_NAME

# ---------------------------------------------------------------------------
# Public API — string utilities
# ---------------------------------------------------------------------------

## Replaces every character in a string with an asterisk.
## Returns an empty string when the input is empty.
##
## :param s: The string to mask.
## :returns: A string of asterisks with the same length.
##
## .. code-block:: nim
##   runnableExamples:
##     assert maskString("hello") == "*****"
##     assert maskString("") == ""
##     assert maskString("x") == "*"
func maskString*(s: string): string =
  result = repeat('*', s.len)

## Returns the platform default shell name.  Used as a fallback
## when the configured shell value is empty.
##
## :returns: "powershell" on Windows, "bash" everywhere else.
##
## .. code-block:: nim
##   runnableExamples:
##     assert defaultShell().len > 0
func defaultShell*(): string =
  when defined(windows):
    result = "powershell"
  elif defined(macosx):
    result = "zsh"
  else:
    result = "bash"

## Extracts the content of the first fenced code block from a
## Markdown-formatted string.  Recognises opening fences with
## optional language tags (e.g. `` ```sh ``, `` ```bash ``,
## `` ```powershell ``, or bare `` ``` ``).
##
## :param text: The full text that may contain fenced blocks.
## :returns: The trimmed content of the first code block, or
##           none when no code block is found.
##
## .. code-block:: nim
##   runnableExamples:
##     import std/options
##     let t = "hello\n```sh\nls -la\n```\nbye"
##     assert extractCodeBlock(t) == some("ls -la")
##     assert extractCodeBlock("no block").isNone
func extractCodeBlock*(text: string): Option[string] =
  let lines = text.splitLines()
  var inBlock = false
  var blockLines: seq[string] = @[]
  for line in lines:
    if not inBlock:
      let stripped = line.strip()
      if stripped.startsWith("```"):
        inBlock = true
        blockLines = @[]
        continue
    else:
      let stripped = line.strip()
      if stripped == "```":
        let content = blockLines.join("\n").strip()
        if content.len > 0:
          return some(content)
        return none(string)
      blockLines.add(line)
  if inBlock and blockLines.len > 0:
    let content = blockLines.join("\n").strip()
    if content.len > 0:
      return some(content)
  result = none(string)

## Extracts the output-mode marker from an LLM response.  The
## model may include ``<!-- DIRECT -->`` or
## ``<!-- INTERPRET -->`` after the code block to indicate
## whether the command output should be shown raw or sent back
## for LLM interpretation.
##
## :param text: The full LLM response text.
## :returns: ``"DIRECT"`` or ``"INTERPRET"``.  Defaults to
##           ``"DIRECT"`` when no marker is found.
##
## .. code-block:: nim
##   runnableExamples:
##     assert extractOutputMode(
##       "```sh\nls\n```\n<!-- DIRECT -->") == "DIRECT"
##     assert extractOutputMode(
##       "```sh\nls\n```\n<!-- INTERPRET -->") ==
##       "INTERPRET"
##     assert extractOutputMode("no marker") == "DIRECT"
func extractOutputMode*(text: string): string =
  let upper = toUpperAscii(text)
  if upper.contains("<!-- INTERPRET -->"):
    return "INTERPRET"
  result = "DIRECT"

## Parses an LLM response from the agent loop and returns the
## intended action together with the extracted command (if any).
##
## Parsing rules:
##   1. If no fenced code block is found → aaAnswer.
##   2. If a code block is found, scan for a marker:
##        <!-- CONTINUE -->  → aaContinue
##        <!-- INTERPRET --> → aaInterpret
##        <!-- FINAL -->     → aaFinal
##   3. When a code block exists but no marker is found the
##      default action is aaFinal (get prefers direct output).
##
## :param text: The full LLM response text.
## :returns: A tuple of (action, optional command).
##
## .. code-block:: nim
##   runnableExamples:
##     import std/options
##     let r1 = extractAgentAction(
##       "```sh\nls -la\n```\n<!-- FINAL -->")
##     assert r1.action == aaFinal
##     assert r1.command == some("ls -la")
##     let r2 = extractAgentAction("Just text")
##     assert r2.action == aaAnswer
##     assert r2.command.isNone
func extractAgentAction*(
  text: string
): tuple[action: AgentAction,
         command: Option[string]] =
  let cmd = extractCodeBlock(text)
  if cmd.isNone:
    return (action: aaAnswer, command: none(string))
  let upper = toUpperAscii(text)
  if upper.contains("<!-- CONTINUE -->"):
    result = (action: aaContinue, command: cmd)
  elif upper.contains("<!-- INTERPRET -->"):
    result = (action: aaInterpret, command: cmd)
  else:
    result = (action: aaFinal, command: cmd)

## Formats an integer option value for display.  Returns "false"
## when the value is zero or negative (disabled), otherwise
## returns the integer as a string.
##
## :param value: The integer option value.
## :returns: "false" or the decimal string representation.
##
## .. code-block:: nim
##   runnableExamples:
##     assert formatIntOrDisable(0) == "false"
##     assert formatIntOrDisable(300) == "300"
func formatIntOrDisable*(value: int): string =
  if value <= 0: "false" else: $value

# ---------------------------------------------------------------------------
# Public API — command pattern validation
# ---------------------------------------------------------------------------

## Validates a command string against a forbidden-command regex
## pattern.  Returns true when the command is allowed (no match).
##
## :param command: The command to validate.
## :param pattern: A forbidden-command regex string.
## :returns: true if the command is allowed.
## :raises: GetError: If the pattern is not a valid regex.
##
## .. code-block:: nim
##   runnableExamples:
##     assert validateCommandPattern(
##       "ls -la", "\\brm\\b")
##     assert not validateCommandPattern(
##       "rm -rf /", "\\brm\\b")
proc validateCommandPattern*(
  command: string,
  pattern: string
): bool =
  try:
    result = not command.contains(re2(pattern))
  except CatchableError:
    raise newException(GetError,
      fmt"invalid command-pattern regex: {pattern}")

## Checks whether a user-provided forbidden-command-pattern
## regex adequately covers common dangerous commands.  Returns a
## warning message listing uncovered commands, or an empty
## string.
##
## :param pattern: The user's forbidden-command regex.
## :returns: Warning text, or empty string if adequate.
##
## .. code-block:: nim
##   runnableExamples:
##     discard checkPatternSafety("^ls")
proc checkPatternSafety*(
  pattern: string
): string =
  if pattern.len == 0:
    return ""
  var uncovered: seq[string] = @[]
  for name in DANGEROUS_COMMAND_NAMES:
    try:
      if not name.contains(re2(pattern)):
        uncovered.add(name)
    except CatchableError:
      discard
  if uncovered.len > 0:
    result =
      "warning: custom command-pattern does " &
      "not block these dangerous commands: " &
      uncovered.join(", ")
  else:
    result = ""

# ---------------------------------------------------------------------------
# Private helpers — model version extraction
# ---------------------------------------------------------------------------

## Normalises a model name for comparison: lowercases and
## replaces underscores with hyphens so that
## ``Claude_Opus_4.6`` and ``claude-opus-4.6`` are treated
## identically.
##
## :param model: Raw model identifier string.
## :returns: The normalised lowercase string.
func implNormaliseModel(model: string): string =
  result = toLowerAscii(model).replace('_', '-')

## Extracts the first version-like number that appears after
## the family prefix in a normalised model name.  Skips common
## separators and an optional ``v`` prefix before the digits.
##
## :param model: Normalised model name.
## :param family: Lowercased family prefix to search for.
## :returns: The extracted version as a float, or 0.0.
func implExtractVersion(
  model: string,
  family: string
): float =
  let idx = model.find(family)
  if idx < 0:
    return 0.0
  var pos = idx + family.len
  # Skip separators and optional 'v' prefix.
  while pos < model.len and
      model[pos] in {'-', '_', ' ', '.', 'v'}:
    pos += 1
  var numStr = ""
  var seenDot = false
  while pos < model.len:
    if model[pos] in {'0' .. '9'}:
      numStr.add(model[pos])
    elif model[pos] == '.' and not seenDot:
      numStr.add('.')
      seenDot = true
    else:
      break
    pos += 1
  if numStr.len > 0:
    try:
      return parseFloat(numStr)
    except ValueError:
      return 0.0
  result = 0.0

## Checks whether any weak-variant keyword is present in the
## normalised model name.  The keyword set is deliberately
## narrow: it covers only tiers that are weak regardless of
## their version number.  ``mini`` and ``flash`` are NOT
## included, because high-version variants such as
## ``gemini-3.5-flash`` are genuinely strong; those families
## are gated by version threshold instead.
##
## :param m: Normalised model name.
## :returns: true when a weak keyword is found.
func implHasWeakKeyword(m: string): bool =
  const weakKeywords = [
    "nano", "lite", "small", "haiku",
    "light", "tiny", "micro", "instant"]
  for w in weakKeywords:
    if m.contains(w):
      return true
  result = false

# ---------------------------------------------------------------------------
# Public API — model strength check
# ---------------------------------------------------------------------------

## Checks whether the configured model name corresponds to a
## known high-performance model suitable for command
## generation.
##
## Recognition is purely family + version-threshold based; no
## hard brand block-list is used.  Thresholds are calibrated
## against current frontier-model rankings (mid-2026):
##
## ===============  =================================
## Family           Minimum strong version
## ===============  =================================
## GPT / Codex      gpt >= 5, codex >= 5
## OpenAI o-series  o >= 3
## Claude Opus      >= 4.5  (unversioned -> strong)
## Claude Sonnet    >= 4.6  (unversioned -> strong)
## Gemini           >= 3
## Qwen             >= 3.6
## MiniMax          >= 2.7
## MiMo             >= 2
## Kimi / Moonshot  >= 2.5  (unversioned -> strong)
## GLM              >= 5
## DeepSeek         V >= 4 (distilled excluded)
## Grok             >= 4.2
## Nemotron         >= 3
## ===============  =================================
##
## Models containing genuinely weak-tier keywords (nano,
## lite, tiny, micro, haiku, instant, ...) are always treated
## as weak.  ``mini`` and ``flash`` are intentionally NOT weak
## keywords because high-version variants of those tiers can
## be strong; they are gated by version threshold instead.
##
## Model names are normalised (lowercased, underscores ->
## hyphens) before comparison.
##
## :param model: The model identifier string.
## :returns: true when the model is recognised as strong.
##
## .. code-block:: nim
##   runnableExamples:
##     assert isKnownStrongModel("mimo-v2.5-pro")
##     assert isKnownStrongModel("gpt-5.5")
##     assert isKnownStrongModel("claude-opus-4.8")
##     assert isKnownStrongModel("qwen3.7-max")
##     assert not isKnownStrongModel("claude-3-haiku")
func isKnownStrongModel*(model: string): bool =
  let m = implNormaliseModel(model)
  if m.len == 0:
    return false

  # Always-weak tiers, independent of version.
  if implHasWeakKeyword(m):
    return false

  # MiMo (Xiaomi) family — checked before the generic
  # "-o" o-series rule because "mimo" contains an 'o'.
  if m.contains("mimo"):
    let v = implExtractVersion(m, "mimo")
    if v == 0.0: return true   # unversioned mimo flagship
    return v >= 2.0

  # GPT / Codex family.
  if m.contains("gpt") or m.contains("codex"):
    let v = max(
      implExtractVersion(m, "gpt"),
      implExtractVersion(m, "codex"))
    return v >= 5.0

  # OpenAI o-series reasoning models (o1/o3/o4 ...).
  if m.startsWith("o") or m.contains("-o"):
    let oIdx =
      if m.startsWith("o"): 0
      else: m.find("-o") + 1
    if oIdx >= 0 and oIdx < m.len - 1 and
        m[oIdx] == 'o' and
        m[oIdx + 1] in {'0' .. '9'}:
      return implExtractVersion(m, "o") >= 3.0

  # Claude family.
  if m.contains("claude"):
    if m.contains("opus"):
      let v = implExtractVersion(m, "opus")
      return v == 0.0 or v >= 4.5
    if m.contains("sonnet"):
      let v = implExtractVersion(m, "sonnet")
      return v == 0.0 or v >= 4.6
    if m.contains("haiku"):
      return false
    return implExtractVersion(m, "claude") >= 4.5

  # Gemini family.
  if m.contains("gemini"):
    return implExtractVersion(m, "gemini") >= 3.0

  # Grok family.
  if m.contains("grok"):
    return implExtractVersion(m, "grok") >= 4.2

  # MiniMax family ("minimax" contains "mini").
  if m.contains("minimax"):
    return implExtractVersion(m, "minimax") >= 2.7

  # Qwen family — modern versions are strong.
  if m.contains("qwen"):
    return implExtractVersion(m, "qwen") >= 3.6

  # GLM / ChatGLM family.
  if m.contains("glm"):
    return implExtractVersion(m, "glm") >= 5.0

  # DeepSeek family — V4+ full variants are strong.
  if m.contains("deepseek"):
    if m.contains("distill") or
        m.contains("distilled"):
      return false
    let vNum = implExtractVersion(m, "deepseek")
    if vNum > 0.0 and vNum < 4.0:
      return false
    return vNum >= 4.0

  # Kimi / Moonshot family — K2.5 and beyond are strong.
  if m.contains("kimi") or m.contains("moonshot"):
    let v = max(
      implExtractVersion(m, "kimi"),
      implExtractVersion(m, "k"))
    if v == 0.0: return true   # unversioned flagship
    return v >= 2.5

  # NVIDIA Nemotron family.
  if m.contains("nemotron"):
    return implExtractVersion(m, "nemotron") >= 3.0

  # Unknown family.
  result = false
