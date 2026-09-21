import std/[envvars, json, options, os, strutils, tempfiles, unittest]
when defined(posix):
  import std/posix
import harness_protocol
import harness_types
import native_query_worker
import harness_executor
import query_adapters
import query_glob
import query_policy
import tool_registry

dispatchNativeQueryWorker()

suite "v4 typed query tools":
  test "native argv preserves metacharacters as literal data":
    let call = parseNativeToolCall("p1", "run_process",
      """{"executable":"rg","args":["--","$(touch marker)","space 目录"]}""")
    check call.invocationKind == tikProcess
    check call.executable == "rg"
    check call.argv == @["--", "$(touch marker)", "space 目录"]

  test "all registered tools decode in the native and structured protocols":
    let samples = [
      ("read_environment", """{"names":["XDG_CURRENT_DESKTOP","GET_REPLAY_LABEL"]}"""),
      ("read_file", """{"path":"中文/a b.txt","start_line":20,"limit":10}"""),
      ("search_files", """{"path":".","pattern":"*.nim","offset":20,"include_ignored":true}"""),
      ("run_process", """{"executable":"uname","args":["-a"]}"""),
      ("run_shell", """{"command":"echo $SHELL","shell":"fish","fresh":true}""")]
    for (name, raw) in samples:
      let native = parseNativeToolCall("call", name, raw)
      let structured = parseStructuredAction($(%*{"type": "tool_calls",
        "calls": [{"id": "call", "tool": name, "arguments": parseJson(raw)}]})).get
      check native.invocationKind == structured.calls[0].invocationKind
      check native.command == structured.calls[0].command
      check native.argumentsJson == structured.calls[0].argumentsJson
    check queryToolDefinitions().len == 5

  test "invalid typed fields do not become executable calls":
    for (name, raw) in [
      ("run_process", """{"executable":"sh","args":"-c touch marker"}"""),
      ("run_process", """{"executable":"cat","args":["\u0000"]}"""),
      ("read_environment", """{"names":["HOME; touch marker"]}"""),
      ("read_file", """{"path":"file","limit":1001}"""),
      ("read_file", """{"path":"file","start_line":0}"""),
      ("search_files", """{"include_ignored":"false"}"""),
      ("run_shell", """{"command":"pwd","approved":true}""")]:
      expect ValueError:
        discard parseNativeToolCall("bad", name, raw)

  test "legacy shell tool remains an explicit protocol alias":
    let call = parseNativeToolCall("old", "run_readonly_shell",
      """{"command":"pwd","result_mode":"return_raw"}""")
    check call.invocationKind == tikShell
    check call.command == "pwd"
    check call.resultMode == trmReturnRaw

  test "tool schemas and argument validation reject unknown fields together":
    for definition in queryToolDefinitions():
      let schema = parseJson(definition.parametersJson)
      check not schema["additionalProperties"].getBool
      check schema["properties"].hasKey("required")
      check schema["properties"].hasKey("fresh")

