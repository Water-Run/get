## Compact prompt construction for the get v3 harness.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: harness_prompt.nim
## :License: AGPL-3.0
##
## This module builds the short, strategy-aware prompt used by every v3
## harness. It also declares the provider-native read-only shell tool while
## retaining a strict JSON fallback for compatible endpoints without tools.

{.experimental: "strictFuncs".}

import std/[options, strformat, strutils]

import harness_protocol
import harness_types
import llm
import sysinfo
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## JSON Schema for the provider-native read-only shell tool.
const SHELL_TOOL_SCHEMA* = """{
  "type":"object",
  "properties":{
    "command":{"type":"string","minLength":1},
    "purpose":{"type":"string"},
    "result_mode":{"type":"string","enum":["return_raw","continue"]}
  },
  "required":["command","result_mode"],
  "additionalProperties":false
}"""

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Returns concise behavioral guidance for one harness strategy.
##
## :param kind: Active harness policy.
## :returns: One strategy instruction sentence.
func implStrategyInstruction(kind: HarnessKind): string =
  case kind
  of hkAuto:
    result = "Prefer one terminal call; continue only when evidence is needed."
  of hkDirect:
    result = "Tool output is returned verbatim. If calling once, the command " &
      "itself must produce the exact requested format, including yes/no or " &
      "transformed output; otherwise answer directly."
  of hkLoop:
    result = "Use one call per turn; continue when output needs interpretation."
  of hkParallel:
    result = "Batch independent read-only checks in parallel when useful."

## Returns only the shell-specific guidance needed for executable commands.
func implShellInstruction(shell: string): string =
  let lower = toLowerAscii(shell)
  if lower.contains("powershell") or lower.contains("pwsh"):
    result = "PowerShell: use native executable cmdlets, not POSIX aliases; " &
      "prefer Get-Location, Get-ChildItem, Get-Content, Get-Process, " &
      "Select-String, Get-Command, and Resolve-Path ~."
  elif lower.contains("cmd"):
    result = "cmd.exe: use native dir, type, where, set, ver, and whoami syntax."
  elif lower.contains("fish"):
    result = "fish: use fish syntax and avoid bash-only constructs."

## Weather requests without a place need the already-discovered named timezone
## made explicit at user-message priority. The note remains a fallback, so an
## actual location in the user's request always wins.
func implWeatherContext(query: string, timeZone: string): string =
  if timeZone.len == 0:
    return ""
  let lower = toLowerAscii(query)
  for marker in ["weather", "forecast", "天气", "天氣", "天気", "날씨"]:
    if lower.contains(marker):
      return "Host fallback: if no place is named, use timezone " & timeZone &
        " as the location. For a web lookup use curl -q -fsSL --max-time 15 " &
        "URL; do not add proxy or progress options."

