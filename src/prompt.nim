## Prompt construction and formatting for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-19
## :File: prompt.nim
## :License: AGPL-3.0
##
## This module assembles system and user prompts for every LLM
## interaction context: instance-mode single-call generation,
## multi-round agent-loop orchestration, double-check safety
## review, output interpretation, cache-worthiness evaluation,
## and isok connectivity verification.
##
## The agent loop protocol defines four possible LLM actions:
##   CONTINUE  — intermediate command; execute and feed back.
##   FINAL     — terminal command; execute and show directly.
##   INTERPRET — terminal command; execute then summarise.
##   (no code block) — direct text answer from the LLM.
## The default when no marker is present is FINAL, reflecting
## get's preference for direct command output over interpretation.

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
# Private helpers — shared context block
# ---------------------------------------------------------------------------

## Builds the shared context block included in both instance and
## agent system prompts: read-only constraints, format rules,
## shell-specific syntax rules, tool selection guidance, system
## information, bundled tools, optional custom prompt, and
## optional command-pattern note.
##
## The shell-specific section is derived from the ``shell``
## parameter and injects a strong, family-appropriate syntax
## contract (PowerShell / cmd.exe / POSIX).  This is necessary
## because the generic phrase "use correct syntax for this
## shell" has proven too weak in practice: models routinely
## produce Unix-style ``pwd`` / ``ls`` / ``grep`` invocations
## even when the target shell is PowerShell, relying on alias
## compatibility that breaks as soon as pipelines or flags
## diverge from the alias surface.
##
## :param info: System information snapshot.
## :param shell: The shell that will execute commands.
## :param customPrompt: Optional user-supplied system prompt.
## :param pattern: Optional forbidden-command regex note.
## :returns: The multi-line context string.
func implBuildBaseContext(
  info: SysInfo,
  shell: string,
  customPrompt: Option[string],
  pattern: Option[string]
): string =
  var lines: seq[string] = @[]
  lines.add("STRICT READ-ONLY CONSTRAINTS " &
    "(VIOLATION IS FORBIDDEN):")
  lines.add(
    "- This tool performs READ-ONLY operations " &
    "ONLY. You MUST NEVER generate commands that " &
    "modify, delete, create, write, move, rename," &
    " or alter ANY data, files, directories, " &
    "system settings, or external state.")
  lines.add(
    "- If the user's query CANNOT be answered " &
    "with a purely read-only command, respond " &
    "with a plain text explanation instead of a " &
    "code block. NEVER generate a destructive " &
    "command even if the user asks for it.")
  lines.add(
    "- Commands like rm, del, mv, cp, mkdir, " &
    "touch, chmod, chown, tee, write, " &
    "Set-Content, New-Item, Remove-Item, " &
    "Move-Item, redirect (>), append (>>), " &
    "and similar are STRICTLY FORBIDDEN.")
  lines.add(
    "- For bundled tools: NEVER use flags that " &
    "write files or modify state " &
    "(e.g. pmc -o/-c, tree -o/--output, " &
    "treepp /O, fd -x with write commands).")
  lines.add("")
  lines.add("COMMAND FORMAT:")
  lines.add(
    "- Wrap every command in a ```sh fenced " &
    "code block.")
  lines.add(
    "- Generate exactly ONE command per code " &
    "block (you may use pipes or && to chain " &
    "read-only sub-commands).")
  lines.add(
    fmt"- The command must work in {shell}. " &
    "Ensure correct syntax for this shell, " &
    "following the shell-specific rules below.")
  lines.add(
    "- Prefer using bundled tools listed below " &
    "when they fit the task; they are already " &
    "available in PATH and guaranteed to work.")
  lines.add(
    "- Verify your command mentally before " &
    "outputting — check flag names, argument " &
    "order, and shell quoting.")

  let shellLower = toLowerAscii(shell)
  if shellLower.contains("powershell") or
      shellLower.contains("pwsh"):
    lines.add("")
    lines.add(
      "POWERSHELL-SPECIFIC RULES (MANDATORY):")
    lines.add(
      "- The target shell is PowerShell. You " &
      "MUST use native PowerShell cmdlets, NOT " &
      "Unix-style aliases or POSIX utilities. " &
      "Even when an alias exists (e.g. `pwd`, " &
      "`ls`, `cat`, `ps`, `cp`, `mv`), ALWAYS " &
      "prefer the full cmdlet form. This rule " &
      "is not optional.")
    lines.add(
      "- Required cmdlet mappings you MUST " &
      "follow for read-only operations:")
    lines.add(
      "    pwd           -> Get-Location")
    lines.add(
      "    ls / dir      -> Get-ChildItem")
    lines.add(
      "    cat / type    -> Get-Content")
    lines.add(
      "    ps            -> Get-Process")
    lines.add(
      "    grep          -> Select-String")
    lines.add(
      "    head / tail   -> Select-Object " &
      "-First N / -Last N")
    lines.add(
      "    wc -l         -> (Get-Content ...)" &
      ".Count  or  Measure-Object -Line")
    lines.add(
      "    which / where -> Get-Command")
    lines.add(
      "    env           -> Get-ChildItem Env:")
    lines.add(
      "    df / du       -> Get-PSDrive  or  " &
      "Get-Volume")
    lines.add(
      "    uname / id    -> $PSVersionTable, " &
      "[Environment]::OSVersion, whoami")
    lines.add(
      "    curl / wget   -> Invoke-WebRequest " &
      "(read-only: -Method Get only, no -OutFile)")
    lines.add(
      "- PowerShell pipelines pass OBJECTS, not " &
      "text. Use `| Select-Object`, " &
      "`| Where-Object { $_.Prop -eq ... }`, " &
      "`| Sort-Object`, `| Measure-Object` with " &
      "script blocks instead of awk/sed/cut.")
    lines.add(
      "- Use backtick (`) for line continuation," &
      " NEVER backslash. Use `;` to chain on a " &
      "single line. Prefer `;` over `&&` because " &
      "`&&` is only available in PowerShell 7+; " &
      "if you are unsure of the host version, " &
      "avoid `&&`.")
    lines.add(
      "- Quote arguments with single quotes to " &
      "suppress variable expansion; use double " &
      "quotes only when you intend `$var` " &
      "interpolation.")
    lines.add(
      "- Native Windows tools (ipconfig, " &
      "systeminfo, netstat, tasklist, " &
      "Get-NetIPAddress, Get-NetAdapter) ARE " &
      "allowed and often preferable. Prefer " &
      "Get-NetIPAddress / Get-NetAdapter over " &
      "ipconfig when a structured result is " &
      "needed.")
    lines.add(
      "- Forbidden in PowerShell (write-mode): " &
      "Set-Content, Add-Content, Clear-Content, " &
      "New-Item, Remove-Item, Move-Item, " &
      "Rename-Item, Out-File, Tee-Object, " &
      "Stop-Process, Stop-Service, Start-Service," &
      " Set-* cmdlets, any use of `>` or `>>` " &
      "redirection.")
  elif shellLower.contains("cmd"):
    lines.add("")
    lines.add("CMD.EXE-SPECIFIC RULES:")
    lines.add(
      "- The target shell is cmd.exe. Use " &
      "classic Windows shell syntax: `dir`, " &
      "`type`, `where`, `set`, `findstr`, " &
      "`ipconfig`, `systeminfo`, `tasklist`.")
    lines.add(
      "- Chain commands with `&` (always) or " &
      "`&&` (only on success). Use `^` for line " &
      "continuation.")
    lines.add(
      "- Variables use `%VAR%` expansion. " &
      "Quote paths with spaces using double " &
      "quotes.")
    lines.add(
      "- Forbidden (write-mode): `del`, " &
      "`erase`, `rd`, `rmdir`, `move`, `copy`, " &
      "`xcopy`, `mkdir`, `md`, `ren`, `rename`, " &
      "`attrib`, redirects `>` and `>>`.")
  else:
    lines.add("")
    lines.add("BASH / POSIX SHELL RULES:")
    lines.add(
      "- The target shell is a POSIX-compatible " &
      "shell (bash, zsh, sh). Use standard POSIX " &
      "utilities: `ls`, `cat`, `grep`, `find`, " &
      "`awk`, `sed`, `head`, `tail`, `wc`, " &
      "`cut`, `sort`, `uniq`, `xargs`, `stat`, " &
      "`uname`, `id`, `df`, `du`.")
    lines.add(
      "- Chain commands with `&&` (on success) " &
      "or `||` (on failure). Use `\\` for line " &
      "continuation.")
    lines.add(
      "- Quote variable expansions as \"$var\" " &
      "to prevent word splitting. Use single " &
      "quotes for literal text.")
    lines.add(
      "- Forbidden (write-mode): `rm`, `rmdir`," &
      " `mv`, `cp`, `mkdir`, `touch`, `chmod`, " &
      "`chown`, `tee`, `dd`, `install`, `ln`, " &
      "redirects `>` and `>>`, `xargs` piped " &
      "into any of the above.")

  lines.add("")
  lines.add("TOOL SELECTION GUIDANCE:")
  lines.add(
    "- For directory tree visualisation: use " &
    "`tree` (Linux) or `treepp` (Windows).")
  lines.add(
    "- For searching file contents: use `rg` " &
    "(ripgrep).")
  lines.add(
    "- For finding files by name: use `fd`.")
  lines.add(
    "- For packaging code context: use `pmc`.")
  lines.add(
    "- For code statistics (lines of code): " &
    "use `tokei`.")
  lines.add(
    "- For calculations or text processing: " &
    "use `lua -e '<code>'`.")
  lines.add(
    "- For AST-level code search: use `sg` " &
    "(ast-grep).")
  lines.add(
    "- For syntax-highlighted file viewing: " &
    "use `bat` (e.g. bat --style=plain " &
    "--paging=never <file>).")
  lines.add(
    "- For Markdown rendering in terminal: " &
    "use `mdcat` (e.g. mdcat --no-pager " &
    "<file>).")
  lines.add(
    "- If the user's request clearly requires " &
    "a third-party library or tool that is not " &
    "available, explain what is needed rather " &
    "than generating a command that will fail.")
  lines.add("")
  lines.add("SYSTEM INFORMATION:")
  lines.add(formatSysInfo(info))
  let bundledBlock = formatBundledTools(
    info.bundledTools)
  if bundledBlock.len > 0:
    lines.add("")
    lines.add(bundledBlock)
  if customPrompt.isSome:
    lines.add("")
    lines.add("ADDITIONAL INSTRUCTIONS:")
    lines.add(customPrompt.get)
  if pattern.isSome:
    lines.add("")
    lines.add(
      "NOTE: The generated command MUST NOT match" &
      " the following forbidden-command regex " &
      "pattern: " & pattern.get &
      ". If your command would match this " &
      "pattern, respond with a plain text " &
      "explanation instead.")
  result = lines.join("\n")

