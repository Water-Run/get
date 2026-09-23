## Output styling and formatting for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-09-23
## :File: style.nim
## :License: AGPL-3.0
##
## Process lines, warnings, and errors go to stderr; answers and settings go
## to stdout. Colour is used only when the target stream is an interactive
## terminal and neither ``NO_COLOR`` nor ``TERM=dumb`` asks for plain text, so
## pipes and redirections always receive plain text.
##
## On Windows, ANSI virtual terminal processing must be enabled via initAnsi
## before any styled output is written. initAnsi is a no-op elsewhere.

{.experimental: "strictFuncs".}

import std/[os, strutils, terminal]
import markdown_render

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Whether the environment permits colour at all. A stream still gets plain
## text unless it is a terminal.
type
  StyleKind* = enum
    skSimp  ## Plain text only.
    skColor ## Colour on interactive terminals.

## Classifies the semantic state of a configuration value for colouring.
type
  ValueState* = enum
    vsNeutral  ## No special meaning; default foreground.
    vsGood     ## Recognised / in-range (green).
    vsBad      ## Off / disabled (dim).
    vsWarn     ## Out-of-range or unrecognised (amber).
    vsMuted    ## De-emphasised text (dim).

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const ANSI_RESET* = "\e[0m"
const ANSI_BOLD* = "\e[1m"
const ANSI_DIM* = "\e[2m"
const ANSI_RED* = "\e[31m"
const ANSI_GREEN* = "\e[32m"
const ANSI_YELLOW* = "\e[33m"
const ANSI_CYAN* = "\e[36m"

## Width of the key column in ``get config``, ``get cache``, and ``get log``.
const KEY_COLUMN_WIDTH* = 18

## Column widths of one process line: tool, target, status, duration.
const PROCESS_TOOL_WIDTH = 15
const PROCESS_TARGET_WIDTH = 16
const PROCESS_STATUS_WIDTH = 12

# ---------------------------------------------------------------------------
# Platform-specific ANSI enabling (Windows)
# ---------------------------------------------------------------------------

when defined(windows):
  const IMPL_STD_OUTPUT_HANDLE = -11'i32
  const IMPL_STD_ERROR_HANDLE = -12'i32
  const IMPL_ENABLE_VTP = 0x0004'u32

  proc implGetStdHandle(
    nStdHandle: int32
  ): int {.importc: "GetStdHandle",
    stdcall, dynlib: "kernel32".}

  proc implGetConsoleMode(
    hConsole: int,
    lpMode: ptr uint32
  ): int32 {.importc: "GetConsoleMode",
    stdcall, dynlib: "kernel32".}

  proc implSetConsoleMode(
    hConsole: int,
    dwMode: uint32
  ): int32 {.importc: "SetConsoleMode",
    stdcall, dynlib: "kernel32".}

## Enables ANSI virtual terminal processing on Windows. No-op elsewhere.
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
# Public API — style detection
# ---------------------------------------------------------------------------

## Returns skColor unless ``NO_COLOR`` is set or ``TERM`` is ``dumb``.
proc detectStyle*(): StyleKind =
  if existsEnv("NO_COLOR") or getEnv("TERM") == "dumb": skSimp
  else: skColor

## Whether a write to ``f`` may carry colour.
proc implColored(kind: StyleKind, f: File): bool =
  kind == skColor and f.isatty()

func implPaint(on: bool, prefix, text: string): string =
  if on and prefix.len > 0: prefix & text & ANSI_RESET else: text

func ansiForState(state: ValueState): string =
  case state
  of vsNeutral: result = ""
  of vsGood:    result = ANSI_GREEN
  of vsBad:     result = ANSI_DIM
  of vsWarn:    result = ANSI_YELLOW
  of vsMuted:   result = ANSI_DIM

# ---------------------------------------------------------------------------
# Public API — stderr messages
# ---------------------------------------------------------------------------

## Writes a progress or status note to stderr.
proc styleProgress*(kind: StyleKind, text: string) =
  stderr.writeLine(implPaint(implColored(kind, stderr), ANSI_DIM, text))

