## Prompt construction and formatting for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-14
## :File: prompt.nim
## :License: AGPL-3.0
##
## This module assembles the system prompt and user prompt sent to
## the LLM for each command context: query generation, double-check
## safety review, output interpretation, and isok connectivity
## verification.  Every builder returns a seq[LlmMessage] that can
## be passed directly to the LLM client.
##
## The query prompt now includes descriptions of bundled tools
## (rg, fd, sg, pmc, treepp/tree) so the model can leverage them
## when generating commands.

{.experimental: "strictFuncs".}

import std/[options, strformat, strutils]

import sysinfo
import utils

# ---------------------------------------------------------------------------
# Constants — isok connectivity check
# ---------------------------------------------------------------------------

## System prompt instructing the model to reply with exactly "ok".
const ISOK_SYSTEM_PROMPT* =
  "Reply with exactly the word 'ok' and nothing else."

## User prompt for the isok connectivity check.
const ISOK_USER_PROMPT* = "ok"

## Maximum tokens allocated for the isok response.  The expected
## reply is a single word, so a small budget suffices.
const ISOK_MAX_TOKENS* = 32

# ---------------------------------------------------------------------------
# Public API — query prompt
# ---------------------------------------------------------------------------

## Builds the message list for the initial command-generation
## request.  The system message contains constraints (read-only,
## code-block formatting), system information, bundled tool
## documentation, the configured shell, an optional custom system
## prompt, and an optional command-pattern note.  The user message
## contains the raw query.
##
## :param info: System information snapshot.
## :param query: The user's natural-language query.
## :param shell: The shell that will execute the command.
## :param instance: When true the model is asked to produce clean
##                  human-readable output; when false the output
##                  will be interpreted by a follow-up LLM call.
## :param customPrompt: Optional user-supplied system prompt.
## :param pattern: Optional command-pattern regex note.
## :returns: A two-element seq (system, user) of LlmMessage.
##
## .. code-block:: nim
##   runnableExamples:
##     import std/options
##     let info = SysInfo(os: "linux", arch: "amd64",
##       hostname: "", username: "", cwd: "/tmp",
##       shell: "bash", shellVersion: "",
##       availableTools: @[],
##       bundledTools: @[], binDir: "")
##     let msgs = buildQueryMessages(info, "test",
##       "bash", false, none(string), none(string))
##     assert msgs.len == 2
func buildQueryMessages*(
  info: SysInfo,
  query: string,
  shell: string,
  instance: bool,
  customPrompt: Option[string],
  pattern: Option[string]
): seq[LlmMessage] =
  var sysLines: seq[string] = @[]
  sysLines.add(
    "You are a command-line assistant. Your task" &
    " is to generate a single shell command that" &
    " retrieves the information the user " &
    "requested.")
  sysLines.add("")
  sysLines.add("CONSTRAINTS:")
  sysLines.add(
    "- This tool performs read-only operations" &
    " only. NEVER generate commands that modify," &
    " delete, create, or write data.")
  sysLines.add(
    "- Wrap your command in a ```sh fenced code" &
    " block.")
  sysLines.add(
    "- Generate exactly ONE command (you may use" &
    " pipes or && to chain read-only " &
    "sub-commands).")
  sysLines.add(
    fmt"- The command must work in {shell}.")
  sysLines.add(
    "- Prefer using bundled tools listed below" &
    " when they fit the task; they are already" &
    " available in PATH.")
  if instance:
    sysLines.add(
      "- The output will be shown directly to the" &
      " user. Make it clean and human-readable.")
  else:
    sysLines.add(
      "- The output will be processed further." &
      " Focus on capturing the needed information" &
      " as completely as possible.")
  sysLines.add("")
  sysLines.add("SYSTEM INFORMATION:")
  sysLines.add(formatSysInfo(info))
  let bundledBlock = formatBundledTools(
    info.bundledTools)
  if bundledBlock.len > 0:
    sysLines.add("")
    sysLines.add(bundledBlock)
  if customPrompt.isSome:
    sysLines.add("")
    sysLines.add("ADDITIONAL INSTRUCTIONS:")
    sysLines.add(customPrompt.get)
  if pattern.isSome:
    sysLines.add("")
    sysLines.add(
      "NOTE: The generated command must match the" &
      " following regex pattern: " & pattern.get)
  let sysContent = sysLines.join("\n")
  result = @[
    LlmMessage(role: "system", content: sysContent),
    LlmMessage(role: "user", content: query)
  ]

