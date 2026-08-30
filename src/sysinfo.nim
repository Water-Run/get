## System information gathering for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: sysinfo.nim
## :License: AGPL-3.0
##
## This module collects runtime system information such as OS
## type, CPU architecture, current working directory, username,
## hostname, and available command-line tools detected on PATH.
## The gathered snapshot is included in LLM prompts so the model
## can generate context-aware commands.  It also provides a
## diagnostic environment check that verifies Windows 10+ /
## macOS 12+ / Linux 6.0+ on a 64-bit platform.

{.experimental: "strictFuncs".}

import std/[os, osproc, strformat, strutils, times]

# ---------------------------------------------------------------------------
# Compile-time architecture gate
# ---------------------------------------------------------------------------

when not (hostCPU == "amd64" or hostCPU == "arm64"):
  {.error:
    "get requires a 64-bit platform (amd64 or arm64)".}

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Holds a snapshot of the current system environment used to
## provide context to the LLM when generating commands.
type
  SysInfo* = object
    os*: string             ## Operating system (e.g. "linux").
    arch*: string           ## CPU architecture (e.g. "amd64").
    hostname*: string       ## Machine hostname.
    username*: string       ## Current username.
    cwd*: string            ## Current working directory.
    localDate*: string      ## Local calendar date in YYYY-MM-DD form.
    timeZone*: string       ## Named local timezone when cheaply discoverable.
    shell*: string          ## Configured shell name.
    shellVersion*: string   ## Shell --version first line.
    availableTools*: seq[string]  ## Tools found on PATH.

# ---------------------------------------------------------------------------
# Constants — tools to probe
# ---------------------------------------------------------------------------

## Tools to probe for on PATH.  Kept to commonly useful commands
## so the startup cost is acceptable.
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

## Skill-style usage hints for tools detected on PATH.  Surfaced in
## the LLM system prompt so the model can pick the right tool
## without guessing.  Entries are deliberately concise.
const PROBE_TOOL_HINTS* = [
  ("git",     "version-control inspection (log, status, diff, show)"),
  ("curl",    "HTTP GET / file fetch — use -sS, never -o/-O"),
  ("wget",    "HTTP downloader that normally writes a file; prefer curl"),
  ("python3", "Python 3 interpreter for ad-hoc scripts"),
  ("python",  "Python 2/3 interpreter for ad-hoc scripts"),
  ("node",    "JavaScript runtime for ad-hoc scripts"),
  ("deno",    "secure JavaScript/TypeScript runtime"),
  ("docker",  "container/image inspection (ps, images, inspect)"),
  ("jq",      "JSON pretty-printing & query language"),
  ("sed",     "stream editor — for read-only transforms only"),
  ("awk",     "field-oriented text processor"),
  ("grep",    "line-based regex search"),
  ("find",    "filesystem walker (read-only when no -delete)"),
  ("ssh",     "remote shell — read-only commands only"),
  ("rsync",   "file sync — read-only when used with --dry-run"),
  ("nim",     "Nim compiler / language tools"),
  ("nimble",  "Nim package manager — read-only via list/show")
]

## Returns the Skill-style hint for a probe tool, or empty string
## when the tool has no curated hint.
func getProbeHint*(name: string): string =
  for (n, hint) in PROBE_TOOL_HINTS:
    if n == name: return hint
  result = ""

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func implSafeTimezoneName(value: string): string =
  let candidate = value.strip()
  if candidate.len == 0 or candidate.len > 128 or candidate.startsWith(":"):
    return ""
  for character in candidate:
    if character notin {
      'A' .. 'Z', 'a' .. 'z', '0' .. '9', '/', '_', '-', '+'
    }:
      return ""
  result = candidate

proc implLocalTimezoneName(): string =
  result = implSafeTimezoneName(getEnv("TZ", ""))
  if result.len > 0:
    return
  when defined(posix):
    try:
      if symlinkExists("/etc/localtime"):
        let target = expandSymlink("/etc/localtime")
        let marker = "zoneinfo/"
        let markerIndex = target.find(marker)
        if markerIndex >= 0 and markerIndex + marker.len < target.len:
          result = implSafeTimezoneName(
            target[markerIndex + marker.len .. ^1])
          if result.len > 0:
            return
      if fileExists("/etc/timezone"):
        result = implSafeTimezoneName(readFile("/etc/timezone"))
    except OSError, IOError:
      result = ""

## Attempts to obtain the shell version string by running
## ``<shell> --version``.
##
## :param shell: Shell executable name or path.
## :returns: First line of version output, or empty on failure.
proc implGetShellVersion(shell: string): string =
  try:
    let (output, exitCode) =
      execCmdEx(shell & " --version")
    if exitCode == 0 and output.len > 0:
      result = output.strip().splitLines()[0]
    else:
      result = ""
  except OSError, IOError:
    result = ""

