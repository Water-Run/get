## Output styling and formatting for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-14
## :File: style.nim
## :License: AGPL-3.0
##
## This module provides three output style modes — simp, std, and
## vivid — that control how progress indicators, separators,
## warnings, commands, and results are rendered on stderr and
## stdout.  The simp mode produces plain unformatted text, std adds
## ANSI colours and divider lines, and vivid provides animated
## spinners and Markdown rendering via the bundled mdcat binary.
##
## All styled output directed at progress or status goes to stderr;
## final results go to stdout.  The module exposes pure or
## side-effect-only procs that accept a StyleKind so that callers
## need not branch on style themselves.

{.experimental: "strictFuncs".}

import std/[os, osproc, strformat, strutils]

import utils

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Enumerates the three supported output styles.
type
  StyleKind* = enum
    skSimp  ## Plain text, no formatting.
    skStd   ## Dividers and basic ANSI colours.
    skVivid ## Animated spinners, colours, mdcat rendering.

# ---------------------------------------------------------------------------
# Constants — ANSI escape codes
# ---------------------------------------------------------------------------

## Resets all ANSI attributes.
const ANSI_RESET* = "\e[0m"

## Bold text.
const ANSI_BOLD* = "\e[1m"

## Dim / faint text.
const ANSI_DIM* = "\e[2m"

## Red foreground.
const ANSI_RED* = "\e[31m"

## Green foreground.
const ANSI_GREEN* = "\e[32m"

## Yellow foreground.
const ANSI_YELLOW* = "\e[33m"

## Cyan foreground.
const ANSI_CYAN* = "\e[36m"

## Magenta foreground.
const ANSI_MAGENTA* = "\e[35m"

# ---------------------------------------------------------------------------
# Constants — dividers used by std mode
# ---------------------------------------------------------------------------

## Thin separator for minor boundaries.
const DIV_THIN* = "---"

## Emphasis separator for warnings.
const DIV_WARN* = "***"

## Major section separator.
const DIV_SECTION* = "==="

## Footer separator.
const DIV_FOOTER* = "____"

## Decorative separator for special notices.
const DIV_NOTICE* = "\\\\\\\\\\\\"

# ---------------------------------------------------------------------------
# Constants — vivid mode spinner frames
# ---------------------------------------------------------------------------

## Braille-dot spinner frames for vivid mode animation.
const SPINNER_FRAMES* = [
  "\xe2\xa0\x8b", "\xe2\xa0\x99",
  "\xe2\xa0\xb9", "\xe2\xa0\xb8",
  "\xe2\xa0\xbc", "\xe2\xa0\xb4",
  "\xe2\xa0\xa6", "\xe2\xa0\xa7",
  "\xe2\xa0\x87", "\xe2\xa0\x8f"]

# ---------------------------------------------------------------------------
# Public API — style parsing
# ---------------------------------------------------------------------------

## Parses a style name string into a StyleKind.
##
## :param s: One of ``"simp"``, ``"std"``, or ``"vivid"``
##           (case-insensitive).
## :returns: The corresponding StyleKind.
## :raises: GetError: If the string is not a recognised style.
##
## .. code-block:: nim
##   runnableExamples:
##     assert parseStyle("std") == skStd
##     assert parseStyle("VIVID") == skVivid
func parseStyle*(s: string): StyleKind =
  case toLowerAscii(s.strip())
  of "simp":  result = skSimp
  of "std":   result = skStd
  of "vivid": result = skVivid
  else:
    raise newException(GetError,
      fmt"invalid style '{s}': expected " &
      "'simp', 'std', or 'vivid'")

## Returns the string representation of a StyleKind.
##
## :param kind: The style kind to convert.
## :returns: ``"simp"``, ``"std"``, or ``"vivid"``.
##
## .. code-block:: nim
##   runnableExamples:
##     assert styleName(skStd) == "std"
func styleName*(kind: StyleKind): string =
  case kind
  of skSimp:  result = "simp"
  of skStd:   result = "std"
  of skVivid: result = "vivid"

# ---------------------------------------------------------------------------
# Public API — mdcat availability
# ---------------------------------------------------------------------------

## Checks whether the bundled mdcat binary is available.
##
## :param binDir: Absolute path to the bundled bin directory.
## :returns: true when mdcat exists and is executable.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — depends on filesystem.
##     discard
proc isMdcatAvailable*(binDir: string): bool =
  if binDir.len == 0:
    return false
  when defined(windows):
    let path = binDir / "mdcat.exe"
  else:
    let path = binDir / "mdcat"
  result = fileExists(path)

## Renders a text string through mdcat for Markdown display.
## Falls back to plain output when mdcat is unavailable.
##
## :param text: The Markdown text to render.
## :param binDir: Absolute path to the bundled bin directory.
## :returns: The rendered text, or the original text on failure.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — requires mdcat binary.
##     discard
proc renderMarkdown*(
  text: string,
  binDir: string
): string =
  if not isMdcatAvailable(binDir):
    return text
  when defined(windows):
    let mdcatPath = binDir / "mdcat.exe"
  else:
    let mdcatPath = binDir / "mdcat"
  try:
    let (output, exitCode) = execCmdEx(
      fmt"{mdcatPath} --no-pager",
      input = text)
    if exitCode == 0 and output.len > 0:
      result = output
    else:
      result = text
  except OSError, IOError:
    result = text

# ---------------------------------------------------------------------------
# Public API — styled stderr output
# ---------------------------------------------------------------------------

