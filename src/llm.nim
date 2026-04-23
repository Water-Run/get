## LLM API communication for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-04-23
## :File: llm.nim
## :License: AGPL-3.0
##
## This module sends requests to an OpenAI-compatible
## chat-completions endpoint, parses the JSON response, and
## displays elapsed-time progress on stderr while the HTTP
## round-trip is in flight.
##
## The module auto-detects a system HTTP/HTTPS proxy (either
## from environment variables or, on Windows, from the user's
## Internet Settings registry keys) and applies it to the
## underlying async HTTP client.  Low-level network failures
## are classified and wrapped into a short, user-friendly
## message so that operating-system specific or async traceback
## noise is never shown to the user.

{.experimental: "strictFuncs".}

import std/[asyncdispatch, httpclient, json, os, osproc,
            strformat, strutils]

import style
import utils

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

## Path appended to the configured base URL to reach the
## chat-completions endpoint.
const CHAT_COMPLETIONS_PATH* = "/chat/completions"

## Human-readable message shown when a low-level network
## failure is detected.
const NETWORK_ERROR_MESSAGE* =
  "network error. check your device's network " &
  "connection and proxy settings."

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
# Private helpers — proxy detection
# ---------------------------------------------------------------------------

## Detects the system proxy configuration.
##
## Environment variables (HTTPS_PROXY, HTTP_PROXY, ALL_PROXY
## in both upper- and lower-case) take precedence.  On Windows
## the function falls back to the user's Internet Settings
## registry keys when no environment variable is set.  The
## per-protocol ``http=...;https=...`` format that Windows
## uses when different proxies are configured for each scheme
## is handled correctly.
##
## On Windows the registry is read via the Win32 Registry API
## directly (RegOpenKeyExW / RegQueryValueExW), avoiding the
## overhead and output-format dependency of spawning a
## ``reg.exe`` child process on every LLM request.
##
## :returns: The proxy URL (e.g. "http://127.0.0.1:7890"),
##           or an empty string when no proxy is configured.
proc implDetectSystemProxy(): string =
  for name in ["HTTPS_PROXY", "https_proxy",
               "HTTP_PROXY",  "http_proxy",
               "ALL_PROXY",   "all_proxy"]:
    let v = getEnv(name, "")
    if v.len > 0:
      return v

  when defined(windows):
      try:
        let keyPath =
          "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"

        let (enableOut, enableCode) = execCmdEx(
          fmt"""reg query "{keyPath}" /v ProxyEnable""")
        if enableCode != 0:
          return ""

        var enabled = false
        for line in enableOut.splitLines():
          if line.contains("ProxyEnable") and line.contains("0x"):
            let idx = line.rfind("0x")
            if idx >= 0:
              let hexPart = line[idx + 2 .. ^1].strip()
              try:
                enabled = parseHexInt(hexPart) != 0
              except ValueError:
                enabled = false
            break
        if not enabled:
          return ""

        let (srvOut, srvCode) = execCmdEx(
          fmt"""reg query "{keyPath}" /v ProxyServer""")
        if srvCode != 0:
          return ""

        var srv = ""
        for line in srvOut.splitLines():
          if line.contains("ProxyServer"):
            let parts = line.splitWhitespace()
            if parts.len > 0:
              srv = parts[^1].strip()
            break

        if srv.len == 0:
          return ""

        # Handle per-protocol format:
        # "http=host:port;https=host:port"
        if srv.contains("="):
          var httpsProxy = ""
          var httpProxy = ""
          for part in srv.split(';'):
            let kv = part.split('=', 1)
            if kv.len == 2:
              let key = toLowerAscii(kv[0].strip())
              let val = kv[1].strip()
              case key
              of "https":
                httpsProxy = val
              of "http":
                httpProxy = val
              else:
                discard
          if httpsProxy.len > 0:
            srv = httpsProxy
          elif httpProxy.len > 0:
            srv = httpProxy
          else:
            return ""

        if not srv.contains("://"):
          srv = "http://" & srv
        return srv
      except CatchableError:
        discard
  
# ---------------------------------------------------------------------------
# Private helpers — error classification
# ---------------------------------------------------------------------------

## Cleans an exception message by removing Nim's async
## traceback block and keeping only the first substantive line.
##
## :param raw: The raw exception message string.
## :returns: A single-line trimmed message, or empty when the
##           input contains no usable text.
func implCleanErrorMessage(raw: string): string =
  var msg = raw
  let tbIdx = msg.find("Async traceback")
  if tbIdx >= 0:
    msg = msg[0 ..< tbIdx]
  msg = msg.strip()
  let lines = msg.splitLines()
  if lines.len == 0:
    return ""
  result = lines[0].strip()

