## System information gathering for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-13
## :File: sysinfo.nim
## :License: AGPL-3.0
##
## This module collects runtime system information such as OS type,
## CPU architecture, current working directory, username, hostname,
## and available command-line tools.  The gathered snapshot is included
## in LLM prompts so the model can generate context-aware commands.

{.experimental: "strictFuncs".}

import std/[os, osproc, strformat, strutils]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Holds a snapshot of the current system environment used to provide
## context to the LLM when generating commands.
type
  SysInfo* = object
    os*: string              ## Operating system (e.g. "linux").
    arch*: string            ## CPU architecture (e.g. "amd64").
    hostname*: string        ## Machine hostname.
    username*: string        ## Current username.
    cwd*: string             ## Current working directory.
    shell*: string           ## Configured shell name.
    shellVersion*: string    ## Shell --version first line.
    availableTools*: seq[string] ## Tools found on PATH.

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Tools to probe for on PATH.  Kept to commonly useful commands so
## the startup cost is acceptable.
const PROBE_TOOLS* = [
  "git", "curl", "wget",
  "python3", "python", "pip3", "pip",
  "node", "npm", "deno", "bun",
  "docker",
  "gcc", "g++", "clang", "make", "cmake",
  "cargo", "rustc", "go", "java",
  "ruby", "perl",
  "jq", "sed", "awk", "grep", "find",
  "tar", "zip", "unzip",
  "ssh", "rsync",
  "nim", "nimble"
]

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Attempts to obtain the shell version string by running
## ``<shell> --version`` and returning the first line of output.
##
## :param shell: Shell executable name or path.
## :returns: First line of version output, or empty on failure.
proc implGetShellVersion(shell: string): string =
  try:
    let (output, exitCode) = execCmdEx(shell & " --version")
    if exitCode == 0 and output.len > 0:
      result = output.strip().splitLines()[0]
    else:
      result = ""
  except OSError, IOError:
    result = ""

## Checks whether a tool is available on PATH using ``which`` (Unix)
## or ``where`` (Windows).
##
## :param tool: The command name to check.
## :returns: true when the tool is found.
proc implToolAvailable(tool: string): bool =
  try:
    when defined(windows):
      let (_, exitCode) = execCmdEx(
        fmt"where {tool}")
    else:
      let (_, exitCode) = execCmdEx(
        fmt"which {tool}")
    result = exitCode == 0
  except OSError, IOError:
    result = false

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Collects a snapshot of the current system environment.
##
## :param shell: The configured shell name used for execution.
## :returns: A populated SysInfo instance.
##
## .. code-block:: nim
##   runnableExamples:
##     let info = collectSysInfo("bash")
##     assert info.os.len > 0
proc collectSysInfo*(shell: string): SysInfo =
  result = SysInfo(
    os: hostOS,
    arch: hostCPU,
    hostname: "",
    username: "",
    cwd: getCurrentDir(),
    shell: shell,
    shellVersion: "",
    availableTools: @[]
  )
  # Hostname
  try:
    result.hostname = getEnv("HOSTNAME",
      getEnv("COMPUTERNAME", ""))
    if result.hostname.len == 0:
      let (h, code) = execCmdEx("hostname")
      if code == 0:
        result.hostname = h.strip()
  except OSError, IOError:
    discard
  # Username
  when defined(windows):
    result.username = getEnv("USERNAME", "")
  else:
    result.username = getEnv("USER", "")
  # Shell version
  result.shellVersion = implGetShellVersion(shell)
  # Available tools
  for tool in PROBE_TOOLS:
    if implToolAvailable(tool):
      result.availableTools.add(tool)

## Formats a SysInfo snapshot into a multi-line string suitable for
## inclusion in an LLM prompt.
##
## :param info: The system information snapshot.
## :returns: A human-readable description of the system.
##
## .. code-block:: nim
##   runnableExamples:
##     let info = SysInfo(os: "linux", arch: "amd64",
##       hostname: "dev", username: "user", cwd: "/home",
##       shell: "bash", shellVersion: "5.2",
##       availableTools: @["git"])
##     let s = formatSysInfo(info)
##     assert s.contains("linux")
func formatSysInfo*(info: SysInfo): string =
  var lines: seq[string] = @[]
  lines.add(fmt"OS: {info.os}")
  lines.add(fmt"Architecture: {info.arch}")
  if info.hostname.len > 0:
    lines.add(fmt"Hostname: {info.hostname}")
  if info.username.len > 0:
    lines.add(fmt"Username: {info.username}")
  lines.add(fmt"Working directory: {info.cwd}")
  lines.add(fmt"Shell: {info.shell}")
  if info.shellVersion.len > 0:
    lines.add(fmt"Shell version: {info.shellVersion}")
  if info.availableTools.len > 0:
    lines.add(
      "Available tools: " &
      info.availableTools.join(", "))
  result = lines.join("\n")