## Builds the compact system instruction shared by native and fallback modes.
##
## :param info: Fast environment snapshot.
## :param shell: Effective shell executable.
## :param kind: Active harness strategy.
## :param budget: Hard run limits visible to the model.
## :param customPrompt: Optional user instruction appended verbatim.
## :param commandPattern: Optional supplemental forbidden regex.
## :returns: Complete system message text.
func implSystemPrompt(
  info: SysInfo,
  shell: string,
  kind: HarnessKind,
  budget: RunBudget,
  customPrompt: Option[string],
  commandPattern: Option[string],
  toolsDisabled: bool
): string =
  let dateContext =
    if info.localDate.len > 0:
      fmt"; local_date={info.localDate}"
    else:
      ""
  let timezoneContext =
    if info.timeZone.len > 0:
      fmt"; timezone={info.timeZone}"
    else:
      ""
  var lines = @[
    "get v3: fast read-only assistant.",
    fmt"Env: OS={info.os}; arch={info.arch}; cwd={info.cwd}; " &
      fmt"shell={shell}{dateContext}{timezoneContext}."
  ]
  if toolsDisabled:
    lines.add(
      "No tools are available for this request. Answer directly from reasoning " &
      "and follow the user's requested format; never emit a command or tool call.")
  else:
    lines.add(@[
      "Answer static facts; inspect dynamic/local facts via " &
        READ_ONLY_SHELL_TOOL & " with runnable, placeholder-free commands.",
      "Only inspect/retrieve; no write/delete/install/config/signal/mutation " &
        "or true/false.",
      "One bounded plan; every pipeline/short ;/&&/|| sequence is " &
        "observational. Text: head/tail, " &
        "stdout-only sed, or pure AWK field selectors. Counts: use qualified " &
        "globs+wc or find -printf/grep -o then sort|uniq -c; never " &
        "find -exec. Performance: " &
        "top -b -n 1 | head -n 15 on Linux, top -l 1 -n 15 on macOS, " &
        "or Get-Process | Select-Object -First 15 on PowerShell; no unbounded " &
        "monitors.",
      "No scripts, wrappers, inline code; no substitution/loops/backgrounding/" &
        "splatting/output files/advanced redirects; literal < file needs a data " &
        "reader; variables: " &
        "$HOME, $USER, $LOGNAME, and $PWD.",
      "Globs need ./ or --. Web: curl -q; wget --no-config --no-hsts -O-.",
      "Weather without place: infer it from named timezone, never proxy egress; " &
        "use local units.",
      "Code composition: find -printf | sed | sort | uniq -c; " &
        "skip .git/.ci/.release/build/dist/node_modules/__pycache__; return a " &
        "compact breakdown.",
      "Git summaries, first batch: branch -vv --no-color; staged via diff " &
        "--cached, unstaged via diff-files (both --name-only --no-ext-diff " &
        "--no-textconv); untracked via ls-files --others --exclude-standard | " &
        "head -n 30; " &
        "top dirs via " &
        "cut -d/ -f1 | sort | uniq -c. Cap names+counts; never " &
        "status or plain diff. Systemd: " &
        "systemctl list-units or systemctl --failed --no-pager. macOS " &
        "services: launchctl list | head -n 21, then answer.",
      "return_raw only for complete requested answer output; continue to " &
        "explain/compare/summarize composition/status.",
      "grep/diff/cmp/test exit 1 is evidence, not a crash. On failure explain " &
        "or try one simpler reader; don't repeat timed-out/truncated commands.",
      implStrategyInstruction(kind),
      fmt"Limits: {budget.maxTurns} turns, {budget.maxToolCalls} tools, " &
        fmt"{budget.maxParallel} concurrent.",
      "Without native tools emit one JSON action: " &
        "{\"type\":\"answer\",\"text\":\"...\"} or " &
        "{\"type\":\"tool_calls\",\"calls\":[{" &
        "\"command\":\"...\",\"result_mode\":\"return_raw|continue\"}]}.",
      "JSON only; be concise."
    ])
    let shellInstruction = implShellInstruction(shell)
    if shellInstruction.len > 0:
      lines.add(shellInstruction)
  if customPrompt.isSome and customPrompt.get.strip().len > 0:
    lines.add("Additional user configuration: " & customPrompt.get.strip())
  if commandPattern.isSome and commandPattern.get.strip().len > 0:
    lines.add("Also avoid commands matching this supplemental regex: " &
      commandPattern.get.strip())
  if toolsDisabled:
    lines.add("This request explicitly disables all tools; answer with text only.")
  result = lines.join("\n")

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Detects an explicit user instruction that disables all tool use.
##
## Quoted examples are ignored so a request to explain the phrase itself does
## not accidentally disable local inspection. Runtime enforcement remains the
## authority: when this returns true, native and textual tool calls are denied.
func explicitlyDisablesTools*(query: string): bool =
  let normalized = toLowerAscii(query)
    .replace("don’t", "do not")
    .replace("don't", "do not")
    .replace("“", "\"")
    .replace("”", "\"")
    .replace("‘", "'")
    .replace("’", "'")
  const directives = [
    "without calling a tool", "without calling tools",
    "without using a tool", "without using tools",
    "without any tool", "without any tools", "without tools",
    "do not call a tool", "do not call tools",
    "do not use a tool", "do not use tools",
    "never call a tool", "never call tools",
    "never use a tool", "never use tools",
    "不要调用工具", "不调用任何工具", "不调用工具", "请勿调用工具",
    "别调用工具", "不要使用工具", "不使用任何工具", "不使用工具",
    "无需调用工具", "不用任何工具", "不用工具"
  ]
  var quote = '\0'
  var index = 0
  while index < normalized.len:
    let character = normalized[index]
    if quote == '\0' and character in {'\'', '\"', '`'}:
      quote = character
      inc(index)
      continue
    if quote != '\0' and character == quote:
      quote = '\0'
      inc(index)
      continue
    if quote == '\0':
      for directive in directives:
        if normalized.continuesWith(directive, index):
          return true
    inc(index)
  result = false

## Returns the native function definition for read-only shell inspection.
##
## :returns: A provider-neutral tool definition with a strict argument schema.
##
## .. code-block:: nim
##   runnableExamples:
##     assert shellToolDefinition().name == "run_readonly_shell"
func shellToolDefinition*(): LlmToolDefinition =
  result = LlmToolDefinition(
    name: READ_ONLY_SHELL_TOOL,
    description: "Run one read-only shell command and capture bounded output.",
    parametersJson: SHELL_TOOL_SCHEMA,
    strict: false
  )

## Builds initial messages for any v3 harness strategy.
##
## :param info: Fast environment snapshot.
## :param query: Natural-language user request.
## :param shell: Effective shell executable.
## :param kind: Active harness strategy.
## :param budget: Hard run limits.
## :param customPrompt: Optional configured system instruction.
## :param commandPattern: Optional supplemental forbidden regex.
## :returns: System and user messages ready for a model turn.
##
## .. code-block:: nim
##   runnableExamples:
##     import std/options
##     let info = SysInfo(os: "linux", arch: "amd64", cwd: "/tmp",
##       shell: "bash", hostname: "", username: "", shellVersion: "",
##       availableTools: @[])
##     let messages = buildHarnessMessages(info, "show cwd", "bash", hkAuto,
##       defaultRunBudget(hkAuto), none(string), none(string))
##     assert messages.len == 2
func buildHarnessMessages*(
  info: SysInfo,
  query: string,
  shell: string,
  kind: HarnessKind,
  budget: RunBudget,
  customPrompt: Option[string],
  commandPattern: Option[string],
  toolsDisabled = false
): seq[LlmMessage] =
  let weatherContext = implWeatherContext(query, info.timeZone)
  let userContent =
    if weatherContext.len > 0: query & "\n" & weatherContext
    else: query
  result = @[
    LlmMessage(
      role: "system",
      content: implSystemPrompt(
        info, shell, kind, budget,
        customPrompt, commandPattern, toolsDisabled),
      toolCallId: "",
      toolCallsJson: ""
    ),
    LlmMessage(
      role: "user",
      content: userContent,
      toolCallId: "",
      toolCallsJson: ""
    )
  ]
