## System information gathering for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-14
## :File: sysinfo.nim
## :License: AGPL-3.0
##
## This module collects runtime system information such as OS type,
## CPU architecture, current working directory, username, hostname,
## available command-line tools, and bundled binary tools shipped
## alongside the executable.  The gathered snapshot is included in
## LLM prompts so the model can generate context-aware commands.
## It also provides a startup environment check that verifies
## Windows 10+ / Linux 6.0+ on a 64-bit platform.

{.experimental: "strictFuncs".}

import std/[os, osproc, strformat, strutils]

import utils

# ---------------------------------------------------------------------------
# Compile-time architecture gate
# ---------------------------------------------------------------------------

when not (hostCPU == "amd64" or hostCPU == "arm64"):
  {.error: "get requires a 64-bit platform (amd64 or arm64)".}

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Describes a single tool bundled in the bin/ directory next to the
## executable.
type
  BundledTool* = object
    name*: string         ## Command name (platform-specific).
    description*: string  ## Short description of capabilities.

## Holds a snapshot of the current system environment used to
## provide context to the LLM when generating commands.
type
  SysInfo* = object
    os*: string              ## Operating system (e.g. "linux").
    arch*: string            ## CPU architecture (e.g. "amd64").
    hostname*: string        ## Machine hostname.
    username*: string        ## Current username.
    cwd*: string             ## Current working directory.
    shell*: string           ## Configured shell name.
    shellVersion*: string    ## Shell --version first line.
    availableTools*: seq[string]   ## Tools found on PATH.
    bundledTools*: seq[BundledTool] ## Tools shipped in bin/.
    binDir*: string          ## Absolute path to bundled bin dir.

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

## Bundled tool definitions for Linux.  Descriptions include
## key flags and explicit read-only safety notes.
const BUNDLED_DEFS_LINUX = [
  ("rg",
   "ripgrep — ultra-fast regex search in files. " &
   "Usage: rg <pattern> [path]. " &
   "Key flags: -i (case-insensitive), -l (files " &
   "only), -c (count), -n (line numbers), " &
   "--type <t> (filter by file type), " &
   "--json (JSON output). Read-only tool."),
  ("fd",
   "fd — fast file/directory finder. " &
   "Usage: fd <pattern> [path]. " &
   "Key flags: -e <ext>, -t f (files), " &
   "-t d (dirs), --hidden. " &
   "NEVER use -x/--exec with write commands. " &
   "Read-only tool."),
  ("sg",
   "ast-grep (sg) — AST-level structural code " &
   "search and lint. " &
   "Usage: sg -p '<ast-pattern>' [path]. " &
   "Supports many languages. Use sg run " &
   "--pattern '<pat>' for quick searches. " &
   "Read-only tool."),
  ("pmc",
   "pack-my-code — package source files into a " &
   "single text block (ideal for LLM context). " &
   "Usage: pmc [<directory>] (defaults to '.'). " &
   "Key flags: -t (prepend directory tree), " &
   "-s (append statistics), " &
   "-m '<glob>' (include only matching), " &
   "-x '<glob>' (exclude matching), " &
   "-r (ignore .gitignore, direct scan), " &
   "-w <mode> (wrap: md/nil/block), " &
   "-p <mode> (path: relative/name/absolute). " &
   "NEVER use -o or -c flags (they write files/" &
   "clipboard). Read-only tool."),
  ("tree",
   "tree++ (bundled as 'tree') — enhanced " &
   "directory tree listing. " &
   "Usage: tree [path]. " &
   "Key flags: -f/--files (show files), " &
   "-L/--level <n> (depth limit), " &
   "-I/--exclude <pat> (exclude pattern), " &
   "-s/--size (file sizes in bytes), " &
   "-H/--human-readable (human sizes), " &
   "-g/--gitignore (respect .gitignore), " &
   "-N/--no-win-banner (skip header), " &
   "-e/--report (summary statistics). " &
   "NEVER use -o/--output (writes files). " &
   "Read-only tool.")
]

