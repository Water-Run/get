import std/[json, options, os, strutils, tempfiles, unittest]
import config, logger, utils

suite "private configuration and log retention":
  test "atomic settings and keys do not follow destination symlinks":
    let root = createTempDir("get-persistence-", "")
    let envName = when defined(windows): "APPDATA" else: "XDG_CONFIG_HOME"
    let existed = existsEnv(envName)
    let old = getEnv(envName)
    putEnv(envName, root)
    defer:
      if existed: putEnv(envName, old)
      else: delEnv(envName)
      removeDir(root)
    saveKey(some("test-private-key"))
    check loadKey() == some("test-private-key")
    when defined(posix):
      check getFilePermissions(getKeyFilePath()) == {fpUserRead, fpUserWrite}
      let unrelated = root / "unrelated"
      writeFile(unrelated, "keep")
      removeFile(getKeyFilePath())
      createSymlink(unrelated, getKeyFilePath())
      saveKey(some("replacement"))
      check readFile(unrelated) == "keep"
      check loadKey() == some("replacement")
    setConfigOption("markdown", "false")
    check not loadConfig().markdown
    setConfigOption("markdown", "")
    check loadConfig().markdown
    for path in walkFiles(getAppConfigDir() / ".get-write-*.tmp"):
      checkpoint(path)
      check false

  test "one JSON line per query replaces an old text log and keeps the newest":
    let root = createTempDir("get-log-retention-", "")
    let envName = when defined(windows): "APPDATA" else: "XDG_CONFIG_HOME"
    let existed = existsEnv(envName)
    let old = getEnv(envName)
    putEnv(envName, root)
    defer:
      if existed: putEnv(envName, old)
      else: delEnv(envName)
      removeDir(root)
    writeFile(getLogFilePath(),
      "[2026-09-07 01:00:00] query: old-one\n" &
      "[2026-09-07 01:00:00] output: first\n\nparagraph\n\n")
    logQuery(QueryRecord(query: "new\nquery", rounds: 2, toolCalls: 3,
      denied: 1, cacheHit: "none", exitCode: 0, elapsedMs: 1200), 2)
    var content = readFile(getLogFilePath())
    check "old-one" notin content
    check content.count('\n') == 1
    let record = parseJson(content.strip())
    check record["query"].getStr == "new\nquery"
    check record["rounds"].getInt == 2
    check record["tool_calls"].getInt == 3
    check record["denied"].getInt == 1
    check record["cache_hit"].getStr == "none"
    check record["exit_code"].getInt == 0
    check record["elapsed_ms"].getInt == 1200
    for index in 0 ..< 3:
      logQuery(QueryRecord(query: "q" & $index, cacheHit: "plan"), 2)
    content = readFile(getLogFilePath())
    check content.strip().splitLines().len == 2
    check "\"q1\"" in content and "\"q2\"" in content
    logQuery(QueryRecord(query: repeat("长", 300)), 0)
    let preview = parseJson(readFile(getLogFilePath()).strip().splitLines()[^1])
    check preview["query"].getStr.endsWith("...")
    check cleanLog() == 3
