import std/[options, os, strutils, tempfiles, unittest]
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

  test "retention counts full multiline entries and escapes new data":
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
      "[2026-09-07 01:00:00] output: first\n\nparagraph\n\n" &
      "[2026-09-07 01:00:01] query: old-two\n" &
      "[2026-09-07 01:00:01] output: keep this\n\nparagraph-two\n\n")
    logExecution("new\nquery", "pwd", "first\n\nlast", 0, 2)
    let content = readFile(getLogFilePath())
    check "old-one" notin content
    check "old-two" in content
    check "paragraph-two" in content
    check "new\\nquery" in content
    check "first\\n\\nlast" in content
    check cleanLog() == 2
