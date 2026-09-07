## Mandatory read-only command policy for get v3.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: command_policy.nim
## :License: AGPL-3.0
##
## The policy is allowlist-based. It first decodes a deliberately small shell
## grammar (simple commands, pipelines, and reader-only sequences), then
## validates every executable and the state-changing options of otherwise
## read-only tools. Unknown syntax and unknown executables fail closed. This
## avoids blacklist obfuscation bypasses and false positives from dangerous
## words used only as search text.

{.experimental: "strictFuncs".}

import std/strutils

type
  CommandPolicyDecision* = object
    allowed*: bool  ## Whether the command may proceed to configurable checks.
    reason*: string ## Concise rejection reason, or empty when allowed.

  ParsedCommand = object
    valid: bool
    reason: string
    stages: seq[seq[string]]
    variableExpansionStages: seq[bool]
    unstableVariableExpansionStages: seq[bool]
    inputRedirectionStages: seq[bool]
    unsafeUnquotedGlobStages: seq[bool]
    unsafePowerShellSplat: bool

const SIMPLE_READ_ONLY_COMMANDS = [
  "pwd", "ls", "dir", "cat", "type", "head", "tail", "wc", "cut",
  "tr", "grep", "egrep", "fgrep", "jq", "column", "basename",
  "dirname", "readlink", "realpath", "stat", "du", "df",
  "free", "uname", "whoami", "id", "uptime", "printenv", "locale",
  "host", "dig", "netstat", "lsof", "ps", "pstree", "vmstat",
  "iostat", "mpstat", "lsblk", "lscpu", "lspci", "lsusb",
  "nproc", "lsmem", "lsns", "lsipc", "lslocks", "lsmod", "modinfo",
  "pmap", "pidof", "sw_vers", "system_profiler", "ioreg",
  "lsb_release", "biosdecode", "cpuid", "acpi", "glxinfo", "clinfo",
  "rocminfo", "vm_stat",
  "findmnt", "md5sum", "sha1sum", "sha224sum", "sha256sum",
  "sha384sum", "sha512sum", "b2sum", "cksum", "strings",
  "od", "hexdump", "cmp", "comm", "nl", "fold", "fmt", "expand",
  "unexpand", "paste", "join", "tac", "rev", "numfmt", "tsort",
  "getconf", "cal", "lsattr", "getfacl", "namei", "tokei",
  "getenforce", "sestatus", "aa-status", "apparmor_status",
  "systemd-detect-virt", "systemd-cgls", "numastat", "kextstat",
  "mdls",
  "test", "[", "printf", "echo", "true",
  "false", "tty", "groups", "users", "who", "w", "last", "lastlog",
  "getent", "where", "whereis", "which", "ver", "systeminfo",
  "tasklist", "driverquery", "qwinsta", "qprocess"
]

## Exact PowerShell readers and pure pipeline formatters. Wildcard Get-* matching
## is avoided because third-party modules can autoload arbitrary functions.
const POWERSHELL_READ_ONLY_COMMANDS = [
  "get-location", "get-childitem", "get-item", "get-content",
  "get-process", "get-service", "get-command", "get-date",
  "get-ciminstance", "get-computerinfo", "get-winevent", "get-counter",
  "get-volume", "get-disk", "get-partition", "get-netadapter",
  "get-netipaddress", "get-netroute", "get-nettcpconnection",
  "get-netudpendpoint", "get-acl", "get-authenticodesignature",
  "get-filehash", "get-host", "get-culture", "get-uiculture",
  "get-scheduledtask", "get-localuser", "get-localgroup", "get-hotfix",
  "get-dnsclientserveraddress", "get-netipconfiguration",
  "get-physicaldisk", "get-storagepool", "get-pnpdevice", "get-eventlog",
  "get-wmiobject", "get-netfirewallprofile", "get-netfirewallrule",
  "get-netfirewallportfilter", "get-netneighbor", "get-netconnectionprofile",
  "get-dnsclientcache", "get-smbshare", "get-smbconnection", "get-psdrive",
  "get-itemproperty", "get-itempropertyvalue", "get-localgroupmember",
  "get-scheduledtaskinfo", "get-bitlockervolume", "get-tpm",
  "get-mpcomputerstatus", "get-mppreference", "get-appxpackage",
  "get-windowsoptionalfeature", "get-windowscapability",
  "get-processmitigation", "get-computerrestorepoint", "test-netconnection",
  "test-connection", "confirm-securebootuefi", "tnc",
  "resolve-dnsname", "get-netipinterface", "get-dnsclient",
  "get-dnsclientglobalsetting", "get-netadapterstatistics",
  "get-netadapteradvancedproperty", "get-netoffloadglobalsetting",
  "get-netnat", "get-netnatsession", "get-netnatstaticmapping",
  "get-netlbfoteam", "get-netlbfoteammember", "get-smbmapping",
  "get-smbclientconfiguration", "get-smbserverconfiguration",
  "get-diskimage", "get-storagereliabilitycounter", "get-mpthreat",
  "get-mpthreatdetection", "get-cimclass", "get-pnpdeviceproperty",
  "get-random", "get-variable", "get-history", "get-module",
  "get-help", "measure-object", "select-object",
  "sort-object", "group-object", "compare-object", "where-object",
  "format-list", "format-table", "format-wide", "format-custom",
  "out-string", "out-null", "write-output", "select-string", "test-path",
  "resolve-path", "split-path", "join-path", "convertto-json",
  "convertto-csv", "convertto-html", "convertto-xml", "convertfrom-json",
  "convertfrom-csv", "convertfrom-stringdata", "gci", "gc", "gi", "gl",
  "gps", "gsv", "gcm", "sls", "fl", "ft", "fw"
]

const VERSION_ONLY_COMMANDS = [
  "python", "python3", "node", "deno", "ruby", "perl", "php", "java",
  "javac", "nim", "nimble", "gcc", "g++", "clang", "clang++", "rustc",
  "cargo", "go", "dotnet", "cmake", "make", "ninja", "openssl",
  "julia", "lua", "luajit", "swift", "kotlinc"
]

## Programs whose stdin is unambiguously data after their ordinary option
## validation has passed. Keeping this separate from the executable allowlist
## prevents constructs such as `curl --config - < file` from turning a
## read-only-looking redirect into a second, unchecked command language.
const STDIN_DATA_READERS = [
  "cat", "head", "tail", "wc", "cut", "tr", "grep", "egrep", "fgrep",
  "jq", "column", "md5sum", "sha1sum", "sha224sum", "sha256sum",
  "sha384sum", "sha512sum", "b2sum", "cksum", "strings", "od",
  "hexdump", "nl", "fold", "fmt", "expand", "unexpand", "paste", "join",
  "sort", "uniq", "base64", "xxd", "cmp", "comm", "diff", "diff3",
  "awk", "sed"
]

func implReject(reason: string): CommandPolicyDecision =
  result = CommandPolicyDecision(allowed: false, reason: reason)

func implAllow(): CommandPolicyDecision =
  result = CommandPolicyDecision(allowed: true, reason: "")

func implAllDigits(value: string): bool =
  if value.len == 0:
    return false
  for character in value:
    if character notin {'0' .. '9'}:
      return false
  result = true

func implUnsignedAtMost(value: string, maximum: int): bool =
  if not implAllDigits(value):
    return false
  var parsed = 0
  for character in value:
    let digit = ord(character) - ord('0')
    if parsed > (maximum - digit) div 10:
      return false
    parsed = parsed * 10 + digit
  result = parsed <= maximum

func implPositiveAtMost(value: string, maximum: int): bool =
  if not implUnsignedAtMost(value, maximum):
    return false
  for character in value:
    if character != '0':
      return true
  result = false

func implPositiveMultipleAtMost(
  value: string,
  maximum: int,
  multiple: int
): bool =
  if multiple <= 0 or not implPositiveAtMost(value, maximum):
    return false
  var parsed = 0
  for character in value:
    parsed = parsed * 10 + ord(character) - ord('0')
  result = parsed mod multiple == 0

func implDecimalAtMost(value: string, maximum: int): bool =
  if value.len == 0:
    return false
  var whole = 0
  var seenDigit = false
  var seenDecimal = false
  var fractionalNonZero = false
  for character in value:
    if character == '.':
      if seenDecimal:
        return false
      seenDecimal = true
      continue
    if character notin {'0' .. '9'}:
      return false
    seenDigit = true
    let digit = ord(character) - ord('0')
    if seenDecimal:
      fractionalNonZero = fractionalNonZero or digit != 0
    else:
      if whole > (maximum - digit) div 10:
        return false
      whole = whole * 10 + digit
  if not seenDigit or whole > maximum:
    return false
  result = whole < maximum or not fractionalNonZero

func implPositiveDecimalAtMost(value: string, maximum: int): bool =
  if not implDecimalAtMost(value, maximum):
    return false
  for character in value:
    if character in {'1' .. '9'}:
      return true

func implSignedIntegerAtMost(value: string, maximum: int): bool =
  if value.len == 0:
    return false
  let start = if value[0] in {'+', '-'}: 1 else: 0
  if start == value.len:
    return false
  result = implUnsignedAtMost(value[start .. ^1], maximum)

func implSignedIntegerNonZeroAtMost(value: string, maximum: int): bool =
  if not implSignedIntegerAtMost(value, maximum):
    return false
  let start = if value[0] in {'+', '-'}: 1 else: 0
  for index in start ..< value.len:
    if value[index] != '0':
      return true

func implValidateSleep(tokens: seq[string]): CommandPolicyDecision =
  if tokens.len == 2 and toLowerAscii(tokens[1]) in ["--help", "--version"]:
    return implAllow()
  if tokens.len != 2:
    return implReject("sleep requires one duration bounded to 10 seconds")
  var duration = toLowerAscii(tokens[1])
  if duration.endsWith("s"):
    duration.setLen(duration.len - 1)
  if not implDecimalAtMost(duration, 10):
    return implReject("sleep duration exceeds the 10-second bound")
  result = implAllow()

func implValidateSeq(tokens: seq[string]): CommandPolicyDecision =
  if tokens.len == 2 and toLowerAscii(tokens[1]) in ["--help", "--version"]:
    return implAllow()
  var operands: seq[string] = @[]
  var index = 1
  while index < tokens.len:
    let lower = toLowerAscii(tokens[index])
    if lower in ["-s", "--separator", "-f", "--format"]:
      if index + 1 >= tokens.len:
        return implReject("seq formatting option is missing its value")
      index += 2
      continue
    if lower.startsWith("--separator=") or lower.startsWith("--format=") or
        lower in ["-w", "--equal-width"]:
      index += 1
      continue
    if lower == "--":
      if index + 1 < tokens.len:
        operands.add(tokens[index + 1 .. ^1])
      break
    if tokens[index].startsWith("-") and
        not implSignedIntegerAtMost(tokens[index], 100_000):
      return implReject("seq option is outside the finite-output allowlist")
    operands.add(tokens[index])
    index += 1
  if operands.len < 1 or operands.len > 3:
    return implReject("seq requires one to three bounded integer operands")
  for operand in operands:
    if not implSignedIntegerAtMost(operand, 100_000):
      return implReject("seq operand exceeds the finite-output bound")
  if operands.len == 3 and
      not implSignedIntegerNonZeroAtMost(operands[1], 100_000):
    return implReject("seq increment must be a non-zero bounded integer")
  result = implAllow()

func implSafeDiagnosticWord(value: string): bool =
  if value.len == 0 or value.len > 256:
    return false
  for character in value:
    if character notin {
      'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-', '.', '+', '%', ','
    }:
      return false
  result = true

func implSafePidList(value: string): bool =
  if value.len == 0 or value.len > 384:
    return false
  var entries = 1
  var digitsInEntry = 0
  for character in value:
    if character in {'0' .. '9'}:
      digitsInEntry += 1
    elif character == ',' and digitsInEntry > 0 and entries < 32:
      entries += 1
      digitsInEntry = 0
    else:
      return false
  result = digitsInEntry > 0

func implOptionMatches(token: string, option: string): bool =
  let lower = toLowerAscii(token)
  result = lower == toLowerAscii(option) or
    lower.startsWith(toLowerAscii(option) & "=")

func implIsSafeOptionTerminator(tokens: seq[string], index: int): bool =
  ## A bare "--" is unambiguously an option terminator when it is first or
  ## follows an executable/operand. If it immediately follows an option, it
  ## might instead be that option's value; keep scanning in that ambiguous
  ## case so a later mutator cannot hide behind it.
  result = index >= 0 and index < tokens.len and tokens[index] == "--" and
    (index == 0 or not tokens[index - 1].startsWith("-") or
      tokens[index - 1].contains('='))

func implIsSafeOptionTerminatorAfterFlags(
  tokens: seq[string],
  index: int,
  valuelessOptions: openArray[string],
  valuelessShortChars: string = ""
): bool =
  if implIsSafeOptionTerminator(tokens, index):
    return true
  if index <= 0 or index >= tokens.len or tokens[index] != "--":
    return false
  let previous = tokens[index - 1]
  let lowerPrevious = toLowerAscii(previous)
  for option in valuelessOptions:
    if lowerPrevious == toLowerAscii(option):
      return true
  if valuelessShortChars.len == 0 or previous.len < 2 or
      not previous.startsWith("-") or previous.startsWith("--"):
    return false
  for character in previous[1 .. ^1]:
    if character notin valuelessShortChars:
      return false
  result = true

func implHasOption(tokens: seq[string], options: openArray[string]): bool =
  for index, token in tokens:
    if implIsSafeOptionTerminator(tokens, index):
      break
    for option in options:
      if implOptionMatches(token, option):
        return true

## Matches exact forbidden options plus unambiguous-looking GNU long-option
## abbreviations.  Many getopt_long users accept ``--out=...`` as
## ``--output=...``; treating only the fully-spelled form as dangerous would
## leave a generic write bypass.
func implHasForbiddenOption(
  tokens: seq[string],
  options: openArray[string]
): bool =
  for index, token in tokens:
    # GNU-style readers use "--" as an option terminator. A later token that
    # merely looks like an option is an operand/search term, not a control flag.
    if implIsSafeOptionTerminator(tokens, index):
      break
    let lower = toLowerAscii(token)
    let separator = lower.find('=')
    let optionName =
      if separator >= 0: lower[0 ..< separator]
      else: lower
    for option in options:
      let forbidden = toLowerAscii(option)
      if implOptionMatches(token, option):
        return true
      if optionName.startsWith("--") and forbidden.startsWith("--") and
          optionName.len >= 3 and forbidden.startsWith(optionName):
        return true

func implHasForbiddenOptionAfterFlags(
  tokens: seq[string],
  options: openArray[string],
  valuelessOptions: openArray[string],
  valuelessShortChars: string = ""
): bool =
  for index, token in tokens:
    if implIsSafeOptionTerminatorAfterFlags(
        tokens, index, valuelessOptions, valuelessShortChars):
      break
    let lower = toLowerAscii(token)
    let separator = lower.find('=')
    let optionName =
      if separator >= 0: lower[0 ..< separator]
      else: lower
    for option in options:
      let forbidden = toLowerAscii(option)
      if implOptionMatches(token, option):
        return true
      if optionName.startsWith("--") and forbidden.startsWith("--") and
          optionName.len >= 3 and forbidden.startsWith(optionName):
        return true

## PowerShell permits abbreviated parameter names such as ``-OutF`` for
## ``-OutFile``. Only use this helper with a list of write-capable parameters.
func implHasForbiddenPowerShellParameter(
  tokens: seq[string],
  parameters: openArray[string]
): bool =
  for token in tokens:
    let lower = toLowerAscii(token)
    let separator = lower.find(':')
    let parameterName =
      if separator >= 0: lower[0 ..< separator]
      else: lower
    if not parameterName.startsWith("-") or
        parameterName.startsWith("--") or parameterName.len < 2:
      continue
    for parameter in parameters:
      let forbidden = toLowerAscii(parameter)
      if forbidden.startsWith(parameterName):
        return true

func implHasToken(tokens: seq[string], values: openArray[string]): bool =
  for token in tokens:
    let lower = toLowerAscii(token)
    for value in values:
      if lower == toLowerAscii(value):
        return true

## Boolean CLI switches frequently accept an explicit ``=false`` spelling.
## Mere option presence is therefore insufficient when the switch is what
## makes a reader finite (for example Docker's ``--no-stream``).
func implHasEnabledBooleanOption(
  tokens: seq[string],
  option: string
): bool =
  let expected = toLowerAscii(option)
  for index, token in tokens:
    if implIsSafeOptionTerminator(tokens, index):
      break
    let lower = toLowerAscii(token)
    if lower == expected:
      return true
    if lower.startsWith(expected & "="):
      return lower[expected.len + 1 .. ^1] in ["1", "true", "yes", "on"]

func implDockerFollowEnabled(token: string): bool =
  let lower = toLowerAscii(token)
  if lower in ["-f", "--follow"]:
    return true
  for option in ["-f=", "--follow="]:
    if lower.startsWith(option):
      return lower[option.len .. ^1] notin ["0", "false", "no", "off"]
  result = token.startsWith("-") and not token.startsWith("--") and
    token.contains('f')

func implFirstAction(
  tokens: seq[string],
  start: int,
  optionsWithValue: openArray[string]
): string =
  var index = start
  while index < tokens.len:
    let lower = toLowerAscii(tokens[index])
    if not lower.startsWith("-"):
      return lower
    var consumesValue = false
    for option in optionsWithValue:
      if lower == toLowerAscii(option):
        consumesValue = true
        break
    if consumesValue:
      index += 2
    else:
      index += 1

func implCurlSchemeIsReadOnly(value: string): bool =
  var candidate = toLowerAscii(value.strip())
  if candidate.startsWith("--url="):
    candidate = candidate[6 .. ^1]
  # curl accepts schemes without // too (for example gopher:payload). This
  # helper is called only for URL operands, never header or referer values.
  let separator = candidate.find(':')
  if separator <= 0:
    return true
  for character in candidate[0 ..< separator]:
    if character notin {'a' .. 'z', '0' .. '9', '+', '-', '.'}:
      return true
  result = candidate[0 ..< separator] in [
    "http", "https", "file", "ftp", "ftps", "scp", "sftp"
  ]

## Rejects header sources and the standard method-override headers that can
## turn an apparent GET into a state-changing application request.
func implHeaderCanOverrideMethod(value: string): bool =
  let candidate = value.strip()
  if candidate.startsWith("@"):
    return true
  let separator = candidate.find(':')
  if separator <= 0:
    return false
  let name = toLowerAscii(candidate[0 ..< separator].strip())
  result = name in [
    "x-http-method", "x-http-method-override", "x-method-override"
  ]

func implHasCmdExpansion(command: string): bool =
  var index = 0
  while index < command.len:
    if command[index] == '%' and index + 1 < command.len:
      if command[index + 1] in {'0' .. '9'}:
        return true
      let closing = command.find('%', index + 1)
      if closing > index + 1:
        return true
    index += 1

## Returns the executable basename while rejecting attacker-controlled paths.
func implExecutableName(raw: string): string =
  var path = toLowerAscii(raw).replace('\\', '/')
  if path.contains('/'):
    if path.endsWith('/'):
      return ""
    if path.startsWith("./") or path.startsWith("../"):
      return ""
    for segment in path.split('/'):
      if segment in [".", ".."]:
        return ""
    let trustedPosix =
      path.startsWith("/bin/") or path.startsWith("/usr/bin/") or
      path.startsWith("/usr/sbin/") or path.startsWith("/sbin/") or
      path.startsWith("/usr/local/bin/") or
      path.startsWith("/opt/homebrew/bin/")
    let trustedWindows = path.len > 3 and path[0] in {'a' .. 'z'} and
      path[1] == ':' and path[2 .. ^1].startsWith("/windows/system32/")
    if not trustedPosix and not trustedWindows:
      return ""
    let separator = path.rfind('/')
    path = path[separator + 1 .. ^1]
  if path.endsWith(".exe"):
    path.setLen(path.len - 4)
  result = path

## Accepts only a small set of non-secret identity/path variables. Their
## values are passed as arguments to already-approved readers and shell
## expansion does not re-parse metacharacters contained in the value.
func implSafeVariableLength(command: string, index: int): int =
  if index + 2 <= command.len and command[index ..< index + 2] == "$?":
    return 2
  for variable in ["HOME", "USER", "LOGNAME", "PWD"]:
    let braced = "${" & variable & "}"
    let bracedAfter = index + braced.len
    if bracedAfter <= command.len and
        command[index ..< bracedAfter] == braced:
      return braced.len
    let plain = "$" & variable
    let after = index + plain.len
    if after <= command.len and command[index ..< after] == plain and
        (after == command.len or
          command[after] notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}):
      return plain.len

## Variable expansion remains restricted to commands whose complete option
## surface is observational. This admits common model output such as
## `ls -d $HOME` without letting an attacker smuggle write-capable flags into
## curl, find, sort, xxd, or another otherwise constrained reader.
func implAllowsApprovedVariables(executable: string): bool =
  if executable in [
    "tail", "lsof", "findmnt", "vmstat", "iostat", "mpstat", "printf"
  ]:
    return false
  if executable in SIMPLE_READ_ONLY_COMMANDS:
    return true
  result = executable in [
    "write-output", "get-childitem", "get-item", "get-content",
    "get-filehash", "select-string", "test-path", "resolve-path",
    "split-path", "join-path", "gc", "gci", "gi", "sls"
  ]

func implAllowsStablePathVariables(executable: string): bool =
  ## These validators remain safe when a path is one shell word and the child
  ## environment guarantees HOME/PWD are absolute. This admits common
  ## `find "$HOME"` and `rg pattern "$PWD"` diagnostics without reopening
  ## unquoted word-splitting or option injection.
  result = executable in [
    "find", "fd", "fdfind", "rg", "git"
  ]

## Unqualified globs are safe for readers whose complete option surface cannot
## write files or execute helpers. Dual-use tools (find, sed, sort, rg, git,
## and similar validators) still require a qualified glob or ``--`` because a
## hostile filename could otherwise expand into a dangerous option.
func implAllowsUnquotedGlobs(executable: string): bool =
  if executable in ["tail", "lsof", "findmnt", "vmstat", "iostat", "mpstat"]:
    return false
  result = executable in SIMPLE_READ_ONLY_COMMANDS or executable in [
    "write-output", "get-childitem", "get-item", "get-content",
    "get-filehash", "select-string", "test-path", "resolve-path",
    "split-path", "join-path", "gc", "gci", "gi", "sls"
  ]

## Redirection devices are shell-specific. Treating Windows `NUL` as a sink
## on POSIX would instead create a real file named `nul` (and vice versa).
func implIsNullDevice(target: string, shell: string): bool =
  let normalized = toLowerAscii(target)
  let lowerShell = toLowerAscii(shell)
  if lowerShell.contains("powershell") or lowerShell.contains("pwsh"):
    if normalized == "$null":
      return true
    when defined(windows):
      return normalized == "nul"
    else:
      return false  # PowerShell on POSIX creates a real file named nul.
  if lowerShell.contains("cmd"):
    return normalized == "nul"
  result = target == "/dev/null"

func implIsNullSink(target: string, shell: string): bool =
  result = target in ["&1", "&2"] or
    implIsNullDevice(target, shell)

