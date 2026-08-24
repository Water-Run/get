## Cross-platform tests for production TLS context selection.

{.experimental: "strictFuncs".}

import std/unittest

import tls_context

suite "verified TLS contexts":
  test "plain HTTP does not construct an unused TLS context":
    check newTransportSslContext("http://127.0.0.1:8080/v1").isNil

  test "HTTPS constructs a platform-verifying context":
    check not newTransportSslContext("https://example.com/v1").isNil

  test "HTTPS requires a hostname":
    expect ValueError:
      discard newTransportSslContext("https:///v1")
