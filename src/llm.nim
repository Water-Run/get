## LLM API communication for the get tool.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: llm.nim
## :License: AGPL-3.0
##
## This module sends requests to an OpenAI-compatible chat-completions
## endpoint, parses text and native function-tool responses, and displays
## elapsed-time progress while an HTTP round-trip is in flight.  A reusable
## session keeps one HTTP client alive across harness turns.
##
## The module honors terminal HTTP/HTTPS proxy variables and can explicitly
## prefer Windows Internet Settings. NO_PROXY applies to either source.
## Low-level network failures
## are classified and wrapped into a short, user-friendly
## message so that operating-system specific or async traceback
## noise is never shown to the user.

{.experimental: "strictFuncs".}

import std/[asyncdispatch, asyncstreams, httpclient, json, monotimes, net, os,
            strformat, strutils, times, uri]

when defined(windows):
  import std/osproc

import style
import tls_context
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

## Number of immediate retries for transport failures without an HTTP response.
const TRANSIENT_NETWORK_RETRIES* = 3

## Hard cap for one complete provider response body.
const MAX_LLM_RESPONSE_BYTES* = 8 * 1024 * 1024

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

## Raised when the LLM API returns a non-successful HTTP status,
## a malformed response body, or when the request times out.
type
  LlmApiError* = object of GetError

## Defines one provider-native function tool.
type
  LlmToolDefinition* = object
    name*: string            ## Stable function name.
    description*: string     ## Concise model-facing usage description.
    parametersJson*: string  ## JSON Schema object encoded as JSON.
    strict*: bool            ## Whether supporting providers enforce the schema.

## Captures one function tool call returned by a provider.
type
  LlmToolCall* = object
    id*: string         ## Provider call identifier.
    name*: string       ## Function name selected by the model.
    arguments*: string  ## Raw JSON argument object.

## Encapsulates a single chat-completion request.
type
  LlmRequest* = object
    model*: string                       ## Model identifier.
    messages*: seq[LlmMessage]           ## Conversation messages.
    maxTokens*: int                      ## Max tokens (0 = omit).
    tools*: seq[LlmToolDefinition]       ## Available native function tools.
    parallelToolCalls*: bool             ## Allow multiple calls in one turn.

## Encapsulates the parsed response returned by the API.
type
  LlmResponse* = object
    content*: string                ## Text from the first choice.
    tokensUsed*: int                ## Total tokens consumed.
    toolCalls*: seq[LlmToolCall]    ## Provider-native function calls.
    toolCallsJson*: string          ## Original assistant tool_calls JSON.
    finishReason*: string           ## Provider finish reason, when present.
    providerRequests*: int          ## Physical provider attempts represented.

  ## Holds a reusable provider connection for one harness run.
type
  LlmSession* = ref object
    url: string             ## Configured API base URL.
    timeoutSec: int         ## Request timeout in seconds.
    hideProcess: bool       ## Suppress progress output.
    styleKind: StyleKind    ## Terminal output style.
    client: AsyncHttpClient ## Reused HTTP client, including proxy transport.

# ---------------------------------------------------------------------------
# Private helpers — proxy detection
# ---------------------------------------------------------------------------

## Selects terminal or OS proxy input according to explicit preference.
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

## Returns whether NO_PROXY bypasses the target host.
proc implNoProxyMatch(targetHost: string): bool =
  let noProxy = getEnv("NO_PROXY", getEnv("no_proxy", ""))
  if noProxy.len == 0 or targetHost.len == 0:
    return false
  for rawEntry in noProxy.split(','):
    var entry = toLowerAscii(rawEntry.strip())
    if entry == "*":
      return true
    if entry.startsWith("."):
      entry = entry[1 .. ^1]
    let colon = entry.rfind(':')
    if colon > 0 and entry.count(':') == 1:
      entry = entry[0 ..< colon]
    if entry.len > 0 and
        (targetHost == entry or targetHost.endsWith("." & entry)):
      return true
  result = false

