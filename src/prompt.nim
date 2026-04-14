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
## safety review, output interpretation, cache-worthiness check,
## and isok connectivity verification.  Every builder returns a
## seq[LlmMessage] that can be passed directly to the LLM client.
##
## The query prompt includes descriptions of bundled tools
## (rg, fd, sg, pmc, treepp/tree, tokei, lua) so the model can
## leverage them when generating commands.  All prompts strongly
## enforce the read-only constraint and instruct the model to
## refuse generation rather than produce potentially destructive
## commands.
##
## The query prompt also instructs the model to annotate its
## response with ``<!-- DIRECT -->`` or ``<!-- INTERPRET -->`` so
## that the caller can decide whether to show command output raw
## or pass it back for LLM interpretation.

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

## Maximum tokens allocated for the isok response.
const ISOK_MAX_TOKENS* = 32

# ---------------------------------------------------------------------------
# Constants — cache worthiness check
# ---------------------------------------------------------------------------

## Maximum tokens allocated for the cache-check response.
const CACHE_CHECK_MAX_TOKENS* = 32

# ---------------------------------------------------------------------------
# Public API — query prompt
# ---------------------------------------------------------------------------

## Builds the message list for the initial command-generation
## request.  The system message contains strict read-only
## constraints, system information, bundled tool documentation,
## the configured shell, an optional custom system prompt, and
## an optional command-pattern note.
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
    "requested. Focus on directly executing " &
    "tools and commands to obtain the answer " &
    "rather than relying on further processing.")
  sysLines.add("")
  sysLines.add("STRICT READ-ONLY CONSTRAINTS " &
    "(VIOLATION IS FORBIDDEN):")
  sysLines.add(
    "- This tool performs READ-ONLY operations " &
    "ONLY. You MUST NEVER generate commands that " &
    "modify, delete, create, write, move, rename," &
    " or alter ANY data, files, directories, " &
    "system settings, or external state.")
  sysLines.add(
    "- If the user's query CANNOT be answered " &
    "with a purely read-only command, respond " &
    "with a plain text explanation instead of a " &
    "code block. NEVER generate a destructive " &
    "command even if the user asks for it.")
  sysLines.add(
    "- Commands like rm, del, mv, cp, mkdir, " &
    "touch, chmod, chown, tee, write, " &
    "Set-Content, New-Item, Remove-Item, " &
    "Move-Item, redirect (>), append (>>), " &
    "and similar are STRICTLY FORBIDDEN.")
  sysLines.add(
    "- For bundled tools: NEVER use flags that " &
    "write files or modify state " &
    "(e.g. pmc -o/-c, tree -o/--output, " &
    "treepp /O, fd -x with write commands).")
  sysLines.add("")
  sysLines.add("FORMAT:")
  sysLines.add(
    "- Wrap your command in a ```sh fenced code" &
    " block.")
  sysLines.add(
    "- Generate exactly ONE command (you may use" &
    " pipes or && to chain read-only " &
    "sub-commands).")
  sysLines.add(
    fmt"- The command must work in {shell}." &
    " Ensure correct syntax for this shell.")
  sysLines.add(
    "- Prefer using bundled tools listed below" &
    " when they fit the task; they are already" &
    " available in PATH and guaranteed to work.")
  sysLines.add(
    "- Verify your command mentally before " &
    "outputting — check flag names, argument " &
    "order, and shell quoting.")
  if instance:
    sysLines.add(
      "- The output will be shown directly to the" &
      " user. Make it clean and human-readable.")
  else:
    sysLines.add(
      "- After the code block, on a NEW line, " &
      "add exactly ONE of these markers:")
    sysLines.add(
      "  <!-- DIRECT --> if the command output is " &
      "self-explanatory and can be shown directly" &
      " to the user (e.g. tree output, version " &
      "info, file listings, code content, " &
      "network info, system stats, IP addresses," &
      " directory structures, tool output).")
    sysLines.add(
      "  <!-- INTERPRET --> if the command output " &
      "needs interpretation or summarisation to " &
      "answer the user's question (e.g. complex " &
      "log analysis, multi-step reasoning about " &
      "output, comparing multiple data sources).")
    sysLines.add(
      "  Default to <!-- DIRECT --> when " &
      "uncertain. Most queries should use " &
      "DIRECT.")
  sysLines.add("")
  sysLines.add("TOOL SELECTION GUIDANCE:")
  sysLines.add(
    "- For directory tree visualisation: use " &
    "`tree` (Linux) or `treepp` (Windows).")
  sysLines.add(
    "- For searching file contents: use `rg` " &
    "(ripgrep).")
  sysLines.add(
    "- For finding files by name: use `fd`.")
  sysLines.add(
    "- For packaging code context: use `pmc`.")
  sysLines.add(
    "- For code statistics (lines of code): " &
    "use `tokei`.")
  sysLines.add(
    "- For calculations or text processing: " &
    "use `lua -e '<code>'`.")
  sysLines.add(
    "- For AST-level code search: use `sg` " &
    "(ast-grep).")
  sysLines.add(
    "- For syntax-highlighted file viewing: " &
    "use `bat` (e.g. bat --style=plain " &
    "--paging=never <file>).")
  sysLines.add(
    "- For Markdown rendering in terminal: " &
    "use `mdcat` (e.g. mdcat --no-pager " &
    "<file>).")
  sysLines.add(
    "- If the user's request clearly requires " &
    "a third-party library or tool that is not " &
    "available, explain what is needed rather " &
    "than generating a command that will fail.")
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
      "NOTE: The generated command MUST NOT match" &
      " the following forbidden-command regex " &
      "pattern: " & pattern.get &
      ". If your command would match this " &
      "pattern, respond with a plain text " &
      "explanation instead.")
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
## system information so that the reviewer model can assess whether
## the command is strictly read-only and safe.
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
    "You are a strict safety reviewer for shell " &
    "commands. Your ONLY job is to determine " &
    "whether the command below is PURELY " &
    "READ-ONLY and safe to execute.")
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
    "RULES:")
  sysLines.add(
    "- If the command could MODIFY, DELETE, " &
    "CREATE, WRITE, MOVE, or ALTER any file, " &
    "directory, system setting, or external " &
    "state in ANY way, reply with exactly the " &
    "word UNSAFE.")
  sysLines.add(
    "- Forbidden operations include but are not " &
    "limited to: rm, del, mv, cp, mkdir, touch, " &
    "chmod, chown, tee, redirect (>), append " &
    "(>>), write flags on bundled tools " &
    "(pmc -o/-c, tree -o, treepp /O, " &
    "fd -x with write commands).")
  sysLines.add(
    "- If the command is safe and purely read-" &
    "only, reply with the approved command in a " &
    "```sh code block. You may revise the " &
    "command to improve it while keeping it " &
    "strictly read-only.")
  let sysContent = sysLines.join("\n")
  result = @[
    LlmMessage(role: "system", content: sysContent),
    LlmMessage(role: "user",
      content: "Review this command.")
  ]

