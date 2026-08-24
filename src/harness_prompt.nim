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
      "Select-String, Get-Command, and " &
      "[Environment]::GetFolderPath('UserProfile')."
  elif lower.contains("cmd"):
    result = "cmd.exe: use native dir, type, where, set, ver, and whoami syntax."
  elif lower.contains("fish"):
    result = "fish: use fish syntax and avoid bash-only constructs."

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
  commandPattern: Option[string]
): string =
  let dateContext =
    if info.localDate.len > 0:
      fmt"; local_date={info.localDate}"
    else:
      ""
  var lines = @[
    "You are get v3, a fast read-only command-line assistant.",
    fmt"Environment: OS={info.os}; arch={info.arch}; cwd={info.cwd}; " &
      fmt"shell={shell}{dateContext}.",
    "Answer directly when no local inspection is needed. Otherwise use " &
      READ_ONLY_SHELL_TOOL & ".",
    "Never answer dynamic or machine-local questions from memory. Inspect " &
      "first, and return only commands that can run as-is without placeholders.",
    "Commands must only inspect or retrieve information. Never write, delete, " &
      "install, configure, signal, or otherwise mutate state.",
    "Prefer standard inspection commands; never use inline interpreter code.",
    "Use return_raw only when command output is the complete requested answer. " &
      "Use continue to explain, compare, summarize, or transform observations.",
    implStrategyInstruction(kind),
    fmt"Hard limits: {budget.maxTurns} model turn(s), {budget.maxToolCalls} tool " &
      fmt"call(s), {budget.maxParallel} concurrent call(s).",
    "If native tools are unavailable, emit only one JSON action: " &
      "{\"type\":\"answer\",\"text\":\"...\"} or " &
      "{\"type\":\"tool_calls\",\"calls\":[{" &
      "\"command\":\"...\",\"purpose\":\"...\"," &
      "\"result_mode\":\"return_raw|continue\"}]}.",
    "Do not wrap JSON in prose. Keep final answers concise."
  ]
  let shellInstruction = implShellInstruction(shell)
  if shellInstruction.len > 0:
    lines.add(shellInstruction)
  if customPrompt.isSome and customPrompt.get.strip().len > 0:
    lines.add("Additional user configuration: " & customPrompt.get.strip())
  if commandPattern.isSome and commandPattern.get.strip().len > 0:
    lines.add("Also avoid commands matching this supplemental regex: " &
      commandPattern.get.strip())
  result = lines.join("\n")

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

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
  commandPattern: Option[string]
): seq[LlmMessage] =
  result = @[
    LlmMessage(
      role: "system",
      content: implSystemPrompt(
        info, shell, kind, budget,
        customPrompt, commandPattern),
      toolCallId: "",
      toolCallsJson: ""
    ),
    LlmMessage(
      role: "user",
      content: query,
      toolCallId: "",
      toolCallsJson: ""
    )
  ]