## Writes a progress message to stderr with style-appropriate
## formatting.
##
## :param kind: The active output style.
## :param text: The progress message text.
proc styleProgress*(kind: StyleKind, text: string) =
  case kind
  of skSimp:
    stderr.writeLine(text)
  of skStd:
    stderr.writeLine(ANSI_DIM & text & ANSI_RESET)
  of skVivid:
    stderr.writeLine(
      ANSI_CYAN & ANSI_BOLD & text & ANSI_RESET)

## Writes a warning message to stderr with style-appropriate
## formatting.
##
## :param kind: The active output style.
## :param text: The warning message text.
proc styleWarning*(kind: StyleKind, text: string) =
  case kind
  of skSimp:
    stderr.writeLine(text)
  of skStd:
    stderr.writeLine(DIV_WARN)
    stderr.writeLine(
      ANSI_YELLOW & text & ANSI_RESET)
    stderr.writeLine(DIV_WARN)
  of skVivid:
    stderr.writeLine(
      ANSI_YELLOW & ANSI_BOLD &
      "⚠ " & text & ANSI_RESET)

## Writes an error message to stderr with style-appropriate
## formatting.
##
## :param kind: The active output style.
## :param text: The error message text.
proc styleError*(kind: StyleKind, text: string) =
  case kind
  of skSimp:
    stderr.writeLine(text)
  of skStd:
    stderr.writeLine(
      ANSI_RED & text & ANSI_RESET)
  of skVivid:
    stderr.writeLine(
      ANSI_RED & ANSI_BOLD & text & ANSI_RESET)

## Writes a command display to stderr with style-appropriate
## formatting.
##
## :param kind: The active output style.
## :param label: The label prefix (e.g. "command").
## :param command: The command string to display.
proc styleCommand*(
  kind: StyleKind,
  label: string,
  command: string
) =
  case kind
  of skSimp:
    stderr.writeLine(fmt"{label}: {command}")
  of skStd:
    stderr.writeLine(DIV_THIN)
    stderr.writeLine(
      ANSI_CYAN & fmt"{label}: " &
      ANSI_BOLD & command & ANSI_RESET)
  of skVivid:
    stderr.writeLine(
      ANSI_MAGENTA & "❯ " & ANSI_BOLD &
      command & ANSI_RESET)

## Writes a section separator to stderr.  Only emits visible
## output in std mode; simp uses a blank line; vivid uses nothing
## (the formatting itself provides visual separation).
##
## :param kind: The active output style.
## :param separator: The divider string (from DIV_* constants).
proc styleSeparator*(
  kind: StyleKind,
  separator: string
) =
  case kind
  of skSimp:
    stderr.writeLine("")
  of skStd:
    stderr.writeLine(
      ANSI_DIM & separator & ANSI_RESET)
  of skVivid:
    discard

## Writes the vivid-mode experimental warning to stderr.  Only
## emits output when the style is vivid.
##
## :param kind: The active output style.
proc styleVividNotice*(kind: StyleKind) =
  if kind == skVivid:
    stderr.writeLine(
      ANSI_YELLOW & ANSI_BOLD &
      "warning: vivid mode is experimental" &
      ANSI_RESET)

## Writes the vivid-mode mdcat-unavailable warning to stderr.
##
## :param kind: The active output style.
proc styleMdcatWarning*(kind: StyleKind) =
  if kind == skVivid:
    stderr.writeLine(
      ANSI_YELLOW &
      "warning: mdcat not found in bin/, " &
      "markdown rendering unavailable. " &
      "Consider: get set style std" &
      ANSI_RESET)

# ---------------------------------------------------------------------------
# Public API — vivid spinner helpers
# ---------------------------------------------------------------------------

## Returns the spinner frame for the given tick count.
##
## :param tick: A monotonically increasing counter.
## :returns: The Unicode spinner character for this tick.
##
## .. code-block:: nim
##   runnableExamples:
##     let f = spinnerFrame(0)
##     assert f.len > 0
func spinnerFrame*(tick: int): string =
  result = SPINNER_FRAMES[tick mod SPINNER_FRAMES.len]

## Writes a spinner frame with a message to stderr, overwriting
## the current line using carriage return.
##
## :param tick: The current tick counter.
## :param message: Text to display beside the spinner.
proc writeSpinner*(tick: int, message: string) =
  stderr.write(
    "\r" & ANSI_CYAN &
    spinnerFrame(tick) & " " &
    message & ANSI_RESET & "   ")
  stderr.flushFile()

## Clears the spinner line on stderr.
proc clearSpinner*() =
  stderr.write("\r\e[K")
  stderr.flushFile()

# ---------------------------------------------------------------------------
# Public API — result output
# ---------------------------------------------------------------------------

## Writes the final result to stdout, optionally rendering
## Markdown in vivid mode.
##
## :param kind: The active output style.
## :param text: The result text to display.
## :param binDir: Bundled bin directory for mdcat lookup.
proc styleResult*(
  kind: StyleKind,
  text: string,
  binDir: string = ""
) =
  case kind
  of skSimp:
    echo text
  of skStd:
    stderr.writeLine(
      ANSI_DIM & DIV_SECTION & ANSI_RESET)
    echo text
    stderr.writeLine(
      ANSI_DIM & DIV_FOOTER & ANSI_RESET)
  of skVivid:
    if binDir.len > 0 and isMdcatAvailable(binDir):
      let rendered = renderMarkdown(text, binDir)
      stdout.write(rendered)
      if not rendered.endsWith("\n"):
        stdout.write("\n")
    else:
      echo text