# ---------------------------------------------------------------------------
# Public API — interpretation prompt
# ---------------------------------------------------------------------------

## Builds the message list for interpreting command output.
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
    " question based on the command output." &
    " Focus on extracting and presenting the" &
    " relevant information directly.")
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

# ---------------------------------------------------------------------------
# Public API — cache-worthiness check prompt
# ---------------------------------------------------------------------------

## Builds the message list for the cache-worthiness check.  The
## model evaluates whether the query result is stable enough to
## cache for future reuse.
##
## :param query: The original user query.
## :param command: The command that was executed (may be empty).
## :param outputPreview: A truncated preview of the output.
## :returns: A two-element seq (system, user) of LlmMessage.
##
## .. code-block:: nim
##   runnableExamples:
##     let msgs = buildCacheCheckMessages(
##       "system version", "uname -a", "Linux 6.1")
##     assert msgs.len == 2
func buildCacheCheckMessages*(
  query: string,
  command: string,
  outputPreview: string
): seq[LlmMessage] =
  var sysLines: seq[string] = @[]
  sysLines.add(
    "Determine if this query result should be " &
    "cached for future reuse.")
  sysLines.add("")
  sysLines.add(
    "A result SHOULD be cached (CACHE) if it is " &
    "STABLE — the same query would produce the " &
    "same or very similar output when run again " &
    "in the same working directory. Examples: " &
    "system version, installed software, project " &
    "structure, file contents, code analysis, " &
    "static configuration.")
  sysLines.add("")
  sysLines.add(
    "A result should NOT be cached (NOCACHE) if " &
    "it is VOLATILE — it changes frequently or " &
    "depends on the current moment. Examples: " &
    "current time, CPU/memory usage, running " &
    "processes, network status, live metrics, " &
    "disk space, recent log entries, git status " &
    "with uncommitted changes.")
  sysLines.add("")
  sysLines.add(
    "Reply with exactly CACHE or NOCACHE.")
  let sysContent = sysLines.join("\n")
  var userLines: seq[string] = @[]
  userLines.add(fmt"Query: {query}")
  if command.len > 0:
    userLines.add(fmt"Command: {command}")
  if outputPreview.len > 0:
    userLines.add(
      fmt"Output preview: {outputPreview}")
  let userContent = userLines.join("\n")
  result = @[
    LlmMessage(role: "system", content: sysContent),
    LlmMessage(role: "user", content: userContent)
  ]