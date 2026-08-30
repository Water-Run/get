import std/[httpclient, os, uri]

import tls_context

const DefaultReleaseSmokeUrl = "https://example.com/"

let target = getEnv("GET_RELEASE_HTTPS_URL", DefaultReleaseSmokeUrl)
var client = newHttpClient(
  userAgent = "get/3.0.1 release-smoke",
  sslContext = newVerifiedSslContext(parseUri(target).hostname),
  timeout = 30_000,
)

try:
  let response = client.request(target, httpMethod = HttpGet)
  if response.code != Http200:
    quit("HTTPS release smoke returned " & $response.code, QuitFailure)
  if response.body.len == 0:
    quit("HTTPS release smoke returned an empty body", QuitFailure)
  echo "HTTPS release smoke passed: ", response.code
finally:
  client.close()
