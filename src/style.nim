## Output styling and formatting for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-06-06
## :File: style.nim
## :License: AGPL-3.0
##
## This module provides two output modes — simp (plain) and vivid
## — that control how progress indicators, separators, warnings,
## commands, results, and configuration values are rendered on
## stderr and stdout.  Simp mode produces unformatted text; vivid
## mode provides animated spinners, ANSI colours, and semantic
## colourisation of configuration values.
##
## Semantic colourisation (vivid mode only) highlights
## configuration values according to their meaning: booleans use
## a consistent green/grey pair, the API-key placeholder is
## dimmed, the default command-pattern regex is dimmed while its
## ``(default: built-in)`` marker is highlighted, a custom or
## changed pattern is shown in emphatic red, and recognised
## values (known shells, strong models, in-range integers) are
## green while questionable ones are amber.
##
## On Windows, ANSI virtual terminal processing must be
## explicitly enabled via initAnsi before any styled output is
## written.  initAnsi is a no-op on non-Windows platforms.
##
## All styled output directed at progress or status goes to
## stderr; final results go to stdout.

{.experimental: "strictFuncs".}

import std/[strformat, strutils]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Enumerates the two supported output styles.
type
  StyleKind* = enum
    skSimp  ## Plain text, no formatting.
    skVivid ## Animated spinners and semantic colours.

## Classifies the semantic state of a configuration value so
## that vivid mode can colourise it appropriately.
type
  ValueState* = enum
    vsNeutral  ## No special meaning; default foreground.
    vsGood     ## Recognised / in-range (green).
    vsBad      ## Off / disabled / negative sense (grey).
    vsWarn     ## Out-of-range or unrecognised (amber).
    vsMuted    ## De-emphasised text (dim).
    vsDanger   ## Custom / overriding a safe default (red).

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
# Constants — dividers
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
# Platform-specific ANSI enabling (Windows)
# ---------------------------------------------------------------------------

when defined(windows):
  ## Win32 standard output handle constant.
  const IMPL_STD_OUTPUT_HANDLE = -11'i32

  ## Win32 standard error handle constant.
  const IMPL_STD_ERROR_HANDLE = -12'i32

  ## Enables ANSI escape sequence processing.
  const IMPL_ENABLE_VTP = 0x0004'u32

  ## Retrieves a handle for the specified standard device.
  proc implGetStdHandle(
    nStdHandle: int32
  ): int {.importc: "GetStdHandle",
    stdcall, dynlib: "kernel32".}

  ## Retrieves the current console mode.
  proc implGetConsoleMode(
    hConsole: int,
    lpMode: ptr uint32
  ): int32 {.importc: "GetConsoleMode",
    stdcall, dynlib: "kernel32".}

  ## Sets the console mode.
  proc implSetConsoleMode(
    hConsole: int,
    dwMode: uint32
  ): int32 {.importc: "SetConsoleMode",
    stdcall, dynlib: "kernel32".}

# ---------------------------------------------------------------------------
# Public API — ANSI initialisation
# ---------------------------------------------------------------------------

## Enables ANSI virtual terminal processing on Windows.  No-op
## on non-Windows platforms.
##
## .. code-block:: nim
##   runnableExamples:
##     initAnsi()
proc initAnsi*() =
  when defined(windows):
    for h in [IMPL_STD_OUTPUT_HANDLE,
              IMPL_STD_ERROR_HANDLE]:
      let handle = implGetStdHandle(h)
      if handle == -1 or handle == 0:
        continue
      var mode: uint32
      if implGetConsoleMode(
          handle, addr mode) != 0:
        discard implSetConsoleMode(
          handle, mode or IMPL_ENABLE_VTP)

# ---------------------------------------------------------------------------
# Public API — style conversion
# ---------------------------------------------------------------------------

## Converts a vivid boolean flag to the corresponding StyleKind.
##
## :param vivid: true for vivid mode, false for plain mode.
## :returns: skVivid or skSimp.
##
## .. code-block:: nim
##   runnableExamples:
##     assert toStyleKind(true) == skVivid
##     assert toStyleKind(false) == skSimp
func toStyleKind*(vivid: bool): StyleKind =
  if vivid: skVivid else: skSimp

# ---------------------------------------------------------------------------
# Public API — semantic value colourisation
# ---------------------------------------------------------------------------

