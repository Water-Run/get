## Shared constants, path helpers, types, and utility functions for
## the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-14
## :File: utils.nim
## :License: AGPL-3.0
##
## This module provides application-wide constants such as version,
## license, and GitHub URL, path resolution for configuration
## directories and files, shared domain types (GetError, LlmMessage),
## bundled-tool binary directory resolution, model strength
## verification, and general-purpose string utilities consumed by
## every other module.

{.experimental: "strictFuncs".}

import std/[os, options, strutils]

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## The name of the application.
const APP_NAME* = "get"

## The version string, kept in sync with get.nimble.
const APP_VERSION* = "0.2.0"

## One-line introduction shown by `get get --intro`.
const APP_INTRO* = "get anything from your computer"

## SPDX license identifier.
const APP_LICENSE* = "AGPL-3.0"

## Canonical GitHub repository URL.
const APP_GITHUB* = "https://github.com/Water-Run/get"

## Name of the configuration JSON file.
const CONFIG_FILE_NAME* = "config.json"

## Name of the key storage file.
const KEY_FILE_NAME* = "key"

## Name of the append-only log file.
const LOG_FILE_NAME* = "get.log"

## Name of the cache JSON file.
const CACHE_FILE_NAME* = "cache.json"

## Hint displayed after usage errors to direct users to the help
## command for detailed information.
const HELP_HINT* = "Run 'get help' for usage information."

## Name of the bundled binary directory relative to the executable.
const BIN_DIR_NAME* = "bin"

## Development-time path to the bundled binary directory, relative
## to the executable (project root during nimble run).
const DEV_BIN_DIR* = "src" / "bin"

## Warning text emitted when the configured model is not recognised
## as a known high-performance model.
const MODEL_STRENGTH_WARNING* =
  "warning: model is not recognized as a known " &
  "high-performance model.\n" &
  "For operations that execute commands on your " &
  "device, a sufficiently capable model is the " &
  "foundation of safety.\n" &
  "Consider using a known strong model (e.g. " &
  "GPT-5+, Claude 3.7+, Gemini 3+, DeepSeek, " &
  "Grok 4+, GLM 4.7+)."

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Base exception type for all recoverable errors in the get tool.
## Every domain-specific error should inherit from this type so that
## the top-level CLI dispatcher can catch and display them
## uniformly.
type
  GetError* = object of CatchableError

## Represents a single message in an LLM conversation.  This type
## is defined here rather than in the llm module so that both the
## prompt builder and the LLM client can reference it without
## circular imports.
type
  LlmMessage* = object
    role*: string     ## "system", "user", or "assistant".
    content*: string  ## Message content text.

# ---------------------------------------------------------------------------
# Public API — paths
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

## Returns the absolute path to the bundled binary directory.
## Checks the production layout first (``<exe>/bin``), then the
## development layout (``<exe>/src/bin``).  Returns an empty string
## when neither exists.
##
## :returns: Absolute directory path, or empty string.
##
## .. code-block:: nim
##   runnableExamples:
##     discard getBundledBinDir()
proc getBundledBinDir*(): string =
  let appDir = getAppDir()
  let prodPath = appDir / BIN_DIR_NAME
  if dirExists(prodPath):
    return prodPath
  let devPath = appDir / DEV_BIN_DIR
  if dirExists(devPath):
    return devPath
  result = ""

# ---------------------------------------------------------------------------
# Public API — string utilities
# ---------------------------------------------------------------------------

## Replaces every character in a string with an asterisk.
## Returns an empty string when the input is empty.
##
## :param s: The string to mask.
## :returns: A string of asterisks whose length equals the input
##           length.
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
  else:
    result = "bash"

## Extracts the content of the first fenced code block from a
## Markdown-formatted string.  Recognises opening fences with
## optional language tags (e.g. `` ```sh ``, `` ```bash ``,
## `` ```powershell ``, or bare `` ``` ``).
##
## :param text: The full text that may contain fenced code blocks.
## :returns: The trimmed content of the first code block, or none
##           when no code block is found.
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
  return none(string)

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
# Private helpers — model version extraction
# ---------------------------------------------------------------------------

## Extracts the first version-like number that appears after the
## family prefix in a lowercased model name.  Skips common
## separators and an optional ``v`` prefix before the digits.
##
## :param model: Lowercased model name.
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
  return 0.0

# ---------------------------------------------------------------------------
# Public API — model strength check
# ---------------------------------------------------------------------------

## Checks whether the configured model name corresponds to a known
## high-performance model suitable for command generation.
##
## Recognised strong families and their minimum versions:
## GPT >= 5 (including CodeX), Claude >= 3.7, Gemini >= 3,
## Grok >= 4, MiniMax >= 2.7, GLM >= 4.7, DeepSeek (full).
## Models containing weak-variant keywords (mini, nano, lite,
## haiku, flash, etc.) or belonging to unsupported families
## (Doubao, Qwen) are always treated as weak.
##
## :param model: The model identifier string.
## :returns: true when the model is recognised as strong.
##
## .. code-block:: nim
##   runnableExamples:
##     assert isKnownStrongModel("gpt-5.3-codex")
##     assert not isKnownStrongModel("gpt-4o-mini")
func isKnownStrongModel*(model: string): bool =
  let m = toLowerAscii(model)
  if m.len == 0:
    return false

  # Blocked families — never considered strong.
  for blocked in ["doubao", "qwen", "ernie",
      "wenxin", "hunyuan", "spark", "baichuan",
      "yi-"]:
    if m.contains(blocked):
      return false

  # Keywords indicating a reduced-capability variant.
  const weakKeywords = [
    "mini", "nano", "lite", "small", "fast",
    "flash", "haiku", "light", "tiny", "micro",
    "instant"]

  # GPT / Codex family.
  if m.contains("gpt") or m.contains("codex"):
    for w in weakKeywords:
      if m.contains(w): return false
    let vGpt = implExtractVersion(m, "gpt")
    let vCodex = implExtractVersion(m, "codex")
    let v = max(vGpt, vCodex)
    return v >= 5.0

  # Claude family.
  if m.contains("claude"):
    for w in weakKeywords:
      if m.contains(w): return false
    return implExtractVersion(m, "claude") >= 3.7

  # Gemini family.
  if m.contains("gemini"):
    for w in weakKeywords:
      if m.contains(w): return false
    return implExtractVersion(m, "gemini") >= 3.0

  # Grok family.
  if m.contains("grok"):
    for w in weakKeywords:
      if m.contains(w): return false
    return implExtractVersion(m, "grok") >= 4.0

  # MiniMax family (note: "minimax" itself contains "mini" so
  # we must check the family BEFORE the generic weak scan).
  if m.contains("minimax"):
    # "mini" inside "minimax" is the brand, not a weakness.
    for w in weakKeywords:
      if w == "mini":
        continue
      if m.contains(w): return false
    return implExtractVersion(m, "minimax") >= 2.7

  # GLM / ChatGLM family.
  if m.contains("glm"):
    for w in weakKeywords:
      if m.contains(w): return false
    let v1 = implExtractVersion(m, "glm")
    return v1 >= 4.7

  # DeepSeek family — full variants are strong.
  if m.contains("deepseek"):
    for w in weakKeywords:
      if m.contains(w): return false
    return true

  # Unknown family — not recognised.
  return false