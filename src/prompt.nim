## Prompt construction and formatting for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-13
## :File: prompt.nim
## :License: AGPL-3.0
##
## This module assembles the system prompt and user prompt sent to the
## LLM for each command context.  It currently provides prompt constants
## for the isok connectivity verification and will be extended with
## query-prompt builders once full query functionality is implemented.

{.experimental: "strictFuncs".}

# ---------------------------------------------------------------------------
# Constants — isok connectivity check
# ---------------------------------------------------------------------------

## System prompt instructing the model to reply with exactly "ok".
const ISOK_SYSTEM_PROMPT* =
  "Reply with exactly the word 'ok' and nothing else."

## User prompt for the isok connectivity check.
const ISOK_USER_PROMPT* = "ok"

## Maximum tokens allocated for the isok response.  The expected reply
## is a single word, so a small budget suffices.
const ISOK_MAX_TOKENS* = 32