## Ordinary status/diff over a private Git metadata snapshot.
## No repository/global configuration, executable filters, hooks or submodule
## helpers are loaded. Observations explicitly describe this raw-file view.
import std/[monotimes, os, strutils, times]
import command_policy, exec, harness_types, query_adapters

proc gitQueryWords*(call: ToolCall, shell: string): seq[string] =
  let words = if call.invocationKind == tikProcess: @[call.executable] & call.argv
    elif call.invocationKind == tikShell: literalQueryWords(call.command, shell)
    else: @[]
  if words.len < 2 or words[0] notin ["git", "git.exe"]: return
  var index = 1
  while index < words.len:
    if words[index] in ["--no-pager", "--literal-pathspecs"]: inc index
    elif words[index] == "-C" and index + 1 < words.len: index += 2
    else: break
  if index >= words.len or words[index] notin ["status", "diff"]: return
  let subcommand = words[index]
  var paths = false
  for token in words[index + 1 ..< words.len]:
    if paths: continue
    if token == "--": paths = true; continue
    if not token.startsWith('-'): continue
    let allowed = if subcommand == "status":
      token in ["-s", "--short", "-b", "--branch", "-z", "--porcelain",
        "--porcelain=v1", "--porcelain=v2", "--porcelain=1", "--porcelain=2", "--ignored", "--untracked-files",
        "--untracked-files=all", "--untracked-files=normal", "--untracked-files=no",
        "-u", "-uall", "-uno", "--ahead-behind", "--no-ahead-behind"]
      else:
        token in ["--stat", "--shortstat", "--numstat", "--name-only", "--name-status",
          "--raw", "-p", "-u", "--patch", "--cached", "--staged", "--no-color",
          "--color=never", "--no-ext-diff", "--no-textconv", "--check", "--exit-code",
          "--quiet", "-w", "-b", "--ignore-space-at-eol", "--ignore-cr-at-eol",
          "--ignore-blank-lines", "--no-renames", "--binary", "--full-index"] or
          (token.startsWith("-U") and token.len > 2 and token[2..^1].allCharsInSet({'0'..'9'})) or
          (token.startsWith("--unified=") and token.len > 10 and token[10..^1].allCharsInSet({'0'..'9'}))
    if not allowed: return
  result = words

proc executeGitQuery*(call: ToolCall, shell: string, budget: RunBudget,
    scratch: string): ExecResult =
  let words = gitQueryWords(call, shell)
  if words.len == 0: raise newException(IOError, "unsupported Git snapshot query")
  let started = getMonoTime()
  let timeout = if budget.commandTimeoutSec > 0: budget.commandTimeoutSec else: 30
  proc remaining(): int =
    result = timeout - int((getMonoTime() - started).inSeconds)
    if result <= 0: raise newException(IOError, "Git snapshot deadline reached")
  var cwd = if call.cwd.len > 0: absolutePath(call.cwd) else: getCurrentDir()
  var index = 1
  while words[index] != "status" and words[index] != "diff":
    if words[index] == "-C":
      cwd = absolutePath(words[index + 1], cwd)
      index += 2
    else: inc index
  let discovery = executeGitSnapshot(@["rev-parse", "--path-format=absolute",
    "--absolute-git-dir", "--git-common-dir", "--show-toplevel", "--show-object-format"],
    remaining(), 16384, cwd)
  if discovery.exitCode != 0: return discovery
  let paths = discovery.stdout.strip().splitLines()
  if paths.len != 4 or paths[3] notin ["sha1", "sha256"]:
    raise newException(IOError, "Git repository layout is unsupported by the snapshot reader")
  let gitDir = paths[0]
  let common = paths[1]
  let worktree = paths[2]
  if dirExists(common / "reftable"):
    raise newException(IOError, "reftable repositories require another query backend")
  if scratch.len == 0 or not dirExists(scratch):
    raise newException(IOError, "private Git snapshot directory is missing")
  createDir(scratch / "objects" / "info")
  createDir(scratch / "refs")
  # Git's alternate object stores are read-only. No objects or packfiles copied.
  writeFile(scratch / "objects" / "info" / "alternates",
    (common / "objects").replace('\\', '/') & "\n")
  var copied, entries: int
  proc copyMetadata(source, destination: string) =
    discard remaining()
    inc entries
    if entries > 16384: raise newException(IOError, "Git metadata entry limit reached")
    let originalModified = getLastModificationTime(source)
    let data = readBoundedQueryFile(source, 32 * 1024 * 1024)
    copied += data.text.len
    if data.limited or copied > 64 * 1024 * 1024:
      raise newException(IOError, "Git metadata snapshot exceeds 64 MiB")
    createDir(parentDir(destination))
    writeFile(destination, data.text)
    # The index timestamp participates in Git's racy-clean detection. A fresh
    # timestamp can hide same-size edits made within the filesystem clock tick.
    setLastModificationTime(destination, originalModified)
  for name in ["HEAD", "index"]:
    if fileExists(gitDir / name): copyMetadata(gitDir / name, scratch / name)
  for name in ["packed-refs", "shallow", "info/exclude", "info/attributes"]:
    if fileExists(common / name): copyMetadata(common / name, scratch / name)
  for source in walkDirRec(common / "refs"):
    copyMetadata(source, scratch / "refs" / relativePath(source, common / "refs"))
  for source in walkFiles(gitDir / "sharedindex.*"):
    copyMetadata(source, scratch / extractFilename(source))
  var config = "[core]\nrepositoryformatversion = " &
    (if paths[3] == "sha256": "1" else: "0") & "\nbare = false\n" &
    "fsmonitor = false\nuntrackedCache = false\n"
  if paths[3] == "sha256": config.add("[extensions]\nobjectFormat = sha256\n")
  # Preserve safe line-ending/file-mode interpretation, never executable values.
  for key in ["core.filemode", "core.autocrlf", "core.eol", "core.ignorecase", "core.symlinks"]:
    let setting = executeProcessBounded("git", @["config", "--get", key],
      remaining(), 128, cwd, readOnlySandbox = false)
    let value = setting.stdout.strip().toLowerAscii()
    if setting.exitCode == 0 and value in ["true", "false", "input", "lf", "crlf", "native"]:
      config.add("[core]\n" & key[5..^1] & " = " & value & "\n")
  writeFile(scratch / "config", config)
  var args = @["--no-pager", "--git-dir=" & scratch, "--work-tree=" & worktree,
    words[index], "--ignore-submodules=all"]
  if words[index] == "diff": args.add(@["--no-ext-diff", "--no-textconv"])
  args.add(words[index + 1 ..< words.len])
  result = executeGitSnapshot(args, remaining(), budget.maxOutputBytes, cwd)
  result.elapsedMs = (getMonoTime() - started).inMilliseconds