# ---------------------------------------------------------------------------
# Public API — instance mode prompt
# ---------------------------------------------------------------------------

## Builds the message list for instance mode (single-call).
## The LLM is instructed to return exactly one command whose
## output will be shown directly to the user, or a plain text
## answer when no command can satisfy the query.
##
## :param info: System information snapshot.
## :param query: The user's natural-language query.
## :param shell: The shell that will execute the command.
## :param customPrompt: Optional user-supplied system prompt.
## :param pattern: Optional forbidden-command regex note.
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
##     let msgs = buildInstanceMessages(info,
##       "test", "bash", none(string), none(string))
##     assert msgs.len == 2
func buildInstanceMessages*(
  info: SysInfo,
  query: string,
  shell: string,
  customPrompt: Option[string],
  pattern: Option[string]
): seq[LlmMessage] =
  var sysLines: seq[string] = @[]
  sysLines.add(
    "You are a command-line assistant. Your task" &
    " is to generate a single shell command that" &
    " retrieves the information the user " &
    "requested. The command output will be shown" &
    " directly to the user — make it clean and" &
    " human-readable.")
  sysLines.add("")
  sysLines.add(implBuildBaseContext(
    info, shell, customPrompt, pattern))
  let sysContent = sysLines.join("\n")
  result = @[
    LlmMessage(role: "system", content: sysContent),
    LlmMessage(role: "user", content: query)
  ]

