## Mandatory read-only command policy for get v3.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: command_policy.nim
## :License: AGPL-3.0
##
## This module applies a non-configurable safety baseline before the optional
## user regex. It rejects known mutators, write redirection, write-capable
## flags, and arbitrary inline interpreter code while allowing common
## inspection pipelines and harmless redirection to null or existing streams.

{.experimental: "strictFuncs".}

import std/[strutils]

import regex

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Known commands whose primary purpose mutates local or remote state.
const MUTATING_COMMAND_PATTERN =
  "\\b(rm|rmdir|unlink|shred|truncate|mv|move|cp|copy|install|mkdir|mktemp|" &
  "touch|ln|chmod|chown|chgrp|setfacl|mkfs|dd|fdisk|parted|mount|umount|" &
  "kill|killall|pkill|shutdown|reboot|halt|poweroff|passwd|useradd|userdel|" &
  "usermod|groupadd|groupdel|tee|write|wall|del|erase|ren|xcopy|robocopy|" &
  "scp|sftp|rsync|wget|diskpart|bcdedit|takeown|icacls)\\b"

## Shell and language entry points that can hide arbitrary mutation.
const DYNAMIC_CODE_PATTERN =
  "\\b(eval|exec)\\b|" &
  "\\b(python|python3|node|deno|ruby|perl|php)\\b[^\\n;|]*" &
  "(^|[[:space:]])(-c|-e|--eval)([[:space:]]|$)|" &
  "\\b(sh|bash|dash|zsh|fish|ksh|cmd|powershell|pwsh)\\b[^\\n;|]*" &
  "(^|[[:space:]])(-c|/c|-command|-encodedcommand)([[:space:]]|$)"

## State-changing version-control subcommands.
const GIT_MUTATION_PATTERN =
  "\\bgit[[:space:]]+(add|bisect|branch|checkout|cherry-pick|clean|clone|" &
  "commit|fetch|init|merge|mv|pull|push|rebase|reset|restore|revert|rm|" &
  "stash|switch|tag|worktree)\\b"

## State-changing container and cluster subcommands.
const ORCHESTRATOR_MUTATION_PATTERN =
  "\\b(docker|podman)[[:space:]]+(build|commit|compose|container|cp|create|" &
  "exec|image|import|kill|load|login|logout|network|pause|plugin|pull|push|" &
  "rename|restart|rm|rmi|run|save|start|stop|tag|unpause|update|volume)\\b|" &
  "\\bkubectl[[:space:]]+(annotate|apply|attach|autoscale|certificate|cordon|" &
  "cp|create|delete|drain|edit|exec|expose|label|patch|replace|rollout|run|" &
  "scale|set|taint|uncordon)\\b"

## Package-manager operations that install or alter dependencies.
const PACKAGE_MUTATION_PATTERN =
  "\\b(apt|apt-get|dnf|yum|pacman|zypper|brew|winget|choco)[[:space:]]+" &
  "(add|autoremove|clean|dist-upgrade|full-upgrade|install|purge|remove|" &
  "uninstall|update|upgrade)\\b|" &
  "\\b(npm|pnpm|yarn|pip|pip3|gem|cargo|nimble)[[:space:]]+" &
  "(add|install|remove|uninstall|update|upgrade)\\b"

## In-place editor and filesystem-walker mutation flags.
const MUTATING_FLAG_PATTERN =
  "\\b(sed|perl)[^\\n;|]*[[:space:]]-i([^[:alnum:]]|$)|" &
  "\\bfind\\b[^\\n;|]*[[:space:]]-(delete|exec|execdir|ok|okdir)\\b"

## SQL statements that can change persistent database state.
const SQL_MUTATION_PATTERN =
  "(^|[;[:space:]])(alter|create|delete|drop|grant|insert|merge|replace|" &
  "revoke|truncate|update|vacuum)[[:space:]]"

## PowerShell verbs associated with mutation or process control.
const POWERSHELL_MUTATION_PATTERN =
  "\\b(add|clear|copy|disable|enable|export|import|install|move|new|publish|" &
  "remove|rename|restart|set|start|stop|uninstall|unpublish|update)-" &
  "[a-z][a-z0-9-]*\\b"

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Describes the deterministic read-only policy outcome.
type
  CommandPolicyDecision* = object
    allowed*: bool  ## Whether the command may proceed to configurable checks.
    reason*: string ## Concise rejection reason, or empty when allowed.

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Tests a lowercase command against one compiled policy pattern.
##
## :param command: Lowercase command text.
## :param pattern: Constant RE2-compatible pattern.
## :returns: Whether the pattern matches.
proc implMatches(command: string, pattern: string): bool =
  result = command.contains(re2(pattern))

## Returns the unquoted token following an output-redirection operator.
##
## :param command: Original command text.
## :param start: Position immediately after one or two greater-than signs.
## :returns: Lowercase target token, possibly empty.
func implRedirectionTarget(command: string, start: int): string =
  var index = start
  while index < command.len and command[index] in {' ', '\t'}:
    index += 1
  let tokenStart = index
  while index < command.len and
      command[index] notin {' ', '\t', '\r', '\n', ';', '|'}:
    index += 1
  if tokenStart < index:
    result = toLowerAscii(command[tokenStart ..< index])