## Bundled tool definitions for Windows.
const BUNDLED_DEFS_WINDOWS = [
  ("rg",
   "ripgrep — ultra-fast regex search in files. " &
   "Usage: rg <pattern> [path]. " &
   "Key flags: -i, -l, -c, -n, --type <t>, " &
   "--json. Read-only tool."),
  ("fd",
   "fd — fast file/directory finder. " &
   "Usage: fd <pattern> [path]. " &
   "Key flags: -e <ext>, -t f, -t d, --hidden. " &
   "NEVER use -x/--exec with write commands. " &
   "Read-only tool."),
  ("sg",
   "ast-grep (sg) — AST-level structural code " &
   "search and lint. " &
   "Usage: sg -p '<ast-pattern>' [path]. " &
   "Read-only tool."),
  ("pmc",
   "pack-my-code — package source files into a " &
   "single text block for LLM context. " &
   "Usage: pmc [<directory>]. " &
   "Key flags: -t, -s, -m '<glob>', " &
   "-x '<glob>', -r, -w <mode>, -p <mode>. " &
   "NEVER use -o or -c flags. Read-only tool."),
  ("treepp",
   "tree++ — enhanced directory tree for Windows. " &
   "Usage: treepp [path] /F. " &
   "Key flags: /F (show files), /NB (no banner), " &
   "/L <n> (depth limit), /X <pat> (exclude), " &
   "/S (file sizes), /HR (human-readable sizes), " &
   "/G (respect .gitignore), " &
   "/RP (summary report), /B (batch mode). " &
   "NEVER use /O (writes files). Read-only tool.")
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
    let (output, exitCode) =
      execCmdEx(shell & " --version")
    if exitCode == 0 and output.len > 0:
      result = output.strip().splitLines()[0]
    else:
      result = ""
  except OSError, IOError:
    result = ""

## Checks whether a tool is available on PATH using ``which``
## (Unix) or ``where`` (Windows).
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

## Detects which bundled tools are present in the given directory.
##
## :param binDir: Absolute path to the bundled bin directory.
## :returns: A seq of BundledTool for every tool found.
proc implDetectBundledTools(
  binDir: string
): seq[BundledTool] =
  result = @[]
  if binDir.len == 0 or not dirExists(binDir):
    return
  when defined(windows):
    let defs = BUNDLED_DEFS_WINDOWS
  else:
    let defs = BUNDLED_DEFS_LINUX
  for (name, desc) in defs:
    when defined(windows):
      let path = binDir / (name & ".exe")
    else:
      let path = binDir / name
    if fileExists(path):
      result.add(BundledTool(
        name: name, description: desc))

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
  let binDir = getBundledBinDir()
  result = SysInfo(
    os: hostOS,
    arch: hostCPU,
    hostname: "",
    username: "",
    cwd: getCurrentDir(),
    shell: shell,
    shellVersion: "",
    availableTools: @[],
    bundledTools: @[],
    binDir: binDir
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
  result.bundledTools = implDetectBundledTools(binDir)

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
##       availableTools: @["git"],
##       bundledTools: @[], binDir: "")
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
    lines.add(
      fmt"Shell version: {info.shellVersion}")
  if info.availableTools.len > 0:
    lines.add(
      "Available tools: " &
      info.availableTools.join(", "))
  result = lines.join("\n")

## Formats bundled tool descriptions into a multi-line block for
## inclusion in the LLM system prompt.
##
## :param tools: The list of detected bundled tools.
## :returns: A descriptive block, or empty when no tools exist.
##
## .. code-block:: nim
##   runnableExamples:
##     let s = formatBundledTools(@[])
##     assert s.len == 0
func formatBundledTools*(
  tools: seq[BundledTool]
): string =
  if tools.len == 0:
    return ""
  var lines: seq[string] = @[]
  lines.add("BUNDLED TOOLS (pre-installed, " &
    "available in PATH for generated commands):")
  for t in tools:
    lines.add(fmt"- {t.name}: {t.description}")
  result = lines.join("\n")

## Checks whether the runtime environment meets the minimum
## requirements (Windows 10+ / Linux 6.0+, 64-bit).  Returns an
## empty string when everything is fine, or a warning message.
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
              let major = parseInt(parts[0].strip())
              if major < 10:
                return "warning: Windows 10+ " &
                  "required (detected major " &
                  fmt"version {major})"
            except ValueError:
              discard
    except OSError, IOError:
      discard
  elif defined(linux):
    try:
      let (output, code) = execCmdEx("uname -r")
      if code == 0 and output.len > 0:
        let ver = output.strip()
        let parts = ver.split(".")
        if parts.len >= 1:
          try:
            let major = parseInt(parts[0].strip())
            if major < 6:
              return "warning: Linux kernel 6.0+" &
                fmt" required (detected {ver})"
          except ValueError:
            discard
    except OSError, IOError:
      discard
  result = ""