# ---------------------------------------------------------------------------
# Public API — double-check prompt
# ---------------------------------------------------------------------------

## Builds the message list for the double-check safety review.  The
## system message contains the command, the original query, and the
## system information so that the reviewer model can assess safety.
##
## :param command: The generated command to review.
## :param query: The original user query.
## :param info: System information snapshot.
## :returns: A two-element seq (system, user) of LlmMessage.
##
## .. code-block:: nim
##   runnableExamples:
##     let info = SysInfo(os: "linux", arch: "amd64",
##       hostname: "", username: "", cwd: "/tmp",
##       shell: "bash", shellVersion: "",
##       availableTools: @[],
##       bundledTools: @[], binDir: "")
##     let msgs = buildDoubleCheckMessages(
##       "ls -la", "list files", info)
##     assert msgs.len == 2
func buildDoubleCheckMessages*(
  command: string,
  query: string,
  info: SysInfo
): seq[LlmMessage] =
  var sysLines: seq[string] = @[]
  sysLines.add(
    "You are a safety reviewer for shell commands." &
    " Examine the command below and determine if" &
    " it is read-only, safe, and correctly" &
    " addresses the user's query.")
  sysLines.add("")
  sysLines.add(fmt"User query: {query}")
  sysLines.add(fmt"Generated command: {command}")
  sysLines.add("")
  sysLines.add("SYSTEM INFORMATION:")
  sysLines.add(formatSysInfo(info))
  let bundledBlock = formatBundledTools(
    info.bundledTools)
  if bundledBlock.len > 0:
    sysLines.add("")
    sysLines.add(bundledBlock)
  sysLines.add("")
  sysLines.add(
    "If the command is UNSAFE or could modify" &
    " system state, reply with exactly the word" &
    " UNSAFE.")
  sysLines.add(
    "If the command is safe, reply with the" &
    " approved command in a ```sh code block." &
    " You may revise the command if it can be" &
    " improved while remaining read-only.")
  let sysContent = sysLines.join("\n")
  result = @[
    LlmMessage(role: "system", content: sysContent),
    LlmMessage(role: "user",
      content: "Review this command.")
  ]

# ---------------------------------------------------------------------------
# Public API — interpretation prompt
# ---------------------------------------------------------------------------

## Builds the message list for interpreting command output.  The
## system message contains the original query, the command that was
## executed, and the raw output so that the model can produce a
## concise human-readable answer.
##
## :param query: The original user query.
## :param command: The command that was executed.
## :param output: The raw output captured from the command.
## :returns: A two-element seq (system, user) of LlmMessage.
##
## .. code-block:: nim
##   runnableExamples:
##     let msgs = buildInterpretMessages(
##       "disk usage", "df -h", "50G")
##     assert msgs.len == 2
func buildInterpretMessages*(
  query: string,
  command: string,
  output: string
): seq[LlmMessage] =
  var sysLines: seq[string] = @[]
  sysLines.add(
    "You are a helpful assistant. The user asked" &
    " a question, a shell command was executed," &
    " and the output is shown below. Provide a" &
    " clear, concise answer to the user's" &
    " question based on the command output.")
  sysLines.add("")
  sysLines.add(fmt"User's question: {query}")
  sysLines.add(fmt"Command executed: {command}")
  sysLines.add("")
  sysLines.add("Command output:")
  sysLines.add(output)
  let sysContent = sysLines.join("\n")
  result = @[
    LlmMessage(role: "system", content: sysContent),
    LlmMessage(role: "user",
      content: "Answer my question based on the" &
        " command output above.")
  ]