# ---------------------------------------------------------------------------
# Public API — agent loop prompts
# ---------------------------------------------------------------------------

## Builds the initial message list for the agent loop (non-
## instance mode, round 1).  The system prompt explains the
## multi-round protocol with CONTINUE / FINAL / INTERPRET
## markers and includes the full round budget.
##
## :param info: System information snapshot.
## :param query: The user's natural-language query.
## :param shell: The shell that will execute commands.
## :param customPrompt: Optional user-supplied system prompt.
## :param pattern: Optional forbidden-command regex note.
## :param maxRounds: Maximum rounds budget (0 = unlimited).
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
##     let msgs = buildAgentInitMessages(info,
##       "test", "bash", none(string), none(string), 3)
##     assert msgs.len == 2
func buildAgentInitMessages*(
  info: SysInfo,
  query: string,
  shell: string,
  customPrompt: Option[string],
  pattern: Option[string],
  maxRounds: int
): seq[LlmMessage] =
  var sysLines: seq[string] = @[]
  sysLines.add(
    "You are a command-line assistant operating " &
    "in an agent loop. You can execute shell " &
    "commands step by step to gather information " &
    "before producing a final answer.")
  sysLines.add("")
  sysLines.add(implBuildBaseContext(
    info, shell, customPrompt, pattern))
  sysLines.add("")
  sysLines.add("RESPONSE PROTOCOL:")
  sysLines.add(
    "Each response must follow one of these " &
    "formats:")
  sysLines.add("")
  sysLines.add(
    "1. INTERMEDIATE STEP — execute a command " &
    "and continue:")
  sysLines.add(
    "   Wrap a single command in a ```sh code " &
    "block, then add <!-- CONTINUE --> on a " &
    "new line after the closing fence.")
  sysLines.add(
    "   The command will be executed and its " &
    "output returned to you for the next round.")
  sysLines.add("")
  sysLines.add(
    "2. FINAL COMMAND (direct output) — execute" &
    " and show to user:")
  sysLines.add(
    "   Wrap a single command in a ```sh code " &
    "block, then add <!-- FINAL --> on a new " &
    "line (or omit the marker — FINAL is the " &
    "default).")
  sysLines.add(
    "   The output is shown directly to the " &
    "user. This terminates the loop.")
  sysLines.add("")
  sysLines.add(
    "3. FINAL COMMAND (interpreted output) — " &
    "execute and summarise:")
  sysLines.add(
    "   Wrap a single command in a ```sh code " &
    "block, then add <!-- INTERPRET --> on a " &
    "new line.")
  sysLines.add(
    "   The output is sent back for you to " &
    "summarise. Use ONLY when raw output " &
    "genuinely needs explanation. Prefer " &
    "<!-- FINAL -->.")
  sysLines.add("")
  sysLines.add(
    "4. DIRECT TEXT ANSWER — no command needed:")
  sysLines.add(
    "   Respond with plain text (no code " &
    "block). This terminates the loop.")
  sysLines.add(
    "   Use only when no shell command can " &
    "answer the query.")
  sysLines.add("")
  sysLines.add("BEHAVIOUR PREFERENCES:")
  sysLines.add(
    "- Prefer FAST, DIRECT responses. Most " &
    "queries should be answerable in a single " &
    "<!-- FINAL --> command.")
  sysLines.add(
    "- Use <!-- CONTINUE --> only when you " &
    "genuinely need preliminary information " &
    "that cannot be obtained in one command.")
  sysLines.add(
    "- Use <!-- INTERPRET --> only when the " &
    "raw output is genuinely unclear to a " &
    "human reader.")
  sysLines.add(
    "- NEVER loop unnecessarily. Converge to " &
    "a final answer as quickly as possible.")
  if maxRounds > 0:
    sysLines.add("")
    sysLines.add(
      fmt"ROUND BUDGET: You have a maximum of " &
      fmt"{maxRounds} round(s). Plan accordingly.")
  let sysContent = sysLines.join("\n")
  result = @[
    LlmMessage(role: "system", content: sysContent),
    LlmMessage(role: "user", content: query)
  ]

