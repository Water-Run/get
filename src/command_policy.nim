## Mandatory read-only command policy for get v3.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: command_policy.nim
## :License: AGPL-3.0
##
## The policy is allowlist-based. It first decodes a deliberately small shell
## grammar (simple commands plus pipelines), then validates every executable
## and the state-changing options of otherwise read-only tools. Unknown syntax
## and unknown executables fail closed. This avoids blacklist obfuscation
## bypasses and false positives from dangerous words used only as search text.

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
    inputRedirectionStages: seq[bool]
    unsafeUnquotedGlob: bool
    unsafePowerShellSplat: bool

const SIMPLE_READ_ONLY_COMMANDS = [
  "pwd", "ls", "dir", "cat", "type", "head", "tail", "wc", "cut",
  "tr", "grep", "egrep", "fgrep", "jq", "column", "basename",
  "dirname", "readlink", "realpath", "stat", "du", "df",
  "free", "uname", "whoami", "id", "uptime", "printenv", "locale",
  "host", "dig", "nslookup", "traceroute", "tracert",
  "tracepath", "netstat", "lsof", "ps", "pstree", "vmstat",
  "iostat", "mpstat", "lsblk", "lscpu", "lspci", "lsusb",
  "findmnt", "md5sum", "sha1sum", "sha224sum", "sha256sum",
  "sha384sum", "sha512sum", "b2sum", "cksum", "strings",
  "od", "hexdump", "cmp", "comm", "nl", "fold", "fmt", "expand",
  "unexpand", "paste", "join", "seq", "printf", "echo", "true",
  "false", "sleep", "yes", "tty", "groups", "users", "who", "w", "last", "lastlog",
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
  "cargo", "go", "dotnet", "cmake", "make", "ninja", "openssl"
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
  "sort", "uniq", "base64", "xxd", "cmp", "comm", "diff", "diff3"
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

func implOptionMatches(token: string, option: string): bool =
  let lower = toLowerAscii(token)
  result = lower == toLowerAscii(option) or
    lower.startsWith(toLowerAscii(option) & "=")

func implHasOption(tokens: seq[string], options: openArray[string]): bool =
  for token in tokens:
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
  for token in tokens:
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
  for variable in ["$HOME", "$USER", "$LOGNAME", "$PWD"]:
    let after = index + variable.len
    if after <= command.len and command[index ..< after] == variable and
        (after == command.len or
          command[after] notin {'a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'}):
      return variable.len

## Variable expansion remains restricted to commands whose complete option
## surface is observational. This admits common model output such as
## `ls -d $HOME` without letting an attacker smuggle write-capable flags into
## curl, find, sort, xxd, or another otherwise constrained reader.
func implAllowsApprovedVariables(executable: string): bool =
  if executable in SIMPLE_READ_ONLY_COMMANDS:
    return true
  result = executable in [
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
    return normalized in ["$null", "nul"]
  if lowerShell.contains("cmd"):
    return normalized == "nul"
  result = normalized == "/dev/null"

func implIsNullSink(target: string, shell: string): bool =
  result = toLowerAscii(target) in ["&1", "&2"] or
    implIsNullDevice(target, shell)

## Parses simple commands and pipelines. Substitution, chaining, background
## execution, grouping, here-documents, and file output fail closed. A single
## literal-file stdin redirect may be admitted for explicitly safe data
## readers; it is parsed here instead of being accepted as generic shell text.
## Quote concatenation is normalised before executable validation.
func implParseCommand(command: string, shell: string): ParsedCommand =
  var stage: seq[string] = @[]
  var token = ""
  var tokenStarted = false
  var quote = '\0'
  var index = 0
  var stageOptionsEnded = false
  var stageUsesApprovedVariable = false
  var stageUsesInputRedirection = false
  let cmdShell = toLowerAscii(shell).contains("cmd")
  let powerShell = toLowerAscii(shell).contains("powershell") or
    toLowerAscii(shell).contains("pwsh")
  let posixEscapes = shell.len > 0 and not cmdShell and not powerShell

  template finishToken() =
    if tokenStarted:
      stage.add(token)
      if token == "--":
        stageOptionsEnded = true
      token = ""
      tokenStarted = false

  template reject(message: string) =
    return ParsedCommand(valid: false, reason: message, stages: @[])

  while index < command.len:
    let current = command[index]
    if quote != '\0':
      if current == quote:
        quote = '\0'
      elif quote == '"' and current == '$':
        let variableLength = implSafeVariableLength(command, index)
        if variableLength == 0:
          reject("shell expansion is not permitted")
        token.add(command[index ..< index + variableLength])
        tokenStarted = true
        stageUsesApprovedVariable = true
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
      finishToken()
      if index + 1 < command.len and command[index + 1] == '|':
        reject("logical command chaining is not permitted")
      if stage.len == 0:
        reject("pipeline contains an empty stage")
      result.stages.add(stage)
      result.variableExpansionStages.add(stageUsesApprovedVariable)
      result.inputRedirectionStages.add(stageUsesInputRedirection)
      stage = @[]
      stageOptionsEnded = false
      stageUsesApprovedVariable = false
      stageUsesInputRedirection = false
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
      let target = toLowerAscii(command[targetStart ..< index])
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
      index += variableLength
      continue
    if current == '~' and not tokenStarted:
      # POSIX shells and PowerShell expand a word-leading tilde after policy
      # validation. Treat it like an approved path variable so a hostile HOME
      # value cannot become an unchecked option of a write-capable reader.
      stageUsesApprovedVariable = true
    if current == '%' and token == "--":
      reject("PowerShell stop-parsing can hide unchecked parameter expansion")
    if current in {'\r', '\n', ';', '&', '(', ')', '{', '}', '`'}:
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
        result.unsafeUnquotedGlob = true
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
  result.inputRedirectionStages.add(stageUsesInputRedirection)
  result.valid = true

func implValidateFind(tokens: seq[string]): CommandPolicyDecision =
  for token in tokens:
    let lower = toLowerAscii(token)
    if lower in ["-delete", "-exec", "-execdir", "-ok", "-okdir"] or
        lower.startsWith("-exec") or lower.startsWith("-ok") or
        lower.startsWith("-fprint") or lower.startsWith("-fprintf") or
        lower == "-fls":
      return implReject("find action can execute code or write a file")
  result = implAllow()

func implValidateFd(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["-x", "-X", "--exec", "--exec-batch"]):
    return implReject("fd execution options are not read-only")
  for token in tokens:
    if not token.startsWith("--") and
        token.startsWith("-") and
        (token.contains('x') or token.contains('X')):
      return implReject("fd execution options are not read-only")
  result = implAllow()

func implValidateRg(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["--pre", "--pre-glob", "--hostname-bin"]):
    return implReject("rg external-command options are not permitted")
  result = implAllow()

func implValidateSort(
  tokens: seq[string],
  shell: string
): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, [
    "-o", "--output", "--compress-program", "-T", "--temporary-directory"
  ]):
    return implReject("sort option can write a file or execute a helper")
  for token in tokens:
    if token.startsWith("-") and not token.startsWith("--") and
        (token.contains('o') or token.contains('T')):
      return implReject("sort output or temporary-file option is not permitted")
    if (toLowerAscii(shell).contains("cmd") or
        toLowerAscii(tokens[0]).endsWith("sort.exe")) and
        (toLowerAscii(token).startsWith("/o") or
          toLowerAscii(token).startsWith("/t")):
      return implReject("Windows sort output or temporary path is not permitted")
  result = implAllow()

func implValidateDiff(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["--output"]):
    return implReject("diff output option can write a file")
  result = implAllow()

func implValidateBase64(tokens: seq[string]): CommandPolicyDecision =
  # BSD/macOS base64 supports -o output_file even though GNU base64 does not.
  if implHasForbiddenOption(tokens, ["-o", "--output"]):
    return implReject("base64 output option can write a file")
  for token in tokens:
    if token.startsWith("-") and not token.startsWith("--") and
        token.contains('o'):
      return implReject("base64 output option can write a file")
  result = implAllow()

func implValidateTree(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["-o", "--output"]):
    return implReject("tree output option can write a file")
  for token in tokens:
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
  if implHasForbiddenOption(tokens, ["-r", "--revert"]):
    return implReject("xxd reverse mode can write a file")
  for token in tokens:
    if token.startsWith("-") and not token.startsWith("--") and
        toLowerAscii(token).contains('r'):
      return implReject("xxd reverse mode can write a file")
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

func implValidateFile(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["--compile"]):
    return implReject("file compile mode writes a magic database")
  for token in tokens:
    if token.startsWith("-") and not token.startsWith("--") and
        token.contains('C'):
      return implReject("file compile mode writes a magic database")
  result = implAllow()

func implValidatePgrep(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["--signal"]):
    return implReject("pgrep signal mode changes process state")
  result = implAllow()

func implValidateSar(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, ["-o"]):
    return implReject("sar output mode writes an activity file")
  for token in tokens:
    if token.startsWith("-") and not token.startsWith("--") and
        token.contains('o'):
      return implReject("sar output mode writes an activity file")
  result = implAllow()

func implValidatePing(
  tokens: seq[string],
  shell: string
): CommandPolicyDecision =
  let lowerShell = toLowerAscii(shell)
  let isWindows = lowerShell.contains("cmd") or
    lowerShell.contains("powershell") or lowerShell.contains("pwsh")
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
        index += 2
        continue
      for item in [
        ("--count=", 20), ("--size=", 4096)
      ]:
        let option = item[0]
        let maximum = item[1]
        if lower.startsWith(option) and
            not implUnsignedAtMost(token[option.len .. ^1], maximum):
          return implReject("ping count or payload exceeds the safe bound")
      if token.startsWith("-c") and token.len > 2 and
          not implUnsignedAtMost(token[2 .. ^1], 20):
        return implReject("ping count exceeds the safe bound")
      if token.startsWith("-s") and token.len > 2 and
          not implUnsignedAtMost(token[2 .. ^1], 4096):
        return implReject("ping payload exceeds the safe bound")
    index += 1
  result = implAllow()

## Supports the common read-only field-selection form without admitting AWK's
## system(), file redirection, pipes, getline, or program-file capabilities.
func implValidateAwk(tokens: seq[string]): CommandPolicyDecision =
  if tokens.len != 2:
    return implReject("awk is limited to one built-in field selector")
  let program = tokens[1].replace(" ", "").replace("\t", "")
  if program == "{print}" or program in [
    "{print$NF}", "{printNF}", "{printNR}"
  ]:
    return implAllow()
  if program.startsWith("{print$") and program.endsWith("}"):
    let field = program[7 ..< program.len - 1]
    if implAllDigits(field) and field != "0":
      return implAllow()
  result = implReject("awk program is outside the pure field-selector subset")

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
    if token.startsWith("-") and not token.startsWith("--"):
      for flag in ['c', 'C', 'n', 'D', 'E']:
        if token.contains(flag):
          return implReject(
            "dmesg option can clear or reconfigure kernel logging")
  result = implAllow()

func implValidateNetworkReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
  of "ss":
    if implHasForbiddenOption(tokens, ["-K", "--kill"]):
      return implReject("ss kill mode changes socket state")
    for token in tokens:
      if token.startsWith("-") and not token.startsWith("--") and
          token.contains('K'):
        return implReject("ss kill mode changes socket state")
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
      for action in ["add", "change", "delete", "del", "flush"]:
        if lower.len >= 2 and action.startsWith(lower):
          return implReject("route action can change routing state")
  of "ip":
    if implHasForbiddenOption(tokens, ["--batch", "--force"] ) or
        implHasToken(tokens, ["-b", "-batch", "-force"]):
      return implReject("ip batch mode can execute mutating commands")
    for token in tokens:
      let lower = toLowerAscii(token)
      for action in [
        "add", "append", "change", "delete", "replace", "set", "flush",
        "save", "restore", "exec", "xfrm"
      ]:
        # iproute2 accepts unique command abbreviations, such as `se` for
        # `set`; values longer than the action cannot match this condition.
        if lower.len >= 2 and action.startsWith(lower):
          return implReject("ip action can change network state")
  of "ipconfig":
    for token in tokens:
      let lower = toLowerAscii(token)
      if lower.startsWith("/"):
        if lower in [
          "/all", "/allcompartments", "/displaydns", "/showclassid"
        ]:
          continue
        return implReject("ipconfig option can change network state")
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
          "status", "show", "monitor"
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
    if action notin [
      "status", "show", "is-active", "is-enabled", "is-failed", "list-units",
      "list-unit-files", "list-dependencies", "cat", "--version"
    ]:
      return implReject("systemctl action is not an approved query")
  of "journalctl":
    if implHasForbiddenOption(tokens, [
      "--vacuum-size", "--vacuum-time", "--vacuum-files", "--rotate",
      "--sync", "--flush", "--relinquish-var", "--smart-relinquish-var",
      "--setup-keys", "--update-catalog", "--force"
    ]):
      return implReject("journalctl maintenance option changes state")
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
  else:
    discard
  result = implAllow()

func implValidateNvidiaSmi(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenOption(tokens, [
    "-pm", "--persistence-mode", "-pl", "--power-limit", "-ac",
    "--applications-clocks", "-rac", "--reset-applications-clocks", "-lgc",
    "--lock-gpu-clocks", "-rgc", "--reset-gpu-clocks", "-lmc",
    "--lock-memory-clocks", "-rmc", "--reset-memory-clocks", "-r", "--gpu-reset",
    "-gom", "--gom", "-c", "--compute-mode", "--auto-boost-default",
    "--auto-boost-permission", "--clock-lock", "--reset-ecc-errors",
    "-e", "--ecc-config", "-mig", "--mig-mode", "-dm", "--driver-model",
    "-fdm", "--force-driver-model", "-am", "--accounting-mode",
    "-caa", "--clear-accounted-apps", "-gtt", "--gpu-target-temp",
    "--module-power-limit", "--power-hint", "--filename", "--debug"
  ]):
    return implReject("nvidia-smi option changes GPU state")
  for token in tokens:
    let lower = toLowerAscii(token)
    if lower in ["mig", "vgpu", "drain", "daemon", "conf-compute"]:
      return implReject("nvidia-smi management subcommand changes GPU state")
    if token.startsWith("-") and not token.startsWith("--") and
        token.contains('f'):
      return implReject("nvidia-smi output option can write a file")
    for prefix in [
      "-pm", "-pl", "-ac", "-rac", "-lgc", "-rgc", "-lmc", "-rmc",
      "-r", "-gom", "-c", "-e", "-caa", "-gtt", "-mig", "-dm",
      "-fdm", "-am"
    ]:
      if lower.startsWith(prefix):
        return implReject("nvidia-smi option changes GPU state")
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
        "--request-target", "--ftp-account",
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
  for arg in args:
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
    if lower in ["--version", "--help"]:
      return implAllow()
    if original == "-c" or lower in ["--config-env", "--exec-path"] or
        original.startsWith("-c=") or lower.startsWith("--config-env="):
      return implReject("git configuration can inject executable helpers")
    if original == "-C" or lower in ["--git-dir", "--work-tree", "--namespace"]:
      index += 2
    elif lower.startsWith("--git-dir=") or lower.startsWith("--work-tree=") or
        lower in ["--no-pager", "--paginate", "--literal-pathspecs"]:
      index += 1
    else:
      return implReject("unrecognised git global option")
  if index >= tokens.len:
    return implReject("git query is missing a subcommand")
  let subcommand = toLowerAscii(tokens[index])
  let args = if index + 1 < tokens.len: tokens[index + 1 .. ^1] else: @[]
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
  for arg in args:
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
  if subcommand in ["branch", "tag"]:
    if subcommand == "tag" and "-a" in args:
      return implReject("git tag annotation creates a tag")
    if subcommand == "tag" and (
        "-v" in args or implHasForbiddenOption(args, ["--verify"])):
      return implReject("git tag verification can execute a configured verifier")
    var listing = args.len == 0
    for arg in args:
      let lower = toLowerAscii(arg)
      if lower in ["-l", "--list", "--show-current", "-a", "--all", "-r",
          "--remotes", "-v", "-vv", "--verbose", "--contains", "--no-contains",
          "--merged", "--no-merged", "--points-at", "--format"] or
          lower.startsWith("--format=") or lower.startsWith("--contains=") or
          lower.startsWith("--points-at="):
        listing = true
      elif not arg.startsWith("-") and listing:
        discard
      else:
        return implReject("git branch or tag action is not a pure listing")
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
    if args.len == 0 or toLowerAscii(args[0]) in ["-v", "get-url"]:
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
  of "dnf", "yum", "zypper":
    if action in ["list", "info", "search", "repolist", "check-update", "--version"]:
      return implAllow()
  of "pacman":
    if action.startsWith("-q") or action in ["-ss", "-si", "--version"]:
      return implAllow()
  of "brew":
    if action in ["list", "search", "config", "--version"]:
      return implAllow()
    if action == "info":
      for index in 2 ..< tokens.len:
        let operand = toLowerAscii(tokens[index])
        if operand.startsWith(".") or operand.contains("\\") or
            operand.endsWith(".rb"):
          return implReject("brew info cannot evaluate a path-selected formula")
      return implAllow()
  of "winget":
    if action in ["list", "show", "search", "--version"]:
      return implAllow()
  of "choco":
    if action in ["list", "search", "info", "--version"]:
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
      "--recursive-unlink"
    ]):
      return implReject("tar option can execute, extract, or write")
    var listing = implHasOption(tokens, ["--list"])
    for token in tokens:
      if token.startsWith("-") and not token.startsWith("--") and
          token.contains('t'):
        listing = true
      if token.startsWith("-") and not token.startsWith("--"):
        for flag in ['c', 'x', 'r', 'u', 'A', 'F', 'I', 'T']:
          if token.contains(flag):
            return implReject("tar operation may write or execute a helper")
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
    if stdoutMode or (inspectionMode and not explicitDecompress):
      return implAllow()
  of "zcat", "bzcat", "xzcat":
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

