## Small auxiliary prompts for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: prompt.nim
## :License: AGPL-3.0
##
## The main v3 model/action/tool protocol lives in ``harness_prompt``.
## This module deliberately contains only the two prompts outside that
## protocol: the connectivity probe and the optional command safety review.

{.experimental: "strictFuncs".}

import std/[strformat, strutils]

import sysinfo
import utils

## Exact-response connectivity probe.
const ISOK_SYSTEM_PROMPT* =
  "Reply with exactly the word 'ok' and nothing else."
const ISOK_USER_PROMPT* =
  "Please reply with exactly the word 'ok' and nothing else."
const ISOK_MAX_TOKENS* = 256

## Builds the optional second-model review for a proposed command.
## Mandatory deterministic policy is still enforced before and after this
## review; the model is only an additional intent and safety check.
func buildDoubleCheckMessages*(
  command: string,
  query: string,
  info: SysInfo
): seq[LlmMessage] =
  let system = [
    "Review a shell command for read-only safety and user intent.",
    "",
    fmt"User query: {query}",
    fmt"Generated command: {command}",
    "",
    "SYSTEM INFORMATION:",
    formatSysInfo(info),
    "",
    "RULES:",
    "- If the command could modify local or external state in any way, " &
      "reply with exactly UNSAFE.",
    "- Treat writes, deletes, moves, permission changes, redirections, " &
      "and write-mode flags as unsafe.",
    "- If it is read-only but clearly does not answer the query, return a " &
      "corrected read-only command in one ```sh code block.",
    "- Otherwise return the approved command in one ```sh code block.",
    "- Return no explanation."
  ].join("\n")

  result = @[
    LlmMessage(role: "system", content: system),
    LlmMessage(role: "user", content: "Review this command.")
  ]