## Writes a warning to stderr.
proc styleWarning*(kind: StyleKind, text: string) =
  stderr.writeLine(implPaint(implColored(kind, stderr), ANSI_YELLOW, text))

## Writes an error to stderr.
proc styleError*(kind: StyleKind, text: string) =
  stderr.writeLine(implPaint(implColored(kind, stderr), ANSI_RED, text))

## Writes a confirmation of a completed management action to stderr.
proc styleSuccess*(kind: StyleKind, text: string) =
  stderr.writeLine(implPaint(implColored(kind, stderr), ANSI_GREEN, text))

## Returns a process-line target shortened to its column.
func implShortTarget(target: string): string =
  result = target.replace('\n', ' ').replace('\r', ' ').replace('\t', ' ')
  if result.len >= PROCESS_TARGET_WIDTH:
    var cut = PROCESS_TARGET_WIDTH - 4
    while cut > 0 and (byte(result[cut]) and 0xC0'u8) == 0x80'u8:
      dec cut
    result = result[0 ..< cut] & "..."

func implStatusColor(status: string): string =
  case status
  of "ok", "no match", "finding", "reused": ANSI_GREEN
  of "denied": ANSI_RED
  of "timeout", "unsupported": ANSI_YELLOW
  else: ""

## Writes one observation line to stderr: tool, target, status, duration.
## A negative duration (nothing ran) leaves the last column empty.
##
## .. code-block:: text
##   read_file      src/get.nim     ok          12ms
##   run_process    ps              denied
proc styleProcessLine*(kind: StyleKind, tool, target, status: string,
    elapsedMs: int64) =
  let colored = implColored(kind, stderr)
  var line = alignLeft(tool, PROCESS_TOOL_WIDTH - 1) & " " &
    alignLeft(implShortTarget(target), PROCESS_TARGET_WIDTH - 1) & " "
  if elapsedMs >= 0:
    line.add(implPaint(colored, implStatusColor(status),
      alignLeft(status, PROCESS_STATUS_WIDTH - 1)) & " " & $elapsedMs & "ms")
  else:
    line.add(implPaint(colored, implStatusColor(status), status))
  stderr.writeLine(line)

## Shows the single waiting line while a model request is in flight.
proc writeRequesting*(seconds: int) =
  stderr.write("\rrequesting " & $seconds & "s\e[K")
  stderr.flushFile()

## Clears the waiting line.
proc clearRequesting*() =
  stderr.write("\r\e[K")
  stderr.flushFile()

# ---------------------------------------------------------------------------
# Public API — stdout
# ---------------------------------------------------------------------------

## Writes the answer to stdout. Model Markdown is rendered only on an
## interactive terminal; pipes and redirections keep the original text.
proc styleResult*(
  kind: StyleKind,
  text: string,
  markdown: bool = false
) =
  if markdown and stdout.isatty() and getEnv("TERM") != "dumb":
    echo renderMarkdown(text, implColored(kind, stdout))
  else:
    echo text

## Writes one aligned key and value to stdout.
proc styleKeyValue*(
  kind: StyleKind,
  key: string,
  value: string
) =
  let colored = implColored(kind, stdout)
  echo implPaint(colored, ANSI_CYAN, alignLeft(key, KEY_COLUMN_WIDTH - 1)) &
    " " & value

## Writes one aligned configuration key and value, colouring the value by
## meaning on a terminal.
proc styleConfigValue*(
  kind: StyleKind,
  key: string,
  value: string,
  state: ValueState = vsNeutral
) =
  let colored = implColored(kind, stdout)
  echo implPaint(colored, ANSI_CYAN, alignLeft(key, KEY_COLUMN_WIDTH - 1)) &
    " " & implPaint(colored, ansiForState(state), value)

## Writes a single value to stdout.
proc styleValue*(kind: StyleKind, text: string) =
  echo text

## Writes informational text to stdout.
proc styleInfo*(kind: StyleKind, text: string) =
  echo text

## Writes the help text to stdout as plain text.
proc styleHelp*(text: string) =
  echo text