## Parses simple commands, pipelines, and compound sequences whose every
## component is validated independently. Substitution, background execution,
## grouping, here-documents, and file output fail closed. A single literal-file
## stdin redirect may be admitted for explicitly safe data readers; it is
## parsed here instead of being accepted as generic shell text. Quote
## concatenation is normalised before executable validation.
func implParseCommand(command: string, shell: string): ParsedCommand =
  var stage: seq[string] = @[]
  var token = ""
  var tokenStarted = false
  var quote = '\0'
  var index = 0
  var stageOptionsEnded = false
  var stageUsesApprovedVariable = false
  var stageUsesUnstableVariable = false
  var stageUsesInputRedirection = false
  var stageUsesUnsafeGlob = false
  let cmdShell = toLowerAscii(shell).contains("cmd")
  let powerShell = toLowerAscii(shell).contains("powershell") or
    toLowerAscii(shell).contains("pwsh")
  let posixEscapes = shell.len > 0 and not cmdShell and not powerShell
  let fishShell = toLowerAscii(shell).contains("fish")

  template finishToken() =
    if tokenStarted:
      stage.add(token)
      if implIsSafeOptionTerminator(stage, stage.high):
        stageOptionsEnded = true
      token = ""
      tokenStarted = false

  template reject(message: string) =
    return ParsedCommand(valid: false, reason: message, stages: @[])

  template finishStage(emptyMessage: string) =
    finishToken()
    if stage.len == 0:
      reject(emptyMessage)
    result.stages.add(stage)
    result.variableExpansionStages.add(stageUsesApprovedVariable)
    result.unstableVariableExpansionStages.add(stageUsesUnstableVariable)
    result.inputRedirectionStages.add(stageUsesInputRedirection)
    result.unsafeUnquotedGlobStages.add(stageUsesUnsafeGlob)
    stage = @[]
    stageOptionsEnded = false
    stageUsesApprovedVariable = false
    stageUsesUnstableVariable = false
    stageUsesInputRedirection = false
    stageUsesUnsafeGlob = false

  while index < command.len:
    let current = command[index]
    if shell.len == 0 and current == '\\' and index + 1 < command.len and
        command[index + 1] in {'\'', '"'}:
      reject("quoted escapes require an explicit shell for unambiguous validation")
    if quote != '\0':
      # Match the shell's quote rules before looking for a closing quote.
      # Otherwise an escaped quote can hide an actual command separator.
      if current == '\\' and posixEscapes and
          (quote == '"' or (quote == '\'' and fishShell)):
        if index + 1 >= command.len:
          reject("unterminated quoted shell escape")
        let next = command[index + 1]
        let escapes =
          if quote == '\'': next in {'\\', '\''}
          elif fishShell: next in {'\\', '"', '$', '\n'}
          else: next in {'\\', '"', '$', '`', '\n'}
        if escapes:
          if next == '\n':
            reject("quoted line continuations are not supported")
          token.add(next)
          tokenStarted = true
          index += 2
          continue
        token.add(current)
      elif current == quote:
        quote = '\0'
      elif quote == '"' and current == '$':
        let variableLength = implSafeVariableLength(command, index)
        if variableLength == 0:
          reject("shell expansion is not permitted")
        token.add(command[index ..< index + variableLength])
        tokenStarted = true
        stageUsesApprovedVariable = true
        let expansion = command[index ..< index + variableLength]
        if expansion notin ["$HOME", "${HOME}", "$PWD", "${PWD}"]:
          stageUsesUnstableVariable = true
        index += variableLength
        continue
      elif quote == '"' and current == '`':
        reject("shell expansion is not permitted")
      elif current == '\0':
        reject("command contains a NUL byte")
      else:
        token.add(current)
        tokenStarted = true
      index += 1
      continue

    if current == '"' or (current == '\'' and not cmdShell):
      quote = current
      tokenStarted = true
      index += 1
      continue
    if current in {' ', '\t'}:
      finishToken()
      index += 1
      continue
    if current == '\\' and posixEscapes:
      if index + 1 >= command.len or command[index + 1] in {'\r', '\n'}:
        reject("unterminated shell escape is not permitted")
      token.add(command[index + 1])
      tokenStarted = true
      index += 2
      continue
    if current == '|':
      if index + 1 < command.len and command[index + 1] == '|':
        finishStage("logical sequence contains an empty command")
        index += 2
      else:
        finishStage("pipeline contains an empty stage")
        index += 1
      continue
    if current == '&':
      let isAnd = index + 1 < command.len and command[index + 1] == '&'
      if isAnd or cmdShell:
        finishStage("logical sequence contains an empty command")
        index += (if isAnd: 2 else: 1)
        continue
      reject("background execution or invocation syntax is not permitted")
    if current == ';' or current in {'\r', '\n'}:
      if current == ';' and index + 1 < command.len and
          command[index + 1] in {';', '&'}:
        reject("shell control syntax is not permitted")
      finishStage("command sequence contains an empty command")
      index += 1
      if current == '\r' and index < command.len and command[index] == '\n':
        index += 1
      continue
    if current == '>':
      if tokenStarted:
        if implAllDigits(token):
          token = ""
          tokenStarted = false
        else:
          finishToken()
      index += 1
      if index < command.len and command[index] == '>':
        reject("append redirection is not permitted")
      while index < command.len and command[index] in {' ', '\t'}:
        index += 1
      let targetStart = index
      while index < command.len and
          command[index] notin {' ', '\t', '\r', '\n', ';', '|'}:
        index += 1
      if targetStart == index:
        reject("output redirection is missing a target")
      let target = command[targetStart ..< index]
      if not implIsNullSink(target, shell):
        reject("output redirection may modify a file")
      continue
    if current == '<':
      # Only `< literal-path` is supported. The related shell forms `<<`,
      # `<<<`, `<>`, and `<&` either introduce another parser or can open a
      # file for writing, so they remain fail-closed.
      if stageUsesInputRedirection:
        reject("multiple input redirections are not permitted")
      if powerShell:
        reject("PowerShell input redirection is not supported")
      if tokenStarted:
        if implAllDigits(token):
          token = ""
          tokenStarted = false
        else:
          finishToken()
      if stage.len == 0:
        reject("input redirection must follow its executable")
      index += 1
      if index < command.len and command[index] in {'<', '>', '&'}:
        reject("advanced input redirection is not permitted")
      while index < command.len and command[index] in {' ', '\t'}:
        index += 1
      var targetQuote = '\0'
      var targetStarted = false
      while index < command.len:
        let targetCharacter = command[index]
        if targetQuote != '\0':
          if targetCharacter == '\\' and fishShell and targetQuote == '\'' and
              index + 1 < command.len and command[index + 1] in {'\\', '\''}:
            targetStarted = true
            index += 2
            continue
          if targetCharacter == targetQuote:
            targetQuote = '\0'
          elif targetCharacter in {'\r', '\n', '\0'}:
            reject("input redirection target contains unsafe control syntax")
          elif targetQuote == '"' and
              (targetCharacter in {'$', '`'} or
                (cmdShell and targetCharacter in {'%', '!', '^'})):
            reject("input redirection target expansion is not permitted")
          elif targetQuote == '"' and targetCharacter == '\\':
            if index + 1 >= command.len or
                command[index + 1] in {'\r', '\n'}:
              reject("input redirection target has an invalid escape")
            targetStarted = true
            index += 2
            continue
          else:
            targetStarted = true
          index += 1
          continue
        if targetCharacter == '"' or
            (targetCharacter == '\'' and not cmdShell):
          targetQuote = targetCharacter
          index += 1
          continue
        if targetCharacter in {' ', '\t'}:
          break
        if targetCharacter in {'\r', '\n', '\0', ';', '|', '&', '<', '>',
            '(', ')', '{', '}', '`', '$', '*', '?', '[', '!', '^', '%', '#',
            '~'}:
          reject("input redirection target must be a literal file path")
        if targetCharacter == '\\' and posixEscapes:
          if index + 1 >= command.len or
              command[index + 1] in {'\r', '\n'}:
            reject("input redirection target has an invalid escape")
          targetStarted = true
          index += 2
          continue
        targetStarted = true
        index += 1
      if targetQuote != '\0':
        reject("input redirection target has an unterminated quote")
      if not targetStarted:
        reject("input redirection is missing a literal file target")
      stageUsesInputRedirection = true
      continue
    if current == '$':
      let variableLength = implSafeVariableLength(command, index)
      if variableLength == 0:
        reject("unsupported shell control or expansion syntax")
      token.add(command[index ..< index + variableLength])
      tokenStarted = true
      stageUsesApprovedVariable = true
      stageUsesUnstableVariable = true
      index += variableLength
      continue
    if current == '~' and not tokenStarted:
      # POSIX shells and PowerShell expand a word-leading tilde after policy
      # validation. Treat it like an approved path variable so a hostile HOME
      # value cannot become an unchecked option of a write-capable reader.
      stageUsesApprovedVariable = true
    if current == '%' and token == "--":
      reject("PowerShell stop-parsing can hide unchecked parameter expansion")
    if current in {'(', ')', '{', '}', '`'}:
      reject("unsupported shell control or expansion syntax")
    if current in {'!', '^'}:
      reject("shell escape syntax is not permitted")
    if current == '#':
      reject("shell comments are not permitted")
    if current == '\0':
      reject("command contains a NUL byte")
    if current == '@' and powerShell and not tokenStarted:
      # PowerShell expands an unquoted @name array/hashtable only after this
      # gate. A prior stage can populate it through -OutVariable and otherwise
      # smuggle unchecked parameters into the next executable.
      result.unsafePowerShellSplat = true
    if current in {'*', '?', '['}:
      # A basename-leading glob can expand to an attacker-created filename
      # beginning with '-', which the target program then reparses as an
      # option. Directory-qualified/literal-prefixed globs retain a safe first
      # character, while quoted patterns never reach this branch.
      if not stageOptionsEnded and (token.len == 0 or
          (token[0] == '-' and not token.contains('='))):
        stageUsesUnsafeGlob = true
    token.add(current)
    tokenStarted = true
    index += 1

  if quote != '\0':
    reject("command contains an unterminated quote")
  finishToken()
  if stage.len == 0:
    reject("command or pipeline stage is empty")
  result.stages.add(stage)
  result.variableExpansionStages.add(stageUsesApprovedVariable)
  result.unstableVariableExpansionStages.add(stageUsesUnstableVariable)
  result.inputRedirectionStages.add(stageUsesInputRedirection)
  result.unsafeUnquotedGlobStages.add(stageUsesUnsafeGlob)
  result.valid = true

func implValidateFind(tokens: seq[string]): CommandPolicyDecision =
  for token in tokens:
    let lower = toLowerAscii(token)
    if lower in ["-delete", "-exec", "-execdir", "-ok", "-okdir"] or
        lower in ["-fprint", "-fprint0", "-fprintf", "-fls"]:
      return implReject("find action can execute code or write a file")
  result = implAllow()

func implValidateFd(tokens: seq[string]): CommandPolicyDecision =
  const ValuelessOptions = [
    "-H", "--hidden", "-I", "--no-ignore", "--no-ignore-vcs",
    "--no-ignore-parent", "--no-ignore-global", "--no-ignore-dot",
    "-u", "--unrestricted", "-s", "--case-sensitive", "-i",
    "--ignore-case", "-g", "--glob", "-F", "--fixed-strings", "-a",
    "--absolute-path", "-l", "--list-details", "-L", "--follow", "-p",
    "--full-path", "-0", "--print0", "-1", "--one-file-system",
    "--strip-cwd-prefix", "--show-errors", "--no-require-git",
    "--help", "--version"
  ]
  const ValuelessShortChars = "HIusigFalLp01"
  if implHasForbiddenOptionAfterFlags(
      tokens, ["-x", "-X", "--exec", "--exec-batch"],
      ValuelessOptions, ValuelessShortChars):
    return implReject("fd execution options are not read-only")
  var index = 1
  while index < tokens.len:
    let token = tokens[index]
    if implIsSafeOptionTerminatorAfterFlags(
        tokens, index, ValuelessOptions, ValuelessShortChars):
      break
    let lower = toLowerAscii(token)
    if lower in ["-j", "--threads"]:
      if index + 1 >= tokens.len or
          not implUnsignedAtMost(tokens[index + 1], 32):
        return implReject("fd thread count must be between 0 and 32")
      index += 2
      continue
    if lower.startsWith("--threads="):
      if not implUnsignedAtMost(token["--threads=".len .. ^1], 32):
        return implReject("fd thread count must be between 0 and 32")
      index += 1
      continue
    if token.startsWith("-j") and not token.startsWith("--") and
        token.len > 2:
      var value = token[2 .. ^1]
      if value.startsWith("="):
        value = value[1 .. ^1]
      if not implUnsignedAtMost(value, 32):
        return implReject("fd thread count must be between 0 and 32")
      index += 1
      continue
    if lower.startsWith("--") and lower.len >= 3 and
        "--threads".startsWith(lower):
      return implReject("spell the bounded fd --threads option in full")
    if not token.startsWith("--") and
        token.startsWith("-") and
        (token.contains('x') or token.contains('X')):
      return implReject("fd execution options are not read-only")
    index += 1
  result = implAllow()

func implValidateRg(tokens: seq[string]): CommandPolicyDecision =
  const ValuelessOptions = [
    "-n", "--line-number", "-H", "--with-filename", "-h",
    "--no-filename", "-i", "--ignore-case", "-s", "--case-sensitive",
    "-S", "--smart-case", "-v", "--invert-match", "-w", "--word-regexp",
    "-x", "--line-regexp", "-F", "--fixed-strings", "-l",
    "--files-with-matches", "--files-without-match", "-c", "--count",
    "--count-matches", "--files", "--hidden", "--no-ignore",
    "--no-messages", "--stats", "--json", "-0", "--null", "--null-data",
    "-a", "--text", "-U", "--multiline", "--multiline-dotall", "--crlf",
    "--pcre2", "--no-pcre2-unicode", "-z", "--search-zip",
    "--one-file-system", "--no-config", "--help", "--version"
  ]
  const ValuelessShortChars = "nHhisSvwxFlc0aUz"
  if implHasForbiddenOptionAfterFlags(
      tokens, ["--pre", "--pre-glob", "--hostname-bin"],
      ValuelessOptions, ValuelessShortChars):
    return implReject("rg external-command options are not permitted")
  var index = 1
  while index < tokens.len:
    let token = tokens[index]
    if implIsSafeOptionTerminatorAfterFlags(
        tokens, index, ValuelessOptions, ValuelessShortChars):
      break
    let lower = toLowerAscii(token)
    if lower in ["-j", "--threads"]:
      if index + 1 >= tokens.len or
          not implUnsignedAtMost(tokens[index + 1], 32):
        return implReject("rg thread count must be between 0 and 32")
      index += 2
      continue
    if lower.startsWith("--threads="):
      if not implUnsignedAtMost(token["--threads=".len .. ^1], 32):
        return implReject("rg thread count must be between 0 and 32")
      index += 1
      continue
    if token.startsWith("-j") and not token.startsWith("--") and
        token.len > 2:
      var value = token[2 .. ^1]
      if value.startsWith("="):
        value = value[1 .. ^1]
      if not implUnsignedAtMost(value, 32):
        return implReject("rg thread count must be between 0 and 32")
      index += 1
      continue
    if lower.startsWith("--") and lower.len >= 3 and
        "--threads".startsWith(lower):
      return implReject("spell the bounded rg --threads option in full")
    if implOptionMatches(token, "--dfa-size-limit") or
        implOptionMatches(token, "--regex-size-limit"):
      return implReject("rg regex memory-limit overrides are not permitted")
    index += 1
  result = implAllow()

func implValidateSort(
  tokens: seq[string],
  shell: string
): CommandPolicyDecision =
  const ValuelessOptions = [
    "-b", "--ignore-leading-blanks", "-d", "--dictionary-order", "-f",
    "--ignore-case", "-g", "--general-numeric-sort", "-h",
    "--human-numeric-sort", "-i", "--ignore-nonprinting", "-M",
    "--month-sort", "-n", "--numeric-sort", "-R", "--random-sort", "-r",
    "--reverse", "-V", "--version-sort", "-c", "-C", "--check", "-m",
    "--merge", "-s", "--stable", "-u", "--unique", "-z",
    "--zero-terminated", "--debug", "--help", "--version"
  ]
  const ValuelessShortChars = "bdfghiMnRrVcCmsuz"
  if implHasForbiddenOptionAfterFlags(tokens, [
    "-o", "--output", "--compress-program", "-T", "--temporary-directory",
    "-S", "--buffer-size", "--batch-size"
  ], ValuelessOptions, ValuelessShortChars):
    return implReject(
      "sort option can write, execute a helper, or override resource bounds")
  var index = 1
  var optionsEnded = false
  while index < tokens.len:
    let token = tokens[index]
    let lower = toLowerAscii(token)
    if not optionsEnded and implIsSafeOptionTerminatorAfterFlags(
        tokens, index, ValuelessOptions, ValuelessShortChars):
      optionsEnded = true
      index += 1
      continue
    if optionsEnded:
      index += 1
      continue
    if lower == "--parallel":
      if index + 1 >= tokens.len or
          not implPositiveAtMost(tokens[index + 1], 4):
        return implReject("sort parallelism must be between 1 and 4")
      index += 2
      continue
    if lower.startsWith("--parallel="):
      if not implPositiveAtMost(token["--parallel=".len .. ^1], 4):
        return implReject("sort parallelism must be between 1 and 4")
      index += 1
      continue
    if lower.startsWith("--") and lower.len >= 3 and
        "--parallel".startsWith(lower):
      return implReject("spell the bounded sort --parallel option in full")
    if token.startsWith("-") and not token.startsWith("--") and
        (token.contains('o') or token.contains('T') or token.contains('S')):
      return implReject(
        "sort output, temporary-file, or memory override is not permitted")
    if (toLowerAscii(shell).contains("cmd") or
        toLowerAscii(tokens[0]).endsWith("sort.exe")) and
        (toLowerAscii(token).startsWith("/o") or
          toLowerAscii(token).startsWith("/t")):
      return implReject("Windows sort output or temporary path is not permitted")
    index += 1
  result = implAllow()

func implValidateDiff(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["--output"]):
    return implReject("diff output option can write a file")
  result = implAllow()

func implValidateBase64(tokens: seq[string]): CommandPolicyDecision =
  # BSD/macOS base64 supports -o output_file even though GNU base64 does not.
  # GNU -i means --ignore-garbage, while BSD/macOS -i consumes an input path.
  # Select the native interpretation so GNU's ordinary flag stays usable,
  # while a macOS input path of "--" cannot conceal a following -o option.
  when defined(linux):
    const ValuelessOptions = [
      "-d", "--decode", "-D", "-i", "--ignore-garbage", "--help", "--version"
    ]
    const ValuelessShortChars = "dDi"
  else:
    const ValuelessOptions = [
      "-d", "--decode", "-D", "--ignore-garbage", "--help", "--version"
    ]
    const ValuelessShortChars = "dD"
  if implHasForbiddenOptionAfterFlags(
      tokens, ["-o", "--output"], ValuelessOptions, ValuelessShortChars):
    return implReject("base64 output option can write a file")
  for index in 1 ..< tokens.len:
    let token = tokens[index]
    if implIsSafeOptionTerminatorAfterFlags(
        tokens, index, ValuelessOptions, ValuelessShortChars):
      break
    if token.startsWith("-") and not token.startsWith("--") and
        token.contains('o'):
      return implReject("base64 output option can write a file")
  result = implAllow()

func implValidateTree(tokens: seq[string]): CommandPolicyDecision =
  const ValuelessOptions = [
    "-a", "-c", "-d", "-f", "-i", "-q", "-s", "-u", "-p", "-g", "-h",
    "-D", "-F", "-x", "-t", "-r", "-v", "-A", "-C", "-S", "-U", "-n",
    "-N", "-Q", "-J", "-X",
    "--dirsfirst", "--filesfirst", "--noreport", "--du", "--prune",
    "--matchdirs", "--fromfile", "--metafirst", "--gitignore", "--info",
    "--ignore-case", "--nolinks", "--si", "--fromtabfile", "--fflinks",
    "--inodes", "--device", "--hyperlink", "--help", "--version"
  ]
  const ValuelessShortChars = "acdfiqsupghDFxtrvACSunNQJX"
  if implHasForbiddenOptionAfterFlags(
      tokens, ["-o", "--output"], ValuelessOptions, ValuelessShortChars):
    return implReject("tree output option can write a file")
  for index in 1 ..< tokens.len:
    let token = tokens[index]
    if implIsSafeOptionTerminatorAfterFlags(
        tokens, index, ValuelessOptions, ValuelessShortChars):
      break
    if token.startsWith("-") and not token.startsWith("--") and
        token.contains('o'):
      return implReject("tree output option can write a file")
  result = implAllow()

func implValidateUniq(tokens: seq[string]): CommandPolicyDecision =
  var operands = 0
  var index = 1
  while index < tokens.len:
    let lower = toLowerAscii(tokens[index])
    if lower in [
      "-f", "--skip-fields", "-s", "--skip-chars", "-w", "--check-chars"
    ]:
      if index + 1 >= tokens.len:
        return implReject("uniq option is missing its value")
      index += 2
      continue
    if tokens[index] == "--":
      operands += tokens.len - index - 1
      break
    if tokens[index] == "-":
      operands += 1
    elif tokens[index].startsWith("-"):
      index += 1
      continue
    else:
      operands += 1
    index += 1
  if operands > 1:
    return implReject("uniq second file operand is an output target")
  result = implAllow()

func implValidateXxd(tokens: seq[string]): CommandPolicyDecision =
  var operands = 0
  var index = 1
  while index < tokens.len:
    let lower = toLowerAscii(tokens[index])
    if lower in ["-c", "-g", "-l", "-o", "-s", "-n"]:
      if index + 1 >= tokens.len:
        return implReject("xxd option is missing its value")
      index += 2
      continue
    if tokens[index] == "--":
      operands += tokens.len - index - 1
      break
    if tokens[index] == "-":
      operands += 1
    elif tokens[index].startsWith("-"):
      index += 1
      continue
    else:
      operands += 1
    index += 1
  if operands > 1:
    return implReject("xxd output-file operand is not permitted")
  result = implAllow()

## Rejects readers' indefinite follow/sample forms. A one-shot CLI assistant
## should revise these to bounded snapshots rather than waiting for its hard
## process deadline to kill an otherwise observational command.
func implValidateFiniteReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "tail":
    if implHasForbiddenOption(tokens, ["--follow", "--retry", "--pid"]):
      return implReject("tail follow mode is unbounded; request a finite tail")
    for token in tokens:
      if token.startsWith("-") and not token.startsWith("--") and
          (token.contains('f') or token.contains('F')):
        return implReject("tail follow mode is unbounded; request a finite tail")
  of "lsof":
    for token in tokens:
      if token.startsWith("-D"):
        return implReject("lsof device-cache options can write a file")
      if token.startsWith("+r") or token.startsWith("-r"):
        return implReject("lsof repeat mode is unbounded")
  of "findmnt":
    if implHasForbiddenOption(tokens, ["--poll"]) or
        "-p" in tokens:
      return implReject("findmnt poll mode is unbounded")
  of "netstat":
    if implHasForbiddenOption(tokens, ["--continuous"]):
      return implReject("netstat continuous mode is unbounded")
    for index in 1 ..< tokens.len:
      let token = tokens[index]
      if implAllDigits(token):
        return implReject("netstat interval mode is unbounded")
      when defined(linux):
        if token.startsWith("-") and not token.startsWith("--") and
            token.contains('c'):
          return implReject("netstat continuous mode is unbounded")
      elif defined(macosx):
        if token == "-w" or token.startsWith("-w="):
          return implReject("netstat interval mode is unbounded")
  of "vm_stat":
    if tokens.len == 1:
      return implAllow()
    if tokens.len != 4 or tokens[1] != "-c" or
        not implPositiveAtMost(tokens[2], 5) or
        not implDecimalAtMost(tokens[3], 10):
      return implReject(
        "vm_stat interval mode requires -c COUNT (1..5) and interval <= 10")
  of "vmstat", "iostat", "mpstat":
    var numericOperands: seq[string] = @[]
    var index = 1
    while index < tokens.len:
      let lower = toLowerAscii(tokens[index])
      let consumesValue =
        (name == "vmstat" and lower in ["-p", "--partition", "-s", "--unit"]) or
        (name == "iostat" and lower in ["-f", "-j", "-g", "-p", "--dec"]) or
        (name == "mpstat" and lower in ["-i", "-n", "-p", "--dec"])
      if consumesValue and index + 1 < tokens.len:
        index += 2
        continue
      if lower.startsWith("--dec="):
        index += 1
        continue
      if implAllDigits(tokens[index]):
        numericOperands.add(tokens[index])
      index += 1
    if numericOperands.len == 1:
      return implReject(name & " interval without a count is unbounded")
    if numericOperands.len > 2 or (numericOperands.len == 2 and (
        not implPositiveAtMost(numericOperands[0], 10) or
        not implPositiveAtMost(numericOperands[1], 5))):
      return implReject(name & " sampling interval/count exceeds the bound")
  of "free":
    var hasInterval = false
    var hasCount = false
    var index = 1
    while index < tokens.len:
      let lower = toLowerAscii(tokens[index])
      if lower in ["-s", "--seconds"]:
        if index + 1 >= tokens.len or
            not implPositiveDecimalAtMost(tokens[index + 1], 10):
          return implReject(
            "free sampling interval must be greater than 0 and at most 10 seconds")
        hasInterval = true
        index += 2
        continue
      if lower.startsWith("--seconds="):
        if not implPositiveDecimalAtMost(
            tokens[index]["--seconds=".len .. ^1], 10):
          return implReject(
            "free sampling interval must be greater than 0 and at most 10 seconds")
        hasInterval = true
        index += 1
        continue
      if lower in ["-c", "--count"]:
        if index + 1 >= tokens.len or
            not implPositiveAtMost(tokens[index + 1], 5):
          return implReject("free sample count must be between 1 and 5")
        hasCount = true
        index += 2
        continue
      if lower.startsWith("--count="):
        if not implPositiveAtMost(
            tokens[index]["--count=".len .. ^1], 5):
          return implReject("free sample count must be between 1 and 5")
        hasCount = true
        index += 1
        continue
      if tokens[index].startsWith("-") and
          not tokens[index].startsWith("--") and
          (tokens[index].contains('s') or tokens[index].contains('c')):
        return implReject(
          "spell bounded free --seconds/--count sampling options separately")
      index += 1
    if hasInterval and not hasCount:
      return implReject("free interval mode requires a finite count")
  else:
    discard
  result = implAllow()