## Reads terminal proxy environment variables for the target scheme.
proc implTerminalProxy(targetScheme: string): string =
  let schemeNames =
    if targetScheme == "http":
      ["HTTP_PROXY", "http_proxy", "HTTPS_PROXY", "https_proxy"]
    else:
      ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"]
  for name in schemeNames:
    let value = getEnv(name, "")
    if value.len > 0:
      return value
  for name in ["ALL_PROXY", "all_proxy"]:
    let value = getEnv(name, "")
    if value.len > 0:
      return value
  result = ""

when defined(windows):
  ## Reads the enabled Windows Internet Settings proxy for one scheme.
  proc implWindowsSystemProxy(targetScheme: string): string =
    try:
      let keyPath =
        "HKCU\\Software\\Microsoft\\Windows\\CurrentVersion" &
        "\\Internet Settings"
      let (enableOut, enableCode) = execCmdEx(
        fmt"""reg query "{keyPath}" /v ProxyEnable""")
      if enableCode != 0:
        return ""

      var enabled = false
      for line in enableOut.splitLines():
        if line.contains("ProxyEnable") and line.contains("0x"):
          let index = line.rfind("0x")
          if index >= 0:
            try:
              enabled = parseHexInt(
                line[index + 2 .. ^1].strip()) != 0
            except ValueError:
              enabled = false
          break
      if not enabled:
        return ""

      let (serverOut, serverCode) = execCmdEx(
        fmt"""reg query "{keyPath}" /v ProxyServer""")
      if serverCode != 0:
        return ""
      var server = ""
      for line in serverOut.splitLines():
        if line.contains("ProxyServer"):
          let parts = line.splitWhitespace()
          if parts.len > 0:
            server = parts[^1].strip()
          break
      if server.len == 0:
        return ""

      if server.contains("="):
        var httpProxy = ""
        var httpsProxy = ""
        for part in server.split(';'):
          let pair = part.split('=', 1)
          if pair.len == 2:
            case toLowerAscii(pair[0].strip())
            of "http": httpProxy = pair[1].strip()
            of "https": httpsProxy = pair[1].strip()
            else: discard
        if targetScheme == "http":
          server =
            if httpProxy.len > 0: httpProxy
            else: httpsProxy
        else:
          server =
            if httpsProxy.len > 0: httpsProxy
            else: httpProxy
      if server.len > 0 and not server.contains("://"):
        server = "http://" & server
      result = server
    except CatchableError:
      result = ""

## Detects the effective proxy once for a reusable provider session.
##
## Terminal environment variables are always eligible. Windows Internet
## Settings are queried only when preferSystemProxy is true and then take
## precedence. NO_PROXY bypasses both sources.
proc implDetectProxy(
  targetUrl: string,
  preferSystemProxy: bool
): tuple[url: string, source: string] =
  var targetHost = ""
  var targetScheme = ""
  try:
    let target = parseUri(targetUrl)
    targetHost = toLowerAscii(target.hostname)
    targetScheme = toLowerAscii(target.scheme)
  except ValueError:
    discard
  if implNoProxyMatch(targetHost):
    return (url: "", source: "")

  let terminalProxy = implTerminalProxy(targetScheme)
  var systemProxy = ""
  when defined(windows):
    if preferSystemProxy:
      systemProxy = implWindowsSystemProxy(targetScheme)
  result = implChooseProxy(
    terminalProxy, systemProxy, preferSystemProxy)

