## LLM API communication for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-17
## :File: llm.nim
## :License: AGPL-3.0
##
## This module sends requests to an OpenAI-compatible
## chat-completions endpoint, parses the JSON response, and
## displays elapsed-time progress on stderr while the HTTP
## round-trip is in flight.

{.experimental: "strictFuncs".}

import std/[asyncdispatch, httpclient, json,
            strformat, strutils]

import style
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Path appended to the configured base URL to reach the
## chat-completions endpoint.
const CHAT_COMPLETIONS_PATH* = "/chat/completions"

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Raised when the LLM API returns a non-successful HTTP status,
## a malformed response body, or when the request times out.
type
  LlmApiError* = object of GetError

## Encapsulates a single chat-completion request.
type
  LlmRequest* = object
    model*: string              ## Model identifier.
    messages*: seq[LlmMessage]  ## Conversation messages.
    maxTokens*: int             ## Max tokens (0 = omit).

## Encapsulates the parsed response returned by the API.
type
  LlmResponse* = object
    content*: string  ## Text from the first choice.
    tokensUsed*: int  ## Total tokens consumed.

# ---------------------------------------------------------------------------
# Private helpers — request construction
# ---------------------------------------------------------------------------

## Builds the JSON request body.
##
## :param req: The LLM request parameters.
## :returns: A JsonNode representing the request body.
proc implBuildRequestBody(
  req: LlmRequest
): JsonNode =
  var msgs = newJArray()
  for m in req.messages:
    msgs.add(%*{
      "role": m.role,
      "content": m.content})
  result = %*{
    "model": req.model,
    "messages": msgs
  }
  if req.maxTokens > 0:
    result["max_tokens"] = %req.maxTokens

## Strips any trailing slash from a URL.
##
## :param url: The raw URL string.
## :returns: The URL without a trailing slash.
func implNormaliseUrl(url: string): string =
  result = url.strip(
    trailing = true, chars = {'/'})

# ---------------------------------------------------------------------------
# Private helpers — async HTTP
# ---------------------------------------------------------------------------

## Posts the JSON body and returns the raw response body.
##
## :param client: An open async HTTP client.
## :param endpoint: The full URL.
## :param body: The serialised JSON request body.
## :returns: The response body as a string.
## :raises: LlmApiError: On non-200 status.
proc implPostRequest(
  client: AsyncHttpClient,
  endpoint: string,
  body: string
): Future[string] {.async.} =
  let resp = await client.post(
    endpoint, body = body)
  let respBody = await resp.body
  if resp.code != Http200:
    let codeInt = resp.code.int
    let preview =
      if respBody.len > 512:
        respBody[0 ..< 512] & "..."
      else:
        respBody
    raise newException(LlmApiError,
      fmt"API returned HTTP {codeInt}: {preview}")
  result = respBody

# ---------------------------------------------------------------------------
# Private helpers — progress display
# ---------------------------------------------------------------------------