func implValidateFile(tokens: seq[string]): CommandPolicyDecision =
  const ValuelessOptions = [
    "-v", "--version", "-b", "--brief", "-c", "--checking-printout", "-i",
    "--mime", "--mime-type", "--mime-encoding", "-z", "--uncompress", "-Z",
    "--uncompress-noreport", "-k", "--keep-going", "-l", "--list", "-L",
    "--dereference", "-h", "--no-dereference", "-n", "--no-buffer", "-N",
    "--no-pad", "-0", "--print0", "-r", "--raw", "-s", "--special-files",
    "-S", "--no-sandbox", "-d", "--debug", "--apple", "--extension",
    "--help"
  ]
  const ValuelessShortChars = "vbcizZklLhnN0rsSd"
  if implHasForbiddenOptionAfterFlags(
      tokens, ["--compile", "--preserve-date"],
      ValuelessOptions, ValuelessShortChars):
    return implReject("file option can write a magic database or timestamps")
  for index in 1 ..< tokens.len:
    let token = tokens[index]
    if implIsSafeOptionTerminatorAfterFlags(
        tokens, index, ValuelessOptions, ValuelessShortChars):
      break
    if token.startsWith("-") and not token.startsWith("--") and
        (token.contains('C') or token.contains('p')):
      return implReject("file option can write a magic database or timestamps")
  result = implAllow()

## A bare nslookup enters an interactive command loop. Require an explicit
## query name (and optionally a server) so ordinary DNS diagnostics stay
## available without admitting an unbounded interpreter-like mode.
func implValidateNslookup(tokens: seq[string]): CommandPolicyDecision =
  var hasQueryName = false
  for index in 1 ..< tokens.len:
    let token = tokens[index]
    if token == "-":
      return implReject("nslookup interactive mode is not permitted")
    if not token.startsWith("-"):
      hasQueryName = true
  if not hasQueryName:
    return implReject("nslookup requires an explicit query name")
  result = implAllow()

func implValidatePgrep(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["--signal"]):
    return implReject("pgrep signal mode changes process state")
  result = implAllow()

func implValidateSampledReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  if name == "sar":
    if implHasForbiddenOption(tokens, ["-o"]):
      return implReject("sar output mode writes an activity file")
    for token in tokens:
      if token.startsWith("-") and not token.startsWith("--") and
          token.contains('o'):
        return implReject("sar output mode writes an activity file")
  elif name == "pidstat":
    for token in tokens:
      if implHasForbiddenOption(@[token], ["--exec"]) or
          (token.startsWith("-e") and not token.startsWith("--")):
        return implReject("pidstat exec mode can run an arbitrary program")

  var numericOperands: seq[string] = @[]
  var index = 1
  while index < tokens.len:
    let token = tokens[index]
    let consumesValue =
      (name == "sar" and token in [
        "-f", "-i", "-s", "-e", "-P", "-j", "-n", "-m", "-I"
      ]) or
      (name == "pidstat" and token in ["-C", "-G", "-p", "-U", "-T"])
    if consumesValue:
      if index + 1 >= tokens.len:
        return implReject(name & " option is missing its value")
      index += 2
      continue
    if tokens[index].startsWith("-"):
      index += 1
      continue
    if implAllDigits(tokens[index]):
      numericOperands.add(tokens[index])
    index += 1
  if numericOperands.len == 1:
    return implReject(name & " interval without a count is unbounded")
  if numericOperands.len > 2 or (numericOperands.len == 2 and (
      not implPositiveAtMost(numericOperands[0], 10) or
      not implPositiveAtMost(numericOperands[1], 5))):
    return implReject(name & " sampling interval/count exceeds the bound")
  result = implAllow()