## Redacts optional credentials before a proxy URL is displayed.
##
## :param proxyUrl: Configured proxy URL, possibly containing user info.
## :returns: Display-safe URL with credentials replaced by a marker.
func implRedactProxy(proxyUrl: string): string =
  let separator = proxyUrl.find("@")
  if separator < 0:
    return proxyUrl
  let scheme = proxyUrl.find("://")
  if scheme >= 0 and scheme < separator:
    return proxyUrl[0 .. scheme + 2] &
      "***@" & proxyUrl[separator + 1 .. ^1]
  result = "***@" & proxyUrl[separator + 1 .. ^1]
  
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
    if m.role == "tool" and m.toolCallId.len == 0:
      raise newException(LlmApiError,
        "tool message is missing tool_call_id")
    if m.toolCallId.len > 0 and m.role != "tool":
      raise newException(LlmApiError,
        "tool_call_id is only valid on tool messages")
    if m.toolCallsJson.len > 0 and m.role != "assistant":
      raise newException(LlmApiError,
        "tool_calls is only valid on assistant messages")
    var messageNode = %*{
      "role": m.role,
      "content": m.content
    }
    if m.toolCallId.len > 0:
      messageNode["tool_call_id"] = %m.toolCallId
    if m.toolCallsJson.len > 0:
      try:
        let callsNode = parseJson(m.toolCallsJson)
        if callsNode.kind != JArray:
          raise newException(LlmApiError,
            "assistant tool calls must be a JSON array")
        messageNode["tool_calls"] = callsNode
        if m.content.len == 0:
          messageNode["content"] = newJNull()
      except JsonParsingError:
        raise newException(LlmApiError,
          "assistant tool calls contain malformed JSON")
    msgs.add(messageNode)
  result = %*{
    "model": req.model,
    "messages": msgs
  }
  if req.maxTokens > 0:
    result["max_tokens"] = %req.maxTokens
  if req.tools.len > 0:
    var toolsNode = newJArray()
    for tool in req.tools:
      var parameters: JsonNode
      try:
        parameters = parseJson(tool.parametersJson)
      except JsonParsingError:
        raise newException(LlmApiError,
          fmt"tool '{tool.name}' has malformed parameters JSON")
      if parameters.kind != JObject:
        raise newException(LlmApiError,
          fmt"tool '{tool.name}' parameters must be an object")
      var functionNode = %*{
        "name": tool.name,
        "description": tool.description,
        "parameters": parameters
      }
      if tool.strict:
        functionNode["strict"] = %true
      toolsNode.add(%*{
        "type": "function",
        "function": functionNode
      })
    result["tools"] = toolsNode
    result["tool_choice"] = %"auto"
    if req.parallelToolCalls:
      result["parallel_tool_calls"] = %true

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

## Reads an HTTP response without permitting an unbounded provider payload.
##
## Both declared and streamed sizes are checked because chunked responses do
## not carry a Content-Length header and untrusted endpoints can lie about it.
proc implReadBodyBounded(
  response: AsyncResponse
): Future[string] {.async.} =
  var declaredSize = -1
  try:
    declaredSize = response.contentLength()
  except ValueError:
    raise newException(LlmApiError,
      "API returned an invalid Content-Length header")
  if declaredSize > MAX_LLM_RESPONSE_BYTES:
    raise newException(LlmApiError,
      fmt"API response exceeds {MAX_LLM_RESPONSE_BYTES} bytes")

  result = ""
  while true:
    let (hasValue, chunk) = await response.bodyStream.read()
    if not hasValue:
      break
    if chunk.len > MAX_LLM_RESPONSE_BYTES - result.len:
      raise newException(LlmApiError,
        fmt"API response exceeds {MAX_LLM_RESPONSE_BYTES} bytes")
    result.add(chunk)

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
  let respBody = await implReadBodyBounded(resp)
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
  let timeoutMs =
    if timeoutSec <= 0:
      0
    elif timeoutSec > high(int) div 1000:
      high(int)
    else:
      timeoutSec * 1000
  if hideProcess:
    if timeoutMs > 0:
      let completed = await withTimeout(fut, timeoutMs)
      if not completed:
        raise newException(LlmApiError,
          fmt"request timed out after {timeoutSec}s. " &
          NETWORK_ERROR_MESSAGE)
    result = await fut
    return

  var elapsedMs = 0
  var displayedSeconds = 0
  var lineOpen = false
  let initialMsg = spinnerLabel & "..."
  if sk == skVivid:
    writeSpinner(0, initialMsg)
  else:
    stderr.write(spinnerLabel)
    stderr.flushFile()
    lineOpen = true
  while not fut.finished:
    let remainingMs =
      if timeoutMs > 0:
        timeoutMs - elapsedMs
      else:
        100
    if remainingMs <= 0:
      break
    let intervalMs = min(100, remainingMs)
    let completed = await withTimeout(fut, intervalMs)
    if completed:
      break
    elapsedMs += intervalMs
    let elapsedSeconds = elapsedMs div 1000
    if elapsedSeconds > displayedSeconds:
      displayedSeconds = elapsedSeconds
      if sk == skVivid:
        let message =
          if timeoutSec > 0:
            fmt"{spinnerLabel}... {elapsedSeconds}/{timeoutSec}s"
          else:
            fmt"{spinnerLabel}... {elapsedSeconds}s"
        writeSpinner(elapsedSeconds, message)
      else:
        if elapsedSeconds <= 10:
          if elapsedSeconds mod 2 == 0:
            stderr.write(".")
            stderr.flushFile()
        elif elapsedSeconds == 11:
          if lineOpen:
            stderr.writeLine("")
            lineOpen = false
          let waitMsg =
            if timeoutSec > 0:
              fmt"- waited 10/{timeoutSec}s"
            else:
              "- waited 10s (no timeout)"
          stderr.writeLine(waitMsg)
        elif elapsedSeconds mod 10 == 0:
          let waitMsg =
            if timeoutSec > 0:
              fmt"- waited {elapsedSeconds}" &
              fmt"/{timeoutSec}s"
            else:
              fmt"- waited {elapsedSeconds}s" &
              " (no timeout)"
          stderr.writeLine(waitMsg)
  if sk == skVivid:
    clearSpinner()
  elif lineOpen:
    stderr.writeLine("")
  if not fut.finished:
    raise newException(LlmApiError,
      fmt"request timed out after {timeoutSec}s. " &
      NETWORK_ERROR_MESSAGE)
  result = await fut