## Finds output redirection that can create or modify a regular file.
##
## :param command: Original shell command.
## :returns: True when an unquoted write target is not null or another stream.
func implHasWriteRedirection(command: string): bool =
  var singleQuoted = false
  var doubleQuoted = false
  var escaped = false
  var index = 0
  while index < command.len:
    let character = command[index]
    if escaped:
      escaped = false
      index += 1
      continue
    if character == '\\' and not singleQuoted:
      escaped = true
      index += 1
      continue
    if character == '\'' and not doubleQuoted:
      singleQuoted = not singleQuoted
      index += 1
      continue
    if character == '"' and not singleQuoted:
      doubleQuoted = not doubleQuoted
      index += 1
      continue
    if character == '>' and not singleQuoted and not doubleQuoted:
      var targetStart = index + 1
      if targetStart < command.len and command[targetStart] == '>':
        targetStart += 1
      let target = implRedirectionTarget(command, targetStart)
      if target notin ["/dev/null", "nul", "&1", "&2"]:
        return true
    index += 1
  result = false

## Detects curl options capable of mutating remote state or uploading data.
##
## :param command: Lowercase command text.
## :returns: True when curl is used with a non-read-only option.
func implHasMutatingCurl(command: string): bool =
  let lower = toLowerAscii(command)
  if not lower.contains("curl"):
    return false
  let padded = " " & lower.replace('\n', ' ') & " "
  for marker in [
    " -d ", " -d'", " -d\"", " --data", " --json", " --form",
    " --upload-file", " -t ",
    " -x post", " -x put", " -x patch", " -x delete",
    " --request post", " --request put", " --request patch",
    " --request delete"
  ]:
    if padded.contains(marker):
      return true
  for rawToken in command.replace('\n', ' ').splitWhitespace():
    let token = rawToken.strip(chars = {'\'', '"'})
    let lowerToken = toLowerAscii(token)
    if token.startsWith("-F") or token.startsWith("-T") or
        token.startsWith("-O") or token.startsWith("-D") or
        token.startsWith("-d") or token.startsWith("-o") or
        lowerToken.startsWith("--data") or
        lowerToken.startsWith("--dump-header") or
        lowerToken.startsWith("--etag-save") or
        lowerToken.startsWith("--form") or
        lowerToken.startsWith("--json") or
        lowerToken.startsWith("--output") or
        lowerToken.startsWith("--remote-header-name") or
        lowerToken.startsWith("--remote-name") or
        lowerToken.startsWith("--trace") or
        lowerToken.startsWith("--upload-file"):
      return true
    for httpMethod in ["post", "put", "patch", "delete"]:
      if lowerToken == "-x" & httpMethod or
          lowerToken == "--request=" & httpMethod:
        return true
  result = false

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Applies the mandatory read-only command baseline.
##
## This check is intentionally conservative. The configured command-pattern
## is an additional filter and cannot disable this baseline.
##
## :param command: Model-proposed or cached shell command.
## :returns: Allow decision with a stable reason when rejected.
##
## .. code-block:: nim
##   runnableExamples:
##     assert checkReadOnlyCommand("git status").allowed
##     assert not checkReadOnlyCommand("rm -rf /tmp/example").allowed
func checkReadOnlyCommand*(command: string): CommandPolicyDecision =
  let normalized = command.strip()
  if normalized.len == 0:
    return CommandPolicyDecision(
      allowed: false,
      reason: "command is empty"
    )
  if normalized.contains('\0'):
    return CommandPolicyDecision(
      allowed: false,
      reason: "command contains a NUL byte"
    )
  if implHasWriteRedirection(normalized):
    return CommandPolicyDecision(
      allowed: false,
      reason: "output redirection may modify a file"
    )
  let lower = toLowerAscii(normalized)
  if implMatches(lower, MUTATING_COMMAND_PATTERN):
    return CommandPolicyDecision(
      allowed: false,
      reason: "command invokes a known state-changing utility"
    )
  if implMatches(lower, DYNAMIC_CODE_PATTERN):
    return CommandPolicyDecision(
      allowed: false,
      reason: "arbitrary inline interpreter code is not allowed"
    )
  if implMatches(lower, GIT_MUTATION_PATTERN):
    return CommandPolicyDecision(
      allowed: false,
      reason: "git subcommand can modify repository state"
    )
  if implMatches(lower, ORCHESTRATOR_MUTATION_PATTERN):
    return CommandPolicyDecision(
      allowed: false,
      reason: "container or cluster subcommand can modify state"
    )
  if implMatches(lower, PACKAGE_MUTATION_PATTERN):
    return CommandPolicyDecision(
      allowed: false,
      reason: "package-manager subcommand can modify dependencies"
    )
  if implMatches(lower, MUTATING_FLAG_PATTERN):
    return CommandPolicyDecision(
      allowed: false,
      reason: "command uses an in-place or executing flag"
    )
  if implMatches(lower, SQL_MUTATION_PATTERN):
    return CommandPolicyDecision(
      allowed: false,
      reason: "command contains a state-changing SQL statement"
    )
  if implMatches(lower, POWERSHELL_MUTATION_PATTERN):
    return CommandPolicyDecision(
      allowed: false,
      reason: "PowerShell verb can modify state"
    )
  if implHasMutatingCurl(normalized):
    return CommandPolicyDecision(
      allowed: false,
      reason: "curl options can write, upload, or mutate state"
    )
  result = CommandPolicyDecision(
    allowed: true,
    reason: ""
  )