## Waits for the future while printing elapsed-time progress.
##
## :param fut: The future for the in-flight request.
## :param timeoutSec: Maximum wait in seconds (0 = no limit).
## :param hideProcess: Suppress progress when true.
## :param sk: The active output style.
## :returns: The value carried by the future.
## :raises: LlmApiError: If the timeout is exceeded.
proc implAwaitWithProgress(
  fut: Future[string],
  timeoutSec: int,
  hideProcess: bool,
  sk: StyleKind
): Future[string] {.async.} =
  var elapsed = 0
  var lineOpen = false
  if not hideProcess:
    if sk == skVivid:
      writeSpinner(0, "requesting...")
    else:
      stderr.write("requesting")
      stderr.flushFile()
      lineOpen = true
  while not fut.finished:
    await sleepAsync(1000)
    elapsed += 1
    if not hideProcess:
      if sk == skVivid:
        let msg =
          if timeoutSec > 0:
            fmt"requesting... {elapsed}" &
            fmt"/{timeoutSec}s"
          else:
            fmt"requesting... {elapsed}s"
        writeSpinner(elapsed, msg)
      else:
        if elapsed <= 10:
          if elapsed mod 2 == 0:
            stderr.write(".")
            stderr.flushFile()
        elif elapsed == 11:
          if lineOpen:
            stderr.writeLine("")
            lineOpen = false
          let waitMsg =
            if timeoutSec > 0:
              fmt"- waited 10/{timeoutSec}s"
            else:
              "- waited 10s (no timeout)"
          stderr.writeLine(waitMsg)
        elif elapsed mod 10 == 0:
          let waitMsg =
            if timeoutSec > 0:
              fmt"- waited {elapsed}" &
              fmt"/{timeoutSec}s"
            else:
              fmt"- waited {elapsed}s" &
              " (no timeout)"
          stderr.writeLine(waitMsg)
    if timeoutSec > 0 and
        elapsed >= timeoutSec:
      if sk == skVivid:
        clearSpinner()
      elif lineOpen:
        stderr.writeLine("")
      raise newException(LlmApiError,
        fmt"request timed out after " &
        fmt"{timeoutSec}s")
  if not hideProcess:
    if sk == skVivid:
      clearSpinner()
    elif lineOpen:
      stderr.writeLine("")
  result = fut.read

# ---------------------------------------------------------------------------
# Private helpers — response parsing
# ---------------------------------------------------------------------------

## Parses the raw JSON body into an LlmResponse.
##
## :param body: The raw JSON string.
## :returns: A populated LlmResponse.
## :raises: LlmApiError: If the JSON is malformed.
proc implParseResponse(body: string): LlmResponse =
  var node: JsonNode
  try:
    node = parseJson(body)
  except JsonParsingError:
    raise newException(LlmApiError,
      "API returned malformed JSON")
  let choices = node{"choices"}
  if choices.isNil or choices.kind != JArray or
      choices.len == 0:
    raise newException(LlmApiError,
      "API response contains no choices")
  let msg = choices[0]{"message"}
  if msg.isNil:
    raise newException(LlmApiError,
      "API response missing 'message'")
  let content = msg{"content"}
  if content.isNil:
    raise newException(LlmApiError,
      "API response missing 'content'")
  result = LlmResponse(
    content: content.getStr().strip(),
    tokensUsed:
      node{"usage"}{"total_tokens"}.getInt(0))

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Sends an LlmRequest to the configured endpoint and returns
## the parsed LlmResponse.
##
## :param req: The request payload.
## :param url: The API base URL.
## :param apiKey: The Bearer token.
## :param timeoutSec: Maximum seconds to wait (0 = no limit).
## :param hideProcess: Suppress progress when true.
## :param sk: The active output style.
## :returns: A populated LlmResponse on success.
## :raises: LlmApiError: On timeout, HTTP error, or bad JSON.
## :raises: GetError: If apiKey or url is empty.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc sendLlmRequest*(
  req: LlmRequest,
  url: string,
  apiKey: string,
  timeoutSec: int = 300,
  hideProcess: bool = false,
  sk: StyleKind = skSimp
): LlmResponse =
  if apiKey.len == 0:
    raise newException(GetError,
      "API key is not configured")
  if url.len == 0:
    raise newException(GetError,
      "API URL is not configured")
  let endpoint =
    implNormaliseUrl(url) & CHAT_COMPLETIONS_PATH

  proc impl(): Future[LlmResponse] {.async.} =
    let client = newAsyncHttpClient()
    client.headers = newHttpHeaders({
      "Authorization": fmt"Bearer {apiKey}",
      "Content-Type": "application/json"})
    try:
      let bodyStr = $implBuildRequestBody(req)
      let fut = implPostRequest(
        client, endpoint, bodyStr)
      let respBody = await implAwaitWithProgress(
        fut, timeoutSec, hideProcess, sk)
      result = implParseResponse(respBody)
    finally:
      client.close()

  try:
    result = waitFor impl()
  except LlmApiError:
    raise
  except GetError:
    raise
  except CatchableError as e:
    raise newException(LlmApiError,
      fmt"request failed: {e.msg}")