# ---------------------------------------------------------------------------
# Private helpers — response parsing
# ---------------------------------------------------------------------------

## Removes complete provider-visible reasoning tags from message content.
func implStripOneXmlBlock(text: string, tag: string): string =
  let openTag = "<" & tag & ">"
  let closeTag = "</" & tag & ">"
  let lower = toLowerAscii(text)
  var cursor = 0
  while true:
    let start = lower.find(openTag, cursor)
    if start < 0:
      if cursor < text.len:
        result.add(text[cursor .. ^1])
      break
    if start > cursor:
      result.add(text[cursor ..< start])
    let close = lower.find(closeTag, start + openTag.len)
    if close < 0:
      # An unterminated reasoning suffix is never user-facing output.
      break
    cursor = close + closeTag.len

## Removes orphan provider-template closing tags from message content.
func implStripOneXmlClosingTag(text: string, tag: string): string =
  let closeTag = "</" & tag & ">"
  let lower = toLowerAscii(text)
  var cursor = 0
  while true:
    let position = lower.find(closeTag, cursor)
    if position < 0:
      if cursor < text.len:
        result.add(text[cursor .. ^1])
      break
    if position > cursor:
      result.add(text[cursor ..< position])
    cursor = position + closeTag.len

func implStripThinkBlocks(content: string): string =
  result = implStripOneXmlBlock(content, "think")
  result = implStripOneXmlBlock(result, "thinking")
  for tag in [
    "think", "thinking", "parameter", "final_comment",
    "invoke", "function", "tool_call"
  ]:
    result = implStripOneXmlClosingTag(result, tag)
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
  if msg.isNil or msg.kind != JObject:
    raise newException(LlmApiError,
      "API response missing 'message'")
  let content = msg{"content"}
  var contentText = ""
  if not content.isNil and content.kind == JString:
    contentText = implStripThinkBlocks(content.getStr())
  var calls: seq[LlmToolCall] = @[]
  var callsJson = ""
  let callsNode = msg{"tool_calls"}
  if not callsNode.isNil and callsNode.kind != JNull:
    if callsNode.kind != JArray:
      raise newException(LlmApiError,
        "API response 'tool_calls' is not an array")
    callsJson = $callsNode
    for callNode in callsNode:
      if callNode.kind != JObject:
        raise newException(LlmApiError,
          "API response contains malformed tool call")
      let callType = callNode{"type"}.getStr("function")
      if callType != "function":
        raise newException(LlmApiError,
          fmt"API response uses unsupported tool-call type '{callType}'")
      let callId = callNode{"id"}.getStr("").strip()
      let functionNode = callNode{"function"}
      if functionNode.isNil or functionNode.kind != JObject:
        raise newException(LlmApiError,
          "API response tool call is missing 'function'")
      let functionName = functionNode{"name"}.getStr("").strip()
      let arguments = functionNode{"arguments"}.getStr("").strip()
      if callId.len == 0 or functionName.len == 0 or
          arguments.len == 0:
        raise newException(LlmApiError,
          "API response contains incomplete tool call")
      calls.add(LlmToolCall(
        id: callId,
        name: functionName,
        arguments: arguments
      ))
  if contentText.len == 0 and calls.len == 0:
    raise newException(LlmApiError,
      "API response contains neither content nor tool calls")
  result = LlmResponse(
    content: contentText,
    tokensUsed:
      node{"usage"}{"total_tokens"}.getInt(0),
    toolCalls: calls,
    toolCallsJson: callsJson,
    finishReason:
      choices[0]{"finish_reason"}.getStr(""),
    providerRequests: 1
  )