## Returns the ANSI prefix for a value state, or an empty
## string for neutral / non-vivid output.
##
## :param kind: The active output style.
## :param state: The semantic state of the value.
## :returns: An ANSI escape prefix, or empty string.
##
## .. code-block:: nim
##   runnableExamples:
##     assert ansiForState(skSimp, vsGood) == ""
func ansiForState(
  kind: StyleKind,
  state: ValueState
): string =
  if kind != skVivid:
    return ""
  case state
  of vsNeutral: result = ""
  of vsGood:    result = ANSI_GREEN
  of vsBad:     result = ANSI_DIM
  of vsWarn:    result = ANSI_YELLOW
  of vsMuted:   result = ANSI_DIM
  of vsDanger:  result = ANSI_RED & ANSI_BOLD

# ---------------------------------------------------------------------------
# Private helpers — built-in help colourisation
# ---------------------------------------------------------------------------

## Applies lightweight ANSI colouring to a help text string for
## vivid mode.  The colour scheme is intentionally restrained:
## the banner and section headers are bold cyan, example/usage
## ``get`` invocations are bold green, flags beginning with
## ``--`` are amber, and option-name leaders are highlighted
## cyan while their descriptions stay neutral.
##
## :param text: The full help text to colourise.
## :returns: The colourised string.
func implColorizeHelp(text: string): string =
  var lines: seq[string] = @[]
  var isFirst = true
  for rawLine in text.splitLines():
    if isFirst:
      isFirst = false
      lines.add(
        ANSI_CYAN & ANSI_BOLD &
        rawLine & ANSI_RESET)
      continue
    let stripped = rawLine.strip()
    if stripped.len == 0:
      lines.add("")
      continue
    if not rawLine.startsWith(" ") and
        stripped.endsWith(":"):
      lines.add(
        ANSI_CYAN & ANSI_BOLD &
        rawLine & ANSI_RESET)
    elif rawLine.startsWith("  get "):
      lines.add(
        ANSI_GREEN & ANSI_BOLD &
        rawLine & ANSI_RESET)
    elif rawLine.startsWith("  --"):
      lines.add(
        ANSI_YELLOW & ANSI_BOLD &
        rawLine & ANSI_RESET)
    elif rawLine.startsWith("  ") and
        not rawLine.startsWith("    ") and
        stripped.len > 0 and
        stripped[0] in {'a' .. 'z', 'A' .. 'Z'}:
      let trimmed = rawLine.strip(
        leading = true, trailing = false)
      let spIdx = trimmed.find(' ')
      let indent = rawLine.len - trimmed.len
      let pad = repeat(' ', indent)
      if spIdx > 0:
        let name = trimmed[0 ..< spIdx]
        let rest = trimmed[spIdx .. ^1]
        lines.add(
          pad & ANSI_CYAN & ANSI_BOLD &
          name & ANSI_RESET & rest)
      else:
        lines.add(
          pad & ANSI_CYAN & ANSI_BOLD &
          trimmed & ANSI_RESET)
    else:
      lines.add(rawLine)
  result = lines.join("\n")

# ---------------------------------------------------------------------------
# Public API — styled stderr output
# ---------------------------------------------------------------------------

## Writes a progress message to stderr.
##
## :param kind: The active output style.
## :param text: The progress message text.
proc styleProgress*(kind: StyleKind, text: string) =
  case kind
  of skSimp:
    stderr.writeLine(text)
  of skVivid:
    stderr.writeLine(
      ANSI_CYAN & ANSI_BOLD & text & ANSI_RESET)

## Writes a warning message to stderr.
##
## :param kind: The active output style.
## :param text: The warning message text.
proc styleWarning*(kind: StyleKind, text: string) =
  case kind
  of skSimp:
    stderr.writeLine(text)
  of skVivid:
    stderr.writeLine(
      ANSI_YELLOW & ANSI_BOLD &
      "\xe2\x9a\xa0 " & text & ANSI_RESET)

## Writes an error message to stderr.
##
## :param kind: The active output style.
## :param text: The error message text.
proc styleError*(kind: StyleKind, text: string) =
  case kind
  of skSimp:
    stderr.writeLine(text)
  of skVivid:
    stderr.writeLine(
      ANSI_RED & ANSI_BOLD & text & ANSI_RESET)

## Writes a success message to stderr.
##
## :param kind: The active output style.
## :param text: The success message text.
proc styleSuccess*(kind: StyleKind, text: string) =
  case kind
  of skSimp:
    stderr.writeLine(text)
  of skVivid:
    stderr.writeLine(
      ANSI_GREEN & ANSI_BOLD & text & ANSI_RESET)

## Writes a command display to stderr.
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
  of skVivid:
    stderr.writeLine(
      ANSI_MAGENTA & "\xe2\x9d\xaf " &
      ANSI_BOLD & command & ANSI_RESET)

