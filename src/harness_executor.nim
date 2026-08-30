## Bounded batch execution for get v3 harness tool calls.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: harness_executor.nim
## :License: AGPL-3.0
##
## This module executes already-authorized read-only shell calls with stable
## ordering and bounded concurrency. Dedicated threads are used only for
## parallel subprocess pipe draining because Nim's portable process streams
## are blocking; model networking remains asynchronous in the LLM module.

{.experimental: "strictFuncs".}

import std/[strformat]

import exec
import harness_protocol
import harness_types
import utils

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Carries one completed worker value through a thread-safe channel.
type
  WorkerResult = object
    index: int                   ## Original batch position.
    observation: ToolObservation ## Successful observation value.
    errorMessage: string         ## Sanitized worker failure, if any.

## Carries one authorized call through the worker task channel.
type
  WorkerTask = object
    index: int    ## Original batch position, or negative for shutdown.
    call: ToolCall ## Already-authorized tool call.

## Supplies shared queues and immutable execution settings to a worker.
type
  WorkerArguments = object
    shell: string                   ## Effective shell executable.
    budget: RunBudget               ## Timeout and output limits.
    tasks: ptr Channel[WorkerTask]   ## Shared pending-task channel.
    results: ptr Channel[WorkerResult] ## Shared result channel.

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Converts one process result into a typed tool observation.
##
## :param call: Originating authorized tool call.
## :param value: Bounded process result.
## :returns: Provider-independent observation.
func implObservation(call: ToolCall, value: ExecResult): ToolObservation =
  result = ToolObservation(
    callId: call.id,
    toolName: call.toolName,
    command: call.command,
    output: value.output,
    exitCode: value.exitCode,
    elapsedMs: value.elapsedMs,
    timedOut: value.timedOut,
    truncated: value.truncated,
    policyRejected: false
  )

## Executes one authorized tool call synchronously.
##
## :param call: Validated and policy-approved call.
## :param shell: Effective shell executable.
## :param budget: Command deadline and capture cap.
## :returns: Bounded observation.
## :raises: GetError: If the shell cannot be started.
proc implExecuteOne(
  call: ToolCall,
  shell: string,
  budget: RunBudget
): ToolObservation {.gcsafe.} =
  if call.toolName != READ_ONLY_SHELL_TOOL:
    raise newException(GetError,
      fmt"unsupported executable tool '{call.toolName}'")
  let value = executeCommandBounded(
    call.command,
    shell,
    budget.commandTimeoutSec,
    budget.maxOutputBytes,
    readOnlySandbox = true
  )
  result = implObservation(call, value)

## Drains authorized calls from the work queue and reports every completion.
##
## :param arguments: Shared queues plus immutable execution settings.
proc implWorker(arguments: WorkerArguments) {.thread, gcsafe.} =
  while true:
    let task = arguments.tasks[].recv()
    if task.index < 0:
      return
    try:
      let observation = implExecuteOne(
        task.call,
        arguments.shell,
        arguments.budget
      )
      arguments.results[].send(WorkerResult(
        index: task.index,
        observation: observation,
        errorMessage: ""
      ))
    except CatchableError as error:
      arguments.results[].send(WorkerResult(
        index: task.index,
        observation: ToolObservation(),
        errorMessage: error.msg
      ))

## Executes a complete batch through a bounded dynamic worker pool.
##
## :param calls: Complete authorized batch.
## :param workerCount: Positive number of persistent worker threads.
## :param shell: Effective shell executable.
## :param budget: Command deadline and capture cap.
## :returns: Observations in original call order.
## :raises: GetError: If any worker fails to start its command.
proc implExecuteParallel(
  calls: seq[ToolCall],
  workerCount: int,
  shell: string,
  budget: RunBudget
): seq[ToolObservation] =
  var taskChannel: Channel[WorkerTask]
  var resultChannel: Channel[WorkerResult]
  taskChannel.open(calls.len + workerCount)
  resultChannel.open(calls.len)
  for index, call in calls:
    taskChannel.send(WorkerTask(index: index, call: call))
  for _ in 0 ..< workerCount:
    taskChannel.send(WorkerTask(
      index: -1,
      call: ToolCall(
        id: "",
        toolName: "",
        command: "",
        purpose: "",
        resultMode: trmReturnRaw
      )
    ))

  var threads = newSeq[Thread[WorkerArguments]](workerCount)
  for index in 0 ..< workerCount:
    createThread(threads[index], implWorker, WorkerArguments(
      shell: shell,
      budget: budget,
      tasks: addr taskChannel,
      results: addr resultChannel
    ))

  result = newSeq[ToolObservation](calls.len)
  var firstError = ""
  for _ in 0 ..< calls.len:
    let workerResult = resultChannel.recv()
    if workerResult.errorMessage.len > 0:
      if firstError.len == 0:
        firstError = workerResult.errorMessage
    else:
      result[workerResult.index] = workerResult.observation
  for thread in threads:
    joinThread(thread)
  taskChannel.close()
  resultChannel.close()
  if firstError.len > 0:
    raise newException(GetError, firstError)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Executes an authorized tool batch with bounded concurrency.
##
## The caller must run every command through the central safety policy before
## invoking this function. A concurrency value of one avoids worker overhead.
## A fixed worker pool pulls the next call as soon as any worker is free, and
## results always preserve model call order.
##
## :param calls: Validated and authorized read-only shell calls.
## :param shell: Effective shell executable.
## :param budget: Per-command deadline and capture cap.
## :param maxParallel: Maximum calls active at the same time.
## :returns: One observation per call in stable input order.
## :raises: GetError: If inputs are invalid or a command cannot start.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc executeToolBatch*(
  calls: seq[ToolCall],
  shell: string,
  budget: RunBudget,
  maxParallel: int
): seq[ToolObservation] =
  if shell.len == 0:
    raise newException(GetError, "tool executor requires a shell")
  if maxParallel <= 0:
    raise newException(GetError,
      "tool executor parallelism must be positive")
  if calls.len == 0:
    return @[]
  if maxParallel == 1 or calls.len == 1:
    result = newSeq[ToolObservation](calls.len)
    for index, call in calls:
      result[index] = implExecuteOne(call, shell, budget)
    return
  result = implExecuteParallel(
    calls,
    min(maxParallel, calls.len),
    shell,
    budget
  )