when defined(getTest):
  ## Detects the effective proxy for a target URL in test builds.
  ##
  ## :param targetUrl: Provider URL used for scheme and NO_PROXY selection.
  ## :returns: Selected proxy URL, or an empty string when bypassed.
  ##
  ## .. code-block:: nim
  ##   runnableExamples:
  ##     discard
  proc detectSystemProxyForTest*(
    targetUrl: string,
    preferSystemProxy: bool = false
  ): string =
    result = implDetectProxy(
      targetUrl, preferSystemProxy).url

  ## Tests proxy source precedence without platform registry access.
  func chooseProxyForTest*(
    terminalProxy: string,
    systemProxy: string,
    preferSystemProxy: bool
  ): tuple[url: string, source: string] =
    result = implChooseProxy(
      terminalProxy, systemProxy, preferSystemProxy)

  ## Builds a provider request body in test builds.
  ##
  ## :param req: Request value to encode.
  ## :returns: Chat-completions JSON body.
  ## :raises: LlmApiError: If embedded tool JSON is malformed.
  ##
  ## .. code-block:: nim
  ##   runnableExamples:
  ##     discard
  proc buildLlmRequestBodyForTest*(req: LlmRequest): JsonNode =
    result = implBuildRequestBody(req)

  ## Parses a raw provider response in test builds.
  ##
  ## :param body: Raw chat-completions response body.
  ## :returns: Parsed response including native tool calls.
  ## :raises: LlmApiError: If the response is malformed.
  ##
  ## .. code-block:: nim
  ##   runnableExamples:
  ##     discard
  proc parseLlmResponseForTest*(body: string): LlmResponse =
    result = implParseResponse(body)

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Creates a reusable LLM session for one harness run.
##
## Direct and proxy requests share one keep-alive HTTP client. Proxy detection
## occurs only once per session, and TLS certificate verification remains
## enabled on every platform.
##
## :param url: API base URL.
## :param apiKey: Bearer token; never included in logs or errors.
## :param timeoutSec: Maximum seconds per request; zero disables the limit.
## :param hideProcess: Suppress request progress output.
## :param sk: Terminal output style.
## :param preferSystemProxy: Prefer Windows Internet Settings when enabled.
## :returns: An initialized LlmSession.
## :raises: GetError: If the URL or key is empty.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc newLlmSession*(
  url: string,
  apiKey: string,
  timeoutSec: int = 300,
  hideProcess: bool = false,
  sk: StyleKind = skSimp,
  preferSystemProxy: bool = false
): LlmSession =
  if apiKey.len == 0:
    raise newException(GetError,
      "API key is not configured")
  if url.len == 0:
    raise newException(GetError,
      "API URL is not configured")
  let proxy = implDetectProxy(url, preferSystemProxy)
  if proxy.url.len > 0 and not hideProcess:
    styleProgress(sk,
      fmt"using {proxy.source} proxy: {implRedactProxy(proxy.url)}")
  let sslContext = newTransportSslContext(url)
  let client =
    if proxy.url.len > 0:
      newAsyncHttpClient(
        maxRedirects = 0,
        sslContext = sslContext,
        proxy = newProxy(proxy.url))
    else:
      newAsyncHttpClient(
        maxRedirects = 0,
        sslContext = sslContext)
  client.headers = newHttpHeaders({
    "Authorization": fmt"Bearer {apiKey}",
    "Content-Type": "application/json"
  })
  result = LlmSession(
    url: implNormaliseUrl(url),
    timeoutSec: timeoutSec,
    hideProcess: hideProcess,
    styleKind: sk,
    client: client
  )

