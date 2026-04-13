## LLM API communication for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-13
## :File: llm.nim
## :License: AGPL-3.0
##
## This module sends requests to an OpenAI-compatible
## chat-completions endpoint, parses the JSON response, and displays
## elapsed-time progress on stderr while the HTTP round-trip is in
## flight.  It uses asynchronous I/O so that a one-second timer can
## fire between event-loop polls without blocking the transfer.
##
## The LlmRequest type accepts a generic seq[LlmMessage] so that
## callers (prompt builders, isok, double-check) can construct
## arbitrary conversation histories.

{.experimental: "strictFuncs".}

import std/[asyncdispatch, httpclient, json, strformat, strutils]

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

## Raised when the LLM API returns a non-successful HTTP status, a
## malformed response body, or when the request exceeds the
## configured timeout.
type
  LlmApiError* = object of GetError

## Encapsulates a single chat-completion request.
type
  LlmRequest* = object
    model*: string              ## Model identifier.
    messages*: seq[LlmMessage]  ## Conversation messages.
    maxTokens*: int             ## Maximum tokens for the response.

## Encapsulates the parsed response returned by the API.
type
  LlmResponse* = object
    content*: string  ## Text from the first choice.
    tokensUsed*: int  ## Total tokens consumed (0 if unavailable).

# ---------------------------------------------------------------------------
# Private helpers — request construction
# ---------------------------------------------------------------------------

## Builds the JSON request body for an OpenAI-compatible
## chat-completions endpoint from the message list.
##
## :param req: The LLM request parameters.
## :returns: A JsonNode representing the full request body.
proc implBuildRequestBody(req: LlmRequest): JsonNode =
  var msgs = newJArray()
  for m in req.messages:
    msgs.add(%*{"role": m.role, "content": m.content})
  result = %*{
    "model": req.model,
    "max_tokens": req.maxTokens,
    "messages": msgs
  }

## Strips any trailing slash from a URL so that appending a path
## segment does not produce a double slash.
##
## :param url: The raw URL string.
## :returns: The URL without a trailing slash.
func implNormaliseUrl(url: string): string =
  result = url.strip(trailing = true, chars = {'/'})

# ---------------------------------------------------------------------------
# Private helpers — async HTTP
# ---------------------------------------------------------------------------

## Posts the JSON body to the endpoint and returns the raw response
## body string.
##
## :param client: An open async HTTP client with headers set.
## :param endpoint: The full URL including the path.
## :param body: The serialised JSON request body.
## :returns: The response body as a string.
## :raises: LlmApiError: If the server returns a non-200 status.
proc implPostRequest(
  client: AsyncHttpClient,
  endpoint: string,
  body: string
): Future[string] {.async.} =
  let resp = await client.post(endpoint, body = body)
  let respBody = await resp.body
  if resp.code != Http200:
    let codeInt = resp.code.int
    let preview =
      if respBody.len > 512: respBody[0 ..< 512] & "..."
      else: respBody
    raise newException(LlmApiError,
      fmt"API returned HTTP {codeInt}: {preview}")
  result = respBody

# ---------------------------------------------------------------------------
# Private helpers — progress display
# ---------------------------------------------------------------------------

## Waits for the given future while printing elapsed-time progress
## to stderr.  During the first nine seconds a dot is appended each
## second.  From ten seconds onward a "waited N/Ts" line is printed
## every ten seconds.  Raises when the elapsed time reaches the
## timeout limit.
##
## :param fut: The future representing the in-flight request.
## :param timeoutSec: Maximum wait in seconds.
## :param hideProcess: Suppress all progress output when true.
## :returns: The value carried by the future.
## :raises: LlmApiError: If the timeout is exceeded.
proc implAwaitWithProgress(
  fut: Future[string],
  timeoutSec: int,
  hideProcess: bool
): Future[string] {.async.} =
  var elapsed = 0
  var lineOpen = false
  if not hideProcess:
    stderr.write("requesting")
    stderr.flushFile()
    lineOpen = true
  while not fut.finished:
    await sleepAsync(1000)
    elapsed += 1
    if not hideProcess:
      if elapsed < 10:
        stderr.write(".")
        stderr.flushFile()
      elif elapsed == 10:
        stderr.writeLine("")
        stderr.writeLine(
          fmt"- waited {elapsed}/{timeoutSec}s")
        lineOpen = false
      elif elapsed mod 10 == 0:
        stderr.writeLine(
          fmt"- waited {elapsed}/{timeoutSec}s")
        lineOpen = false
    if elapsed >= timeoutSec:
      if lineOpen:
        stderr.writeLine("")
      raise newException(LlmApiError,
        fmt"request timed out after {timeoutSec}s")
  if not hideProcess and lineOpen:
    stderr.writeLine("")
  result = fut.read

# ---------------------------------------------------------------------------
# Private helpers — response parsing
# ---------------------------------------------------------------------------

## Parses the raw JSON body returned by an OpenAI-compatible
## endpoint into an LlmResponse.
##
## :param body: The raw JSON string.
## :returns: A populated LlmResponse.
## :raises: LlmApiError: If the JSON is malformed or missing
##          required fields.
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
      "API response missing 'message' in first choice")
  let content = msg{"content"}
  if content.isNil:
    raise newException(LlmApiError,
      "API response missing 'content' in message")
  result = LlmResponse(
    content: content.getStr().strip(),
    tokensUsed: node{"usage"}{"total_tokens"}.getInt(0)
  )

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Sends an LlmRequest to the configured OpenAI-compatible endpoint
## and returns the parsed LlmResponse.  While the HTTP round-trip
## is in progress, elapsed-time information is written to stderr
## unless hideProcess is true.
##
## :param req: The request payload (model, messages, maxTokens).
## :param url: The API base URL.
## :param apiKey: The Bearer token.  Must not be empty.
## :param timeoutSec: Maximum seconds to wait before aborting.
## :param hideProcess: Suppress progress output when true.
## :returns: A populated LlmResponse on success.
## :raises: LlmApiError: On timeout, HTTP error, or malformed
##          response.
## :raises: GetError: If apiKey or url is empty.
##
## .. code-block:: nim
##   runnableExamples:
##     # Illustrative — requires a live API endpoint.
##     discard
proc sendLlmRequest*(
  req: LlmRequest,
  url: string,
  apiKey: string,
  timeoutSec: int = 300,
  hideProcess: bool = false
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
      "Content-Type": "application/json"
    })
    try:
      let bodyStr = $implBuildRequestBody(req)
      let fut = implPostRequest(
        client, endpoint, bodyStr)
      let respBody = await implAwaitWithProgress(
        fut, timeoutSec, hideProcess)
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