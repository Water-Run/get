## Shared constants, path helpers, types, and utility functions for
## the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-13
## :File: utils.nim
## :License: AGPL-3.0
##
## This module provides application-wide constants such as version,
## license, and GitHub URL, path resolution for configuration
## directories and files, shared domain types (GetError, LlmMessage),
## and general-purpose string utilities consumed by every other
## module.

{.experimental: "strictFuncs".}

import std/[os, options, strutils]

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## The name of the application.
const APP_NAME* = "get"

## The version string, kept in sync with get.nimble.
const APP_VERSION* = "0.1.0"

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
  # Unclosed fence — return accumulated content if any.
  if inBlock and blockLines.len > 0:
    let content = blockLines.join("\n").strip()
    if content.len > 0:
      return some(content)
  return none(string)