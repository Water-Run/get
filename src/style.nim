## Output styling and formatting for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-17
## :File: style.nim
## :License: AGPL-3.0
##
## This module provides two output modes — plain and vivid — that
## control how progress indicators, separators, warnings, commands,
## and results are rendered on stderr and stdout.  Plain mode
## produces unformatted text; vivid mode provides animated spinners,
## ANSI colours, and optional external rendering via bat and mdcat.
##
## On Windows, ANSI virtual terminal processing must be explicitly
## enabled via initAnsi before any styled output is written.
## initAnsi is a no-op on non-Windows platforms.
##
## When external-display is enabled (default), bat is used for
## syntax-highlighted output and mdcat is used for Markdown
## rendering in vivid mode.  When external tools are unavailable,
## vivid mode falls back to built-in ANSI colourisation.  Missing
## binaries trigger a warning and graceful fallback.
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

## Enumerates the two supported output styles.
type
  StyleKind* = enum
    skSimp  ## Plain text, no formatting.
    skVivid ## Animated spinners, colours, external rendering.

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
# Constants — dividers (passed by callers, used only for vivid)
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

  ## Enables ANSI escape sequence processing on a
  ## Windows console handle.
  const IMPL_ENABLE_VTP = 0x0004'u32

  ## Retrieves a handle for the specified standard device.
  proc implGetStdHandle(
    nStdHandle: int32
  ): int {.importc: "GetStdHandle",
    stdcall, dynlib: "kernel32".}

  ## Retrieves the current input mode of a console's
  ## input buffer or output screen buffer.
  proc implGetConsoleMode(
    hConsole: int,
    lpMode: ptr uint32
  ): int32 {.importc: "GetConsoleMode",
    stdcall, dynlib: "kernel32".}

  ## Sets the input mode of a console's input buffer or
  ## output screen buffer.
  proc implSetConsoleMode(
    hConsole: int,
    dwMode: uint32
  ): int32 {.importc: "SetConsoleMode",
    stdcall, dynlib: "kernel32".}

# ---------------------------------------------------------------------------
# Public API — ANSI initialisation
# ---------------------------------------------------------------------------

## Enables ANSI virtual terminal processing on Windows so that
## escape sequences produce colours and formatting rather than
## appearing as raw text.  Must be called before any styled
## output is written.  This is a no-op on non-Windows platforms.
##
## .. code-block:: nim
##   runnableExamples:
##     initAnsi()  # safe to call on any platform
proc initAnsi*() =
  when defined(windows):
    for h in [IMPL_STD_OUTPUT_HANDLE,
              IMPL_STD_ERROR_HANDLE]:
      let handle = implGetStdHandle(h)
      if handle == -1 or handle == 0:
        continue
      var mode: uint32
      if implGetConsoleMode(handle, addr mode) != 0:
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
# Public API — external tool availability
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

## Checks whether the bundled bat binary is available.
##
## :param binDir: Absolute path to the bundled bin directory.
## :returns: true when bat exists and is executable.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — depends on filesystem.
##     discard
proc isBatAvailable*(binDir: string): bool =
  if binDir.len == 0:
    return false
  when defined(windows):
    let path = binDir / "bat.exe"
  else:
    let path = binDir / "bat"
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

## Renders a text string through bat for syntax-highlighted
## display.  Falls back to plain output when bat is unavailable.
##
## :param text: The text to render.
## :param binDir: Absolute path to the bundled bin directory.
## :returns: The rendered text, or the original text on failure.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — requires bat binary.
##     discard
proc renderWithBat*(
  text: string,
  binDir: string
): string =
  if not isBatAvailable(binDir):
    return text
  when defined(windows):
    let batPath = binDir / "bat.exe"
  else:
    let batPath = binDir / "bat"
  try:
    let (output, exitCode) = execCmdEx(
      fmt"{batPath} --style=plain --paging=never" &
      " --color=always",
      input = text)
    if exitCode == 0 and output.len > 0:
      result = output
    else:
      result = text
  except OSError, IOError:
    result = text