## Closes the reusable transport owned by a session.
##
## :param session: Session to close. Repeated calls are harmless.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc closeLlmSession*(session: LlmSession) =
  if not session.isNil and not session.client.isNil:
    session.client.close()
    session.client = nil

## Sends one request through an existing reusable session.
##
## The public boundary is synchronous; its internal transport remains async so
## progress animation and request timeouts continue to work.
##
## :param session: Reusable provider session.
## :param req: Request payload, including optional native tools.
## :param spinnerLabel: Text shown while awaiting the provider.
## :param preferSystemProxy: Prefer Windows Internet Settings when enabled.
## :returns: Parsed text and/or native tool calls.
## :raises: LlmApiError: On timeout, HTTP error, or malformed response.
## :raises: GetError: If the session is invalid.
##
## .. code-block:: nim
##   runnableExamples:
##     discard
proc sendLlmRequest*(
  session: LlmSession,
  req: LlmRequest,
  spinnerLabel: string = "requesting"
): LlmResponse =
  if session.isNil:
    raise newException(GetError,
      "LLM session is not initialized")
  let endpoint = session.url & CHAT_COMPLETIONS_PATH

  let bodyStr = $implBuildRequestBody(req)

  ## Sends and parses this request asynchronously and must be awaited.
  ##
  ## :returns: Parsed provider response.
  ## :raises: LlmApiError: If the transport is closed or the request fails.
  proc impl(attemptTimeoutSec: int): Future[LlmResponse] {.async.} =
    if session.client.isNil:
      raise newException(LlmApiError,
        "LLM session transport is closed")
    let fut = implPostRequest(
      session.client, endpoint, bodyStr)
    let respBody = await implAwaitWithProgress(
      fut, attemptTimeoutSec,
      session.hideProcess, session.styleKind,
      spinnerLabel)
    result = implParseResponse(respBody)

  let requestStarted = getMonoTime()
  var transientFailures = 0
  while true:
    let attemptTimeoutSec =
      if session.timeoutSec <= 0:
        0
      else:
        let elapsedMs =
          (getMonoTime() - requestStarted).inMilliseconds
        let remainingMs =
          int64(session.timeoutSec) * 1000 - elapsedMs
        if remainingMs <= 0:
          raise newException(LlmApiError,
            fmt"request timed out after {session.timeoutSec}s. " &
            NETWORK_ERROR_MESSAGE)
        int(max(1'i64, (remainingMs + 999) div 1000))
    try:
      result = waitFor impl(attemptTimeoutSec)
      result.providerRequests += transientFailures
      return
    except LlmApiError:
      raise
    except GetError:
      raise
    except CatchableError as error:
      let clean = implCleanErrorMessage(error.msg)
      let isTransient =
        clean.len == 0 or implIsNetworkError(clean)
      if isTransient and
          transientFailures < TRANSIENT_NETWORK_RETRIES:
        transientFailures += 1
        # Nim's keep-alive client can retain a socket marked connected after
        # some TLS/read failures. Closing it here preserves the session and
        # headers while forcing the next attempt onto a fresh connection.
        if not session.client.isNil:
          session.client.close()
        continue
      if isTransient:
        raise newException(LlmApiError,
          NETWORK_ERROR_MESSAGE)
      raise newException(LlmApiError,
        fmt"request failed: {clean}")

## Sends a one-shot request through a temporary session.
##
## Existing v2 call sites use this compatibility overload. The v3 harness uses
## the session overload so multiple turns retain the same connection.
##
## :param req: Request payload.
## :param url: API base URL.
## :param apiKey: Bearer token.
## :param timeoutSec: Maximum seconds to wait; zero disables the limit.
## :param hideProcess: Suppress request progress output.
## :param sk: Terminal output style.
## :param spinnerLabel: Text shown while awaiting the provider.
## :returns: Parsed text and/or native tool calls.
## :raises: LlmApiError: On timeout, HTTP error, or malformed response.
## :raises: GetError: If required configuration is missing.
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
  let session = newLlmSession(
    url, apiKey, timeoutSec, hideProcess, sk,
    preferSystemProxy)
  try:
    result = sendLlmRequest(
      session, req, spinnerLabel)
  finally:
    closeLlmSession(session)