suite "v4 native observations":
  test "a missing file is negative evidence, but a directory is a reader error":
    let root = createTempDir("get-v4-absent-", "")
    defer: removeDir(root)
    let missing = parseNativeToolCall("absent", "read_file", $(%*{
      "path": root / "absent.txt", "required": true}))
    let value = executeAuthorizedBatch(@[authorizeQuery(missing, "bash").plan],
      "bash", defaultRunBudget(hkAuto), 1)[0]
    check value.status == osNoMatch
    check value.exitCode == 0
    check not parseJson(value.output)["exists"].getBool
    let directory = parseNativeToolCall("directory", "read_file", $(%*{"path": root}))
    let invalid = executeBuiltinQuery(directory, defaultRunBudget(hkAuto))
    check invalid.status == osUnavailable
    check invalid.exitCode != 0

  test "environment values preserve missing/empty semantics and mask credentials":
    putEnv("GET_V4_FIXTURE_LABEL", "value with spaces; $(echo data)")
    putEnv("GET_V4_FIXTURE_EMPTY", "")
    putEnv("GET_V4_FIXTURE_TOKEN", "fixture-secret-123")
    defer:
      delEnv("GET_V4_FIXTURE_LABEL")
      delEnv("GET_V4_FIXTURE_EMPTY")
      delEnv("GET_V4_FIXTURE_TOKEN")
    let call = parseNativeToolCall("env", "read_environment", """{
      "names":["GET_V4_FIXTURE_LABEL","GET_V4_FIXTURE_EMPTY",
        "GET_V4_FIXTURE_MISSING","GET_V4_FIXTURE_TOKEN"]}""")
    let decision = authorizeQuery(call, "bash")
    check decision.kind == qdAllowed
    let value = executeBuiltinQuery(decision.plan.call, defaultRunBudget(hkAuto))
    let data = parseJson(value.output)["values"]
    check data["GET_V4_FIXTURE_LABEL"].getStr == "value with spaces; $(echo data)"
    check data["GET_V4_FIXTURE_EMPTY"].getStr == ""
    check data["GET_V4_FIXTURE_MISSING"].kind == JNull
    check data["GET_V4_FIXTURE_TOKEN"].getStr == "[redacted]"

  test "file pages preserve line identity across Unicode and space paths":
    let root = createTempDir("get-v4-query-", "")
    defer: removeDir(root)
    let path = root / "space 中文.txt"
    writeFile(path, "zero\none\ntwo\nthree\nfour\n")
    let call = parseNativeToolCall("file", "read_file", $(%*{
      "path": path, "start_line": 2, "limit": 2}))
    let value = executeBuiltinQuery(call, defaultRunBudget(hkAuto))
    check value.exitCode == 0
    let data = parseJson(value.output)
    check data["lines"].len == 2
    check data["lines"][0]["line"].getInt == 2
    check data["lines"][0]["text"].getStr == "one"
    check data["lines"][1]["text"].getStr == "two"
    check data["next_line"].getInt == 4
    check data["has_more"].getBool
    let second = parseNativeToolCall("next", "read_file", $(%*{
      "path": path, "start_line": data["next_line"].getInt, "limit": 2}))
    let last = parseJson(executeBuiltinQuery(second, defaultRunBudget(hkAuto)).output)
    check last["lines"][0]["text"].getStr == "three"
    check not last["has_more"].getBool

  test "file listing honors nested ignores, negation, generated trees and pagination":
    let root = createTempDir("get-v4-search-", "")
    defer: removeDir(root)
    createDir(root / "src")
    createDir(root / "nested" / "build")
    writeFile(root / ".gitignore", "*.py\n!keep.py\n")
    writeFile(root / "keep.py", "included\n")
    writeFile(root / "skip.py", "excluded\n")
    writeFile(root / "src" / ".gitignore", "local.nim\n")
    writeFile(root / "src" / "local.nim", "excluded\n")
    writeFile(root / "src" / "app.nim", "needle\n")
    writeFile(root / "nested" / "build" / "generated.nim", "excluded\n")
    let call = parseNativeToolCall("list", "search_files", $(%*{
      "path": root, "pattern": "*.nim", "limit": 1}))
    let data = parseJson(executeBuiltinQuery(call, defaultRunBudget(hkAuto)).output)
    check data["observed_matches"].getInt == 1
    check data["matches"][0]["path"].getStr == "src/app.nim"
    check data["complete"].getBool
    let allFiles = parseNativeToolCall("all", "search_files", $(%*{
      "path": root, "pattern": "*.nim", "include_ignored": true, "limit": 1}))
    let allData = parseJson(executeBuiltinQuery(allFiles, defaultRunBudget(hkAuto)).output)
    check allData["observed_matches"].getInt == 3
    check allData["has_more"].getBool
    let py = parseNativeToolCall("py", "search_files", $(%*{"path": root, "pattern": "*.py"}))
    let pyData = parseJson(executeBuiltinQuery(py, defaultRunBudget(hkAuto)).output)
    check pyData["observed_matches"].getInt == 1
    check pyData["matches"][0]["path"].getStr == "keep.py"

  test "literal content search distinguishes a match from no match":
    let root = createTempDir("get-v4-match-", "")
    defer: removeDir(root)
    writeFile(root / "data.txt", "first\n[needle].*\nlast\n")
    let call = parseNativeToolCall("match", "search_files", $(%*{
      "path": root, "pattern": "[needle].*", "content": true}))
    let data = parseJson(executeBuiltinQuery(call, defaultRunBudget(hkAuto)).output)
    check data["observed_matches"].getInt == 1
    check data["matches"][0]["line"].getInt == 2
    let absent = parseNativeToolCall("absent", "search_files", $(%*{
      "path": root, "pattern": "absent", "content": true}))
    check executeBuiltinQuery(absent, defaultRunBudget(hkAuto)).status == osNoMatch

  when defined(posix):
    test "FIFO reads fail promptly instead of waiting for a writer":
      let root = createTempDir("get-v4-fifo-", "")
      defer: removeDir(root)
      let fifo = root / "pipe"
      require mkfifo(fifo.cstring, Mode(0o600)) == 0
      let call = parseNativeToolCall("fifo", "read_file", $(%*{"path": fifo}))
      let value = executeBuiltinQuery(call, defaultRunBudget(hkAuto))
      check value.status == osUnavailable
      check value.output.contains("regular file")

    test "argv execution never expands data into a second shell command":
      let root = createTempDir("get-v4-argv-", "")
      defer: removeDir(root)
      let marker = root / "never-created"
      let text = "$(touch " & marker & "); echo not-another-command"
      let call = parseNativeToolCall("argv", "run_process", $(%*{
        "executable": "printf", "args": ["%s", text], "cwd": root}))
      let decision = authorizeQuery(call, "bash")
      require decision.kind == qdAllowed
      let values = executeAuthorizedBatch(@[decision.plan], "bash", defaultRunBudget(hkAuto), 1)
      check values[0].exitCode == 0
      check values[0].output == text
      check not fileExists(marker)

suite "bounded query glob matching":
  test "recursive directories, classes and literal Unicode names":
    check queryGlobMatches("main.nim", "**/*.nim")
    check queryGlobMatches("a/b/main.nim", "**/*.nim")
    check not queryGlobMatches("a/main.nim", "*.nim")
    check queryGlobMatches("test5.py", "test[0-9].py")
    check not queryGlobMatches("testa.py", "test[0-9].py")
    check queryGlobMatches("中文/a b.txt", "中文/*.txt")
    check queryGlobMatches("a.py", "[!0-9].py")


suite "v4 process observation semantics":
  when defined(posix):
    test "a literal process can report a false condition without failing evidence":
      let call = parseNativeToolCall("missing", "run_process", """{"executable":"test","args":["-e","/GET_V4_NONEXISTENT_FIXTURE_PATH"]}""")
      let values = executeToolBatch(@[call], "bash", defaultRunBudget(hkAuto), 1)
      check values[0].exitCode == 1
      check values[0].status == osNoMatch