## Writes the agent loop round indicator to stderr.
##
## :param kind: The active output style.
## :param current: The current round number (1-based).
## :param maxRounds: Configured maximum rounds (0 = unlimited).
proc styleRound*(
  kind: StyleKind,
  current: int,
  maxRounds: int
) =
  let text =
    if maxRounds > 0:
      fmt"round {current}/{maxRounds}"
    else:
      fmt"round {current}"
  case kind
  of skSimp:
    stderr.writeLine(text)
  of skVivid:
    stderr.writeLine(
      ANSI_DIM & "\xe2\x94\x80\xe2\x94\x80 " &
      ANSI_CYAN & ANSI_BOLD & text & ANSI_RESET &
      ANSI_DIM &
      " \xe2\x94\x80\xe2\x94\x80" & ANSI_RESET)

## Writes a section separator to stderr.  Simp emits a blank
## line; vivid emits nothing.
##
## :param kind: The active output style.
## :param separator: The divider string (kept for API
##                   stability).
proc styleSeparator*(
  kind: StyleKind,
  separator: string
) =
  case kind
  of skSimp:
    stderr.writeLine("")
  of skVivid:
    discard

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
  result = SPINNER_FRAMES[
    tick mod SPINNER_FRAMES.len]

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

## Writes the final result to stdout as plain text.  The result
## text is always echoed verbatim; no external rendering is
## performed because v2.1 ships no terminal renderer binaries.
##
## :param kind: The active output style.
## :param text: The result text to display.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc styleResult*(
  kind: StyleKind,
  text: string
) =
  echo text

# ---------------------------------------------------------------------------
# Public API — unified styled output helpers
# ---------------------------------------------------------------------------

## Writes a key-value pair to stdout.
##
## :param kind: The active output style.
## :param key: The option or field name.
## :param value: The value to display.
proc styleKeyValue*(
  kind: StyleKind,
  key: string,
  value: string
) =
  case kind
  of skSimp:
    echo fmt"{key} = {value}"
  of skVivid:
    echo ANSI_CYAN & ANSI_BOLD & key &
      ANSI_RESET & " = " & value

## Writes a key-value pair to stdout with semantic colouring of
## the value in vivid mode.  The value may be split into a main
## segment and an optional trailing segment that is highlighted
## separately (used for the ``(default: built-in)`` marker on
## the command-pattern value).
##
## :param kind: The active output style.
## :param key: The option or field name.
## :param value: The main value text.
## :param state: Semantic state controlling the value colour.
## :param trailer: Optional trailing text appended after the
##                 value and shown highlighted (bold cyan) in
##                 vivid mode.
##
## .. code-block:: nim
##   runnableExamples:
##     styleConfigValue(skSimp, "shell", "bash", vsGood)
proc styleConfigValue*(
  kind: StyleKind,
  key: string,
  value: string,
  state: ValueState = vsNeutral,
  trailer: string = ""
) =
  case kind
  of skSimp:
    if trailer.len > 0:
      echo fmt"{key} = {value} {trailer}"
    else:
      echo fmt"{key} = {value}"
  of skVivid:
    let valPrefix = ansiForState(kind, state)
    var line = ANSI_CYAN & ANSI_BOLD & key &
      ANSI_RESET & " = "
    if valPrefix.len > 0:
      line.add(valPrefix & value & ANSI_RESET)
    else:
      line.add(value)
    if trailer.len > 0:
      line.add(" " & ANSI_CYAN & ANSI_BOLD &
        trailer & ANSI_RESET)
    echo line

## Writes a single value to stdout.
##
## :param kind: The active output style.
## :param text: The value text to display.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc styleValue*(kind: StyleKind, text: string) =
  case kind
  of skSimp:
    echo text
  of skVivid:
    echo ANSI_CYAN & ANSI_BOLD &
      text & ANSI_RESET

## Writes a section header to stderr.
##
## :param kind: The active output style.
## :param title: The section title text.
proc styleHeader*(kind: StyleKind, title: string) =
  case kind
  of skSimp:
    stderr.writeLine(title)
  of skVivid:
    stderr.writeLine(
      ANSI_CYAN & ANSI_BOLD & title & ANSI_RESET)

## Writes informational text to stdout.
##
## :param kind: The active output style.
## :param text: The informational text to display.
proc styleInfo*(kind: StyleKind, text: string) =
  case kind
  of skSimp:
    echo text
  of skVivid:
    echo text

## Displays help text to stdout.  In vivid mode the built-in
## colouriser is applied; in plain mode the text is echoed
## verbatim.
##
## :param kind: The active output style.
## :param text: The help text content.
proc styleHelp*(
  kind: StyleKind,
  text: string
) =
  case kind
  of skSimp:
    echo text
  of skVivid:
    echo implColorizeHelp(text)
