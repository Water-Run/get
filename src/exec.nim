## Shell command execution and output capture for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-13
## :File: exec.nim
## :License: AGPL-3.0
##
## This module provides procedures to execute shell commands generated
## by the LLM, capture their combined stdout/stderr output, and
## enforce safety constraints including command-pattern regex
## validation and interactive manual-confirm gating.  Commands are
## run through the configured shell via startProcess so that
## arguments are passed directly without additional quoting layers.

{.experimental: "strictFuncs".}

import std/[osproc, streams, options, re, strformat, strutils]

import utils

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Encapsulates the result of a shell command execution.
type
  ExecResult* = object
    output*: string   ## Combined stdout and stderr output.
    exitCode*: int    ## Process exit code (0 = success).

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Builds the argument list for invoking a command through the given
## shell.  PowerShell/pwsh receives ``-NoProfile -NonInteractive
## -Command <cmd>``; cmd.exe receives ``/C <cmd>``; everything else
## (bash, zsh, sh, fish …) receives ``-c <cmd>``.
##
## :param shell: Shell executable name or path.
## :param command: The command string to execute.
## :returns: A seq of shell arguments.
func implBuildShellArgs(
  shell: string,
  command: string
): seq[string] =
  let lower = toLowerAscii(shell)
  if lower.contains("powershell") or lower.contains("pwsh"):
    result = @[
      "-NoProfile", "-NonInteractive",
      "-Command", command
    ]
  elif lower.contains("cmd"):
    result = @["/C", command]
  else:
    result = @["-c", command]

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Validates a command string against a regular-expression pattern.
## Returns true when the pattern is found anywhere in the command.
## The caller is expected to reject execution when this returns false.
##
## :param command: The command to validate.
## :param pattern: A PCRE regular-expression string.
## :returns: true if the pattern matches.
## :raises: GetError: If the pattern is not a valid regex.
##
## .. code-block:: nim
##   runnableExamples:
##     assert validateCommandPattern("ls -la", "^ls") == true
##     assert validateCommandPattern("rm -rf /", "^ls") == false
proc validateCommandPattern*(
  command: string,
  pattern: string
): bool =
  try:
    result = command.contains(re(pattern))
  except CatchableError:
    raise newException(GetError,
      fmt"invalid command-pattern regex: {pattern}")

## Displays the command on stderr and reads a single line from stdin.
## Returns true only when the user types "y" (case-insensitive).
##
## :param command: The command awaiting confirmation.
## :returns: true if the user confirms with "y".
##
## .. code-block:: nim
##   runnableExamples:
##     # Interactive — cannot be tested non-interactively.
##     discard
proc confirmExecution*(command: string): bool =
  stderr.write(fmt"execute: {command}\nconfirm? (y/N): ")
  stderr.flushFile()
  try:
    let response = readLine(stdin)
    result = toLowerAscii(response.strip()) == "y"
  except EOFError:
    result = false

## Executes a command string through the specified shell and returns
## the captured combined output together with the exit code.
##
## :param command: The command to execute.
## :param shell: Shell executable name or path.
## :returns: An ExecResult with captured output and exit code.
## :raises: GetError: If the shell process cannot be started.
##
## .. code-block:: nim
##   runnableExamples:
##     # Platform-specific — illustrative only.
##     discard
proc executeCommand*(
  command: string,
  shell: string
): ExecResult =
  let args = implBuildShellArgs(shell, command)
  var p: Process
  try:
    p = startProcess(
      shell,
      args = args,
      options = {poStdErrToStdOut, poUsePath}
    )
  except OSError as e:
    raise newException(GetError,
      fmt"cannot start shell '{shell}': {e.msg}")
  let output = p.outputStream.readAll()
  let exitCode = p.waitForExit()
  p.close()
  result = ExecResult(
    output: output,
    exitCode: exitCode
  )