func implValidateTracer(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  var index = 1
  while index < tokens.len:
    let token = tokens[index]
    let lower = toLowerAscii(token)
    var maximum = -1
    var decimal = false
    if name == "traceroute":
      let separator = lower.find('=')
      let optionName = if separator >= 0: lower[0 ..< separator] else: lower
      if optionName.len >= 3 and "--module".startsWith(optionName):
        var tracerMethod = ""
        if separator >= 0:
          tracerMethod = lower[separator + 1 .. ^1]
        elif index + 1 < tokens.len:
          index += 1
          tracerMethod = toLowerAscii(tokens[index])
        if tracerMethod notin [
          "default", "icmp", "tcp", "tcpconn", "udp", "udplite", "raw"
        ]:
          return implReject("traceroute module must be a built-in method")
        index += 1
        continue
      for item in [
        ("--max-hops", 64, false), ("--first-hop", 64, false),
        ("--queries", 5, false), ("--wait", 10, true),
        ("--sendwait", 10, true), ("--sim-queries", 10, false)
      ]:
        if optionName.len >= 3 and item[0].startsWith(optionName):
          if separator >= 0:
            let value = token[separator + 1 .. ^1]
            if (item[2] and not implDecimalAtMost(value, item[1])) or
                (not item[2] and not implUnsignedAtMost(value, item[1])):
              return implReject(
                "traceroute option exceeds the diagnostic bound")
            index += 1
            maximum = -2
          else:
            maximum = item[1]
            decimal = item[2]
          break
      if maximum == -2:
        continue
      if token in ["-m", "-f"] or
          lower in ["--max-hops", "--first-hop"]:
        maximum = 64
      elif token == "-q" or lower == "--queries":
        maximum = 5
      elif token in ["-w", "-z"] or lower in ["--wait", "--sendwait"]:
        maximum = 10
        decimal = true
      elif token == "-N" or lower == "--sim-queries":
        maximum = 10
      elif token == "-M":
        if index + 1 >= tokens.len or
            toLowerAscii(tokens[index + 1]) notin [
              "default", "icmp", "tcp", "tcpconn", "udp", "udplite", "raw"
            ]:
          return implReject("traceroute module must be a built-in method")
        index += 2
        continue
      elif token in ["-g", "-i", "-p", "-s", "-t"] or
          lower in [
            "--gateway", "--interface", "--module", "--port", "--source",
            "--tos"
          ]:
        if index + 1 >= tokens.len:
          return implReject("traceroute option is missing its value")
        index += 2
        continue
    elif name == "tracert":
      if lower == "-h":
        maximum = 64
      elif lower == "-w":
        maximum = 10_000
      elif lower in ["-j", "-s"]:
        if index + 1 >= tokens.len:
          return implReject("tracert option is missing its value")
        index += 2
        continue
    else:
      if lower in ["-m", "--max-hops"]:
        maximum = 64
      elif lower in ["-l", "--length"]:
        maximum = 65_535
      elif lower in ["-p", "--port"]:
        maximum = 65_535

    if maximum >= 0:
      if index + 1 >= tokens.len:
        return implReject(name & " bound option is missing its value")
      let value = tokens[index + 1]
      if (decimal and not implDecimalAtMost(value, maximum)) or
          (not decimal and not implUnsignedAtMost(value, maximum)):
        return implReject(name & " option exceeds the diagnostic bound")
      index += 2
      continue

    var matchedAttached = false
    if name == "traceroute":
      for item in [
        ("-m", 64, false), ("-f", 64, false), ("-q", 5, false),
        ("-w", 10, true), ("-z", 10, true), ("-N", 10, false)
      ]:
        if token.startsWith(item[0]) and token.len > item[0].len:
          let value = token[item[0].len .. ^1]
          if (item[2] and not implDecimalAtMost(value, item[1])) or
              (not item[2] and not implUnsignedAtMost(value, item[1])):
            return implReject("traceroute option exceeds the diagnostic bound")
          matchedAttached = true
          break
    elif name == "tracert":
      for item in [("-h", 64), ("-w", 10_000)]:
        if lower.startsWith(item[0]) and lower.len > item[0].len:
          if not implUnsignedAtMost(lower[item[0].len .. ^1], item[1]):
            return implReject("tracert option exceeds the diagnostic bound")
          matchedAttached = true
          break
    elif name == "tracepath":
      for item in [("-m", 64), ("-l", 65_535), ("-p", 65_535)]:
        if lower.startsWith(item[0]) and lower.len > item[0].len:
          if not implUnsignedAtMost(lower[item[0].len .. ^1], item[1]):
            return implReject("tracepath option exceeds the diagnostic bound")
          matchedAttached = true
          break
    discard matchedAttached
    index += 1
  result = implAllow()

func implValidatePing(
  tokens: seq[string],
  shell: string
): CommandPolicyDecision =
  let lowerShell = toLowerAscii(shell)
  let isWindows = lowerShell.contains("cmd") or
    lowerShell.contains("powershell") or lowerShell.contains("pwsh")
  if tokens.len == 2 and toLowerAscii(tokens[1]) in [
      "-h", "--help", "-v", "--version"]:
    return implAllow()
  var hasPosixBound = false
  var index = 1
  while index < tokens.len:
    let token = tokens[index]
    let lower = toLowerAscii(token)
    if isWindows:
      if lower == "-t":
        return implReject("unbounded Windows ping is not permitted")
      if lower in ["-n", "-l"]:
        if index + 1 >= tokens.len:
          return implReject("ping limit option is missing its value")
        let maximum = if lower == "-n": 20 else: 4096
        if not implUnsignedAtMost(tokens[index + 1], maximum):
          return implReject("ping count or payload exceeds the safe bound")
        index += 2
        continue
    else:
      if lower in ["-f", "--flood", "-a", "--adaptive"] or
          (token.startsWith("-") and not token.startsWith("--") and
            (token.contains('f') or token.contains('A'))):
        return implReject("ping flood mode can exhaust network resources")
      if lower in ["-i", "--interval"] or
          lower.startsWith("--interval="):
        return implReject("custom ping intervals are not permitted")
      if lower in ["-c", "-s", "--count", "--size"]:
        if index + 1 >= tokens.len:
          return implReject("ping limit option is missing its value")
        let maximum = if lower in ["-c", "--count"]: 20 else: 4096
        if not implUnsignedAtMost(tokens[index + 1], maximum):
          return implReject("ping count or payload exceeds the safe bound")
        if lower in ["-c", "--count"]:
          hasPosixBound = true
        index += 2
        continue
      if lower in ["-w", "--deadline"]:
        if index + 1 >= tokens.len or
            not implPositiveAtMost(tokens[index + 1], 10):
          return implReject("ping deadline is missing or exceeds 10 seconds")
        hasPosixBound = true
        index += 2
        continue
      for item in [
        ("--count=", 20), ("--size=", 4096), ("--deadline=", 10)
      ]:
        let option = item[0]
        let maximum = item[1]
        if lower.startsWith(option) and
            not implUnsignedAtMost(token[option.len .. ^1], maximum):
          return implReject("ping count or payload exceeds the safe bound")
        if lower.startsWith(option) and option != "--size=":
          hasPosixBound = true
      if token.startsWith("-c") and token.len > 2 and
          not implUnsignedAtMost(token[2 .. ^1], 20):
        return implReject("ping count exceeds the safe bound")
      if token.startsWith("-c") and token.len > 2:
        hasPosixBound = true
      if token.startsWith("-w") and token.len > 2:
        if not implPositiveAtMost(token[2 .. ^1], 10):
          return implReject("ping deadline exceeds 10 seconds")
        hasPosixBound = true
      if token.startsWith("-s") and token.len > 2 and
          not implUnsignedAtMost(token[2 .. ^1], 4096):
        return implReject("ping payload exceeds the safe bound")
    index += 1
  if not isWindows and not hasPosixBound:
    return implReject("POSIX ping requires a bounded count or deadline")
  result = implAllow()

## Accepts procps ``top`` only as a finite, non-interactive snapshot. The
## Linux and macOS programs use incompatible flags, so each documented dialect
## is parsed independently instead of treating arbitrary options as harmless.
func implValidateTopGnu(tokens: seq[string]): bool =
  var hasBatch = false
  var hasIterations = false
  var index = 1
  while index < tokens.len:
    let token = tokens[index]
    let lower = toLowerAscii(token)
    if lower in [
      "--batch-mode", "--cmdline-toggle", "--threads-show",
      "--idle-toggle", "--accum-time-toggle", "--secure-mode",
      "--single-cpu-toggle"
    ]:
      hasBatch = hasBatch or lower == "--batch-mode"
      index += 1
      continue
    if lower in [
      "--iterations", "--delay", "--scale-summary-mem",
      "--scale-task-mem", "--sort-override", "--pid",
      "--filter-any-user", "--filter-only-euser"
    ]:
      if index + 1 >= tokens.len:
        return false
      let value = tokens[index + 1]
      case lower
      of "--iterations":
        if not implPositiveAtMost(value, 5):
          return false
        hasIterations = true
      of "--delay":
        if not implDecimalAtMost(value, 10):
          return false
      of "--scale-summary-mem":
        if value.len != 1 or value[0] notin {'k', 'm', 'g', 't', 'p', 'e'}:
          return false
      of "--scale-task-mem":
        if value.len != 1 or value[0] notin {'k', 'm', 'g', 't', 'p'}:
          return false
      of "--pid":
        if not implSafePidList(value):
          return false
      else:
        if not implSafeDiagnosticWord(value):
          return false
      index += 2
      continue
    if lower == "--width":
      if index + 1 < tokens.len and implAllDigits(tokens[index + 1]):
        if not implPositiveAtMost(tokens[index + 1], 512):
          return false
        index += 2
      else:
        index += 1
      continue
    var matchedLongValue = false
    for item in [
      ("--iterations=", 0), ("--delay=", 1),
      ("--scale-summary-mem=", 2), ("--scale-task-mem=", 3),
      ("--sort-override=", 4), ("--pid=", 5),
      ("--filter-any-user=", 6), ("--filter-only-euser=", 7),
      ("--width=", 8)
    ]:
      if lower.startsWith(item[0]):
        let value = token[item[0].len .. ^1]
        case item[1]
        of 0:
          if not implPositiveAtMost(value, 5):
            return false
          hasIterations = true
        of 1:
          if not implDecimalAtMost(value, 10):
            return false
        of 2:
          if value.len != 1 or value[0] notin {'k', 'm', 'g', 't', 'p', 'e'}:
            return false
        of 3:
          if value.len != 1 or value[0] notin {'k', 'm', 'g', 't', 'p'}:
            return false
        of 5:
          if not implSafePidList(value):
            return false
        of 8:
          if not implPositiveAtMost(value, 512):
            return false
        else:
          if not implSafeDiagnosticWord(value):
            return false
        matchedLongValue = true
        break
    if matchedLongValue:
      index += 1
      continue
    if not token.startsWith("-") or token.startsWith("--") or
        token.len < 2:
      return false
    var cursor = 1
    while cursor < token.len:
      let option = token[cursor]
      if option in {'b', 'c', 'H', 'i', 'S', 's', '1'}:
        hasBatch = hasBatch or option == 'b'
        cursor += 1
        continue
      if option notin {'n', 'd', 'E', 'e', 'o', 'p', 'U', 'u', 'w'}:
        return false
      var value = ""
      if cursor + 1 < token.len:
        value = token[cursor + 1 .. ^1]
        if value.startsWith("="):
          value = value[1 .. ^1]
      elif option == 'w':
        if index + 1 < tokens.len and implAllDigits(tokens[index + 1]):
          value = tokens[index + 1]
          index += 1
      else:
        if index + 1 >= tokens.len:
          return false
        value = tokens[index + 1]
        index += 1
      case option
      of 'n':
        if not implPositiveAtMost(value, 5):
          return false
        hasIterations = true
      of 'd':
        if not implDecimalAtMost(value, 10):
          return false
      of 'E':
        if value.len != 1 or value[0] notin {'k', 'm', 'g', 't', 'p', 'e'}:
          return false
      of 'e':
        if value.len != 1 or value[0] notin {'k', 'm', 'g', 't', 'p'}:
          return false
      of 'p':
        if not implSafePidList(value):
          return false
      of 'w':
        if value.len > 0 and not implPositiveAtMost(value, 512):
          return false
      else:
        if not implSafeDiagnosticWord(value):
          return false
      cursor = token.len
    index += 1
  result = hasBatch and hasIterations

func implValidateTopMac(tokens: seq[string]): bool =
  var hasSamples = false
  var index = 1
  while index < tokens.len:
    let token = tokens[index]
    if token in ["-a", "-d", "-e", "-F", "-f", "-R", "-r", "-S", "-u", "-W"]:
      index += 1
      continue
    if token in [
      "-c", "-i", "-l", "-ncols", "-o", "-O", "-s", "-n",
      "-stats", "-pid", "-user", "-U"
    ]:
      if index + 1 >= tokens.len:
        return false
      let value = tokens[index + 1]
      case token
      of "-c":
        if value notin ["a", "d", "e", "n"]:
          return false
      of "-i":
        if not implPositiveAtMost(value, 10):
          return false
      of "-l":
        if not implPositiveAtMost(value, 5):
          return false
        hasSamples = true
      of "-ncols":
        if not implPositiveAtMost(value, 512):
          return false
      of "-s":
        if not implDecimalAtMost(value, 10):
          return false
      of "-n":
        # macOS top documents -n as an upper bound on displayed processes;
        # unlike -l, zero is valid and produces a summary-only snapshot.
        if not implUnsignedAtMost(value, 200):
          return false
      of "-pid":
        if not implUnsignedAtMost(value, 2_147_483_647):
          return false
      else:
        if not implSafeDiagnosticWord(value):
          return false
      index += 2
      continue
    var option = ""
    var value = ""
    for candidate in ["-ncols", "-stats", "-pid", "-user", "-l", "-i", "-s", "-n", "-o", "-O", "-U"]:
      if token.startsWith(candidate) and token.len > candidate.len:
        option = candidate
        value = token[candidate.len .. ^1]
        if value.startsWith("="):
          value = value[1 .. ^1]
        break
    if option.len == 0:
      return false
    case option
    of "-l":
      if not implPositiveAtMost(value, 5):
        return false
      hasSamples = true
    of "-i":
      if not implPositiveAtMost(value, 10):
        return false
    of "-ncols":
      if not implPositiveAtMost(value, 512):
        return false
    of "-s":
      if not implDecimalAtMost(value, 10):
        return false
    of "-n":
      if not implUnsignedAtMost(value, 200):
        return false
    of "-pid":
      if not implUnsignedAtMost(value, 2_147_483_647):
        return false
    else:
      if not implSafeDiagnosticWord(value):
        return false
    index += 1
  result = hasSamples

func implValidateTop(tokens: seq[string]): CommandPolicyDecision =
  if tokens.len == 2 and toLowerAscii(tokens[1]) in [
    "-h", "--help", "-v", "--version"
  ]:
    return implAllow()
  if implValidateTopGnu(tokens) or implValidateTopMac(tokens):
    return implAllow()
  result = implReject(
    "top requires a bounded non-interactive snapshot: use -b -n 1 on " &
    "Linux or -l 1 on macOS, with recognized read-only options")

func implSafeAwkPrintExpression(expression: string): bool =
  if expression.len == 0:
    return true
  for item in expression.split(','):
    if item in ["NR", "NF", "$0", "$NF"]:
      continue
    if item.startsWith("$") and item.len > 1 and
        implPositiveAtMost(item[1 .. ^1], 10_000):
      continue
    if item.len >= 2 and item[0] == '"' and item[^1] == '"':
      var safeLiteral = true
      for index in 1 ..< item.len - 1:
        if item[index] notin {
          'A' .. 'Z', 'a' .. 'z', '0' .. '9', '_', '-', '.', '/', ':',
          '(', ')', '[', ']', '+', '='
        }:
          safeLiteral = false
          break
      if safeLiteral:
        continue
    return false
  result = true

func implSafeAwkField(value: string): bool =
  if value in ["NR", "NF", "$0", "$NF"]:
    return true
  result = value.startsWith("$") and value.len > 1 and
    implPositiveAtMost(value[1 .. ^1], 10_000)

func implSafeAwkScalar(value: string): bool =
  if implSafeAwkField(value):
    return true
  let numericStart =
    if value.len > 0 and value[0] in {'+', '-'}: 1
    else: 0
  if numericStart < value.len and
      implDecimalAtMost(value[numericStart .. ^1], 1_000_000_000):
    return true
  # Reuse the deliberately small quoted-literal grammar accepted by print.
  result = implSafeAwkPrintExpression(value)

func implSafeAwkCondition(condition: string): bool =
  if condition.len == 0:
    return true
  if condition in ["NR", "NF"]:
    return true
  var regexStart = 0
  if condition.startsWith("!"):
    regexStart = 1
  if condition.len - regexStart >= 2 and
      condition[regexStart] == '/' and condition[^1] == '/':
    var escaped = false
    var safeRegex = true
    for index in regexStart + 1 ..< condition.len - 1:
      if escaped:
        escaped = false
      elif condition[index] == '\\':
        escaped = true
      elif condition[index] == '/':
        safeRegex = false
        break
    if safeRegex and not escaped:
      return true
  for operation in ["==", "!=", ">=", "<=", ">", "<"]:
    for field in ["NR", "NF"]:
      let prefix = field & operation
      if condition.startsWith(prefix):
        return implUnsignedAtMost(
          condition[prefix.len .. ^1], 1_000_000_000)
    let separator = condition.find(operation)
    if separator > 0 and separator + operation.len < condition.len and
        implSafeAwkField(condition[0 ..< separator]) and
        implSafeAwkScalar(condition[separator + operation.len .. ^1]):
      return true
  result = false

## Supports common pure selectors without admitting AWK's system(), getline,
## file redirection, pipes, program files, extension loading, or general code.
func implSafeAwkProgram(raw: string): bool =
  let program = raw.replace(" ", "").replace("\t", "")
  if program.len == 0 or program.len > 512 or program.contains('\n') or
      program.contains('\r'):
    return false
  # A lone numeric or /regex/ pattern is AWK's built-in, side-effect-free
  # record filter (its implicit action is ``print $0``).
  if implSafeAwkCondition(program):
    return true
  if not program.endsWith("}"):
    return false
  var cursor = 0
  var rules = 0
  while cursor < program.len:
    if program[cursor] == ';':
      cursor += 1
      if cursor >= program.len:
        return false
    let bodyStart = program.find('{', cursor)
    if bodyStart < cursor or
        not implSafeAwkCondition(program[cursor ..< bodyStart]):
      return false
    let bodyEnd = program.find('}', bodyStart + 1)
    if bodyEnd < 0 or program.find('{', bodyStart + 1) in
        bodyStart + 1 ..< bodyEnd:
      return false
    var body = program[bodyStart + 1 ..< bodyEnd]
    if not body.startsWith("print"):
      return false
    body = body[5 .. ^1]
    if body.endsWith(";exit"):
      body = body[0 ..< body.len - 5]
    if not implSafeAwkPrintExpression(body):
      return false
    rules += 1
    if rules > 8:
      return false
    cursor = bodyEnd + 1
  result = rules > 0

func implValidateAwk(tokens: seq[string]): CommandPolicyDecision =
  var index = 1
  while index < tokens.len:
    let token = tokens[index]
    if token == "--":
      index += 1
      break
    if token == "-F" or token == "--field-separator":
      if index + 1 >= tokens.len or tokens[index + 1].len == 0 or
          tokens[index + 1].len > 32:
        return implReject("awk field separator is missing or too long")
      index += 2
      continue
    if token.startsWith("-F") and token.len > 2:
      if token.len > 34:
        return implReject("awk field separator is too long")
      index += 1
      continue
    if token.startsWith("--field-separator="):
      let value = token[18 .. ^1]
      if value.len == 0 or value.len > 32:
        return implReject("awk field separator is missing or too long")
      index += 1
      continue
    if token.startsWith("-"):
      return implReject("awk option can load or execute an external program")
    break
  if index >= tokens.len or not implSafeAwkProgram(tokens[index]):
    return implReject("awk program is outside the pure selector subset")
  index += 1
  while index < tokens.len:
    if tokens[index] != "-" and tokens[index].startsWith("-"):
      return implReject("awk input operand resembles an option")
    index += 1
  result = implAllow()

func implSafeSedAddress(value: string): bool =
  if value == "$" or implUnsignedAtMost(value, 1_000_000_000):
    return true
  if value.len < 2 or value[0] != '/':
    return false
  var escaped = false
  for index in 1 ..< value.len:
    if escaped:
      escaped = false
    elif value[index] == '\\':
      escaped = true
    elif value[index] == '/':
      return index == value.len - 1
  result = false

func implSafeSedAddressExpression(raw: string): bool =
  var value = raw
  if value.endsWith("!"):
    value.setLen(value.len - 1)
  if value.len == 0 or implSafeSedAddress(value):
    return true
  let separator = value.find(',')
  if separator <= 0 or separator >= value.len - 1 or
      value.find(',', separator + 1) >= 0:
    return false
  result = implSafeSedAddress(value[0 ..< separator]) and
    implSafeSedAddress(value[separator + 1 .. ^1])

## Accepts one stdout-only substitution. The sed ``e`` and ``w`` flags are
## deliberately excluded because they execute a command or write a file.
func implSafeSedSubstitution(raw: string): bool =
  if raw.len < 4 or raw[0] != 's':
    return false
  let delimiter = raw[1]
  if delimiter.isAlphaNumeric or delimiter in {
      '\\', '\r', '\n', '\0', ' ', '\t', ';', '{', '}'}:
    return false
  var index = 2
  var separators = 0
  var escaped = false
  while index < raw.len and separators < 2:
    let character = raw[index]
    if escaped:
      escaped = false
    elif character == '\\':
      escaped = true
    elif character == delimiter:
      separators += 1
    index += 1
  if separators != 2:
    return false
  let flags = if index < raw.len: raw[index .. ^1] else: ""
  var occurrence = ""
  var occurrenceEnded = false
  for character in flags:
    if character in {'g', 'p', 'i', 'I', 'm', 'M'}:
      occurrenceEnded = occurrence.len > 0
      continue
    if character in {'0' .. '9'} and not occurrenceEnded:
      occurrence.add(character)
      continue
    return false
  result = occurrence.len == 0 or
    implPositiveAtMost(occurrence, 1_000_000_000)

## Accepts a short list of independent stdout substitutions. Semicolons inside
## a pattern or replacement remain data because the scanner first consumes the
## two unescaped substitution delimiters. Every command is then checked by the
## same flag allowlist as a standalone substitution.
func implSafeSedSubstitutionSequence(raw: string): bool =
  var cursor = 0
  var commands = 0
  while cursor < raw.len:
    while cursor < raw.len and raw[cursor] in {' ', '\t'}:
      cursor += 1
    if cursor >= raw.len or raw[cursor] != 's' or cursor + 1 >= raw.len:
      return false
    let commandStart = cursor
    let delimiter = raw[cursor + 1]
    if delimiter.isAlphaNumeric or delimiter in {
        '\\', '\r', '\n', '\0', ' ', '\t', ';', '{', '}'}:
      return false
    cursor += 2
    var separators = 0
    var escaped = false
    while cursor < raw.len and separators < 2:
      let character = raw[cursor]
      if escaped:
        escaped = false
      elif character == '\\':
        escaped = true
      elif character == delimiter:
        separators += 1
      cursor += 1
    if separators != 2:
      return false
    while cursor < raw.len and raw[cursor] != ';':
      cursor += 1
    let command = raw[commandStart ..< cursor].strip()
    if not implSafeSedSubstitution(command):
      return false
    commands += 1
    if commands > 8:
      return false
    if cursor < raw.len:
      cursor += 1
      if cursor >= raw.len:
        return false
  result = commands > 0

## ``sed`` is useful for file inspection and stdout transformations, but its
## full language can write files or execute commands. Admit only address +
## observational-command expressions such as ``1,20p`` and one stdout-only
## substitution such as ``s/.*\\.//``.
func implSafeSedProgram(raw: string): bool =
  let program = raw.strip()
  if program.len == 0 or program.len > 512 or
      program.contains('\n') or program.contains('\r'):
    return false
  if program.contains(';'):
    return implSafeSedSubstitutionSequence(program)
  if implSafeSedSubstitution(program):
    return true
  if program[^1] notin {'p', 'P', 'q', 'Q', 'd', 'D', '=', 'l', 'n', 'N'}:
    return false
  result = implSafeSedAddressExpression(program[0 ..< program.len - 1])

func implValidateSed(tokens: seq[string]): CommandPolicyDecision =
  if tokens.len == 2 and toLowerAscii(tokens[1]) in ["-h", "--help", "--version"]:
    return implAllow()
  var index = 1
  var expressionCount = 0
  var optionsEnded = false
  while index < tokens.len:
    let token = tokens[index]
    if not optionsEnded and token == "--":
      optionsEnded = true
      index += 1
      continue
    if not optionsEnded and token.startsWith("--"):
      if token in [
        "--quiet", "--silent", "--regexp-extended", "--unbuffered",
        "--separate", "--null-data", "--posix", "--sandbox", "--binary"
      ]:
        index += 1
        continue
      if token == "--expression":
        if index + 1 >= tokens.len or
            not implSafeSedProgram(tokens[index + 1]):
          return implReject("sed expression is outside the display-only subset")
        expressionCount += 1
        index += 2
        continue
      if token.startsWith("--expression="):
        if not implSafeSedProgram(token[13 .. ^1]):
          return implReject("sed expression is outside the display-only subset")
        expressionCount += 1
        index += 1
        continue
      return implReject("sed option can modify files or load a program")
    if not optionsEnded and token.startsWith("-") and token != "-":
      var cursor = 1
      while cursor < token.len:
        let option = token[cursor]
        if option in {'n', 'E', 'r', 'u', 's', 'z', 'b'}:
          cursor += 1
          continue
        if option != 'e':
          return implReject("sed option can modify files or load a program")
        var expression = ""
        if cursor + 1 < token.len:
          expression = token[cursor + 1 .. ^1]
        elif index + 1 < tokens.len:
          expression = tokens[index + 1]
          index += 1
        if not implSafeSedProgram(expression):
          return implReject("sed expression is outside the display-only subset")
        expressionCount += 1
        cursor = token.len
      index += 1
      continue
    if expressionCount == 0:
      if not implSafeSedProgram(token):
        return implReject("sed expression is outside the display-only subset")
      expressionCount = 1
      index += 1
    break
  if expressionCount == 0:
    return implReject("sed requires a display-only expression")
  while index < tokens.len:
    if not optionsEnded and tokens[index] != "-" and
        tokens[index].startsWith("-"):
      return implReject("sed input operand resembles an option")
    index += 1
  result = implAllow()

func implValidateSensors(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["-s", "--set"]):
    return implReject("sensors set mode can change hardware thresholds")
  for token in tokens:
    if token.startsWith("-") and not token.startsWith("--"):
      var index = 1
      while index < token.len:
        if token[index] == 's':
          return implReject("sensors set mode can change hardware thresholds")
        if token[index] == 'c':
          break
        index += 1
  result = implAllow()

func implValidateDate(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["-s", "--set"]):
    return implReject("date-setting options are not read-only")
  for token in tokens:
    if token.startsWith("-s") and not token.startsWith("--"):
      return implReject("date-setting options are not read-only")
  var index = 1
  while index < tokens.len:
    let lower = toLowerAscii(tokens[index])
    if lower in ["-d", "--date", "-r", "--reference", "-f", "--file"]:
      if index + 1 >= tokens.len:
        return implReject("date query option is missing its value")
      index += 2
      continue
    if lower.startsWith("--date=") or lower.startsWith("--reference=") or
        lower.startsWith("--file=") or tokens[index].startsWith("-") or
        tokens[index].startsWith("+"):
      index += 1
      continue
    return implReject("ambiguous date operand may set the system clock")
  result = implAllow()

func implValidateHostname(tokens: seq[string]): CommandPolicyDecision =
  for token in tokens:
    if token == "-F" or toLowerAscii(token) in ["-b", "--boot", "--file"] or
        (token.startsWith("-F") and not token.startsWith("--")) or
        implHasForbiddenOption(@[token], ["--file"]):
      return implReject("hostname-setting options are not read-only")
  if tokens.len > 1:
    for index in 1 ..< tokens.len:
      if not tokens[index].startsWith("-"):
        return implReject("hostname operand may change the host name")
  result = implAllow()

func implValidateDmesg(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, [
    "-c", "-C", "-n", "-D", "-E", "--clear", "--read-clear",
    "--console-level", "--console-off", "--console-on"
  ]):
    return implReject("dmesg option can clear or reconfigure kernel logging")
  for token in tokens:
    if token in ["-w", "-W"] or
        toLowerAscii(token) in ["--follow", "--follow-new"]:
      return implReject("dmesg follow mode is unbounded")
    if token.startsWith("-") and not token.startsWith("--"):
      if token.contains('w') or token.contains('W'):
        return implReject("dmesg follow mode is unbounded")
      for flag in ['c', 'C', 'n', 'D', 'E']:
        if token.contains(flag):
          return implReject(
            "dmesg option can clear or reconfigure kernel logging")
  result = implAllow()

func implValidateStorageReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "mount":
    var index = 1
    while index < tokens.len:
      let option = toLowerAscii(tokens[index])
      if option in ["-l", "--show-labels", "-v", "--verbose", "-h",
          "--help", "--version"]:
        index += 1
      elif option in ["-t", "--types", "-o", "-O", "--test-opts"]:
        if index + 1 >= tokens.len:
          return implReject("mount listing option is missing its value")
        index += 2
      elif option.startsWith("--types=") or
          option.startsWith("--test-opts="):
        index += 1
      else:
        return implReject("mount is allowed only in filesystem listing mode")
  of "blkid":
    if implHasForbiddenOption(tokens, [
      "--cache-file", "--write-cache", "--garbage-collect"
    ]) or implHasToken(tokens, ["-c", "-w", "-g"]):
      return implReject("blkid cache options can modify persistent state")
    for token in tokens:
      if token.startsWith("-c") or token.startsWith("-w") or
          (token.startsWith("-g") and not token.startsWith("--")):
        return implReject("blkid cache options can modify persistent state")
  of "dmidecode":
    if implHasForbiddenOption(tokens, ["--dump-bin"]):
      return implReject("dmidecode dump mode can write a file")
  of "udevadm":
    if tokens.len < 2 or toLowerAscii(tokens[1]) notin [
      "info", "--version", "--help"
    ]:
      return implReject("udevadm is allowed only for device information")
    if implHasForbiddenOption(tokens, ["--cleanup-db"]):
      return implReject("udevadm cleanup changes device state")
  else:
    discard
  result = implAllow()

func implValidateHostDiagnostic(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "numactl":
    if tokens.len == 2 and tokens[1] in ["-H", "--hardware", "-s", "--show"]:
      return implAllow()
    return implReject("numactl is allowed only for hardware/show queries")
  of "auditctl":
    var hasQuery = false
    for index in 1 ..< tokens.len:
      if tokens[index] in ["-s", "-l", "-v"]:
        hasQuery = true
      else:
        return implReject("auditctl is allowed only for status/rule listing")
    if hasQuery:
      return implAllow()
  of "swapon":
    var hasQuery = false
    var index = 1
    while index < tokens.len:
      let lower = toLowerAscii(tokens[index])
      if lower in [
        "-s", "--summary", "--show", "--bytes", "--noheadings", "--raw",
        "--json"
      ] or lower.startsWith("--show="):
        hasQuery = true
        index += 1
        continue
      if lower in ["-o", "--output"]:
        if index + 1 >= tokens.len:
          return implReject("swapon output columns are missing")
        hasQuery = true
        index += 2
        continue
      if lower.startsWith("--output="):
        hasQuery = true
        index += 1
        continue
      return implReject("swapon option can activate swap")
    if hasQuery:
      return implAllow()
  of "losetup":
    var hasQuery = false
    var index = 1
    while index < tokens.len:
      let lower = toLowerAscii(tokens[index])
      if lower in [
        "-a", "--all", "-l", "--list", "--json", "--raw", "--noheadings"
      ]:
        hasQuery = true
        index += 1
        continue
      if lower in ["-j", "--associated", "-o", "--output"]:
        if index + 1 >= tokens.len:
          return implReject("losetup query option is missing its value")
        hasQuery = true
        index += 2
        continue
      if lower.startsWith("--associated=") or lower.startsWith("--output="):
        hasQuery = true
        index += 1
        continue
      return implReject("losetup option can attach or change a loop device")
    if hasQuery:
      return implAllow()
  else:
    discard
  result = implReject(name & " action is not an approved host query")

func implValidateTmux(tokens: seq[string]): CommandPolicyDecision =
  if tokens.len < 2:
    return implReject("tmux query is missing a subcommand")
  for token in tokens:
    # tmux splits an individual or trailing semicolon, while interior
    # semicolons in a format value remain ordinary data.
    if token.endsWith(";") or token.contains('\n') or token.contains('\r'):
      return implReject("tmux command sequences are not permitted")
    if token.contains("#("):
      return implReject("tmux format shell commands are not permitted")
  var index = 1
  while index < tokens.len and tokens[index].startsWith("-"):
    let option = tokens[index]
    if option in ["-L", "-S"]:
      if index + 1 >= tokens.len:
        return implReject("tmux socket option is missing its value")
      index += 2
    elif option == "-u":
      index += 1
    elif option == "-V" and tokens.len == 2:
      return implAllow()
    else:
      return implReject("tmux global option can load config or write logs")
  if index >= tokens.len:
    return implReject("tmux query is missing a subcommand")
  let action = toLowerAscii(tokens[index])
  if action in ["display-message", "display"]:
    if implHasToken(tokens[index + 1 .. ^1], ["-p", "-a"]):
      return implAllow()
    return implReject("tmux display-message must print to stdout")
  if action in [
    "list-sessions", "ls", "list-windows", "lsw", "list-panes", "lsp",
    "list-clients", "lsc", "list-commands", "lscm", "list-keys", "lsk",
    "show-options", "show", "show-window-options", "show-environment",
    "info", "has-session", "list-buffers", "lsb", "show-buffer", "showb"
  ]:
    return implAllow()
  result = implReject("tmux subcommand is not an approved query")

func implValidateCrontab(tokens: seq[string]): CommandPolicyDecision =
  var hasList = false
  var index = 1
  while index < tokens.len:
    let option = toLowerAscii(tokens[index])
    if option == "-l":
      hasList = true
      index += 1
    elif option == "-u":
      if index + 1 >= tokens.len or
          not implSafeDiagnosticWord(tokens[index + 1]):
        return implReject("crontab user query is missing a literal user")
      index += 2
    else:
      return implReject("crontab is allowed only in list mode")
  if not hasList:
    return implReject("crontab is allowed only in list mode")
  result = implAllow()

func implValidateAtq(tokens: seq[string]): CommandPolicyDecision =
  var index = 1
  while index < tokens.len:
    let option = toLowerAscii(tokens[index])
    if option in ["-v", "--help", "--version"]:
      index += 1
    elif option == "-q":
      if index + 1 >= tokens.len or tokens[index + 1].len != 1:
        return implReject("atq queue query is missing one queue name")
      index += 2
    else:
      return implReject("atq option is outside queue-listing mode")
  result = implAllow()

func implValidateMokutil(tokens: seq[string]): CommandPolicyDecision =
  var hasQuery = false
  var index = 1
  while index < tokens.len:
    let option = toLowerAscii(tokens[index])
    if option in [
      "--sb-state", "--list-enrolled", "--list-new", "--list-delete",
      "--list-sbat-revocations", "--pk", "--kek", "--db", "--dbx",
      "--timeout", "--version"
    ]:
      hasQuery = true
      index += 1
    elif option == "--test-key":
      if index + 1 >= tokens.len:
        return implReject("mokutil test-key is missing a certificate path")
      hasQuery = true
      index += 2
    elif option in ["--verbose", "-v"]:
      index += 1
    else:
      return implReject("mokutil option can modify Secure Boot state")
  if not hasQuery:
    return implReject("mokutil query is missing an approved action")
  result = implAllow()

func implValidateLocalNetworkReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "ifconfig":
    var interfaces = 0
    for index in 1 ..< tokens.len:
      let value = toLowerAscii(tokens[index])
      if value in [
        "up", "down", "create", "destroy", "delete", "alias", "-alias",
        "add", "remove", "mtu", "metric", "media", "ssid", "channel",
        "inet", "inet6", "ether", "lladdr", "netmask", "broadcast",
        "promisc", "-promisc", "allmulti", "-allmulti", "multicast",
        "-multicast", "txqueuelen", "mem_start", "irq", "io_addr",
        "tunnel", "dstaddr", "pointopoint", "-pointopoint", "dynamic",
        "description", "vlan", "vlandev", "group", "-group", "carp",
        "mediaopt", "-mediaopt", "powersave", "-powersave"
      ]:
        return implReject("ifconfig argument can change interface state")
      if value.startsWith("-"):
        if value notin ["-a", "-l", "-u", "-d", "-m", "-v", "-s"]:
          return implReject("ifconfig option is outside query mode")
      else:
        interfaces += 1
        if interfaces > 1 or not implSafeDiagnosticWord(value):
          return implReject("ifconfig accepts at most one literal interface")
  of "resolvectl":
    var action = ""
    for index in 1 ..< tokens.len:
      let value = toLowerAscii(tokens[index])
      if value in [
        "dns", "domain", "default-route", "llmnr", "mdns", "dnsovertls",
        "dnssec", "nta", "revert", "flush-caches", "reset-statistics",
        "reset-server-features", "monitor"
      ]:
        return implReject("resolvectl action changes or continuously monitors state")
      if action.len == 0 and not value.startsWith("-"):
        action = value
    if action.len > 0 and action notin [
      "status", "query", "service", "openpgp", "tlsa", "statistics",
      "show-cache", "log-level", "--help", "--version"
    ]:
      return implReject("resolvectl action is not an approved query")
    if action == "log-level" and tokens.len != 2:
      return implReject("resolvectl log-level with a value changes state")
  of "networkctl":
    # --runtime is valueless. Treating it as value-taking would skip the real
    # action in "networkctl --runtime reload" and admit a mutator.
    let action = implFirstAction(tokens, 1, ["--root"])
    if action.len > 0 and action notin [
      "list", "status", "lldp", "label", "cat", "--help", "--version"
    ]:
      return implReject("networkctl action is not an approved query")
  of "rfkill":
    if tokens.len > 1 and toLowerAscii(tokens[1]) notin [
      "list", "-n", "--noheadings", "-r", "--raw", "-o", "--output",
      "--output-all", "-h", "--help", "-v", "--version"
    ]:
      return implReject("rfkill is allowed only in list mode")
    if implHasToken(tokens, ["block", "unblock", "toggle", "event"]):
      return implReject("rfkill action can change or continuously monitor state")
  else:
    discard
  result = implAllow()

func implValidateMacReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  if tokens.len < 2:
    return implReject(name & " query is missing an action")
  let action = toLowerAscii(tokens[1])
  case name
  of "launchctl":
    if action notin [
      "list", "print", "print-cache", "print-disabled", "blame", "procinfo",
      "hostinfo", "version", "help"
    ]:
      return implReject("launchctl action is not an approved query")
  of "scutil":
    if action in ["--dns", "--proxy", "--nwi"]:
      return implAllow()
    if action == "--get" and tokens.len == 3:
      return implAllow()
    if action == "--nc" and tokens.len >= 3 and
        toLowerAscii(tokens[2]) in ["list", "status", "show"]:
      return implAllow()
    return implReject("scutil is limited to explicit query operations")
  of "diskutil":
    if action in ["list", "info", "listfilesystems"]:
      return implAllow()
    if action in ["apfs", "corestorage", "cs"] and tokens.len > 2 and
        toLowerAscii(tokens[2]) == "list":
      return implAllow()
    return implReject("diskutil action is not an approved query")
  of "defaults":
    if action notin ["read", "read-type", "find", "domains", "help"]:
      return implReject("defaults action can modify preferences")
  of "mdutil":
    if not implHasToken(tokens, ["-s"]):
      return implReject("mdutil is allowed only for Spotlight status queries")
    for token in tokens:
      if token.startsWith("-") and token notin ["-s", "-a", "-v"]:
        return implReject("mdutil option can change the Spotlight index")
  of "log":
    if action notin ["show", "stats", "help"]:
      return implReject("log action can write or continuously stream")
  of "pmset":
    if action != "-g" or tokens.len > 3:
      return implReject("pmset is allowed only for one-shot -g queries")
    if tokens.len == 3 and toLowerAscii(tokens[2]) in [
      "live", "rawlog", "thermlog", "assertionslog"
    ]:
      return implReject("pmset live log mode is unbounded")
  of "networksetup":
    if not (action.startsWith("-get") or action.startsWith("-list")):
      return implReject("networksetup is limited to get/list queries")
    for index in 2 ..< tokens.len:
      let value = toLowerAscii(tokens[index])
      if value.startsWith("-set") or value.startsWith("-create") or
          value.startsWith("-delete") or value.startsWith("-add") or
          value.startsWith("-remove") or value.startsWith("-enable") or
          value.startsWith("-disable") or value == "-detectnewhardware":
        return implReject("networksetup argument can change network state")
  of "csrutil":
    if not ((tokens.len == 2 and action == "status") or
        (tokens.len == 3 and action == "authenticated-root" and
          toLowerAscii(tokens[2]) == "status")):
      return implReject("csrutil is allowed only for status queries")
  of "spctl":
    if tokens.len != 2 or action notin ["--status", "-s"]:
      return implReject("spctl is allowed only for Gatekeeper status")
  of "fdesetup":
    if action notin ["status", "isactive", "supportsauthrestart", "list"]:
      return implReject("fdesetup action is not an approved query")
  of "systemextensionsctl":
    if tokens.len != 2 or action != "list":
      return implReject("systemextensionsctl is allowed only for list")
  of "nvram":
    for index in 1 ..< tokens.len:
      if tokens[index] notin ["-p", "-x"]:
        return implReject("nvram is allowed only for print queries")
    if "-p" notin tokens:
      return implReject("nvram query requires -p")
  of "profiles":
    if action notin ["status", "show", "list", "help", "version"]:
      return implReject("profiles action is not an approved query")
    var index = 2
    while index < tokens.len:
      let lower = toLowerAscii(tokens[index])
      if lower == "-output":
        if index + 1 >= tokens.len:
          return implReject("profiles -output is missing its destination")
        index += 1
        if toLowerAscii(tokens[index]) notin ["stdout", "stdout-xml"]:
          return implReject("profiles output files can modify the filesystem")
      elif lower.startsWith("-output="):
        if lower["-output=".len .. ^1] notin ["stdout", "stdout-xml"]:
          return implReject("profiles output files can modify the filesystem")
      elif lower.startsWith("-output"):
        return implReject("profiles output destination is not an approved sink")
      index += 1
  of "tmutil":
    if action notin [
      "status", "listbackups", "latestbackup", "destinationinfo",
      "listlocalsnapshots", "listlocalsnapshotdates", "machinedirectory"
    ]:
      return implReject("tmutil action is not an approved query")
  else:
    discard
  result = implAllow()

func implValidateMacMetadataReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "xattr":
    var index = 1
    var optionsEnded = false
    while index < tokens.len:
      let token = tokens[index]
      let lower = toLowerAscii(token)
      if optionsEnded or not token.startsWith("-") or token == "-":
        index += 1
        continue
      if token == "--":
        optionsEnded = true
        index += 1
        continue
      if lower in ["--write", "--delete", "--clear"]:
        return implReject("xattr option can modify extended attributes")
      if lower.startsWith("--"):
        return implReject("xattr long option is outside listing mode")
      if token == "-p":
        if index + 1 >= tokens.len:
          return implReject("xattr print option is missing an attribute name")
        index += 2
        continue
      for option in token[1 .. ^1]:
        if option in ['w', 'd', 'c']:
          return implReject("xattr option can modify extended attributes")
        if option notin ['l', 'r', 's', 'v', 'x']:
          return implReject("xattr option is outside listing mode")
      index += 1
    return implAllow()
  of "mdfind":
    var index = 1
    while index < tokens.len:
      let option = toLowerAscii(tokens[index])
      if option == "-live":
        return implReject("mdfind live mode is unbounded")
      if option in ["-onlyin", "-name", "-s"]:
        if index + 1 >= tokens.len:
          return implReject("mdfind option is missing its value")
        index += 2
      elif option.startsWith("-") and option notin [
          "-interpret", "-literal", "-count", "-0"
      ]:
        return implReject("mdfind option is outside finite query mode")
      else:
        index += 1
    return implAllow()
  of "pkgutil":
    if tokens.len < 2 or toLowerAscii(tokens[1]) notin [
      "--pkgs", "--pkgs-plist", "--pkg-info", "--pkg-info-plist",
      "--files", "--groups", "--group-pkgs", "--file-info",
      "--file-info-plist", "--check-signature", "--payload-files"
    ]:
      return implReject("pkgutil action can change receipts or write files")
    for index in 2 ..< tokens.len:
      if tokens[index].startsWith("-"):
        return implReject("pkgutil accepts one explicit query action")
    return implAllow()
  of "plutil":
    if implHasToken(tokens, [
      "-convert", "-insert", "-replace", "-remove", "-create"
    ]):
      return implReject("plutil action can modify a property list")
    if not implHasToken(tokens, ["-p", "-lint"]):
      return implReject("plutil is allowed only for print or lint queries")
    for token in tokens:
      if token.startsWith("-") and token notin ["-p", "-lint", "--"]:
        return implReject("plutil option is outside print/lint mode")
    return implAllow()
  of "xcode-select":
    if tokens.len == 2 and toLowerAscii(tokens[1]) in [
      "-p", "--print-path", "-v", "--version"
    ]:
      return implAllow()
    return implReject("xcode-select is allowed only for path/version queries")
  else:
    discard
  result = implReject(name & " action is not an approved macOS query")

func implValidateNetworkReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "ss":
    if implHasForbiddenOption(tokens, ["-K", "--kill", "--events"]):
      return implReject("ss kill/events mode changes state or is unbounded")
    for token in tokens:
      if token.startsWith("-") and not token.startsWith("--") and
          (token.contains('K') or token.contains('E')):
        return implReject("ss kill/events mode changes state or is unbounded")
  of "arp":
    if implHasForbiddenOption(tokens, ["-d", "-s", "-f"]):
      return implReject("arp option can change the neighbor table")
    for token in tokens:
      if token.startsWith("-d") or token.startsWith("-s") or
          token.startsWith("-f"):
        return implReject("arp option can change the neighbor table")
  of "route":
    for token in tokens:
      let lower = toLowerAscii(token)
      if lower in ["-f", "/f"]:
        return implReject("route action can change routing state")
      if lower == "monitor":
        return implReject("route monitor mode is unbounded")
      for action in ["add", "change", "delete", "del", "flush"]:
        if lower.len >= 2 and action.startsWith(lower):
          return implReject("route action can change routing state")
  of "ip":
    if implHasForbiddenOption(tokens, ["--batch", "--force"] ) or
        implHasToken(tokens, ["-b", "-batch", "-force"]):
      return implReject("ip batch mode can execute mutating commands")
    var index = 1
    while index < tokens.len and tokens[index].startsWith("-"):
      let option = toLowerAscii(tokens[index])
      if option in ["-n", "-netns", "-netnamespace", "-family", "-f"]:
        if index + 1 >= tokens.len:
          return implReject("ip query option is missing its value")
        index += 2
      elif option in [
          "-4", "-6", "-0", "-br", "-brief", "-d", "-details",
          "-s", "-stats", "-statistics", "-h", "-human", "-human-readable",
          "-o", "-oneline", "-j", "-json", "-p", "-pretty",
          "-r", "-resolve", "-c", "-color", "-c=never", "-color=never",
          "-version", "-v"]:
        index += 1
      else:
        return implReject("ip global option is outside the query allowlist")
    if index >= tokens.len:
      return implAllow()
    let objectName = toLowerAscii(tokens[index])
    if objectName notin [
        "address", "addr", "a", "link", "l", "route", "r", "rule",
        "neighbor", "neighbour", "neigh", "n", "maddress", "maddr",
        "mroute", "tunnel", "tuntap", "netns", "vrf", "netconf",
        "token", "tcpmetrics", "nexthop"]:
      return implReject("ip object is outside the query allowlist")
    index += 1
    if index < tokens.len and toLowerAscii(tokens[index]) notin [
        "show", "list", "lst", "get", "help"]:
      return implReject(
        "ip requires an explicit show/list/get action; mutation abbreviations are rejected")
    # netns/tunnel and other namespaces interpret get differently. Keep get
    # only for the documented route lookup (which has no mutation semantics).
    if index < tokens.len and toLowerAscii(tokens[index]) == "get" and
        objectName notin ["route", "r"]:
      return implReject("ip get is limited to route lookups")
  of "ipconfig":
    if tokens.len == 1:
      return implAllow()
    if tokens[1].startsWith("/"):
      for index in 1 ..< tokens.len:
        let lower = toLowerAscii(tokens[index])
        if lower in [
          "/all", "/allcompartments", "/displaydns", "/showclassid"
        ]:
          continue
        return implReject("ipconfig option can change network state")
    else:
      let action = toLowerAscii(tokens[1])
      if action notin [
        "getifaddr", "ifcount", "getoption", "getpacket", "getv6packet",
        "getra", "getsummary", "getdhcpduid", "getdhcpiaid"
      ]:
        return implReject(
          "macOS ipconfig is limited to explicit get/summary queries")
  of "nmcli":
    var index = 1
    while index < tokens.len and tokens[index].startsWith("-"):
      let option = toLowerAscii(tokens[index])
      if option in [
        "-t", "--terse", "-p", "--pretty", "-a", "--ask", "-s",
        "--show-secrets"
      ]:
        index += 1
      elif option in [
        "-m", "--mode", "-c", "--colors", "-e", "--escape", "-w",
        "--wait", "-f", "--fields", "-g", "--get-values"
      ]:
        if index + 1 >= tokens.len:
          return implReject("nmcli option is missing its value")
        index += 2
      elif option.contains('=') and (
          option.startsWith("--mode=") or option.startsWith("--colors=") or
          option.startsWith("--escape=") or option.startsWith("--wait=") or
          option.startsWith("--fields=") or
          option.startsWith("--get-values=")):
        index += 1
      else:
        return implReject("nmcli global option is outside the query allowlist")
    if index >= tokens.len:
      return implAllow()
    let objectName = toLowerAscii(tokens[index])
    let remaining = tokens.len - index
    if objectName == "monitor":
      return implReject("nmcli monitor mode is unbounded")
    case objectName
    of "general":
      if remaining == 1 or (remaining == 2 and
          toLowerAscii(tokens[index + 1]) in [
            "status", "permissions", "hostname", "logging"
          ]):
        return implAllow()
    of "networking":
      if remaining == 1 or (remaining == 2 and
          toLowerAscii(tokens[index + 1]) == "connectivity") or
          (remaining == 3 and
            toLowerAscii(tokens[index + 1]) == "connectivity" and
            toLowerAscii(tokens[index + 2]) == "check"):
        return implAllow()
    of "radio":
      if remaining <= 2 and (remaining == 1 or
          toLowerAscii(tokens[index + 1]) in ["all", "wifi", "wwan"]):
        return implAllow()
    of "connection":
      if remaining >= 2 and toLowerAscii(tokens[index + 1]) == "show":
        return implAllow()
    of "device":
      if remaining >= 2 and toLowerAscii(tokens[index + 1]) in [
          "status", "show"
      ]:
        return implAllow()
      if remaining >= 3 and
          toLowerAscii(tokens[index + 1]) in ["wifi", "lldp"] and
          toLowerAscii(tokens[index + 2]) == "list":
        return implAllow()
    of "monitor":
      if remaining == 1:
        return implAllow()
    else:
      discard
    return implReject("nmcli is limited to explicit query operations")
  of "netsh":
    for token in tokens:
      let lower = toLowerAscii(token)
      for action in [
        "set", "add", "delete", "reset", "exec", "import", "export",
        "connect", "disconnect", "start", "stop"
      ]:
        if lower.len >= 2 and action.startsWith(lower):
          return implReject("netsh action can change network state")
    if not implHasToken(tokens, ["show"]):
      return implReject("netsh is allowed only for show operations")
  else:
    discard
  result = implAllow()

func implValidateSystemReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["--host", "--machine", "--image"]):
    return implReject("remote or image transports can execute helpers")
  for token in tokens:
    let lower = toLowerAscii(token)
    if token in ["-H", "-M"] or lower in ["--host", "--machine", "--image"] or
        lower.startsWith("--host=") or lower.startsWith("--machine=") or
        lower.startsWith("--image="):
      return implReject("remote or image transports can execute helpers")
  case name
  of "systemctl":
    if tokens.len == 1:
      return implAllow()
    let action = implFirstAction(tokens, 1, [
      "--host", "-H", "--machine", "-M", "--type", "-t", "--state",
      "--property", "-p", "--root", "--image"
    ])
    if action.len == 0:
      var index = 1
      while index < tokens.len:
        let option = toLowerAscii(tokens[index])
        if option in [
          "--failed", "--all", "-a", "--full", "-l", "--reverse",
          "--after", "--before", "--show-types", "--no-pager", "--plain",
          "--legend", "--no-legend", "--value", "--quiet", "-q",
          "--system", "--user", "--global", "--version"
        ]:
          index += 1
          continue
        if option in [
          "--type", "-t", "--state", "--property", "-p", "--root"
        ]:
          if index + 1 >= tokens.len:
            return implReject("systemctl query option is missing its value")
          index += 2
          continue
        if option.startsWith("--type=") or option.startsWith("--state=") or
            option.startsWith("--property=") or option.startsWith("--root="):
          index += 1
          continue
        return implReject("systemctl option is outside the query allowlist")
      return implAllow()
    if action notin [
      "status", "show", "is-active", "is-enabled", "is-failed", "list-units",
      "is-system-running", "list-unit-files", "list-dependencies", "list-jobs",
      "list-timers", "list-sockets", "list-paths", "list-automounts",
      "get-default", "show-environment", "cat", "--version"
    ]:
      return implReject("systemctl action is not an approved query")
    if implHasForbiddenOption(tokens, ["--wait"]):
      return implReject("systemctl wait mode is unbounded")
  of "journalctl":
    if implHasForbiddenOption(tokens, [
      "--vacuum-size", "--vacuum-time", "--vacuum-files", "--rotate",
      "--sync", "--flush", "--relinquish-var", "--smart-relinquish-var",
      "--setup-keys", "--update-catalog", "--force"
    ]):
      return implReject("journalctl maintenance option changes state")
    if implHasForbiddenOption(tokens, ["--follow"]):
      return implReject("journalctl follow mode is unbounded")
    for token in tokens:
      if token.startsWith("-") and not token.startsWith("--") and
          token.contains('f'):
        return implReject("journalctl follow mode is unbounded")
    for token in tokens:
      let lower = toLowerAscii(token)
      let optionName =
        if lower.contains('='): lower[0 ..< lower.find('=')]
        else: lower
      if optionName == "--cursor-file" or
          (optionName.len > "--cursor".len and
            "--cursor-file".startsWith(optionName)):
        return implReject("journalctl cursor file can modify persistent state")
  of "timedatectl":
    let action = implFirstAction(tokens, 1, ["--host", "-H", "--machine", "-M"])
    if tokens.len > 1 and action notin [
      "status", "show", "timesync-status", "show-timesync", "list-timezones"
    ]:
      return implReject("timedatectl action is not an approved query")
  of "loginctl":
    let action = implFirstAction(tokens, 1, ["--host", "-H", "--machine", "-M"])
    if tokens.len > 1 and action notin [
      "list-sessions", "list-users", "list-seats", "session-status",
      "user-status", "seat-status", "show-session", "show-user", "show-seat"
    ]:
      return implReject("loginctl action is not an approved query")
  of "sysctl":
    if implHasForbiddenOption(tokens, [
      "-w", "--write", "-p", "--load", "--system"
    ]):
      return implReject("sysctl write or load mode changes kernel state")
    for token in tokens:
      if token.contains('=') or
          (token.startsWith("-") and not token.startsWith("--") and
            (token.contains('w') or token.contains('p'))):
        return implReject("sysctl assignment changes kernel state")
  of "hostnamectl":
    let action = implFirstAction(tokens, 1, ["--host", "-H", "--machine", "-M"])
    if action.len > 0 and action notin ["status", "--help", "--version"]:
      return implReject("hostnamectl action is not an approved query")
  of "localectl":
    let action = implFirstAction(tokens, 1, ["--host", "-H", "--machine", "-M"])
    if action.len > 0 and action notin [
      "status", "list-locales", "list-keymaps", "list-x11-keymap-models",
      "list-x11-keymap-layouts", "list-x11-keymap-variants",
      "list-x11-keymap-options", "--help", "--version"
    ]:
      return implReject("localectl action is not an approved query")
  of "service":
    if not ((tokens.len == 2 and
        toLowerAscii(tokens[1]) == "--status-all") or
        (tokens.len == 3 and toLowerAscii(tokens[2]) == "status")):
      return implReject("service is allowed only for status queries")
  of "systemd-analyze":
    let action = implFirstAction(tokens, 1, ["--host", "-H", "--machine", "-M"])
    if action.len > 0 and action notin [
      "time", "blame", "critical-chain", "plot", "dot", "dump",
      "cat-config", "unit-files", "unit-paths", "exit-status", "capability",
      "condition", "calendar", "timestamp", "timespan", "verify", "security",
      "inspect-elf", "--help", "--version"
    ]:
      return implReject("systemd-analyze action is not an approved query")
  else:
    discard
  result = implAllow()

func implNvidiaOptionMatches(token: string, option: string): bool =
  let separator = token.find('=')
  let optionName = if separator >= 0: token[0 ..< separator] else: token
  if option.startsWith("--"):
    return toLowerAscii(optionName) == toLowerAscii(option)
  result = optionName == option

func implHasNvidiaOption(
  tokens: seq[string],
  options: openArray[string]
): bool =
  for index in 2 ..< tokens.len:
    for option in options:
      if implNvidiaOptionMatches(tokens[index], option):
        return true

## NVIDIA reuses short option letters across subcommands (for example top-level
## ``-p`` changes state while ``topo -p`` only prints a path). Validate each
## query namespace against its own documented option surface instead of
## applying top-level mutation prefixes to unrelated subcommands.
func implValidateNvidiaQueryOptions(
  action: string,
  tokens: seq[string],
  options: openArray[string]
): CommandPolicyDecision =
  for index in 2 ..< tokens.len:
    let token = tokens[index]
    if not token.startsWith("-"):
      continue
    var allowed = false
    for option in options:
      if implNvidiaOptionMatches(token, option):
        allowed = true
        break
    if not allowed:
      return implReject(
        "nvidia-smi " & action & " option is outside documented query mode")
  result = implAllow()

func implValidateNvidiaMonitor(
  action: string,
  tokens: seq[string]
): CommandPolicyDecision =
  let optionDecision = implValidateNvidiaQueryOptions(action, tokens, [
    "-i", "--id", "-d", "--delay", "-c", "--count", "-s", "--select",
    "--gpm-metrics", "--gpm-options", "-o", "--options", "-h", "--help",
    "--format"
  ])
  if not optionDecision.allowed:
    return optionDecision
  if implHasNvidiaOption(tokens, ["-h", "--help"]):
    return implAllow()

  var hasBoundedCount = false
  var index = 2
  while index < tokens.len:
    let lower = toLowerAscii(tokens[index])
    if lower in ["-c", "--count"]:
      if index + 1 >= tokens.len or
          not implPositiveAtMost(tokens[index + 1], 5):
        return implReject("nvidia-smi monitor count exceeds the safe bound")
      hasBoundedCount = true
      index += 2
      continue
    if lower.startsWith("-c=") or lower.startsWith("--count="):
      let separator = lower.find('=')
      if not implPositiveAtMost(tokens[index][separator + 1 .. ^1], 5):
        return implReject("nvidia-smi monitor count exceeds the safe bound")
      hasBoundedCount = true
    if lower in ["-d", "--delay"]:
      if index + 1 >= tokens.len or
          not implPositiveAtMost(tokens[index + 1], 10):
        return implReject("nvidia-smi monitor delay exceeds the safe bound")
      index += 2
      continue
    if lower.startsWith("-d=") or lower.startsWith("--delay="):
      let separator = lower.find('=')
      if not implPositiveAtMost(tokens[index][separator + 1 .. ^1], 10):
        return implReject("nvidia-smi monitor delay exceeds the safe bound")
    index += 1
  if not hasBoundedCount:
    return implReject("nvidia-smi monitor requires a bounded sample count")
  result = implAllow()

func implValidateNvidiaSubcommand(
  action: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case action
  of "dmon", "pmon":
    if implHasNvidiaOption(tokens, ["-f", "--filename"]):
      return implReject("nvidia-smi monitor output file can modify the filesystem")
    return implValidateNvidiaMonitor(action, tokens)
  of "topo":
    return implValidateNvidiaQueryOptions(action, tokens, [
      "-m", "--matrix", "-mp", "--matrix_pci", "-i", "--id", "-c",
      "--cpu", "-n", "--nearest_gpus", "-p", "--gpu_path", "-p2p",
      "--p2pstatus", "-C", "--get-numa-id-of-nearby-cpu", "-M",
      "--get-numa-id-of-nearby-mem", "-gnid", "--gpu-numa-id", "-h",
      "--help", "-nvme", "--matrix_nvme"
    ])
  of "nvlink":
    return implValidateNvidiaQueryOptions(action, tokens, [
      "-h", "--help", "-i", "--id", "-l", "--link", "-s", "--status",
      "-c", "--capabilities", "-p", "--pcibusid", "-R",
      "--remotelinkinfo", "-gc", "--getcontrol", "-g", "--getcounters",
      "-e", "--errorcounters", "-ec", "--crcerrorcounters", "-gt",
      "--getthroughput", "-gLowPwrInfo", "--getLowPowerInfo", "-gBwMode",
      "--getBandwidthMode", "-cBridge", "--checkBridge", "-gLWidth",
      "--getLinkWidth", "-info", "--info"
    ])
  of "c2c":
    return implValidateNvidiaQueryOptions(action, tokens, [
      "-h", "--help", "-i", "--id", "-l", "--link", "-s", "--status",
      "-e", "--errorCounters", "-gLowPwrInfo", "-getLowPowerInfo"
    ])
  of "encodersessions", "fbcsessions":
    if implHasNvidiaOption(tokens, ["-l", "--loop"]):
      return implReject("nvidia-smi session loop mode is unbounded")
    return implValidateNvidiaQueryOptions(action, tokens, [
      "-h", "--help", "-i", "--id"
    ])
  of "vgpu":
    if implHasToken(tokens, ["set-scheduler-state"]) or
        implHasNvidiaOption(tokens, [
          "-caa", "--clear-accounted-apps", "-shm",
          "--set-heterogeneous-mode", "-smts", "--set-mig-timeslice-mode"
        ]):
      return implReject("nvidia-smi vgpu option changes scheduler or accounting state")
    if implHasNvidiaOption(tokens, [
        "-l", "--loop", "-lms", "--loop-ms"
      ]):
      return implReject("nvidia-smi vgpu loop mode is unbounded")
    if implHasNvidiaOption(tokens, ["-f", "--filename"]):
      return implReject("nvidia-smi vgpu output file can modify the filesystem")
    return implValidateNvidiaQueryOptions(action, tokens, [
      "-h", "--help", "-i", "--id", "-gi", "--gpu-instance-id", "-q",
      "--query", "-u", "--utilization", "--gpm-metrics", "-p", "--pmon",
      "-s", "--supported", "-c", "--creatable", "-es", "--encodersessions",
      "-m", "--migrationcap", "-ss", "--schedulerstate", "-sc",
      "--schedulercaps", "-sl", "--schedulerlogs",
      "--query-vgpu-scheduler-logs", "-v", "--verbose",
      "--query-accounted-apps", "-fs", "--fbcsessions", "-ghm",
      "--get-heterogeneous-mode", "--query-gpu-instance-vgpu-scheduler-logs",
      "--format"
    ])
  of "power-hint":
    return implValidateNvidiaQueryOptions(action, tokens, [
      "-i", "--id", "-l", "--list-info", "-gc", "--graphics-clock",
      "-mc", "--memory-clock", "-t", "--temperature", "-p", "--profile",
      "-h", "--help"
    ])
  of "base-clocks":
    return implValidateNvidiaQueryOptions(action, tokens, [
      "-i", "--id", "-h", "--help"
    ])
  of "pci":
    if implHasNvidiaOption(tokens, ["-cErrCnt", "--clearErrorCounters"]):
      return implReject("nvidia-smi pci clear mode changes hardware counters")
    return implValidateNvidiaQueryOptions(action, tokens, [
      "-h", "--help", "-i", "--id", "-gErrCnt", "--getErrorCounters",
      "-gCnt", "--getCounters"
    ])
  of "prm":
    return implValidateNvidiaQueryOptions(action, tokens, [
      "-h", "--help", "-i", "--index", "-l", "--list", "-n", "--name",
      "-f", "--info", "-p", "--params", "-c", "--counters"
    ])
  else:
    return implReject("nvidia-smi subcommand is outside query mode")

func implValidateNvidiaSmi(tokens: seq[string]): CommandPolicyDecision =
  if tokens.len > 1 and not tokens[1].startsWith("-"):
    let action = toLowerAscii(tokens[1])
    if action in [
      "stats", "daemon", "replay", "mig", "drain", "conf-compute",
      "clocks", "compute-policy", "boost-slider", "gpm",
      "power-smoothing", "power-profiles"
    ]:
      return implReject(
        "nvidia-smi subcommand can stream, write, or control GPU state")
    return implValidateNvidiaSubcommand(action, tokens)

  if implHasForbiddenOption(tokens, [
    "-pm", "--persistence-mode", "-pl", "--power-limit", "-ac",
    "--applications-clocks", "-rac", "--reset-applications-clocks", "-lgc",
    "--lock-gpu-clocks", "-rgc", "--reset-gpu-clocks", "-lmc",
    "--lock-memory-clocks", "-rmc", "--reset-memory-clocks", "-r", "--gpu-reset",
    "-gom", "--gom", "--compute-mode", "--auto-boost-default",
    "--auto-boost-permission", "--clock-lock", "--reset-ecc-errors",
    "-e", "--ecc-config", "-mig", "--mig-mode", "-dm", "--driver-model",
    "-fdm", "--force-driver-model", "-am", "--accounting-mode",
    "-caa", "--clear-accounted-apps", "-gtt", "--gpu-target-temp",
    "--module-power-limit", "--power-hint", "--filename", "--debug",
    "-p", "-vm", "--virt-mode", "-cc", "--cuda-clocks", "-den",
    "--dram-encryption", "--set-hostname", "-t", "--toggle-led",
    "--multi-instance-gpu"
  ]):
    return implReject("nvidia-smi option changes GPU state")
  for token in tokens:
    let lower = toLowerAscii(token)
    if token == "-l" or lower in ["--loop", "-lms", "--loop-ms"] or
        lower.startsWith("--loop=") or lower.startsWith("--loop-ms=") or
        (token.startsWith("-l") and not token.startsWith("--") and
          token.len > 2 and implAllDigits(token[2 .. ^1])):
      return implReject("nvidia-smi loop mode is unbounded")
    if token.startsWith("-") and not token.startsWith("--") and
        token.contains('f'):
      return implReject("nvidia-smi output option can write a file")
    for prefix in [
      "-pm", "-pl", "-ac", "-rac", "-lgc", "-rgc", "-lmc", "-rmc",
      "-r", "-gom", "-c", "-e", "-caa", "-gtt", "-mig", "-dm",
      "-fdm", "-am", "-p", "-vm", "-den", "-t"
    ]:
      if lower.startsWith(prefix):
        return implReject("nvidia-smi option changes GPU state")
  # Top-level nvidia-smi mixes queries and controls. Keep documented
  # query/list/help families, but fail closed on unknown future switches.
  for index in 1 ..< tokens.len:
    let token = tokens[index]
    if implIsSafeOptionTerminator(tokens, index):
      break
    if not token.startsWith("-"):
      continue
    let separator = token.find('=')
    let optionName =
      if separator >= 0: token[0 ..< separator]
      else: token
    let lower = toLowerAscii(optionName)
    if optionName in ["-h", "-L", "-B", "-q", "-x", "-u", "-i", "-d"] or
        lower in [
          "--help", "--version", "--list-gpus", "--list-excluded-gpus",
          "--query", "--xml-format", "--dtd", "--unit", "--id",
          "--select", "--display", "--format", "--verbose"
        ] or lower.startsWith("--query-") or lower.startsWith("--list-") or
        lower.startsWith("--help-"):
      continue
    return implReject("nvidia-smi option is outside documented query mode")
  result = implAllow()

## ROCm SMI is a mixed monitoring/control CLI. AMD deliberately groups query
## switches under ``--show*`` while clock, fan, power, partition, RAS, load,
## save, and reset switches mutate hardware or files. Keep the broad query
## family useful, but reject every documented control family (including
## argparse-style long-option abbreviations) before considering display flags.
func implValidateRocmSmi(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, [
    "--gpureset", "--load", "--save", "--resetclocks", "--resetfans",
    "--resetprofile", "--resetpoweroverdrive", "--resetxgmierr",
    "--resetperfdeterminism", "--resetcomputepartition",
    "--resetmemorypartition", "--setclock", "--setsclk", "--setmclk",
    "--setpcie", "--setslevel", "--setmlevel", "--setvc", "--setsrange",
    "--setextremum", "--setmrange", "--setfan", "--setperflevel",
    "--setoverdrive", "--setmemoverdrive", "--setpoweroverdrive",
    "--setprofile", "--setperfdeterminism", "--setcomputepartition",
    "--setmemorypartition", "--rasenable", "--rasdisable", "--rasinject",
    "--autorespond"
  ]):
    return implReject("rocm-smi option can modify GPU or filesystem state")
  for index in 1 ..< tokens.len:
    let token = tokens[index]
    if not token.startsWith("-"):
      continue
    let separator = token.find('=')
    let optionName = if separator >= 0: token[0 ..< separator] else: token
    let lower = toLowerAscii(optionName)
    if token == "-r" or lower == "--resetclocks" or
        lower.startsWith("--set") or lower.startsWith("--reset") or
        lower.startsWith("--ras"):
      return implReject("rocm-smi option can modify GPU state")
    if token in [
      "-h", "-V", "-d", "-a", "-i", "-v", "-e", "-f", "-P", "-t",
      "-u", "-b", "-c", "-g", "-l", "-M", "-m", "-o", "-p", "-S", "-s"
    ] or lower.startsWith("--show") or lower in [
      "--help", "--version", "--device", "--alldevices", "--loglevel",
      "--json", "--csv"
    ]:
      continue
    return implReject("rocm-smi option is outside documented query mode")
  result = implAllow()

func implValidateHardwareReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "smartctl":
    if implHasForbiddenOption(tokens, [
      "--smart", "--set", "--offlineauto", "--saveauto", "--test",
      "--captive", "--abort"
    ]):
      return implReject("smartctl option can change device state")
    var index = 1
    while index < tokens.len:
      let token = tokens[index]
      if token.startsWith("-") and not token.startsWith("--"):
        for flag in ['s', 'o', 'S', 't', 'C', 'X']:
          if token.contains(flag):
            return implReject("smartctl option can change device state")
      var logType = ""
      if token == "-l" or toLowerAscii(token) == "--log":
        if index + 1 >= tokens.len:
          return implReject("smartctl log option is missing its value")
        index += 1
        logType = toLowerAscii(tokens[index])
      elif toLowerAscii(token).startsWith("--log="):
        logType = toLowerAscii(token["--log=".len .. ^1])
      if logType.contains("reset") or logType.startsWith("scttempint,") or
          logType.startsWith("scterc,"):
        return implReject("smartctl log option can reset or change device state")
      index += 1
  of "lshw":
    if implHasForbiddenOption(tokens, ["-dump", "--dump"]) or "-X" in tokens:
      return implReject("lshw dump or GUI mode is not a stdout-only query")
  of "upower":
    if implHasForbiddenOption(tokens, ["--monitor", "--monitor-detail"]) or
        "-m" in tokens:
      return implReject("upower monitor mode is unbounded")
  of "ethtool":
    if tokens.len < 2:
      return implReject("ethtool query is missing an interface or action")
    if implHasForbiddenOption(tokens, [
      "--change", "--pause", "--coalesce", "--set-ring", "--features",
      "--offload", "--change-eeprom", "--negotiate", "--identify", "--test",
      "--config-nfc", "--config-ntuple", "--set-channels", "--set-priv-flags",
      "--set-dump", "--set-eee", "--set-fec", "--set-phy-tunable",
      "--set-tunable", "--set-plca-cfg", "--cable-test", "--cable-test-tdr",
      "--flash", "--reset"
    ]):
      return implReject("ethtool option can change interface or device state")
    for token in tokens:
      if token in [
        "-s", "-A", "-C", "-G", "-K", "-E", "-r", "-p", "-t",
        "-N", "-U", "-L", "-W"
      ]:
        return implReject("ethtool option can change interface or device state")
    if not tokens[1].startsWith("-"):
      if tokens.len == 2 and implSafeDiagnosticWord(tokens[1]):
        return implAllow()
      return implReject("bare ethtool query accepts one literal interface")
    let queryAction = tokens[1]
    let lowerAction = toLowerAscii(queryAction)
    if queryAction in [
      "-a", "-c", "-g", "-k", "-i", "-d", "-e", "-S", "-T", "-P",
      "-l", "-m", "-n", "-u"
    ] or lowerAction in [
      "--show-pause", "--show-coalesce", "--show-ring", "--show-features",
      "--show-offload", "--driver", "--register-dump", "--eeprom-dump",
      "--statistics", "--phy-statistics", "--show-nfc", "--show-ntuple",
      "--show-channels", "--module-info", "--show-eee", "--show-fec",
      "--show-priv-flags", "--show-tunable", "--get-plca-cfg"
    ]:
      return implAllow()
    return implReject("ethtool action is outside the query allowlist")
  else:
    discard
  result = implAllow()

func implValidateFirewallReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "ufw":
    if tokens.len >= 2 and toLowerAscii(tokens[1]) in ["status", "show"]:
      return implAllow()
    return implReject("ufw is allowed only for status/show queries")
  of "firewall-cmd":
    if tokens.len < 2:
      return implReject("firewall-cmd query is missing an option")
    for index in 1 ..< tokens.len:
      let option = toLowerAscii(tokens[index])
      if not option.startsWith("-"):
        continue
      if option in [
        "-h", "--help", "-v", "--version", "-q", "--quiet", "--state",
        "--check-config", "--permanent", "--direct", "--zone", "--policy",
        "--ipset"
      ] or option.startsWith("--get-") or option.startsWith("--list-") or
          option == "--list-all" or option.startsWith("--query-") or
          option.startsWith("--info-") or option.startsWith("--path-") or
          option.startsWith("--zone=") or option.startsWith("--policy=") or
          option.startsWith("--ipset="):
        continue
      return implReject("firewall-cmd option is outside query mode")
  of "nft":
    if implHasForbiddenOption(tokens, ["--file", "--interactive"]) or
        "-f" in tokens or "-i" in tokens:
      return implReject("nft input mode can apply state-changing commands")
    var action = ""
    var index = 1
    while index < tokens.len:
      let token = tokens[index]
      if token.contains(';') or token.contains('\n') or token.contains('\r') or
          token.contains('{') or token.contains('}'):
        return implReject("nft embedded command syntax is not permitted")
      if token.startsWith("-") and token notin [
          "-a", "--handle", "-n", "--numeric", "-j", "--json",
          "-s", "--stateless", "-t", "--terse", "-y", "--numeric-priority",
          "-p", "--numeric-protocol", "-N", "--reversedns",
          "-S", "--service", "-u", "--guid"]:
        return implReject("nft option is outside the query allowlist")
      if not token.startsWith("-"):
        if action.len == 0:
          action = toLowerAscii(token)
      index += 1
    if action notin ["list", "get", "describe"]:
      return implReject("nft is allowed only for list/get/describe queries")
  of "iptables", "ip6tables":
    if implHasForbiddenOption(tokens, [
      "--append", "--delete", "--insert", "--replace", "--flush",
      "--zero", "--new", "--delete-chain", "--policy", "--rename-chain",
      "--modprobe", "--set-counters", "-M"
    ]) or "-M" in tokens:
      return implReject(name & " option can change firewall state or run a helper")
    var listing = false
    for token in tokens:
      if token in ["-L", "-S", "-C"] or
          toLowerAscii(token) in [
            "--list", "--list-rules", "--check", "-v", "--version"]:
        listing = true
      if token.startsWith("-") and not token.startsWith("--"):
        for flag in ['A', 'D', 'I', 'R', 'F', 'Z', 'N', 'X', 'E', 'P', 'M']:
          if token.contains(flag):
            return implReject(name & " command can change firewall state")
    if not listing:
      return implReject(name & " requires -L/--list or -S/--list-rules")
  else:
    discard
  result = implAllow()

func implValidateCurl(
  tokens: seq[string],
  shell: string
): CommandPolicyDecision =
  if tokens.len == 2 and toLowerAscii(tokens[1]) in [
    "--version", "-v", "--help", "-h", "--manual", "-m"
  ]:
    return implAllow()
  ## curl reads ~/.curlrc before ordinary arguments; -q/--disable must be the
  ## first argument so a local config cannot inject uploads or output files.
  if tokens.len < 2 or toLowerAscii(tokens[1]) notin ["-q", "--disable"]:
    return implReject("curl requires leading -q/--disable to ignore config")
  var index = 2
  var parallelRequested = false
  var parallelBounded = false
  while index < tokens.len:
    let token = tokens[index]
    if token == "--":
      index += 1
      while index < tokens.len:
        if not implCurlSchemeIsReadOnly(tokens[index]):
          return implReject("curl protocol can issue arbitrary service commands")
        index += 1
      break
    if token.startsWith("--"):
      let separator = token.find('=')
      let name = toLowerAscii(
        if separator >= 0: token[0 ..< separator]
        else: token)
      let noValueOptions = [
        "--disable", "--fail", "--fail-with-body", "--silent",
        "--show-error", "--location", "--head", "--include", "--insecure",
        "--no-buffer", "--globoff", "--verbose", "--ipv4", "--ipv6",
        "--compressed", "--raw", "--path-as-is", "--get", "--http1.0",
        "--http1.1", "--http2", "--http2-prior-knowledge", "--http3",
        "--http3-only", "--retry-connrefused", "--retry-all-errors",
        "--fail-early", "--parallel", "--parallel-immediate",
        "--no-progress-meter", "--progress-bar", "--netrc",
        "--netrc-optional", "--junk-session-cookies", "--list-only",
        "--ftp-pasv", "--disable-epsv", "--disable-eprt", "--ssl",
        "--ssl-reqd", "--cert-status", "--proxy-anyauth", "--proxy-basic",
        "--proxy-digest", "--proxy-negotiate", "--proxy-ntlm", "--anyauth",
        "--basic", "--digest", "--negotiate", "--ntlm", "--version",
        "--help", "--manual"
      ]
      if name in noValueOptions:
        if separator >= 0:
          return implReject("curl flag does not accept an attached value")
        if name in ["--parallel", "--parallel-immediate"]:
          parallelRequested = true
        index += 1
        continue
      let valueOptions = [
        "--request", "--output", "--dump-header", "--cookie-jar", "--url",
        "--header", "--proxy-header", "--user-agent", "--referer",
        "--cookie", "--user", "--proxy-user", "--oauth2-bearer",
        "--max-time", "--connect-timeout", "--speed-limit", "--speed-time",
        "--retry", "--retry-delay", "--retry-max-time", "--max-filesize",
        "--limit-rate", "--rate", "--max-redirs", "--range",
        "--continue-at", "--time-cond", "--etag-compare", "--proxy",
        "--noproxy", "--preproxy", "--socks4", "--socks4a", "--socks5",
        "--socks5-hostname", "--resolve", "--connect-to", "--interface",
        "--local-port", "--unix-socket", "--abstract-unix-socket",
        "--cacert", "--capath", "--proxy-cacert", "--proxy-capath",
        "--tls-max", "--ciphers", "--curves", "--tls13-ciphers",
        "--request-target", "--parallel-max", "--ftp-account",
        "--ftp-method", "--ftp-port", "--aws-sigv4", "--pubkey",
        "--hostpubmd5", "--knownhosts"
      ]
      if name notin valueOptions:
        return implReject("curl option is outside the read-only allowlist")
      var value = ""
      if separator >= 0:
        value = token[separator + 1 .. ^1]
      else:
        if index + 1 >= tokens.len:
          return implReject("curl option is missing its value")
        index += 1
        value = tokens[index]
      if value.len == 0:
        return implReject("curl option has an empty value")
      if name == "--request" and toLowerAscii(value) notin ["get", "head"]:
        return implReject("curl request method is not read-only")
      if name == "--parallel-max":
        if not implPositiveAtMost(value, 4):
          return implReject("curl parallelism must be between 1 and 4")
        parallelBounded = true
      if name in ["--header", "--proxy-header"] and
          implHeaderCanOverrideMethod(value):
        return implReject("curl header can hide a state-changing request method")
      if name in ["--output", "--dump-header", "--cookie-jar"] and
          value != "-" and not implIsNullDevice(value, shell):
        return implReject("curl output option can write a file")
      if name == "--url" and not implCurlSchemeIsReadOnly(value):
        return implReject("curl protocol can issue arbitrary service commands")
      index += 1
      continue
    if token.startsWith("-") and token != "-":
      var position = 1
      while position < token.len:
        let flag = token[position]
        if flag in {
          'q', 'f', 's', 'S', 'L', 'I', 'i', 'k', 'N', 'g', 'v', '4', '6',
          'G', '0', 'j', 'R', 'B', 'Z', 'p', 'l', 'V', 'h', 'M'
        }:
          if flag == 'Z':
            parallelRequested = true
          position += 1
          continue
        if flag notin {
          'X', 'o', 'D', 'c', 'H', 'A', 'e', 'b', 'u', 'm', 'r', 'x', 'U',
          'C', 'z', 'Y', 'y', 'P'
        }:
          return implReject("curl short option is outside the read-only allowlist")
        var value = ""
        if position + 1 < token.len:
          value = token[position + 1 .. ^1]
        else:
          if index + 1 >= tokens.len:
            return implReject("curl short option is missing its value")
          index += 1
          value = tokens[index]
        if value.len == 0:
          return implReject("curl short option has an empty value")
        if flag == 'X' and toLowerAscii(value) notin ["get", "head"]:
          return implReject("curl request method is not read-only")
        if flag == 'H' and implHeaderCanOverrideMethod(value):
          return implReject("curl header can hide a state-changing request method")
        if flag in {'o', 'D', 'c'} and value != "-" and
            not implIsNullDevice(value, shell):
          return implReject("curl output option can write a file")
        position = token.len
      index += 1
      continue
    if not implCurlSchemeIsReadOnly(token):
      return implReject("curl protocol can issue arbitrary service commands")
    index += 1
  if parallelRequested and not parallelBounded:
    return implReject("curl parallel mode requires --parallel-max of 1..4")
  result = implAllow()

func implValidateWget(tokens: seq[string]): CommandPolicyDecision =
  if tokens.len == 2 and toLowerAscii(tokens[1]) in [
    "--version", "-v", "--help", "-h"
  ]:
    return implAllow()
  if implHasForbiddenOption(tokens, [
    "--execute", "--config", "--use-askpass", "--post-data", "--post-file",
    "--method", "--body-data", "--body-file", "--warc-file", "--warc-cdx",
    "--save-cookies", "--mirror", "--recursive", "--background",
    "--delete-after", "--convert-links", "--backup-converted",
    "--output-file", "--append-output", "--rejected-log", "--hsts-file"
  ]):
    return implReject("wget option can mutate remotely, execute config, or write")
  var stdoutOnly = false
  var configDisabled = false
  var hstsDisabled = false
  var index = 1
  while index < tokens.len:
    let token = tokens[index]
    let lower = toLowerAscii(token)
    if lower == "--header":
      if index + 1 >= tokens.len:
        return implReject("wget header option is missing its value")
      if implHeaderCanOverrideMethod(tokens[index + 1]):
        return implReject(
          "wget header can hide a state-changing request method")
      index += 2
      continue
    if lower.startsWith("--header="):
      if implHeaderCanOverrideMethod(token["--header=".len .. ^1]):
        return implReject(
          "wget header can hide a state-changing request method")
      index += 1
      continue
    if lower == "--no-config":
      configDisabled = true
    if lower == "--no-hsts":
      hstsDisabled = true
    if token == "-O" or lower == "--output-document":
      if index + 1 < tokens.len and tokens[index + 1] == "-":
        stdoutOnly = true
        index += 2
        continue
      return implReject("wget output target can write a file")
    if lower.startsWith("--output-document="):
      if token[18 .. ^1] != "-":
        return implReject("wget output target can write a file")
      stdoutOnly = true
    if token.startsWith("-O") and token.len > 2:
      if token[2 .. ^1] != "-":
        return implReject("wget output target can write a file")
      stdoutOnly = true
    if token.startsWith("-") and token.endsWith("O-"):
      stdoutOnly = true
    if lower.startsWith("--execute") or lower.startsWith("--config") or
        lower.startsWith("--use-askpass") or
        (token.startsWith("-") and not token.startsWith("--") and
          token.contains('e')):
      return implReject("wget configuration execution is not permitted")
    if lower.startsWith("--post") or lower.startsWith("--method") or
        lower.startsWith("--body") or lower.startsWith("--warc-file") or
        lower.startsWith("--warc-cdx") or lower.startsWith("--save-cookies") or
        lower in ["-m", "--mirror", "-r", "--recursive", "-b", "--background",
          "--delete-after", "--convert-links", "--backup-converted"]:
      return implReject("wget option can mutate remotely or write a tree")
    if token in ["-o", "-a"] or lower in [
      "--output-file", "--append-output"
    ] or lower.startsWith("--output-file=") or
        lower.startsWith("--append-output=") or
        lower.startsWith("--rejected-log=") or
        lower.startsWith("--hsts-file="):
      return implReject("wget log output can write a file")
    if token.startsWith("-") and not token.startsWith("--"):
      for flag in ['o', 'a', 'm', 'r', 'b']:
        if token.contains(flag):
          return implReject("wget short option can write files")
    index += 1
  if not configDisabled:
    return implReject("wget requires --no-config to ignore executable config")
  if not hstsDisabled:
    return implReject("wget requires --no-hsts to avoid stateful HSTS storage")
  if not stdoutOnly:
    return implReject("wget must send its response to stdout with -O-")
  result = implAllow()

## Detects Git options that render file content through the diff machinery.
## These paths require explicit textconv/helper suppression even when a
## contradictory --no-patch/-s flag is also present elsewhere in argv.
func implGitRendersDiff(args: seq[string]): bool =
  for index, arg in args:
    if implIsSafeOptionTerminator(args, index):
      break
    let lower = toLowerAscii(arg)
    let separator = lower.find('=')
    let optionName =
      if separator >= 0: lower[0 ..< separator]
      else: lower
    # --color is a complete display option, not an abbreviation of
    # --color-words. Preserve that common non-diff-rendering form.
    if optionName notin ["--color", "--no-color"] and
        implHasForbiddenOption(@[arg], [
          "--patch", "--patch-with-raw", "--patch-with-stat", "--stat",
          "--numstat", "--shortstat", "--dirstat", "--dirstat-by-file",
          "--word-diff", "--word-diff-regex", "--color-words", "--raw",
          "--binary", "--unified", "--function-context", "--remerge-diff",
          "--diff-merges", "--cc", "--combined"
        ]):
      return true
    if (arg.startsWith("-p") and not arg.startsWith("--")) or
        arg in ["-u", "-W", "-c"] or arg.startsWith("-U"):
      return true

func implValidateGit(tokens: seq[string]): CommandPolicyDecision =
  var index = 1
  while index < tokens.len and tokens[index].startsWith("-"):
    let original = tokens[index]
    let lower = toLowerAscii(tokens[index])
    if lower == "--version" or (lower == "--help" and tokens.len == 2):
      return implAllow()
    if original == "-c" or lower in ["--config-env", "--exec-path"] or
        original.startsWith("-c=") or lower.startsWith("--config-env="):
      return implReject("git configuration can inject executable helpers")
    if original == "-C" or lower in ["--git-dir", "--work-tree", "--namespace"]:
      index += 2
    elif lower.startsWith("--git-dir=") or lower.startsWith("--work-tree=") or
        lower in ["--no-pager", "--literal-pathspecs"]:
      index += 1
    else:
      return implReject("unrecognised git global option")
  if index >= tokens.len:
    return implReject("git query is missing a subcommand")
  let subcommand = toLowerAscii(tokens[index])
  let args = if index + 1 < tokens.len: tokens[index + 1 .. ^1] else: @[]
  if subcommand == "blame":
    # Without an explicit revision blame reads the working tree and applies
    # clean filters, even when external diff/textconv is disabled.
    let separator = args.find("--")
    if separator < 1 or separator + 2 != args.len or
        args[separator - 1].startsWith("-") or
        not implHasOption(args, ["--no-textconv"]):
      return implReject(
        "git blame requires --no-textconv REV -- FILE; worktree blame can run filters")
    if implHasForbiddenOption(args, ["--contents", "--reverse"]):
      return implReject("git blame worktree/contents mode can run filters")
    # A revision after a value-taking option may actually be its value.
    if separator >= 2 and args[separator - 2].startsWith("-") and
        args[separator - 2] notin [
          "--no-textconv", "-p", "--porcelain", "--line-porcelain",
          "--incremental", "-l", "-t", "-s", "-e", "--show-email", "-w"]:
      return implReject("git blame requires an unambiguous explicit revision")
  if implHasForbiddenOption(args, [
    "--output", "--ext-diff", "--textconv", "--filters",
    "--open-files-in-pager"
  ]):
    return implReject("git query option can write or execute a helper")
  if subcommand == "grep":
    for arg in args:
      if arg == "--":
        break
      if arg.startsWith("-O") and not arg.startsWith("--"):
        return implReject("git grep pager option can execute an external helper")
  if implHasForbiddenOption(args, ["--show-signature"]):
    return implReject("git signature display can execute a configured verifier")
  for argIndex, arg in args:
    if implIsSafeOptionTerminator(args, argIndex):
      break
    let lower = toLowerAscii(arg)
    # The format can be attached or supplied as the following token. Reject
    # verifier-triggering atoms anywhere in argv so the separated form cannot
    # escape validation.
    if arg.contains("%G") or lower.contains("%(signature"):
      return implReject("git signature formatting can execute a configured verifier")
  let logRendersDiff = implGitRendersDiff(args)
  if subcommand in ["log", "reflog"] and logRendersDiff and
      (not implHasOption(args, ["--no-ext-diff"]) or
        not implHasOption(args, ["--no-textconv"])):
    return implReject(
      "git patch output requires --no-ext-diff and --no-textconv")
  if subcommand == "show":
    let noPatch = implHasOption(args, ["--no-patch"]) or "-s" in args
    if (not noPatch or implGitRendersDiff(args)) and (
        not implHasOption(args, ["--no-ext-diff"]) or
        not implHasOption(args, ["--no-textconv"])):
      return implReject("git show requires --no-ext-diff and --no-textconv")
  if subcommand in [
    "log", "show", "grep", "blame", "rev-parse", "ls-files",
    "ls-tree", "cat-file", "describe", "name-rev", "shortlog", "show-ref",
    "for-each-ref", "count-objects", "version"
  ]:
    if implHasForbiddenOption(args, [
      "--output", "--ext-diff", "--textconv", "--filters",
      "--open-files-in-pager"
    ]):
      return implReject("git query option can write or execute a helper")
    if subcommand == "describe" and
        implHasForbiddenOption(args, ["--dirty", "--broken"]):
      return implReject("git describe worktree checks can invoke clean filters")
    if subcommand == "ls-files" and
        implHasForbiddenOption(args, ["--eol"]):
      return implReject("git ls-files --eol can inspect worktree attributes")
    return implAllow()
  if subcommand == "help":
    if args.len == 1 and toLowerAscii(args[0]) in [
      "-a", "--all", "-g", "--guides", "-c", "--config"
    ]:
      return implAllow()
    return implReject("git help viewers can execute external programs")
  if subcommand == "diff":
    if implHasForbiddenOption(args, ["--output", "--ext-diff", "--textconv"]):
      return implReject("git diff helper or output option is not permitted")
    if not implHasOption(args, ["--no-ext-diff"]) or
        not implHasOption(args, ["--no-textconv"]):
      return implReject("git diff requires --no-ext-diff and --no-textconv")
    if not implHasOption(args, ["--cached", "--staged", "--no-index"]):
      return implReject(
        "git worktree diff can invoke clean filters; use --cached or --no-index")
    return implAllow()
  if subcommand == "diff-files":
    if implHasForbiddenOption(args, [
      "--output", "--ext-diff", "--textconv", "--patch", "--stat",
      "--patch-with-raw", "--patch-with-stat", "--binary", "--unified",
      "--function-context", "--numstat", "--shortstat", "--dirstat",
      "--word-diff"
    ]):
      return implReject("git diff-files content rendering is not permitted")
    for arg in args:
      if (arg.startsWith("-p") or arg.startsWith("-U") or arg == "-u" or
          arg == "-W") and not arg.startsWith("--"):
        return implReject("git diff-files patch rendering is not permitted")
    if not implHasOption(args, ["--no-ext-diff"]) or
        not implHasOption(args, ["--no-textconv"]):
      return implReject(
        "git diff-files requires --no-ext-diff and --no-textconv")
    if not implHasOption(args, ["--name-only", "--name-status", "--raw"]):
      return implReject("git diff-files is limited to metadata-only output")
    return implAllow()
  if subcommand == "branch":
    var index = 0
    var listing = args.len == 0
    while index < args.len:
      let arg = args[index]
      let lower = toLowerAscii(arg)
      if lower in [
        "-l", "--list", "-a", "--all", "-r", "--remotes", "-v", "-vv",
        "--verbose", "--color", "--no-color", "--column", "--no-column",
        "--no-abbrev", "--show-current", "-i", "--ignore-case"
      ]:
        listing = true
        index += 1
        continue
      if lower in [
        "--contains", "--no-contains", "--points-at", "--sort", "--format"
      ]:
        if index + 1 >= args.len:
          return implReject("git branch query option is missing its value")
        listing = true
        index += 2
        continue
      if lower in ["--merged", "--no-merged"]:
        listing = true
        index += 1
        if index < args.len and not args[index].startsWith("-"):
          index += 1
        continue
      if lower.startsWith("--contains=") or
          lower.startsWith("--no-contains=") or
          lower.startsWith("--points-at=") or lower.startsWith("--sort=") or
          lower.startsWith("--format=") or lower.startsWith("--merged=") or
          lower.startsWith("--no-merged=") or lower.startsWith("--color=") or
          lower.startsWith("--column=") or lower.startsWith("--abbrev="):
        listing = true
        index += 1
        continue
      if not arg.startsWith("-") and listing and
          implHasOption(args, ["-l", "--list"]):
        index += 1
        continue
      return implReject("git branch action is not a pure listing")
    return implAllow()
  if subcommand == "tag":
    if implHasForbiddenOption(args, [
      "--annotate", "--sign", "--local-user", "--force", "--delete",
      "--verify", "--create-reflog", "--cleanup", "--file", "--edit",
      "--trailer"
    ]) or implHasToken(args, ["-a", "-s", "-u", "-f", "-d", "-v"]):
      return implReject("git tag action can create, delete, or verify a tag")
    var explicitList = false
    var operands = 0
    var index = 0
    while index < args.len:
      let arg = args[index]
      let lower = toLowerAscii(arg)
      if lower in ["-l", "--list"]:
        explicitList = true
        index += 1
        continue
      if lower == "--":
        operands += args.len - index - 1
        break
      if lower in [
        "--contains", "--no-contains", "--merged", "--no-merged",
        "--points-at"
      ]:
        explicitList = true
        if index + 1 >= args.len:
          return implReject("git tag query option is missing its value")
        index += 2
        continue
      if lower in ["--sort", "--format"]:
        if index + 1 >= args.len:
          return implReject("git tag query option is missing its value")
        index += 2
        continue
      if lower in [
        "--ignore-case", "--omit-empty", "--no-column", "--color",
        "--column", "-i"
      ]:
        index += 1
        continue
      if arg.startsWith("-n") and not arg.startsWith("--") and
          (arg.len == 2 or implUnsignedAtMost(arg[2 .. ^1], 1_000_000)):
        explicitList = true
        index += 1
        continue
      if lower.startsWith("--contains=") or
          lower.startsWith("--no-contains=") or
          lower.startsWith("--merged=") or
          lower.startsWith("--no-merged=") or
          lower.startsWith("--points-at="):
        explicitList = true
        index += 1
        continue
      if lower.startsWith("--sort=") or lower.startsWith("--format=") or
          lower.startsWith("--color=") or lower.startsWith("--column="):
        index += 1
        continue
      if arg.startsWith("-"):
        return implReject("git tag option is outside pure listing mode")
      operands += 1
      index += 1
    if operands > 0 and not explicitList:
      return implReject("git tag operands require explicit --list")
    return implAllow()
  if subcommand == "config":
    if implHasForbiddenOption(args, [
      "--add", "--replace-all", "--unset", "--unset-all",
      "--rename-section", "--remove-section", "--edit"
    ]) or "-e" in args:
      return implReject("git config mutation is not permitted")
    if implHasOption(args, [
      "--get", "--get-all", "--get-regexp", "--get-urlmatch", "--list", "-l",
      "--show-origin", "--show-scope", "--name-only"
    ]):
      return implAllow()
    return implReject("git config is allowed only in explicit query mode")
  if subcommand == "remote":
    if args.len == 0:
      return implAllow()
    var remoteIndex = 0
    if toLowerAscii(args[remoteIndex]) in ["-v", "--verbose"]:
      remoteIndex += 1
      if remoteIndex >= args.len:
        return implAllow()
    if toLowerAscii(args[remoteIndex]) == "get-url":
      remoteIndex += 1
      var operands = 0
      while remoteIndex < args.len:
        let value = toLowerAscii(args[remoteIndex])
        if value in ["--push", "--all"]:
          remoteIndex += 1
          continue
        if args[remoteIndex].startsWith("-"):
          return implReject("git remote get-url option is not read-only")
        operands += 1
        remoteIndex += 1
      if operands == 1:
        return implAllow()
    return implReject("git remote action is not read-only")
  if subcommand == "worktree" and args.len > 0 and
      toLowerAscii(args[0]) == "list":
    return implAllow()
  if subcommand == "reflog" and
      (args.len == 0 or toLowerAscii(args[0]) == "show"):
    return implAllow()
  if subcommand == "submodule" and args.len > 0 and
      toLowerAscii(args[0]) == "status":
    return implAllow()
  result = implReject("git subcommand is not in the read-only allowlist")

func implValidateContainer(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  if tokens.len < 2:
    return implReject(name & " query is missing a subcommand")
  let action = toLowerAscii(tokens[1])
  var effectiveAction = action
  if action in ["container", "image", "network", "volume"] and tokens.len > 2:
    effectiveAction = toLowerAscii(tokens[2])
  if effectiveAction == "logs":
    for token in tokens:
      if implDockerFollowEnabled(token):
        return implReject(name & " logs follow mode is unbounded")
  if effectiveAction == "stats" and
      not implHasEnabledBooleanOption(tokens, "--no-stream"):
    return implReject(name & " stats requires --no-stream")
  if effectiveAction == "events" and
      not implHasOption(tokens, ["--until"]):
    return implReject(name & " events requires a finite --until bound")
  if action in [
    "ps", "images", "inspect", "logs", "version", "info", "top", "stats",
    "events", "diff", "history"
  ]:
    return implAllow()
  if action in ["container", "image", "network", "volume"] and tokens.len > 2:
    let nested = toLowerAscii(tokens[2])
    if nested in ["ls", "inspect", "logs", "top", "stats", "history"]:
      return implAllow()
  if name == "docker" and action == "compose" and tokens.len > 2 and
      toLowerAscii(tokens[2]) in ["ps", "logs", "config", "images", "top", "ls"]:
    var hasShortOutput = false
    for token in tokens:
      if token.startsWith("-o") and not token.startsWith("--"):
        hasShortOutput = true
    if toLowerAscii(tokens[2]) == "config" and (
        implHasForbiddenOption(tokens, ["--output"]) or hasShortOutput):
      return implReject(name & " compose config output can write a file")
    if toLowerAscii(tokens[2]) == "logs":
      for token in tokens:
        if implDockerFollowEnabled(token):
          return implReject("docker compose logs follow mode is unbounded")
    return implAllow()
  result = implReject(name & " subcommand is not in the read-only allowlist")

func implValidateKubectl(tokens: seq[string]): CommandPolicyDecision =
  if tokens.len < 2:
    return implReject("kubectl query is missing a subcommand")
  if implHasForbiddenOption(tokens, [
    "--kubeconfig", "--cache-dir", "--profile", "--profile-output",
    "--output-directory"
  ]):
    return implReject(
      "kubectl config, cache, profile, or file output is not permitted")
  var index = 1
  while index < tokens.len and tokens[index].startsWith("-"):
    let option = toLowerAscii(tokens[index])
    if option.contains('='):
      index += 1
    elif option in ["--namespace", "-n", "--context", "--cluster", "--user"]:
      index += 2
    else:
      index += 1
  if index >= tokens.len:
    return implReject("kubectl query is missing a subcommand")
  let action = toLowerAscii(tokens[index])
  for token in tokens:
    let lower = toLowerAscii(token)
    if lower in ["-w", "--watch", "--watch-only"] or
        ((lower.startsWith("--watch=") or
          lower.startsWith("--watch-only=")) and not lower.endsWith("=false")):
      return implReject("kubectl watch mode is unbounded")
    if action == "logs" and (lower in ["-f", "--follow"] or
        (token.startsWith("-f") and not token.startsWith("--")) or
        (lower.startsWith("--follow=") and not lower.endsWith("=false"))):
      return implReject("kubectl logs follow mode is unbounded")
  if action in [
    "get", "describe", "logs", "explain", "api-resources", "api-versions",
    "version", "top"
  ]:
    return implAllow()
  if action == "cluster-info":
    if index + 1 < tokens.len and
        toLowerAscii(tokens[index + 1]) == "dump":
      return implReject("kubectl cluster-info dump can write diagnostic files")
    return implAllow()
  if action == "auth" and index + 1 < tokens.len and
      toLowerAscii(tokens[index + 1]) == "can-i":
    return implAllow()
  if action == "config" and index + 1 < tokens.len and
      toLowerAscii(tokens[index + 1]) in ["view", "current-context", "get-contexts"]:
    return implAllow()
  result = implReject("kubectl subcommand is not in the read-only allowlist")

func implValidatePackageQuery(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  if tokens.len < 2:
    return implReject(name & " query is missing an action")
  case name
  of "apt", "apt-get", "apt-cache":
    if implHasForbiddenOption(tokens, ["--option", "--config-file"]) or
        "-o" in tokens or "-c" in tokens:
      return implReject("APT configuration injection is not permitted")
    for token in tokens:
      if token.startsWith("-o") or token.startsWith("-c"):
        if not token.startsWith("--"):
          return implReject("APT configuration injection is not permitted")
  of "dnf", "yum":
    if implHasForbiddenOption(tokens, [
      "--config", "--setopt", "--enableplugin", "--disableplugin",
      "--installroot"
    ]) or "-c" in tokens:
      return implReject(name & " plugin or config injection is not permitted")
    for token in tokens:
      if token.startsWith("-c") and not token.startsWith("--"):
        return implReject(name & " plugin or config injection is not permitted")
  of "zypper":
    if implHasForbiddenOption(tokens, [
      "--config", "--reposd-dir", "--cache-dir", "--root"
    ]):
      return implReject("zypper config injection is not permitted")
  of "pacman":
    if implHasForbiddenOption(tokens, [
      "--config", "--root", "--dbpath", "--hookdir", "--logfile",
      "--cachedir", "--gpgdir", "--sysroot"
    ]):
      return implReject("pacman config or output redirection is not permitted")
  of "pip", "pip3":
    if implHasForbiddenOption(tokens, [
      "--python", "--config-settings", "--log", "--cache-dir"
    ]):
      return implReject("pip interpreter, config, or output path is not permitted")
  of "npm":
    if implHasForbiddenOption(tokens, [
      "--userconfig", "--globalconfig", "--cache", "--logs-dir",
      "--script-shell", "--ignore-scripts", "--foreground-scripts",
      "--timing"
    ]):
      return implReject("npm config, script, or output injection is not permitted")
  of "cargo":
    if implHasForbiddenOption(tokens, ["--config"]):
      return implReject("cargo config injection is not permitted")
  of "rpm":
    if implHasForbiddenOption(tokens, [
      "--eval", "--pipe", "--setperms", "--setugids", "--restore",
      "--rebuilddb", "--initdb", "--import", "--install", "--upgrade",
      "--freshen", "--erase", "--verify", "--define", "--predefine", "--undefine",
      "--macros", "--rcfile", "--load", "--specfile"
    ]) or implHasToken(tokens, ["-i", "-U", "-F", "-e"]) or
        (tokens.len > 1 and tokens[1].startsWith("-V")):
      return implReject(
        "rpm action can execute package scripts, macros, or modify packages")
    for token in tokens:
      if token.startsWith("-") and not token.startsWith("--") and
          (token.contains('E') or token.contains('D')):
        return implReject("rpm macro evaluation/definition can execute code")
  else:
    discard
  let action = toLowerAscii(tokens[1])
  case name
  of "apt", "apt-get":
    if action in ["list", "show", "search", "policy", "--version"]:
      return implAllow()
  of "apt-cache":
    if action in ["show", "search", "policy", "depends", "rdepends", "pkgnames", "stats"]:
      return implAllow()
  of "dnf", "yum":
    if action in [
      "list", "info", "search", "repolist", "check-update", "repoquery",
      "provides", "--version"
    ]:
      return implAllow()
    if action == "history" and (tokens.len == 2 or
        toLowerAscii(tokens[2]) in ["list", "info", "userinstalled"]):
      return implAllow()
    if action in ["module", "group"] and tokens.len >= 3 and
        toLowerAscii(tokens[2]) in ["list", "info"]:
      return implAllow()
  of "zypper":
    if action in [
      "list-updates", "lu", "patches", "packages", "pa", "repos", "lr",
      "products", "patterns", "search", "se", "info", "if", "--version"
    ]:
      return implAllow()
  of "pacman":
    if action.startsWith("-q") or action in ["-ss", "-si", "--version"]:
      return implAllow()
  of "brew":
    if action in [
      "list", "search", "config", "outdated", "leaves", "deps", "uses",
      "missing", "--version"
    ]:
      return implAllow()
    if action == "services" and tokens.len >= 3 and
        toLowerAscii(tokens[2]) == "list":
      return implAllow()
    if action == "info":
      for index in 2 ..< tokens.len:
        let operand = toLowerAscii(tokens[index])
        if operand.startsWith(".") or operand.startsWith("/") or
            operand.contains("\\") or
            operand.endsWith(".rb"):
          return implReject("brew info cannot evaluate a path-selected formula")
      return implAllow()
  of "winget":
    if action in ["list", "show", "search", "--version"]:
      return implAllow()
    if action == "upgrade" and tokens.len == 2:
      return implAllow()
  of "choco":
    if action in ["list", "search", "info", "outdated", "--version"]:
      return implAllow()
  of "pip", "pip3":
    if action in ["list", "show", "freeze", "check", "debug", "--version"]:
      return implAllow()
  of "npm":
    if action in ["list", "ls", "view", "info", "search", "outdated", "why", "--version"]:
      return implAllow()
  of "pnpm", "yarn":
    if action == "--version":
      return implAllow()
  of "cargo":
    if action in ["search", "--version", "-v"]:
      return implAllow()
  of "nimble":
    if action in ["list", "search", "--version", "-v"]:
      return implAllow()
  of "rpm":
    if action.startsWith("-q") or action in ["--query", "--version"]:
      return implAllow()
  of "dpkg":
    if action in [
      "-l", "--list", "-s", "--status", "-L", "--listfiles", "-S",
      "--search", "--print-architecture", "--print-foreign-architectures",
      "--compare-versions", "--version"
    ]:
      return implAllow()
  of "apk":
    if action in ["info", "search", "list", "policy", "version", "dot"]:
      return implAllow()
  of "snap":
    if action in [
      "list", "info", "find", "services", "connections", "changes", "tasks",
      "warnings", "version"
    ]:
      return implAllow()
  of "flatpak":
    if action in [
      "list", "info", "search", "remote-ls", "remotes", "history",
      "documents", "permission-show", "--version"
    ]:
      return implAllow()
  else:
    discard
  result = implReject(name & " action is not in the read-only allowlist")

func implValidateArchive(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "tar", "bsdtar":
    if implHasForbiddenOption(tokens, [
      "--checkpoint-action", "--to-command", "--use-compress-program",
      "--delete", "--append", "--update", "--concatenate", "--extract",
      "--create", "--index-file", "--listed-incremental", "--info-script",
      "--new-volume-script", "--rsh-command", "--rmt-command", "--volno-file",
      "--files-from", "--remove-files", "--unlink-first",
      "--recursive-unlink", "--multi-volume", "--tape-length"
    ]):
      return implReject("tar option can execute, extract, or write")
    var listing = implHasOption(tokens, ["--list"])
    let forceLocal = implHasOption(tokens, ["--force-local"])

    # GNU tar permits clustered short options whose first value-taking option
    # consumes the remainder (for example -tvfhost:archive.tar or -tvb20).
    # Decode that boundary instead of searching raw letters inside filenames.
    func attachedShortValue(
      token: string,
      target: char
    ): tuple[present: bool, value: string] =
      if token.len < 2 or not token.startsWith("-") or token.startsWith("--"):
        return
      for position in 1 ..< token.len:
        let option = token[position]
        if option in {'b', 'C', 'f', 'F', 'g', 'H', 'I', 'K', 'L', 'N',
            'T', 'V', 'X'}:
          if option == target:
            result.present = true
            if position + 1 < token.len:
              result.value = token[position + 1 .. ^1]
          return

    func shortOptionPrefix(token: string): string =
      if token.len < 2 or not token.startsWith("-") or token.startsWith("--"):
        return
      for position in 1 ..< token.len:
        let option = token[position]
        result.add(option)
        if option in {'b', 'C', 'f', 'F', 'g', 'H', 'I', 'K', 'L', 'N',
            'T', 'V', 'X'}:
          return

    var archiveFromPrevious = false
    for index, token in tokens:
      let lower = toLowerAscii(token)
      let isArchiveValue = archiveFromPrevious
      var archiveCandidate = ""
      if isArchiveValue:
        archiveCandidate = token
        archiveFromPrevious = false
      elif lower == "--file":
        archiveFromPrevious = true
      elif lower.startsWith("--file="):
        archiveCandidate = token["--file=".len .. ^1]
      else:
        let attachedArchive = attachedShortValue(token, 'f')
        if attachedArchive.present:
          if attachedArchive.value.len > 0:
            archiveCandidate = attachedArchive.value
          else:
            archiveFromPrevious = true
      if not forceLocal and archiveCandidate.len > 0:
        let colon = archiveCandidate.find(':')
        let windowsDrive = colon == 1 and archiveCandidate[0].isAlphaAscii
        if colon > 0 and not windowsDrive and
            not archiveCandidate.startsWith("-"):
          return implReject(
            "tar remote archives can execute a transport helper; use --force-local")
      if isArchiveValue:
        continue
      var blockingFactor = ""
      if lower == "--blocking-factor" or token == "-b":
        if index + 1 >= tokens.len:
          return implReject("tar blocking factor is missing its value")
        blockingFactor = tokens[index + 1]
      elif lower.startsWith("--blocking-factor="):
        blockingFactor = token["--blocking-factor=".len .. ^1]
      else:
        let attachedBlocking = attachedShortValue(token, 'b')
        if attachedBlocking.present:
          if attachedBlocking.value.len > 0:
            blockingFactor = attachedBlocking.value
          elif index + 1 >= tokens.len:
            return implReject("tar blocking factor is missing its value")
          else:
            blockingFactor = tokens[index + 1]
      if blockingFactor.len > 0 and
          not implPositiveAtMost(blockingFactor, 2048):
        return implReject("tar blocking factor exceeds the 2048-block bound")
      var recordSize = ""
      if lower == "--record-size":
        if index + 1 >= tokens.len:
          return implReject("tar record size is missing its value")
        recordSize = tokens[index + 1]
      elif lower.startsWith("--record-size="):
        recordSize = token["--record-size=".len .. ^1]
      if recordSize.len > 0 and not implPositiveMultipleAtMost(
          recordSize, 1_048_576, 512):
        return implReject(
          "tar record size must be a 512-byte multiple at most 1 MiB")
      let shortOptions = shortOptionPrefix(token)
      if 't' in shortOptions:
        listing = true
      for flag in ['c', 'x', 'r', 'u', 'A', 'F', 'I', 'T', 'M', 'L', 'g']:
        if flag in shortOptions:
          return implReject("tar operation may write or execute a helper")
    if archiveFromPrevious:
      return implReject("tar archive option is missing its value")
    if listing:
      return implAllow()
  of "unzip", "zipinfo":
    if name == "zipinfo":
      return implAllow()
    if implHasForbiddenOption(tokens, ["--directory"]):
      return implReject("unzip output directory is not permitted")
    var inspectionMode = implHasOption(
      tokens, ["-l", "-v", "-Z", "-t", "-p", "-c"])
    for token in tokens:
      if token.startsWith("-") and not token.startsWith("--"):
        for flag in ['d', 'f', 'o', 'u', 'x', 'T']:
          if token.contains(flag):
            return implReject("unzip option can extract or replace files")
        for flag in ['l', 'v', 'Z', 't', 'p', 'c']:
          if token.contains(flag):
            inspectionMode = true
    if inspectionMode:
      return implAllow()
  of "gzip", "gunzip", "bzip2", "bunzip2", "xz", "unxz":
    if implHasForbiddenOption(tokens, ["--suffix"]):
      return implReject(name & " suffix mode can create an output file")
    var stdoutMode = implHasOption(tokens, ["-c", "--stdout", "--to-stdout"])
    var inspectionMode = implHasOption(tokens, ["-l", "--list", "-t", "--test"])
    var explicitDecompress = false
    for token in tokens:
      if token.startsWith("-") and not token.startsWith("--"):
        if token.contains('S'):
          return implReject(name & " suffix mode can create an output file")
        stdoutMode = stdoutMode or token.contains('c')
        inspectionMode = inspectionMode or token.contains('l') or
          token.contains('t')
        explicitDecompress = explicitDecompress or token.contains('d')
    if name in ["xz", "unxz"]:
      var decompressing = name == "unxz"
      var index = 1
      while index < tokens.len:
        let token = tokens[index]
        if implIsSafeOptionTerminator(tokens, index):
          break
        let lower = toLowerAscii(token)
        if lower == "--decompress" or
            (token.startsWith("-") and not token.startsWith("--") and
              token.contains('d')):
          decompressing = true
        if token == "-T" or lower == "--threads":
          if index + 1 >= tokens.len or
              not implUnsignedAtMost(tokens[index + 1], 4):
            return implReject("xz thread count must be between 0 and 4")
          index += 2
          continue
        if lower.startsWith("--threads="):
          if not implUnsignedAtMost(token["--threads=".len .. ^1], 4):
            return implReject("xz thread count must be between 0 and 4")
          index += 1
          continue
        if token.startsWith("-T") and not token.startsWith("--") and
            token.len > 2:
          var value = token[2 .. ^1]
          if value.startsWith("="):
            value = value[1 .. ^1]
          if not implUnsignedAtMost(value, 4):
            return implReject("xz thread count must be between 0 and 4")
          index += 1
          continue
        if implHasForbiddenOption(@[token], [
            "--block-size", "--block-list", "--flush-timeout",
            "--memlimit-compress", "--memlimit-decompress",
            "--memlimit-mt-decompress", "--memlimit", "--filters",
            "--filters1", "--filters2", "--filters3", "--filters4",
            "--filters5", "--filters6", "--filters7", "--filters8",
            "--filters9", "--lzma1", "--lzma2"
          ]) or token == "-M":
          return implReject("xz memory/filter overrides are not permitted")
        if not decompressing and token.startsWith("-") and
            not token.startsWith("--"):
          for flag in ['7', '8', '9', 'e']:
            if token.contains(flag):
              return implReject(
                "xz high-memory compression presets are not permitted")
        index += 1
    if stdoutMode or (inspectionMode and not explicitDecompress):
      return implAllow()
  of "xzcat":
    if implHasForbiddenOption(tokens, [
        "--threads", "--block-size", "--block-list", "--flush-timeout",
        "--memlimit-compress", "--memlimit-decompress",
        "--memlimit-mt-decompress", "--memlimit", "--filters", "--filters1",
        "--filters2", "--filters3", "--filters4", "--filters5", "--filters6",
        "--filters7", "--filters8", "--filters9", "--lzma1", "--lzma2"
      ]):
      return implReject("xzcat resource overrides are not permitted")
    for token in tokens:
      if token.startsWith("-T") or token.startsWith("-M"):
        return implReject("xzcat resource overrides are not permitted")
    return implAllow()
  of "zcat", "bzcat":
    return implAllow()
  else:
    discard
  result = implReject(name & " operation can create or replace files")

func implValidateVersionTool(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  if name.startsWith("python"):
    if tokens.len == 2 and (
        toLowerAscii(tokens[1]) == "--version" or
        tokens[1] in ["-V", "-VV"]):
      return implAllow()
    return implReject("Python is allowed only for version inspection")
  if tokens.len == 2 and toLowerAscii(tokens[1]) in [
    "--version", "-version", "-v", "-vv", "version"
  ]:
    return implAllow()
  result = implReject(name & " is allowed only for version inspection")

func implValidateToolchainReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  if tokens.len < 2:
    return implReject(name & " query is missing an action")
  let action = toLowerAscii(tokens[1])
  case name
  of "go":
    if action == "version":
      return implAllow()
    if action == "env":
      for token in tokens[2 .. ^1]:
        let lower = toLowerAscii(token)
        if lower in ["-w", "-u"] or lower.startsWith("-w=") or
            lower.startsWith("-u=") or token.contains('='):
          return implReject("go env write/unset mode changes persistent state")
      return implAllow()
  of "dotnet":
    if tokens.len == 2 and action in [
      "--info", "--version", "--list-sdks", "--list-runtimes"
    ]:
      return implAllow()
  of "rustup":
    if action == "show":
      return implAllow()
    if action in ["toolchain", "target", "component"] and tokens.len >= 3 and
        toLowerAscii(tokens[2]) == "list":
      return implAllow()
    if action == "which" and tokens.len == 3:
      return implAllow()
  of "swift":
    if tokens.len == 2 and action in [
      "--version", "-version", "-print-target-info"
    ]:
      return implAllow()
  of "xcodebuild":
    if tokens.len == 2 and action in ["-version", "-showsdks"]:
      return implAllow()
  of "java":
    var hasVersion = false
    for index in 1 ..< tokens.len:
      let option = toLowerAscii(tokens[index])
      if option in ["-version", "--version", "-showversion"]:
        hasVersion = true
      elif not option.startsWith("-xshowsettings"):
        return implReject("java is allowed only for version/settings inspection")
    if hasVersion:
      return implAllow()
  else:
    discard
  result = implReject(name & " action is not in the toolchain query allowlist")

func implValidateNetCommand(tokens: seq[string]): CommandPolicyDecision =
  if tokens.len < 2:
    return implReject("net query is missing a subcommand")
  for token in tokens[2 .. ^1]:
    let lower = toLowerAscii(token)
    if token.contains('='):
      return implReject("net assignment can change Windows state")
    for mutator in [
      "/add", "/delete", "/active", "/expires", "/passwordchg",
      "/passwordreq", "/times", "/workstations", "/comment", "/grant",
      "/revoke", "/cache", "/persistent", "/savecred", "/set"
    ]:
      if lower.len >= 2 and mutator.startsWith(lower):
        return implReject("net option can change Windows state")
  let action = toLowerAscii(tokens[1])
  case action
  of "start", "use", "session":
    if tokens.len == 2:
      return implAllow()
  of "accounts":
    if tokens.len == 2 or (tokens.len == 3 and
        toLowerAscii(tokens[2]) == "/domain"):
      return implAllow()
  of "user", "localgroup", "group":
    if tokens.len == 2:
      return implAllow()
    if tokens.len == 3 and not tokens[2].startsWith("/") and
        tokens[2] != "*":
      return implAllow()
    if tokens.len == 4 and not tokens[2].startsWith("/") and
        toLowerAscii(tokens[3]) == "/domain":
      return implAllow()
  of "share":
    if tokens.len == 2 or (tokens.len == 3 and
        not tokens[2].startsWith("/") and not tokens[2].contains('=')):
      return implAllow()
  of "statistics", "stats":
    if tokens.len == 2 or (tokens.len == 3 and
        toLowerAscii(tokens[2]) in ["workstation", "server"]):
      return implAllow()
  of "config":
    if tokens.len == 3 and
        toLowerAscii(tokens[2]) in ["workstation", "server"]:
      return implAllow()
  of "view":
    if tokens.len <= 3:
      return implAllow()
  of "help", "helpmsg":
    if tokens.len <= 3:
      return implAllow()
  else:
    discard
  result = implReject("net subcommand or operands can change Windows state")

func implValidateWindowsReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "net":
    return implValidateNetCommand(tokens)
  of "set":
    for token in tokens:
      if token.contains('='):
        return implReject("set assignment changes shell state")
    return implAllow()
  of "reg":
    if tokens.len > 1 and toLowerAscii(tokens[1]) == "query":
      return implAllow()
  of "sc":
    if tokens.len > 1 and toLowerAscii(tokens[1]) in [
      "query", "queryex", "qc", "qdescription", "enumdepend",
      "getdisplayname", "getkeyname"
    ]:
      return implAllow()
  of "wevtutil":
    if tokens.len > 1 and toLowerAscii(tokens[1]) in [
      "el", "enum-logs", "gl", "get-loginfo", "gli", "qe", "query-events",
      "gp", "get-publisher"
    ]:
      return implAllow()
  of "certutil":
    if tokens.len > 1 and toLowerAscii(tokens[1]) == "-hashfile":
      return implAllow()
  of "cmdkey":
    if tokens.len == 2 and toLowerAscii(tokens[1]) == "/list":
      return implAllow()
  of "tzutil":
    if tokens.len == 2 and toLowerAscii(tokens[1]) in ["/g", "/l", "/?"]:
      return implAllow()
  of "powercfg":
    if tokens.len < 2:
      return implReject("powercfg query is missing an action")
    let powerAction = toLowerAscii(tokens[1])
    if powerAction in [
      "/list", "/l", "/query", "/q", "/getactivescheme",
      "/availablesleepstates", "/a", "/devicequery", "/requests",
      "/lastwake", "/waketimers", "/aliases", "/?"
    ]:
      return implAllow()
    if powerAction == "/requestsoverride" and tokens.len == 2:
      return implAllow()
  of "schtasks":
    if implHasToken(tokens, [
      "/create", "/delete", "/change", "/run", "/end"
    ]):
      return implReject("schtasks action can change or start a task")
    if implHasToken(tokens, ["/query"]):
      return implAllow()
  of "wmic":
    var hasQueryVerb = false
    for token in tokens:
      let lower = toLowerAscii(token)
      if lower.startsWith("/output") or lower.startsWith("/append") or
          lower.startsWith("/record") or lower.startsWith("/interactive") or
          lower.startsWith("/format") or lower.startsWith("/every") or
          lower.startsWith("/node") or lower.startsWith("/role") or
          lower.startsWith("/trace") or lower.startsWith("/translate"):
        return implReject(
          "wmic output, repeat, remote, or external-format mode is not permitted")
      if lower in ["call", "create", "delete", "set"]:
        return implReject("wmic verb can invoke a method or change state")
      if lower in ["get", "list"]:
        hasQueryVerb = true
    if hasQueryVerb:
      return implAllow()
  of "dism":
    var hasGetAction = false
    var hasCleanupImage = false
    var hasCleanupQuery = false
    for token in tokens:
      let lower = toLowerAscii(token)
      if lower.startsWith("/logpath") or lower.startsWith("/scratchdir"):
        return implReject("DISM output/scratch path can write files")
      if lower.startsWith("/get-") or lower == "/get":
        hasGetAction = true
      if lower == "/cleanup-image":
        hasCleanupImage = true
      if lower in ["/checkhealth", "/scanhealth", "/analyzecomponentstore"]:
        hasCleanupQuery = true
      if lower in [
          "/restorehealth", "/startcomponentcleanup", "/resetbase",
          "/spsuperseded", "/revertpendingactions"
        ]:
        return implReject("DISM maintenance action can change the Windows image")
      if lower.startsWith("/add-") or lower.startsWith("/remove-") or
          lower.startsWith("/enable-") or lower.startsWith("/disable-") or
          lower.startsWith("/set-") or lower.startsWith("/apply-") or
          lower.startsWith("/mount-") or lower.startsWith("/remount-") or
          lower.startsWith("/unmount-") or lower.startsWith("/commit-") or
          lower.startsWith("/capture-") or lower.startsWith("/append-") or
          lower.startsWith("/delete-") or lower.startsWith("/export-") or
          lower.startsWith("/split-") or lower.startsWith("/optimize-") or
          lower.startsWith("/gen-") or
          (lower.startsWith("/cleanup-") and lower != "/cleanup-image") or
          lower.startsWith("/restore") or lower.startsWith("/revert"):
        return implReject("DISM action can change the Windows image")
    if hasGetAction:
      return implAllow()
    if hasCleanupImage and hasCleanupQuery:
      return implAllow()
  of "fsutil":
    if tokens.len >= 2 and toLowerAscii(tokens[1]) == "fsinfo":
      return implAllow()
  of "query":
    if tokens.len >= 2 and toLowerAscii(tokens[1]) in [
      "user", "session", "process", "termserver"
    ]:
      return implAllow()
  of "bcdedit":
    if tokens.len >= 2 and toLowerAscii(tokens[1]) == "/enum":
      for index in 2 ..< tokens.len:
        let value = toLowerAscii(tokens[index])
        if value.startsWith("/") and value != "/v":
          return implReject("bcdedit option is outside enumeration mode")
      return implAllow()
  of "manage-bde":
    if tokens.len >= 2 and toLowerAscii(tokens[1]) == "-status":
      for index in 2 ..< tokens.len:
        if tokens[index].startsWith("-"):
          return implReject("manage-bde status accepts only volume operands")
      return implAllow()
    if tokens.len >= 4 and toLowerAscii(tokens[1]) == "-protectors" and
        toLowerAscii(tokens[2]) == "-get":
      for index in 3 ..< tokens.len:
        if tokens[index].startsWith("-"):
          return implReject(
            "manage-bde protector query accepts only volume operands")
      return implAllow()
  of "fltmc":
    if tokens.len == 2 and toLowerAscii(tokens[1]) in [
      "filters", "instances", "volumes"
    ]:
      return implAllow()
  of "wsl":
    if tokens.len >= 2:
      for index in 1 ..< tokens.len:
        if toLowerAscii(tokens[index]) notin [
          "-l", "--list", "-v", "--verbose", "-o", "--online",
          "--running", "--status", "--version", "--help"
        ]:
          return implReject("wsl is allowed only for list/status queries")
      return implAllow()
  else:
    discard
  result = implReject(name & " action is not an approved Windows query")

func implValidateWebCmdlet(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenPowerShellParameter(tokens, [
    "-body", "-infile", "-outfile", "-form", "-websession",
    "-sessionvariable", "-statuscodevariable", "-responseheadersvariable",
    "-credential", "-token"
  ]):
    return implReject(
      "PowerShell web option can write, assign variables, or mutate remotely")
  var index = 1
  while index < tokens.len:
    let token = tokens[index]
    let lower = toLowerAscii(token)
    let separator = lower.find(':')
    let parameter = if separator >= 0: lower[0 ..< separator] else: lower
    if parameter == "-method":
      var requestMethod = ""
      if separator >= 0:
        requestMethod = lower[separator + 1 .. ^1]
      elif index + 1 < tokens.len:
        index += 1
        requestMethod = toLowerAscii(tokens[index])
      if requestMethod notin ["get", "head"]:
        return implReject("PowerShell web request method is not read-only")
    elif parameter.len >= 2 and "-method".startsWith(parameter):
      return implReject(
        "abbreviated PowerShell web method is ambiguous; spell -Method")
    index += 1
  result = implAllow()

## Allows only Where-Object's comparison form. Its positional FilterScript
## parameter converts strings to executable ScriptBlocks, so accepting an
## arbitrary quoted argument would bypass shell metacharacter rejection.
func implValidateWhereObject(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenPowerShellParameter(tokens, ["-filterscript"]):
    return implReject("Where-Object script blocks are not permitted")
  var hasComparison = false
  for token in tokens:
    let lower = toLowerAscii(token)
    if token.contains('{') or token.contains('}') or token.contains("$_"):
      return implReject("Where-Object script blocks are not permitted")
    if lower in [
      "-eq", "-ceq", "-ne", "-cne", "-gt", "-cgt", "-ge", "-cge",
      "-lt", "-clt", "-le", "-cle", "-like", "-clike", "-notlike",
      "-cnotlike", "-match", "-cmatch", "-notmatch", "-cnotmatch",
      "-contains", "-ccontains", "-notcontains", "-cnotcontains", "-in",
      "-cin", "-notin", "-cnotin", "-is", "-isnot"
    ]:
      hasComparison = true
  if not hasComparison:
    return implReject("Where-Object requires the non-script comparison form")
  result = implAllow()

func implValidateSortObject(tokens: seq[string]): CommandPolicyDecision =
  # PowerShell's bare `sort` alias resolves to Sort-Object, not sort.exe.
  # In particular, `sort -o file` is parsed as an ambiguous common parameter
  # rather than GNU sort's output option. Reject output/pipeline-variable
  # parameters (including their built-in aliases and prefixes) so the policy
  # decision remains fail-closed and deterministic across PowerShell versions.
  if implHasForbiddenPowerShellParameter(tokens, [
    "-outvariable", "-ov", "-pipelinevariable", "-pv"
  ]):
    return implReject(
      "PowerShell Sort-Object variable-output parameters are not permitted")
  for token in tokens:
    if token.contains('{') or token.contains('}') or token.contains("$_"):
      return implReject("Sort-Object script-block properties are not permitted")
  result = implAllow()

func implValidateGetHelp(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenPowerShellParameter(tokens, ["-online", "-showwindow"]):
    return implReject("Get-Help viewer options can launch an external program")
  result = implAllow()

func implValidatePowerShellFiniteReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "get-content", "gc":
    if implHasForbiddenPowerShellParameter(tokens, ["-wait"]):
      return implReject("Get-Content -Wait is unbounded")
    if implHasForbiddenPowerShellParameter(tokens, ["-raw", "-delimiter"]):
      return implReject(
        "Get-Content whole-file/chunk buffering is not memory bounded")
    var index = 1
    while index < tokens.len:
      let lower = toLowerAscii(tokens[index])
      let separator = lower.find(':')
      let parameter = if separator >= 0: lower[0 ..< separator] else: lower
      if parameter.len >= 2 and "-readcount".startsWith(parameter):
        if parameter != "-readcount":
          return implReject("spell bounded Get-Content parameters in full")
        var value = ""
        if separator >= 0:
          value = tokens[index][separator + 1 .. ^1]
        elif index + 1 < tokens.len:
          index += 1
          value = tokens[index]
        if not implPositiveAtMost(value, 4096):
          return implReject("Get-Content ReadCount exceeds the safe bound")
      index += 1
  of "get-counter":
    if implHasForbiddenPowerShellParameter(tokens, ["-continuous"]):
      return implReject("Get-Counter -Continuous is unbounded")
    var index = 1
    while index < tokens.len:
      let lower = toLowerAscii(tokens[index])
      let separator = lower.find(':')
      let parameter = if separator >= 0: lower[0 ..< separator] else: lower
      var boundedName = ""
      var maximum = 0
      if parameter.len >= 2 and "-maxsamples".startsWith(parameter):
        boundedName = "-maxsamples"
        maximum = 5
      elif parameter.len >= 2 and "-sampleinterval".startsWith(parameter):
        boundedName = "-sampleinterval"
        maximum = 10
      if boundedName.len > 0:
        if parameter != boundedName:
          return implReject("spell bounded Get-Counter parameters in full")
        var value = ""
        if separator >= 0:
          value = tokens[index][separator + 1 .. ^1]
        elif index + 1 < tokens.len:
          index += 1
          value = tokens[index]
        if not implPositiveAtMost(value, maximum):
          return implReject(
            "Get-Counter " & boundedName[1 .. ^1] &
            " exceeds the safe bound")
      index += 1
  of "test-connection":
    if implHasForbiddenPowerShellParameter(tokens, ["-repeat", "-asjob"]):
      return implReject("Test-Connection repeat/background mode is not permitted")
    var index = 1
    while index < tokens.len:
      let lower = toLowerAscii(tokens[index])
      let separator = lower.find(':')
      let parameter = if separator >= 0: lower[0 ..< separator] else: lower
      var boundedName = ""
      var maximum = 0
      for item in [
        ("-count", 20), ("-delay", 10), ("-buffersize", 4096),
        ("-throttlelimit", 16)
      ]:
        if parameter.len >= 2 and item[0].startsWith(parameter):
          boundedName = item[0]
          maximum = item[1]
          break
      if boundedName.len > 0:
        if parameter != boundedName:
          return implReject(
            "spell bounded Test-Connection parameters in full")
        var value = ""
        if separator >= 0:
          value = tokens[index][separator + 1 .. ^1]
        elif index + 1 < tokens.len:
          index += 1
          value = tokens[index]
        if not implPositiveAtMost(value, maximum):
          return implReject(
            "Test-Connection " & boundedName[1 .. ^1] &
            " exceeds the safe bound")
        index += 1
        continue
      index += 1
  else:
    discard
  result = implAllow()

func implValidatePrintf(tokens: seq[string]): CommandPolicyDecision =
  if tokens.len > 1:
    let option = tokens[1]
    if option == "-v" or (option.startsWith("-v") and
        not option.startsWith("--")):
      return implReject("printf variable assignment can evaluate shell syntax")
  result = implAllow()

func implValidateStage(
  tokens: seq[string],
  shell: string
): CommandPolicyDecision =
  if tokens.len == 0:
    return implReject("pipeline contains an empty stage")
  let name = implExecutableName(tokens[0])
  if name.len == 0:
    return implReject("relative or untrusted executable path is not permitted")

  let lowerShell = toLowerAscii(shell)
  if name == "sc" and
      (lowerShell.contains("powershell") or lowerShell.contains("pwsh")) and
      not toLowerAscii(tokens[0]).endsWith("sc.exe"):
    return implReject("bare sc is PowerShell's write-capable Set-Content alias")

  let isPowerShell = lowerShell.contains("powershell") or
    lowerShell.contains("pwsh")
  if isPowerShell and implHasForbiddenPowerShellParameter(tokens, [
      "-outvariable", "-ov", "-pipelinevariable", "-pv",
      "-errorvariable", "-ev", "-warningvariable", "-wv",
      "-informationvariable", "-iv", "-outbuffer", "-ob"
    ]):
    return implReject(
      "PowerShell variable-output and custom buffering parameters are not " &
      "permitted across validated command stages")
  if name == "where-object":
    return implValidateWhereObject(tokens)
  if name == "sort-object":
    return implValidateSortObject(tokens)
  if name == "get-help":
    return implValidateGetHelp(tokens)
  if name == "printf":
    return implValidatePrintf(tokens)
  if name == "sleep":
    return implValidateSleep(tokens)
  if name == "seq":
    return implValidateSeq(tokens)
  if name in ["traceroute", "tracert", "tracepath"]:
    return implValidateTracer(name, tokens)
  if name == "nslookup":
    return implValidateNslookup(tokens)
  if name in [
      "tail", "lsof", "findmnt", "netstat", "vm_stat", "vmstat",
      "iostat", "mpstat", "free"
    ]:
    return implValidateFiniteReader(name, tokens)
  if name in ["get-content", "gc", "get-counter", "test-connection"]:
    let finiteDecision = implValidatePowerShellFiniteReader(name, tokens)
    if not finiteDecision.allowed:
      return finiteDecision
  if isPowerShell:
    if name in ["cat", "type"]:
      let finiteDecision = implValidatePowerShellFiniteReader(
        "get-content", tokens)
      if not finiteDecision.allowed:
        return finiteDecision
    # Windows PowerShell 5.1 resolves these bare names to
    # Invoke-WebRequest aliases before considering curl.exe/wget.exe.
    if lowerShell.contains("powershell") and not lowerShell.contains("pwsh") and
        name in ["curl", "wget"] and
        not toLowerAscii(tokens[0]).endsWith(".exe"):
      return implValidateWebCmdlet(tokens)
    if name == "where" and
        not toLowerAscii(tokens[0]).endsWith("where.exe"):
      return implValidateWhereObject(tokens)
    if name == "sort" and
        not toLowerAscii(tokens[0]).endsWith("sort.exe"):
      return implValidateSortObject(tokens)
    if name == "set":
      return implReject("bare set is PowerShell's write-capable Set-Variable alias")
  elif name == "set" and not lowerShell.contains("cmd"):
    return implReject("set is allowed only as a cmd.exe environment query")

  if name in SIMPLE_READ_ONLY_COMMANDS or name in POWERSHELL_READ_ONLY_COMMANDS:
    return implAllow()
  case name
  of "find": return implValidateFind(tokens)
  of "fd", "fdfind": return implValidateFd(tokens)
  of "rg": return implValidateRg(tokens)
  of "sort": return implValidateSort(tokens, shell)
  of "diff", "diff3": return implValidateDiff(tokens)
  of "base64": return implValidateBase64(tokens)
  of "tree": return implValidateTree(tokens)
  of "uniq": return implValidateUniq(tokens)
  of "xxd": return implValidateXxd(tokens)
  of "file": return implValidateFile(tokens)
  of "pgrep": return implValidatePgrep(tokens)
  of "sar", "pidstat": return implValidateSampledReader(name, tokens)
  of "ping": return implValidatePing(tokens, shell)
  of "top": return implValidateTop(tokens)
  of "awk": return implValidateAwk(tokens)
  of "sed": return implValidateSed(tokens)
  of "sensors": return implValidateSensors(tokens)
  of "yq":
    if implHasForbiddenOption(tokens, [
      "-i", "--inplace", "--in-place", "--split-exp", "--split-exp-file"
    ]):
      return implReject("yq in-place mode can modify files")
    for token in tokens:
      if token.startsWith("-") and not token.startsWith("--") and
          (token.contains('i') or token.contains('s')):
        return implReject("yq in-place/split mode can modify files")
    return implAllow()
  of "date": return implValidateDate(tokens)
  of "hostname": return implValidateHostname(tokens)
  of "dmesg": return implValidateDmesg(tokens)
  of "ss", "arp", "route", "ip", "ipconfig", "nmcli", "netsh":
    return implValidateNetworkReader(name, tokens)
  of "ifconfig", "resolvectl", "networkctl", "rfkill":
    return implValidateLocalNetworkReader(name, tokens)
  of "systemctl", "journalctl", "timedatectl", "loginctl", "sysctl",
      "hostnamectl", "localectl", "service", "systemd-analyze":
    return implValidateSystemReader(name, tokens)
  of "mount", "blkid", "dmidecode", "udevadm":
    return implValidateStorageReader(name, tokens)
  of "numactl", "auditctl", "swapon", "losetup":
    return implValidateHostDiagnostic(name, tokens)
  of "tmux": return implValidateTmux(tokens)
  of "crontab": return implValidateCrontab(tokens)
  of "atq": return implValidateAtq(tokens)
  of "mokutil": return implValidateMokutil(tokens)
  of "launchctl", "scutil", "diskutil", "defaults", "mdutil", "log",
      "pmset", "networksetup", "csrutil", "spctl", "fdesetup",
      "systemextensionsctl", "nvram", "profiles", "tmutil":
    return implValidateMacReader(name, tokens)
  of "xattr", "mdfind", "pkgutil", "plutil", "xcode-select":
    return implValidateMacMetadataReader(name, tokens)
  of "nvidia-smi": return implValidateNvidiaSmi(tokens)
  of "rocm-smi": return implValidateRocmSmi(tokens)
  of "smartctl", "lshw", "upower", "ethtool":
    return implValidateHardwareReader(name, tokens)
  of "ufw", "firewall-cmd", "nft", "iptables", "ip6tables":
    return implValidateFirewallReader(name, tokens)
  of "curl": return implValidateCurl(tokens, shell)
  of "wget": return implValidateWget(tokens)
  of "git": return implValidateGit(tokens)
  of "docker", "podman": return implValidateContainer(name, tokens)
  of "kubectl": return implValidateKubectl(tokens)
  of "apt", "apt-get", "apt-cache", "dnf", "yum", "zypper", "pacman",
      "brew", "winget", "choco", "pip", "pip3", "npm", "pnpm", "yarn",
      "cargo", "nimble", "rpm", "dpkg", "apk", "snap", "flatpak":
    return implValidatePackageQuery(name, tokens)
  of "tar", "bsdtar", "unzip", "zipinfo", "gzip", "gunzip", "bzip2",
      "bunzip2", "xz", "unxz", "zcat", "bzcat", "xzcat":
    return implValidateArchive(name, tokens)
  of "reg", "sc", "wevtutil", "certutil", "cmdkey", "set", "tzutil",
      "powercfg", "schtasks", "wmic", "dism", "fsutil", "net", "query",
      "bcdedit", "manage-bde", "fltmc", "wsl":
    return implValidateWindowsReader(name, tokens)
  of "invoke-webrequest", "invoke-restmethod", "iwr", "irm":
    return implValidateWebCmdlet(tokens)
  of "go", "dotnet", "rustup", "swift", "xcodebuild", "java":
    return implValidateToolchainReader(name, tokens)
  else:
    if name in VERSION_ONLY_COMMANDS or name.startsWith("python"):
      return implValidateVersionTool(name, tokens)
  result = implReject("executable '" & name & "' is not in the read-only allowlist")

## Applies the non-configurable read-only baseline. Only simple allowlisted
## inspection commands and pipelines are accepted. The user regex is an
## additional layer and cannot disable this check.
func checkReadOnlyCommand*(
  command: string,
  shell: string = ""
): CommandPolicyDecision =
  let normalized = command.strip()
  if normalized.len == 0:
    return implReject("command is empty")
  if normalized.len > 32_768:
    return implReject("command exceeds the policy size limit")
  let parsed = implParseCommand(normalized, shell)
  if not parsed.valid:
    return implReject(parsed.reason)
  let lowerShell = toLowerAscii(shell)
  let shellExpandsGlobs = not (
    lowerShell.contains("cmd") or lowerShell.contains("powershell") or
    lowerShell.contains("pwsh"))
  if (lowerShell.contains("powershell") or lowerShell.contains("pwsh")) and
      parsed.unsafePowerShellSplat:
    return implReject(
      "unquoted PowerShell splatting can inject parameters after validation")
  for stageIndex, stage in parsed.stages:
    if stage.len == 0:
      return implReject("pipeline contains an empty stage")
    if lowerShell.contains("cmd") and
        implHasCmdExpansion(stage.join(" ")):
      return implReject("cmd.exe percent expansion is not permitted")
    if parsed.variableExpansionStages[stageIndex] and
        not implAllowsApprovedVariables(implExecutableName(stage[0])):
      if parsed.unstableVariableExpansionStages[stageIndex] or
          not implAllowsStablePathVariables(implExecutableName(stage[0])):
        return implReject(
          "shell expansions require a side-effect-free reader or one " &
          "quoted absolute path variable")
    if parsed.inputRedirectionStages[stageIndex] and
        implExecutableName(stage[0]) notin STDIN_DATA_READERS:
      return implReject(
        "input redirection is limited to validated data readers")
    if shellExpandsGlobs and parsed.unsafeUnquotedGlobStages[stageIndex] and
        not implAllowsUnquotedGlobs(implExecutableName(stage[0])):
      return implReject(
        "unqualified shell glob can inject an option into this dual-use reader; " &
        "prefix it with ./ or place -- before it")
    let decision = implValidateStage(stage, shell)
    if not decision.allowed:
      return decision
  result = implAllow()

## Reports whether an already-safe macOS command contains a platform reader
## that Seatbelt cannot run faithfully. Apple ships ``ps`` setuid and ``top`` /
## ``traceroute`` setgid, which sandbox-exec rejects at exec time even under an
## allow-default profile. ``launchctl list`` succeeds but returns an empty
## service table inside that profile. The complete command must still pass the
## mandatory policy before this narrow compatibility classification applies.
func macosRequiresUnsandboxedReader*(
  command: string,
  shell: string = ""
): bool =
  if not checkReadOnlyCommand(command, shell).allowed:
    return false
  let parsed = implParseCommand(command.strip(), shell)
  if not parsed.valid:
    return false
  for stage in parsed.stages:
    if stage.len == 0:
      continue
    let executable = implExecutableName(stage[0])
    if executable in ["ps", "top", "traceroute"]:
      return true
    if executable == "launchctl" and stage.len >= 2 and
        toLowerAscii(stage[1]) == "list":
      return true
  result = false