## Checks whether a tool is available on PATH.
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

## Collects only environment data available without starting subprocesses.
##
## This is the v3 hot-path collector. Shell version and executable discovery
## remain lazy, avoiding dozens of serial PATH probes before a model request.
##
## :param shell: Configured shell name.
## :returns: A lightweight SysInfo snapshot.
##
## .. code-block:: nim
##   runnableExamples:
##     let info = collectFastSysInfo("bash")
##     assert info.os.len > 0
##     assert info.availableTools.len == 0
proc collectFastSysInfo*(shell: string): SysInfo =
  result = SysInfo(
    os: hostOS,
    arch: hostCPU,
    hostname: getEnv("HOSTNAME", getEnv("COMPUTERNAME", "")),
    username: getEnv("USER", getEnv("USERNAME", "")),
    cwd: getCurrentDir(),
    localDate: now().format("yyyy-MM-dd"),
    timeZone: implLocalTimezoneName(),
    shell: shell,
    shellVersion: "",
    availableTools: @[]
  )

## Collects a snapshot of the current system environment.
##
## :param shell: The configured shell name.
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
    localDate: now().format("yyyy-MM-dd"),
    timeZone: implLocalTimezoneName(),
    shell: shell,
    shellVersion: "",
    availableTools: @[]
  )
  try:
    result.hostname = getEnv("HOSTNAME",
      getEnv("COMPUTERNAME", ""))
    if result.hostname.len == 0:
      let (h, code) = execCmdEx("hostname")
      if code == 0:
        result.hostname = h.strip()
  except OSError, IOError:
    discard
  when defined(windows):
    result.username = getEnv("USERNAME", "")
  else:
    result.username = getEnv("USER", "")
  result.shellVersion = implGetShellVersion(shell)
  for tool in PROBE_TOOLS:
    if implToolAvailable(tool):
      result.availableTools.add(tool)

## Formats a SysInfo snapshot into a multi-line string suitable
## for inclusion in an LLM prompt.
##
## :param info: The system information snapshot.
## :returns: A human-readable description of the system.
##
## .. code-block:: nim
##   runnableExamples:
##     let info = SysInfo(os: "linux", arch: "amd64",
##       hostname: "dev", username: "user",
##       cwd: "/home", shell: "bash",
##       shellVersion: "5.2",
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
  if info.localDate.len > 0:
    lines.add(fmt"Local date: {info.localDate}")
  if info.timeZone.len > 0:
    lines.add(fmt"Timezone: {info.timeZone}")
  lines.add(fmt"Shell: {info.shell}")
  if info.shellVersion.len > 0:
    lines.add(
      fmt"Shell version: {info.shellVersion}")
  if info.availableTools.len > 0:
    lines.add(
      "Available tools: " &
      info.availableTools.join(", "))
  result = lines.join("\n")

## Checks whether the runtime environment meets the minimum
## requirements.  Returns an empty string when OK, or a warning.
##
## :returns: Empty string if OK, warning text otherwise.
##
## .. code-block:: nim
##   runnableExamples:
##     let w = checkEnvironment()
##     discard w
proc checkEnvironment*(): string =
  when defined(windows):
    try:
      let (output, _) = execCmdEx("cmd /c ver")
      let idx = output.find("Version ")
      if idx >= 0:
        let vStart = idx + "Version ".len
        let vEnd = output.find("]", vStart)
        if vEnd > vStart:
          let verStr = output[vStart ..< vEnd]
          let parts = verStr.split(".")
          if parts.len >= 1:
            try:
              let major = parseInt(
                parts[0].strip())
              if major < 10:
                return "warning: Windows 10+ " &
                  "required (detected major " &
                  fmt"version {major})"
            except ValueError:
              discard
    except OSError, IOError:
      discard
  elif defined(macosx):
    try:
      let (output, code) =
        execCmdEx("sw_vers -productVersion")
      if code == 0 and output.len > 0:
        let ver = output.strip()
        let parts = ver.split(".")
        if parts.len >= 1:
          try:
            let major = parseInt(parts[0].strip())
            if major < 12:
              return "warning: macOS 12+ " &
                fmt"required (detected {ver})"
          except ValueError:
            discard
    except OSError, IOError:
      discard
  elif defined(linux):
    try:
      let (output, code) =
        execCmdEx("uname -r")
      if code == 0 and output.len > 0:
        let ver = output.strip()
        let parts = ver.split(".")
        if parts.len >= 1:
          try:
            let major = parseInt(
              parts[0].strip())
            if major < 6:
              return "warning: Linux kernel " &
                fmt"6.0+ required (detected {ver})"
          except ValueError:
            discard
    except OSError, IOError:
      discard
  result = ""