## Extends the conversation history with the assistant's
## previous response and the execution result for the next
## agent round.  Includes urgency text that increases with
## each round.
##
## :param history: Existing conversation messages.
## :param assistantResponse: The LLM's raw response text.
## :param command: The command that was actually executed.
## :param output: The captured command output.
## :param exitCode: The command's exit code.
## :param nextRound: The upcoming round number (1-based).
## :param maxRounds: Maximum rounds budget (0 = unlimited).
## :returns: The extended message list for the next LLM call.
##
## .. code-block:: nim
##   runnableExamples:
##     let history = @[
##       LlmMessage(role: "system", content: "sys"),
##       LlmMessage(role: "user", content: "q")]
##     let msgs = buildAgentContinueMessages(
##       history, "```sh\nls\n```\n<!-- CONTINUE -->",
##       "ls", "file1\nfile2", 0, 2, 3)
##     assert msgs.len == 4
func buildAgentContinueMessages*(
  history: seq[LlmMessage],
  assistantResponse: string,
  command: string,
  output: string,
  exitCode: int,
  nextRound: int,
  maxRounds: int
): seq[LlmMessage] =
  var msgs = history
  msgs.add(LlmMessage(
    role: "assistant",
    content: assistantResponse))
  var userLines: seq[string] = @[]
  if maxRounds > 0:
    userLines.add(
      fmt"[Round {nextRound}/{maxRounds}]")
  else:
    userLines.add(fmt"[Round {nextRound}]")
  userLines.add(
    fmt"Executed command: {command}")
  userLines.add(fmt"Exit code: {exitCode}")
  let trimmed = output.strip()
  if trimmed.len > 0:
    userLines.add("Output:")
    userLines.add(trimmed)
  else:
    userLines.add("Output: (empty)")
  userLines.add("")
  if maxRounds > 0 and nextRound >= maxRounds:
    userLines.add(
      "This is the FINAL round. You MUST " &
      "provide a final answer now. Use " &
      "<!-- FINAL --> with a command, " &
      "<!-- INTERPRET --> with a command, or " &
      "a plain text answer. Do NOT use " &
      "<!-- CONTINUE -->.")
  elif maxRounds > 0 and
      nextRound >= maxRounds - 1:
    userLines.add(
      "Please converge to a final answer. " &
      "The next round is the last.")
  else:
    userLines.add(
      "Continue working toward a final answer.")
  msgs.add(LlmMessage(
    role: "user",
    content: userLines.join("\n")))
  result = msgs