# ---------------------------------------------------------------------------
# Private helpers — built-in help colourisation
# ---------------------------------------------------------------------------

## Applies lightweight ANSI colouring to a help text string so
## that vivid mode produces readable styled output even when the
## external bat binary is not available.
##
## Colouring rules:
##   - The first line (title) is rendered in bold cyan.
##   - Lines that do not start with a space and end with a colon
##     are treated as section headers and coloured in cyan bold.
##   - Lines starting with ``"  get "`` are treated as example
##     commands and coloured in green bold.
##   - Lines starting with ``"  --"`` are treated as flag
##     descriptions and coloured in yellow bold.
##   - All other lines are left unchanged.
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
    # Section headers: not indented and ends with ':'
    if not rawLine.startsWith(" ") and
        stripped.endsWith(":"):
      lines.add(
        ANSI_CYAN & ANSI_BOLD &
        rawLine & ANSI_RESET)
    # Example commands: indented "get ..."
    elif rawLine.startsWith("  get "):
      lines.add(
        ANSI_GREEN & ANSI_BOLD &
        rawLine & ANSI_RESET)
    # Flags: indented "--..."
    elif rawLine.startsWith("  --"):
      lines.add(
        ANSI_YELLOW & ANSI_BOLD &
        rawLine & ANSI_RESET)
    # Option names: 2-space indent, word then spaces
    elif rawLine.startsWith("  ") and
        not rawLine.startsWith("    ") and
        stripped.len > 0 and
        stripped[0] in {'a' .. 'z', 'A' .. 'Z'}:
      let trimmed = rawLine.strip(
        leading = true, trailing = false)
      let spIdx = trimmed.find(' ')
      if spIdx > 0:
        let name = trimmed[0 ..< spIdx]
        let rest = trimmed[spIdx .. ^1]
        let indent = rawLine.len - trimmed.len
        let pad = repeat(' ', indent)
        lines.add(
          pad & ANSI_CYAN & ANSI_BOLD &
          name & ANSI_RESET & rest)
      else:
        lines.add(rawLine)
    else:
      lines.add(rawLine)
  result = lines.join("\n")

# ---------------------------------------------------------------------------
# Public API — external display warnings
# ---------------------------------------------------------------------------

## Emits warnings when external-display settings conflict with the
## active style or when required binaries are missing.
##
## :param sk: The active output style.
## :param extDisplay: Whether external-display is enabled.
## :param binDir: Path to the bundled bin directory.
proc styleExternalDisplayCheck*(
  sk: StyleKind,
  extDisplay: bool,
  binDir: string
) =
  if not extDisplay:
    return
  if sk == skSimp:
    stderr.writeLine(
      "warning: external-display has no " &
      "effect in plain mode")
    return
  # Vivid mode: check for missing binaries.
  var missing: seq[string] = @[]
  if not isBatAvailable(binDir):
    missing.add("bat")
  if not isMdcatAvailable(binDir):
    missing.add("mdcat")
  if missing.len > 0:
    stderr.writeLine(
      ANSI_YELLOW &
      "warning: external display tool(s) " &
      "not found in bin/: " &
      missing.join(", ") & ". " &
      "Falling back to built-in styling." &
      ANSI_RESET)

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
  of skVivid:
    stderr.writeLine(
      ANSI_RED & ANSI_BOLD & text & ANSI_RESET)

## Writes a success message to stderr with style-appropriate
## formatting.
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
  of skVivid:
    stderr.writeLine(
      ANSI_MAGENTA & "❯ " & ANSI_BOLD &
      command & ANSI_RESET)

