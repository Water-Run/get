import std/[json, os, osproc, strutils, tempfiles, unittest]
import harness_executor, harness_protocol, harness_types, native_query_worker, query_policy

dispatchNativeQueryWorker()

suite "v4 Git snapshot queries":
  test "status and diff inspect files without executing configured filters or touching index":
    let root = createTempDir("get-git-fixture-", "")
    defer: removeDir(root)
    proc git(args: seq[string]) =
      let p = startProcess("git", workingDir = root, args = args,
        options = {poUsePath, poStdErrToStdOut})
      defer: p.close()
      require p.waitForExit(5000) == 0
    git(@["init", "-q"])
    writeFile(root / "tracked.txt", "original\n")
    git(@["add", "tracked.txt"])
    git(@["-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid",
      "commit", "-qm", "fixture"])
    writeFile(root / "tracked.txt", "modified\n")
    writeFile(root / "untracked.txt", "new\n")
    writeFile(root / ".gitattributes", "*.txt filter=attack diff=attack\n")
    let marker = root / "helper-ran"
    git(@["config", "filter.attack.clean", "echo dangerous > helper-ran"])
    git(@["config", "filter.attack.required", "true"])
    git(@["config", "diff.attack.command", "echo dangerous > helper-ran"])
    git(@["config", "diff.attack.textconv", "echo dangerous > helper-ran"])
    git(@["config", "core.fsmonitor", "echo dangerous > helper-ran"])
    let before = readFile(root / ".git" / "index")
    for args in [@["status", "--porcelain"], @["diff"], @["diff", "--cached"]]:
      let call = parseNativeToolCall("git", "run_process", $(%*{
        "executable": "git", "args": args, "cwd": root}))
      let decision = authorizeQuery(call, "bash")
      require decision.kind == qdAllowed
      check decision.plan.backend == qbGitSnapshot
      let values = executeAuthorizedBatch(@[decision.plan], "bash", defaultRunBudget(hkAuto), 1)
      checkpoint values[0].output
      require values[0].exitCode == 0
      check "snapshot" in values[0].source
      if args[0] == "status":
        check " M tracked.txt" in values[0].output
        check "?? untracked.txt" in values[0].output
      elif args.len == 1:
        check "-original" in values[0].output
        check "+modified" in values[0].output
      else: check values[0].output.len == 0
      check not fileExists(marker)
      check readFile(root / ".git" / "index") == before
    let shellCall = parseNativeToolCall("shell", "run_shell", $(%*{
      "command": "git status --porcelain", "cwd": root}))
    let value = executeAuthorizedBatch(@[authorizeQuery(shellCall, "bash").plan],
      "bash", defaultRunBudget(hkAuto), 1)[0]
    check value.exitCode == 0
    check "tracked.txt" in value.output
    check not fileExists(marker)

  test "snapshot adapter does not accept write options or executable configuration":
    for args in [@["status", "--output=marker"], @["-c", "alias.status=!touch marker", "status"],
        @["diff", "--ext-diff"], @["diff", "--output", "marker"], @["reset", "--hard"]]:
      let call = parseNativeToolCall("bad", "run_process", $(%*{"executable": "git", "args": args}))
      check authorizeQuery(call, "bash").kind != qdAllowed