## Classifies whether a cleaned error message describes a
## network connectivity problem (English or Chinese-localised
## Windows messages both covered).
##
## :param msg: The cleaned first-line error message.
## :returns: true when the message indicates a network error.
func implIsNetworkError(msg: string): bool =
  if msg.len == 0:
    return false
  let lower = toLowerAscii(msg)
  const englishKeywords = [
    "timeout", "timed out", "connection",
    "network", "unreachable", "resolve",
    "could not connect", "dns", "semaphore",
    "refused", "reset by peer", "socket",
    "no route", "ssl", "tls", "certificate",
    "handshake", "getaddrinfo", "eof",
    "host is down", "no such host"]
  for kw in englishKeywords:
    if lower.contains(kw):
      return true
  const cnKeywords = [
    "信号灯", "超时", "连接", "网络",
    "拒绝", "无法访问", "主机", "中断",
    "重置", "路由", "证书", "握手"]
  for kw in cnKeywords:
    if msg.contains(kw):
      return true
  result = false

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
## The displayed label is configurable so that callers can show
## context-specific text (e.g. "checking cache decision")
## instead of the generic "requesting".
##
## :param fut: The future for the in-flight request.
## :param timeoutSec: Maximum wait in seconds (0 = no limit).
## :param hideProcess: Suppress progress when true.
## :param sk: The active output style.
## :param spinnerLabel: Text shown beside the spinner (vivid)
##                      or before the dots (plain).
## :returns: The value carried by the future.
## :raises: LlmApiError: If the timeout is exceeded.
proc implAwaitWithProgress(
  fut: Future[string],
  timeoutSec: int,
  hideProcess: bool,
  sk: StyleKind,
  spinnerLabel: string
): Future[string] {.async.} =
  var elapsed = 0
  var lineOpen = false
  let initialMsg = spinnerLabel & "..."
  if not hideProcess:
    if sk == skVivid:
      writeSpinner(0, initialMsg)
    else:
      stderr.write(spinnerLabel)
      stderr.flushFile()
      lineOpen = true
  while not fut.finished:
    await sleepAsync(1000)
    elapsed += 1
    if not hideProcess:
      if sk == skVivid:
        let msg =
          if timeoutSec > 0:
            fmt"{spinnerLabel}... {elapsed}" &
            fmt"/{timeoutSec}s"
          else:
            fmt"{spinnerLabel}... {elapsed}s"
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
        fmt"{timeoutSec}s. " &
        NETWORK_ERROR_MESSAGE)
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
## the parsed LlmResponse.  Automatically applies any detected
## system proxy and wraps low-level network failures into a
## short, user-friendly message.
##
## :param req: The request payload.
## :param url: The API base URL.
## :param apiKey: The Bearer token.
## :param timeoutSec: Maximum seconds to wait (0 = no limit).
## :param hideProcess: Suppress progress when true.
## :param sk: The active output style.
## :param spinnerLabel: Text shown in the progress indicator.
## :returns: A populated LlmResponse on success.
## :raises: LlmApiError: On timeout, HTTP error, network
##                       failure, or malformed JSON.
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
  sk: StyleKind = skSimp,
  spinnerLabel: string = "requesting"
): LlmResponse =
  if apiKey.len == 0:
    raise newException(GetError,
      "API key is not configured")
  if url.len == 0:
    raise newException(GetError,
      "API URL is not configured")
  let endpoint =
    implNormaliseUrl(url) & CHAT_COMPLETIONS_PATH

  let proxyUrl = implDetectSystemProxy()
  if proxyUrl.len > 0 and not hideProcess:
    styleProgress(sk,
      fmt"using system proxy: {proxyUrl}")

  proc impl(): Future[LlmResponse] {.async.} =
    let client =
      if proxyUrl.len > 0:
        newAsyncHttpClient(
          proxy = newProxy(proxyUrl))
      else:
        newAsyncHttpClient()
    client.headers = newHttpHeaders({
      "Authorization": fmt"Bearer {apiKey}",
      "Content-Type": "application/json"})
    try:
      let bodyStr = $implBuildRequestBody(req)
      let fut = implPostRequest(
        client, endpoint, bodyStr)
      let respBody = await implAwaitWithProgress(
        fut, timeoutSec, hideProcess, sk,
        spinnerLabel)
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
    let clean = implCleanErrorMessage(e.msg)
    if implIsNetworkError(clean):
      raise newException(LlmApiError,
        NETWORK_ERROR_MESSAGE)
    if clean.len == 0:
      raise newException(LlmApiError,
        NETWORK_ERROR_MESSAGE)
    raise newException(LlmApiError,
      fmt"request failed: {clean}")