## Writes the agent loop round indicator to stderr with
## style-appropriate formatting.
##
## :param kind: The active output style.
## :param current: The current round number (1-based).
## :param maxRounds: The configured maximum rounds (0 = unlimited).
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
      ANSI_DIM & "── " & ANSI_CYAN & ANSI_BOLD &
      text & ANSI_RESET & ANSI_DIM &
      " ──" & ANSI_RESET)

## Writes a section separator to stderr.  Simp emits a blank
## line; vivid emits nothing (visual structure comes from
## coloured text).
##
## :param kind: The active output style.
## :param separator: The divider string (ignored in both modes
##                   but kept for API stability).
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

## Writes the final result to stdout, using external display tools
## when enabled and available.  When isMarkdown is true, mdcat is
## used for rendering; otherwise bat is used for syntax-
## highlighted display.
##
## :param kind: The active output style.
## :param text: The result text to display.
## :param binDir: Bundled bin directory for tool lookup.
## :param extDisplay: Whether external display is enabled.
## :param isMarkdown: Whether the content is Markdown (use mdcat).
proc styleResult*(
  kind: StyleKind,
  text: string,
  binDir: string = "",
  extDisplay: bool = false,
  isMarkdown: bool = false
) =
  case kind
  of skSimp:
    echo text
  of skVivid:
    if extDisplay and binDir.len > 0:
      if isMarkdown and isMdcatAvailable(binDir):
        let rendered = renderMarkdown(text, binDir)
        stdout.write(rendered)
        if not rendered.endsWith("\n"):
          stdout.write("\n")
      elif isBatAvailable(binDir):
        let rendered = renderWithBat(text, binDir)
        stdout.write(rendered)
        if not rendered.endsWith("\n"):
          stdout.write("\n")
      else:
        echo text
    else:
      echo text

# ---------------------------------------------------------------------------
# Public API — unified styled output helpers
# ---------------------------------------------------------------------------

## Writes a key-value pair to stdout with style-appropriate
## formatting.  Used by config display, cache info, log info,
## and similar informational pages.
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

## Writes a single value to stdout with style-appropriate
## formatting.  Used for simple value displays such as
## ``get version`` and ``get get --version``.
##
## :param kind: The active output style.
## :param text: The value text to display.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — produces console output.
##     discard
proc styleValue*(
  kind: StyleKind,
  text: string
) =
  case kind
  of skSimp:
    echo text
  of skVivid:
    echo ANSI_CYAN & ANSI_BOLD &
      text & ANSI_RESET

## Writes a section header to stderr with style-appropriate
## formatting.
##
## :param kind: The active output style.
## :param title: The section title text.
proc styleHeader*(
  kind: StyleKind,
  title: string
) =
  case kind
  of skSimp:
    stderr.writeLine(title)
  of skVivid:
    stderr.writeLine(
      ANSI_CYAN & ANSI_BOLD & title & ANSI_RESET)

## Writes informational text to stdout with style-appropriate
## formatting.
##
## :param kind: The active output style.
## :param text: The informational text to display.
proc styleInfo*(
  kind: StyleKind,
  text: string
) =
  case kind
  of skSimp:
    echo text
  of skVivid:
    echo text

## Displays help text to stdout.  In plain mode the text is
## printed unmodified.  In vivid mode, bat is used when available
## (via external-display); otherwise the built-in ANSI colouriser
## highlights section headers, example commands, and option flags.
##
## :param kind: The active output style.
## :param text: The help text content.
## :param binDir: Bundled bin directory for bat lookup.
## :param extDisplay: Whether external display is enabled.
proc styleHelp*(
  kind: StyleKind,
  text: string,
  binDir: string = "",
  extDisplay: bool = false
) =
  case kind
  of skSimp:
    echo text
  of skVivid:
    if extDisplay and binDir.len > 0 and
        isBatAvailable(binDir):
      let rendered = renderWithBat(text, binDir)
      stdout.write(rendered)
      if not rendered.endsWith("\n"):
        stdout.write("\n")
    else:
      echo implColorizeHelp(text)