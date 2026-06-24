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
## The module honors terminal proxy environment variables and
## can optionally prefer the operating-system proxy settings
## (Windows Internet Settings) when requested by configuration.
## Low-level network failures are classified and wrapped into a
## short, user-friendly message so that operating-system specific
## or async traceback noise is never shown to the user.

{.experimental: "strictFuncs".}

import std/[asyncdispatch, httpclient, json, os, osproc,
            strformat, strutils, streams, net]

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

## Detects the proxy configuration.
##
## Terminal environment variables (HTTPS_PROXY, HTTP_PROXY,
## ALL_PROXY in both upper- and lower-case) provide terminal
## behavior.  When ``preferSystemProxy`` is enabled, Windows
## Internet Settings take precedence over terminal environment
## variables.  The per-protocol ``http=...;https=...`` format
## that Windows uses when different proxies are configured for
## each scheme is handled correctly.
##
## On Windows the registry is read via the Win32 Registry API
## directly (RegOpenKeyExW / RegQueryValueExW), avoiding the
## overhead and output-format dependency of spawning a
## ``reg.exe`` child process on every LLM request.
##
## :returns: The proxy URL (e.g. "http://127.0.0.1:7890"),
##           or an empty string when no proxy is configured.
func implChooseProxy(
  terminalProxy: string,
  systemProxy: string,
  preferSystemProxy: bool
): tuple[url: string, source: string] =
  if preferSystemProxy and systemProxy.len > 0:
    return (url: systemProxy, source: "system")
  if terminalProxy.len > 0:
    return (url: terminalProxy, source: "terminal")
  result = (url: "", source: "")

when defined(getTest):
  func chooseProxyForTest*(
    terminalProxy: string,
    systemProxy: string,
    preferSystemProxy: bool
  ): tuple[url: string, source: string] =
    result = implChooseProxy(
      terminalProxy, systemProxy, preferSystemProxy)

proc implDetectSystemProxy(
  preferSystemProxy: bool
): tuple[url: string, source: string] =
  var terminalProxy = ""
  for name in ["HTTPS_PROXY", "https_proxy",
               "HTTP_PROXY",  "http_proxy",
               "ALL_PROXY",   "all_proxy"]:
    let v = getEnv(name, "")
    if v.len > 0:
      terminalProxy = v
      break

  if not preferSystemProxy:
    return implChooseProxy(
      terminalProxy, "", preferSystemProxy)

  when defined(windows):
      try:
        let keyPath =
          "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings"

        let (enableOut, enableCode) = execCmdEx(
          fmt"""reg query "{keyPath}" /v ProxyEnable""")
        if enableCode != 0:
          return implChooseProxy(
            terminalProxy, "", preferSystemProxy)

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
          return implChooseProxy(
            terminalProxy, "", preferSystemProxy)

        let (srvOut, srvCode) = execCmdEx(
          fmt"""reg query "{keyPath}" /v ProxyServer""")
        if srvCode != 0:
          return implChooseProxy(
            terminalProxy, "", preferSystemProxy)

        var srv = ""
        for line in srvOut.splitLines():
          if line.contains("ProxyServer"):
            let parts = line.splitWhitespace()
            if parts.len > 0:
              srv = parts[^1].strip()
            break

        if srv.len == 0:
          return implChooseProxy(
            terminalProxy, "", preferSystemProxy)

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
            return implChooseProxy(
              terminalProxy, "", preferSystemProxy)

        if not srv.contains("://"):
          srv = "http://" & srv
        return implChooseProxy(
          terminalProxy, srv, preferSystemProxy)
      except CatchableError:
        discard
  result = implChooseProxy(
    terminalProxy, "", preferSystemProxy)
  
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
# Private helpers — curl-based HTTP POST
# ---------------------------------------------------------------------------

