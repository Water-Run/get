## Cross-platform verified TLS context construction.
##
## :Author: WaterRun
## :GitHub: https://github.com/Water-Run/get
## :Date: 2026-08-24
## :File: tls_context.nim
## :License: AGPL-3.0
##
## Nim's OpenSSL backend scans PEM files on Windows but does not import the
## native certificate store. Clean Windows installations therefore fail even
## though their ROOT store is populated. This module imports those trusted DER
## certificates directly into an OpenSSL store without shipping a stale CA
## bundle or disabling peer verification.

{.experimental: "strictFuncs".}

import std/[net, strutils, uri]

when defined(windows):
  import std/[openssl, widestrs]

  type
    WindowsCertStore = pointer
    OpenSslX509Store = pointer
    OpenSslVerifyParam = pointer

    WindowsCertContext {.pure.} = object
      encodingType: uint32
      encoded: ptr uint8
      encodedLength: uint32
      certInfo: pointer
      certStore: WindowsCertStore

    PWindowsCertContext = ptr WindowsCertContext

  proc certOpenSystemStoreW(
    provider: pointer,
    subsystem: WideCString
  ): WindowsCertStore {.stdcall, dynlib: "crypt32.dll",
    importc: "CertOpenSystemStoreW".}

  proc certEnumCertificatesInStore(
    store: WindowsCertStore,
    previous: PWindowsCertContext
  ): PWindowsCertContext {.stdcall, dynlib: "crypt32.dll",
    importc: "CertEnumCertificatesInStore".}

  proc certCloseStore(
    store: WindowsCertStore,
    flags: uint32
  ): int32 {.stdcall, dynlib: "crypt32.dll",
    importc: "CertCloseStore".}

  proc sslCtxGetCertStore(
    context: SslCtx
  ): OpenSslX509Store {.cdecl, dynlib: DLLSSLName,
    importc: "SSL_CTX_get_cert_store".}

  proc sslCtxGetVerifyParam(
    context: SslCtx
  ): OpenSslVerifyParam {.cdecl, dynlib: DLLSSLName,
    importc: "SSL_CTX_get0_param".}

  proc x509StoreAddCert(
    store: OpenSslX509Store,
    certificate: PX509
  ): cint {.cdecl, dynlib: DLLUtilName,
    importc: "X509_STORE_add_cert".}

  proc x509Free(
    certificate: PX509
  ) {.cdecl, dynlib: DLLUtilName, importc: "X509_free".}

  proc x509VerifyParamSet1Host(
    parameter: OpenSslVerifyParam,
    hostname: cstring,
    hostnameLength: csize_t
  ): cint {.cdecl, dynlib: DLLUtilName,
    importc: "X509_VERIFY_PARAM_set1_host".}

  proc x509VerifyParamSet1Ip(
    parameter: OpenSslVerifyParam,
    address: cstring
  ): cint {.cdecl, dynlib: DLLUtilName,
    importc: "X509_VERIFY_PARAM_set1_ip_asc".}

  proc errClearError() {.cdecl, dynlib: DLLUtilName,
    importc: "ERR_clear_error".}

  ## Adds the current user's effective Windows ROOT store to OpenSSL.
  proc implLoadWindowsRoots(context: SslContext): int =
    let nativeStore = certOpenSystemStoreW(nil, newWideCString("ROOT"))
    if nativeStore.isNil:
      raise newException(IOError,
        "cannot open the Windows trusted root certificate store")
    defer:
      discard certCloseStore(nativeStore, 0)

    let opensslStore = sslCtxGetCertStore(context.context)
    if opensslStore.isNil:
      raise newException(IOError,
        "cannot access the OpenSSL certificate store")

    var certificate: PWindowsCertContext = nil
    while true:
      certificate = certEnumCertificatesInStore(nativeStore, certificate)
      if certificate.isNil:
        break
      if certificate.encoded.isNil or certificate.encodedLength == 0:
        continue
      var der = newString(certificate.encodedLength.int)
      copyMem(addr der[0], certificate.encoded, der.len)
      try:
        let decoded = d2i_X509(der)
        if not decoded.isNil:
          if x509StoreAddCert(opensslStore, decoded) == 1:
            result += 1
          else:
            # Duplicate roots are harmless, but OpenSSL leaves the duplicate
            # error queued and it must not contaminate the next TLS operation.
            errClearError()
          x509Free(decoded)
      except CatchableError:
        # Windows can contain non-X.509 contexts. Ignore only that individual
        # item and keep the OpenSSL error queue clean.
        errClearError()

## Creates a peer-verifying TLS context backed by the platform trust roots.
## On Windows, hostname/IP verification is configured in OpenSSL because Nim
## 2.2's socket wrapper omits its post-handshake hostname check on that OS.
proc newVerifiedSslContext*(hostname: string = ""): SslContext =
  when defined(windows):
    result = newContext(verifyMode = CVerifyNone)
    if implLoadWindowsRoots(result) == 0:
      raise newException(IOError,
        "Windows trusted root certificate store is empty")
    SSL_CTX_set_verify(result.context, SSL_VERIFY_PEER, nil)
    if hostname.len > 0:
      let parameter = sslCtxGetVerifyParam(result.context)
      if parameter.isNil:
        raise newException(IOError,
          "cannot configure TLS peer-name verification")
      var isIpAddress = true
      try:
        discard parseIpAddress(hostname)
      except ValueError:
        isIpAddress = false
      let configured =
        if isIpAddress:
          x509VerifyParamSet1Ip(parameter, hostname.cstring)
        else:
          x509VerifyParamSet1Host(
            parameter, hostname.cstring, hostname.len.csize_t)
      if configured != 1:
        raise newException(IOError,
          "cannot configure TLS peer-name verification")
  else:
    result = newContext(verifyMode = CVerifyPeer)

## Returns a hardened context only when the transport actually uses TLS.
## Supplying nil for plain HTTP avoids both needless root-store work and Nim's
## default Windows PEM-file scan; HttpClient never dereferences it for HTTP.
proc newTransportSslContext*(url: string): SslContext =
  let target = parseUri(url)
  if toLowerAscii(target.scheme) == "https":
    if target.hostname.len == 0:
      raise newException(ValueError, "HTTPS URL has no hostname")
    result = newVerifiedSslContext(target.hostname)
