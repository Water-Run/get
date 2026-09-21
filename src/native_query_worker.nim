## Keep potentially slow filesystem reads cancellable through the process runner.
import std/[json, os, times, tempfiles]
import exec, harness_types, query_adapters, query_environment, tool_registry, git_query, observations

var nativeQueryWorkerEnabled = false

proc dispatchNativeQueryWorker*() =
  nativeQueryWorkerEnabled = true
  if paramCount() == 0 or paramStr(1) != "--internal-native-query": return
  if paramCount() != 5: quit(126)
  enterQueryWorker()
  try:
    let call = decodeCachedQueryPlan(paramStr(2))
    let gitReader = gitQueryWords(call, call.shell).len > 0
    if call.invocationKind notin {tikReadFile, tikSearchFiles} and not gitReader: quit(126)
    let timeout = parseJson(paramStr(3)).getInt
    let maximum = parseJson(paramStr(4)).getInt
    if timeout notin 1 .. 3600 or maximum notin 1 .. 100_000_000: quit(126)
    var value: ToolObservation
    let budget = RunBudget(commandTimeoutSec: timeout, maxOutputBytes: maximum)
    if gitReader:
      let observed = executeGitQuery(call, call.shell, budget, paramStr(5))
      value = ToolObservation(output: observed.output, stdout: observed.stdout,
        stderr: observed.stderr, exitCode: observed.exitCode,
        timedOut: observed.timedOut, truncated: observed.truncated,
        status: queryResultStatus(call, observed.exitCode, call.shell),
        source: "host Git snapshot; executable filters and submodule inspection disabled")
    else:
      value = executeBuiltinQuery(call, budget)
    stdout.write($(%*{"output": value.output, "exit_code": value.exitCode,
      "status": ord(value.status), "more": value.moreData,
      "timed_out": value.timedOut, "truncated": value.truncated,
      "source": value.source, "stdout": value.stdout, "stderr": value.stderr}))
    quit(0)
  except CatchableError as error:
    stderr.writeLine(redactEnvironmentSecrets(error.msg))
    quit(126)

proc executeNativeQuery*(call: ToolCall, budget: RunBudget, shell = ""): ToolObservation {.gcsafe.} =
  if not nativeQueryWorkerEnabled or call.invocationKind == tikEnvironment:
    return executeBuiltinQuery(call, budget)
  result = ToolObservation(callId: call.id, toolName: call.toolName,
    command: call.command, argumentsJson: call.argumentsJson,
    identity: queryIdentity(call), required: call.required, evidenceKey: call.evidenceKey,
    sampledAt: now().utc.format("yyyy-MM-dd'T'HH:mm:ss'Z'"), source: "host file reader")
  let timeout = if budget.commandTimeoutSec > 0: budget.commandTimeoutSec else: 30
  let maximum = if budget.maxOutputBytes > 0: budget.maxOutputBytes else: DEFAULT_MAX_OUTPUT_BYTES
  var arguments = if call.argumentsJson.len > 0: parseJson(call.argumentsJson) else: newJObject()
  if call.invocationKind == tikShell:
    arguments["command"] = %call.command
    arguments["shell"] = %(if call.shell.len > 0: call.shell else: shell)
  let plan = $(%*{"tool": call.toolName, "arguments": arguments})
  var scratch = ""
  if gitQueryWords(call, shell).len > 0:
    scratch = createTempDir("get-git-query-", "")
    when defined(posix):
      setFilePermissions(scratch, {fpUserRead, fpUserWrite, fpUserExec})
  defer:
    if scratch.len > 0: removeDir(scratch)
  let value = executeProcessBounded(getAppFilename(),
    @["--internal-native-query", plan, $timeout, $maximum, scratch],
    timeout, min(100_000_000, maximum * 6 + 4096), readOnlySandbox = false)
  result.elapsedMs = value.elapsedMs
  if value.exitCode == 0 and not value.timedOut and not value.truncated:
    try:
      let node = parseJson(value.stdout)
      result.output = redactEnvironmentSecrets(node["output"].getStr)
      result.stdout = redactEnvironmentSecrets(node["stdout"].getStr)
      result.exitCode = node["exit_code"].getInt
      result.status = ObservationStatus(node["status"].getInt)
      result.moreData = node["more"].getBool
      result.truncated = node["truncated"].getBool
      result.timedOut = node["timed_out"].getBool
      result.source = node["source"].getStr
      result.stderr = redactEnvironmentSecrets(node["stderr"].getStr)
      return
    except CatchableError:
      discard
  result.timedOut = value.timedOut
  result.truncated = value.truncated
  result.exitCode = if value.timedOut: 124 else: 1
  result.status = if value.timedOut: osTimedOut elif value.truncated: osTruncated else: osUnavailable
  result.output = "Native reader stopped before a complete page was available. Narrow the read."
  result.stderr = redactEnvironmentSecrets(value.stderr)