# ---------------------------------------------------------------------------
# Public API — double-check prompt
# ---------------------------------------------------------------------------

## Builds the message list for the double-check safety review.
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
  sysLines.add("RULES:")
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

## Builds the message list for the five-mode cache-worthiness
## check.  The model evaluates whether the query result is
## stable enough to cache, whether the scope is global or
## context-bound, and whether the command or the result should
## be stored.  Five possible responses:
##
##   GLOBAL_COMMAND  — command works in any directory; output
##                     changes over time.
##   GLOBAL_RESULT   — answer is universally stable; no
##                     directory or time dependency.
##   CONTEXT_COMMAND — command depends on the current
##                     directory; output may change.
##   CONTEXT_RESULT  — result is stable in the same directory.
##   NOCACHE         — do not cache anything.
##
## :param query: The original user query.
## :param command: The final command that was executed.
## :param outputPreview: A truncated preview of the output.
## :param rounds: Number of agent rounds used (1 for instance).
## :returns: A two-element seq (system, user) of LlmMessage.
##
## .. code-block:: nim
##   runnableExamples:
##     let msgs = buildCacheCheckMessages(
##       "system version", "uname -a", "Linux 6.1", 1)
##     assert msgs.len == 2
func buildCacheCheckMessages*(
  query: string,
  command: string,
  outputPreview: string,
  rounds: int = 1
): seq[LlmMessage] =
  var sysLines: seq[string] = @[]
  sysLines.add(
    "Determine how this query result should be " &
    "cached. Reply with exactly one of: " &
    "GLOBAL_COMMAND, GLOBAL_RESULT, " &
    "CONTEXT_COMMAND, CONTEXT_RESULT, or " &
    "NOCACHE.")
  sysLines.add("")
  sysLines.add(
    "GLOBAL_COMMAND — The command works in ANY " &
    "directory and does not depend on the " &
    "current working directory, but the output " &
    "changes over time. Cache the command for " &
    "re-execution. Examples: system version " &
    "command, disk space check, network status, " &
    "running processes, CPU usage, installed " &
    "package version check.")
  sysLines.add("")
  sysLines.add(
    "GLOBAL_RESULT — The answer is universally " &
    "stable. It does not depend on the working " &
    "directory or change over time. Cache the " &
    "result for immediate reuse. Examples: " &
    "how to use a specific command, what a " &
    "concept means, static system property " &
    "(e.g. OS name, architecture), installed " &
    "software version.")
  sysLines.add("")
  sysLines.add(
    "CONTEXT_COMMAND — The command depends on " &
    "the current working directory (e.g. " &
    "scans files in '.'), and the output may " &
    "change over time. Cache the command for " &
    "re-execution in the same directory. " &
    "Examples: file listing, code statistics, " &
    "git status, directory size, grep results.")
  sysLines.add("")
  sysLines.add(
    "CONTEXT_RESULT — The result is stable " &
    "within the same working directory and " &
    "unlikely to change. Cache the result for " &
    "direct reuse. Examples: current directory " &
    "name, static config file content, project " &
    "name from a manifest, source file content.")
  sysLines.add("")
  sysLines.add(
    "NOCACHE — Do not cache. The query is too " &
    "ephemeral, ambiguous, or context-dependent " &
    "for caching to be useful. Examples: " &
    "transient error investigation, one-off " &
    "exploratory queries, queries whose " &
    "commands depend on intermediate results " &
    "from previous exploration rounds.")
  if rounds > 1:
    sysLines.add("")
    sysLines.add(
      fmt"NOTE: This result was obtained after " &
      fmt"{rounds} exploration round(s). If the " &
      "final command only makes sense after " &
      "intermediate exploration that may yield " &
      "different results next time, prefer " &
      "NOCACHE.")
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