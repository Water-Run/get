## Small cross-process regressions: at most four lightweight worker processes.
import std/[json, monotimes, options, os, osproc, sets, streams, strutils,
            tempfiles, times, unittest]
import config, file_lock, logger, utils

if paramCount() > 0 and paramStr(1) == "--state-worker":
  let mode = paramStr(2)
  let marker = paramStr(3)
  if mode == "hold":
    let lock = acquireFileLock(paramStr(4))
    writeFile(marker, "ready")
    while true: sleep(100)
    releaseFileLock(lock)
  elif mode == "timeout":
    try:
      let lock = acquireFileLock(paramStr(4), timeoutMs = 100)
      releaseFileLock(lock)
      quit(0)
    except FileLockError:
      quit(42)
  else:
    writeFile(marker, "ready")
    case mode
    of "set": setConfigOption(paramStr(4), paramStr(5))
    of "reset": resetConfig()
    of "clean": writeFile(paramStr(4), $cleanLog())
    of "log":
      for index in 0..<8:
        let tag = paramStr(4) & "-" & $index
        logExecution(tag, tag, tag & "\n\nend", 0, parseInt(paramStr(5)))
    else: quit(2)
  quit(0)

proc worker(args: seq[string]): Process =
  startProcess(getAppFilename(), args = @["--state-worker"] & args,
    options = {poStdErrToStdOut})

proc cleanup(workers: seq[Process]) =
  for process in workers:
    if process.running:
      process.terminate()
      discard process.waitForExit(5_000)
    process.close()

proc waitReady(paths: seq[string]) =
  let started = getMonoTime()
  for path in paths:
    while not fileExists(path):
      if (getMonoTime() - started).inMilliseconds > 5_000:
        raise newException(IOError, "state worker did not become ready")
      sleep(10)

proc finish(workers: seq[Process]) =
  for process in workers:
    let code = process.waitForExit(5_000)
    if code != 0:
      if process.running:
        process.terminate()
        discard process.waitForExit(5_000)
      checkpoint(process.outputStream.readAll())
    check code == 0

template isolatedState(body: untyped) =
  let root {.inject.} = createTempDir("get-state-locks-", "")
  let envName = when defined(windows): "APPDATA" else: "XDG_CONFIG_HOME"
  let existed = existsEnv(envName)
  let old = getEnv(envName)
  putEnv(envName, root)
  defer:
    if existed: putEnv(envName, old)
    else: delEnv(envName)
    removeDir(root)
  body

suite "serialized configuration and log updates":
  test "concurrent setters wait for the transaction and preserve different fields":
    isolatedState:
      saveConfig(defaultConfig())
      let initial = readFile(getConfigFilePath())
      var workers: seq[Process] = @[]
      var markers: seq[string] = @[]
      defer: cleanup(workers)
      let lock = acquireFileLock(getAppConfigDir() / ".settings.lock")
      try:
        for index, option in [("model", "concurrent-model"),
                              ("url", "https://concurrent.invalid/v1"),
                              ("markdown", "false"), ("max-rounds", "7")]:
          let marker = root / ("ready-" & $index)
          markers.add(marker)
          workers.add(worker(@["set", marker, option[0], option[1]]))
        waitReady(markers)
        sleep(100)
        check readFile(getConfigFilePath()) == initial
        for process in workers: check process.running
      finally:
        releaseFileLock(lock)
      finish(workers)
      let cfg = loadConfig()
      check cfg.model == "concurrent-model"
      check cfg.url == "https://concurrent.invalid/v1"
      check not cfg.markdown
      check cfg.maxRounds == 7

  test "reset waits for the shared settings lock and clears configuration and key":
    isolatedState:
      setConfigOption("model", "before-reset")
      saveKey(some("isolated-fixture-key"))
      let configBefore = readFile(getConfigFilePath())
      let keyBefore = readFile(getKeyFilePath())
      var workers: seq[Process] = @[]
      defer: cleanup(workers)
      let marker = root / "reset-ready"
      let lock = acquireFileLock(getAppConfigDir() / ".settings.lock")
      try:
        workers.add(worker(@["reset", marker]))
        waitReady(@[marker])
        sleep(100)
        check workers[0].running
        check readFile(getConfigFilePath()) == configBefore
        check readFile(getKeyFilePath()) == keyBefore
      finally:
        releaseFileLock(lock)
      finish(workers)
      check loadConfig().model == defaultConfig().model
      check loadKey().isNone

  test "invalid settings release the writer lock":
    isolatedState:
      expect GetError:
        setConfigOption("markdown", "invalid")
      setConfigOption("markdown", "false")
      check not loadConfig().markdown

  test "concurrent log entries stay whole with and without retention":
    isolatedState:
      for limit in [0, 16]:
        discard cleanLog()
        var workers: seq[Process] = @[]
        try:
          for index in 0..<4:
            workers.add(worker(@["log", root / ("log-ready-" & $index),
              "worker-" & $index, $limit]))
          finish(workers)
        finally:
          cleanup(workers)
        let content = readFile(getLogFilePath())
        var seen = initHashSet[string]()
        for entry in content.strip().split("\n\n"):
          let rows = entry.splitLines()
          require rows.len == 4
          let query = parseJson(rows[0].split("query: ", 1)[1]).getStr()
          let command = parseJson(rows[1].split("command: ", 1)[1]).getStr()
          let output = parseJson(rows[3].split("output: ", 1)[1]).getStr()
          check command == query
          check output == query & "\n\nend"
          check query notin seen
          seen.incl(query)
        check seen.len == (if limit == 0: 32 else: limit)

  test "clean participates in the log writer lock":
    isolatedState:
      logExecution("one", "pwd", "one", 0)
      logExecution("two", "pwd", "two", 0)
      let initial = readFile(getLogFilePath())
      let marker = root / "clean-ready"
      let removed = root / "clean-count"
      var workers: seq[Process] = @[]
      defer: cleanup(workers)
      let lock = acquireFileLock(getLogFilePath() & ".lock")
      try:
        workers.add(worker(@["clean", marker, removed]))
        waitReady(@[marker])
        sleep(100)
        check workers[0].running
        check readFile(getLogFilePath()) == initial
      finally:
        releaseFileLock(lock)
      finish(workers)
      check readFile(removed) == "2"
      check readFile(getLogFilePath()) == ""

  test "contention times out and a terminated owner releases its lock":
    isolatedState:
      let path = root / "crash.lock"
      let marker = root / "owner-ready"
      var workers = @[worker(@["hold", marker, path])]
      defer: cleanup(workers)
      waitReady(@[marker])
      workers.add(worker(@["timeout", root / "unused", path]))
      check workers[1].waitForExit(5_000) == 42
      workers[0].terminate()
      discard workers[0].waitForExit(5_000)
      let recovered = acquireFileLock(path, timeoutMs = 1_000)
      releaseFileLock(recovered)
      check fileExists(path)

  when defined(posix):
    test "a lock cannot follow a symbolic link":
      isolatedState:
        let target = root / "unrelated"
        let path = root / "symlink.lock"
        writeFile(target, "unchanged")
        createSymlink(target, path)
        expect FileLockError:
          discard acquireFileLock(path)
        check readFile(target) == "unchanged"