func implValidateWindowsReader(
  name: string,
  tokens: seq[string]
): CommandPolicyDecision =
  case name
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
  else:
    discard
  result = implReject(name & " action is not an approved Windows query")

func implValidateWebCmdlet(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenPowerShellParameter(tokens, [
    "-method", "-body", "-infile", "-outfile", "-form", "-websession",
    "-sessionvariable", "-credential", "-token"
  ]):
    return implReject("PowerShell web option can write or mutate remotely")
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
  for token in tokens:
    if token.contains('{') or token.contains('}') or token.contains("$_"):
      return implReject("Sort-Object script-block properties are not permitted")
  result = implAllow()

func implValidateGetHelp(tokens: seq[string]): CommandPolicyDecision =
  if implHasForbiddenPowerShellParameter(tokens, ["-online", "-showwindow"]):
    return implReject("Get-Help viewer options can launch an external program")
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
  if name == "where-object":
    return implValidateWhereObject(tokens)
  if name == "sort-object":
    return implValidateSortObject(tokens)
  if name == "get-help":
    return implValidateGetHelp(tokens)
  if name == "printf":
    return implValidatePrintf(tokens)
  if isPowerShell:
    if name == "where" and
        not toLowerAscii(tokens[0]).endsWith("where.exe"):
      return implValidateWhereObject(tokens)
    if name == "sort" and
        not toLowerAscii(tokens[0]).endsWith("sort.exe"):
      return implValidateSortObject(tokens)
    if name == "set":
      return implReject("bare set is PowerShell's write-capable Set-Variable alias")

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
  of "sar": return implValidateSar(tokens)
  of "ping": return implValidatePing(tokens, shell)
  of "awk": return implValidateAwk(tokens)
  of "yq":
    if implHasForbiddenOption(tokens, [
      "-i", "--inplace", "--in-place", "--split-exp", "--split-exp-file"
    ]):
      return implReject("yq in-place mode can modify files")
    for token in tokens:
      if token.startsWith("-") and not token.startsWith("--") and
          token.contains('i'):
        return implReject("yq in-place mode can modify files")
    return implAllow()
  of "date": return implValidateDate(tokens)
  of "hostname": return implValidateHostname(tokens)
  of "dmesg": return implValidateDmesg(tokens)
  of "ss", "arp", "route", "ip", "ipconfig", "nmcli", "netsh":
    return implValidateNetworkReader(name, tokens)
  of "systemctl", "journalctl", "timedatectl", "loginctl", "sysctl":
    return implValidateSystemReader(name, tokens)
  of "nvidia-smi": return implValidateNvidiaSmi(tokens)
  of "curl": return implValidateCurl(tokens, shell)
  of "wget": return implValidateWget(tokens)
  of "git": return implValidateGit(tokens)
  of "docker", "podman": return implValidateContainer(name, tokens)
  of "kubectl": return implValidateKubectl(tokens)
  of "apt", "apt-get", "apt-cache", "dnf", "yum", "zypper", "pacman",
      "brew", "winget", "choco", "pip", "pip3", "npm", "pnpm", "yarn",
      "cargo", "nimble":
    return implValidatePackageQuery(name, tokens)
  of "tar", "bsdtar", "unzip", "zipinfo", "gzip", "gunzip", "bzip2",
      "bunzip2", "xz", "unxz", "zcat", "bzcat", "xzcat":
    return implValidateArchive(name, tokens)
  of "reg", "sc", "wevtutil", "certutil", "cmdkey", "set":
    return implValidateWindowsReader(name, tokens)
  of "invoke-webrequest", "invoke-restmethod", "iwr", "irm":
    return implValidateWebCmdlet(tokens)
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
  if shellExpandsGlobs and parsed.unsafeUnquotedGlob:
    return implReject(
      "unqualified shell glob can expand to an injected option; prefix it with ./")
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
      return implReject(
        "approved shell expansions require a side-effect-free reader")
    if parsed.inputRedirectionStages[stageIndex] and
        implExecutableName(stage[0]) notin STDIN_DATA_READERS:
      return implReject(
        "input redirection is limited to validated data readers")
    let decision = implValidateStage(stage, shell)
    if not decision.allowed:
      return decision
  result = implAllow()