## Posts a JSON body via a curl subprocess and returns the raw
## response body.  This is used as a fallback when a system
## proxy is detected, because Nim 2.x's AsyncHttpClient has a
## known bug with HTTPS CONNECT tunnelling through HTTP
## proxies.  Curl handles proxy tunnelling correctly.
##
## The subprocess inherits the caller's environment, so proxy
## variables (HTTPS_PROXY, HTTP_PROXY, etc.) are picked up
## automatically by curl.
##
## :param endpoint: The full URL to POST to.
## :param body: The serialised JSON request body.
## :param apiKey: The Bearer token.
## :param timeoutSec: Maximum seconds (0 = no limit).
## :returns: The raw response body on HTTP 200.
## :raises: LlmApiError: On non-200 status, timeout, or if
##          curl is not available.
proc implPostViaCurlAsync(
  endpoint: string,
  body: string,
  apiKey: string,
  timeoutSec: int,
  proxyUrl: string
): Future[string] {.async.} =
  var args = @[
    "-sS",
    "-X", "POST",
    endpoint,
    "-H", fmt"Authorization: Bearer {apiKey}",
    "-H", "Content-Type: application/json",
    "--data-binary", "@-",
    "-w", "\n%{http_code}"]
  if proxyUrl.len > 0:
    args.add("--proxy")
    args.add(proxyUrl)
  if timeoutSec > 0:
    args.add("--max-time")
    args.add($timeoutSec)
  let process = startProcess(
    "curl", args = args,
    options = {poUsePath, poStdErrToStdOut})
  try:
    process.inputStream.write(body)
    process.inputStream.flush()
  finally:
    process.inputStream.close()
  while true:
    let exitCode = process.peekExitCode()
    if exitCode != -1:
      break
    await sleepAsync(50)
  let output = process.outputStream.readAll()
  let exitCode = waitForExit(process)
  process.close()
  if exitCode != 0:
    let preview =
      if output.len > 512:
        output[0 ..< 512] & "..."
      else:
        output
    if "timed out" in output.toLowerAscii() or
        "timeout" in output.toLowerAscii() or
        exitCode == 28:
      raise newException(LlmApiError,
        fmt"request timed out after " &
        fmt"{timeoutSec}s. " &
        NETWORK_ERROR_MESSAGE)
    raise newException(LlmApiError,
      fmt"curl failed (exit {exitCode}): {preview}")
  # Split response body from HTTP status code.
  let lines = output.strip().rsplit('\n', 1)
  if lines.len < 2:
    raise newException(LlmApiError,
      "curl returned unexpected output")
  let httpCode = lines[^1].strip()
  let respBody = lines[0 ..< ^1].join("\n")
  if httpCode != "200":
    let preview =
      if respBody.len > 512:
        respBody[0 ..< 512] & "..."
      else:
        respBody
    raise newException(LlmApiError,
      fmt"API returned HTTP {httpCode}: {preview}")
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

## Removes provider-visible reasoning tags from message content.
##
## Some OpenAI-compatible providers return hidden reasoning in
## ``<think>...</think>`` text inside ``message.content``.  That
## text is not part of the user-facing answer and breaks strict
## token checks such as ``get isok``.
func implStripOneXmlBlock(
  text: string,
  tag: string
): string =
  result = text
  let openTag = "<" & tag & ">"
  let closeTag = "</" & tag & ">"
  while true:
    let lower = toLowerAscii(result)
    let start = lower.find(openTag)
    if start < 0:
      break
    let close = lower.find(closeTag, start + openTag.len)
    if close < 0:
      if start == 0:
        result = ""
      else:
        result = result[0 ..< start]
      break
    let afterClose = close + closeTag.len
    let before =
      if start > 0: result[0 ..< start] else: ""
    let after =
      if afterClose < result.len:
        result[afterClose .. ^1]
      else:
        ""
    result = before & after

func implStripThinkBlocks(content: string): string =
  result = implStripOneXmlBlock(content, "think")
  result = implStripOneXmlBlock(result, "thinking")
  result = result.strip()

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
  let cleanContent = implStripThinkBlocks(
    content.getStr())
  result = LlmResponse(
    content: cleanContent,
    tokensUsed:
      node{"usage"}{"total_tokens"}.getInt(0))

when defined(getTest):
  ## Exposes response parsing for test builds.
  proc parseResponseForTest*(body: string): LlmResponse =
    result = implParseResponse(body)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Sends an LlmRequest to the configured endpoint and returns
## the parsed LlmResponse.  Applies terminal proxy environment
## variables, optionally applies OS system proxy settings, and
## wraps low-level network failures into a short, user-friendly
## message.
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
  spinnerLabel: string = "requesting",
  preferSystemProxy: bool = false
): LlmResponse =
  if apiKey.len == 0:
    raise newException(GetError,
      "API key is not configured")
  if url.len == 0:
    raise newException(GetError,
      "API URL is not configured")
  let endpoint =
    implNormaliseUrl(url) & CHAT_COMPLETIONS_PATH

  let proxy = implDetectSystemProxy(preferSystemProxy)
  if proxy.url.len > 0 and not hideProcess:
    styleProgress(sk,
      fmt"using {proxy.source} proxy: {proxy.url}")

  let bodyStr = $implBuildRequestBody(req)

  # When a proxy is detected, use curl subprocess asynchronously via cooperative
  # event-loop yielding, allowing the spinner animation loop to execute.
  proc impl(): Future[LlmResponse] {.async.} =
    var respBody: string
    if proxy.url.len > 0:
      let fut = implPostViaCurlAsync(
        endpoint, bodyStr, apiKey, timeoutSec,
        proxy.url)
      respBody = await implAwaitWithProgress(
        fut, timeoutSec, hideProcess, sk,
        spinnerLabel)
    else:
      let client =
        when defined(windows):
          newAsyncHttpClient(sslContext = newContext(verifyMode = CVerifyNone))
        else:
          newAsyncHttpClient()
      client.headers = newHttpHeaders({
        "Authorization": fmt"Bearer {apiKey}",
        "Content-Type": "application/json"})
      try:
        let fut = implPostRequest(
          client, endpoint, bodyStr)
        respBody = await implAwaitWithProgress(
          fut, timeoutSec, hideProcess, sk,
          spinnerLabel)
      finally:
        client.close()
    result = implParseResponse(respBody)

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

