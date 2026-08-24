# get v3.0.0 release plan

Status: release candidate. Do not create or publish the `v3.0.0` tag until all
required gates below pass on the exact candidate commit.

## Release highlights

- Unified provider-independent `Model -> Action -> Policy -> Tool ->
  Observation` runtime with `auto`, `direct`, `loop`, and `parallel` harnesses.
- Native function tools with strict JSON fallback and an isolated v2 Markdown
  compatibility decoder.
- Bounded parallel command execution with deterministic ordering, deadlines,
  output limits, process-tree cancellation, and mandatory read-only policy.
- Reusable HTTP transport with transient pre-HTTP retries, response-size caps,
  redirect blocking for bearer requests, proxy controls, and robust DeepSeek /
  Qwen response normalization.
- Cache schema v3 with SHA-256 context identities, deterministic eviction,
  cross-process writer locking, atomic durable snapshots, and backup recovery.
- Faster direct-first prompts and removal of router/cache-classifier model
  requests; cached answers require zero provider calls.
- Windows production hardening: DPAPI key storage, PowerShell/cmd guidance,
  process-tree termination, output decoding, runtime DLL packaging, and native
  Windows CI coverage.

## Compatibility notes

- Configuration is migrated to schema v3. The v2 `instance` option maps to the
  new harness setting.
- Cache schema v3 intentionally rejects incompatible or malformed snapshots;
  old cache data is not reused across incompatible provider, policy, shell, or
  working-directory contexts.
- The mandatory read-only policy cannot be disabled. `command-pattern` remains
  an optional additional blocklist.
- Windows release builds use Nim `refc` while Nim 2.2's ARC/ORC Windows runtime
  remains unsafe for the async-HTTP-to-osproc-thread sequence. Linux and macOS
  retain ORC.

## Required release gates

- [ ] GitHub `Windows CI / Windows amd64` passes on the candidate commit.
- [ ] Linux amd64: release build, 63 Nim tests, 18 CLI E2E tests, and the full
  offline suite pass with zero failures.
- [ ] Windows amd64: release build starts with packaged OpenSSL DLLs; 65 Nim
  tests, Windows CLI E2E, DPAPI, PowerShell, proxy, timeout, output-cap,
  parallel-execution, and concurrent-cache tests pass on native Windows.
- [ ] macOS arm64: release build and smoke tests pass on native Apple Silicon.
- [ ] DeepSeek and local Qwen live smoke tests pass on the exact candidate
  binary without logging or persisting credentials.
- [ ] Installer smoke tests pass on clean Linux, Windows 10/11, and macOS user
  accounts with no pre-existing get configuration.
- [ ] Repository credential scan, `git diff --check`, man-page rendering,
  Python byte-compilation, and package validation pass.
- [ ] Every release archive is unpacked and its binary reports `3.0.0`.

## Canonical release package

Create `get-v3.0.0.zip` with this flat layout:

```text
get_ready.py
get-linux-x64
get-windows-x64.exe
libcrypto-1_1-x64.dll
libssl-1_1-x64.dll
get-macos-arm64
get.1
README.md
README-zh.md
LICENSE
SHA256SUMS
```

Build all binaries from the same commit with Nim 2.2.10. Generate
`SHA256SUMS` only after the final archive contents are frozen. Do not reuse an
older binary or DLL by filename alone; record its source and checksum.

## Publish sequence

1. Freeze the candidate commit and wait for every required gate.
2. Build in clean environments and assemble the canonical archive.
3. Verify checksums, versions, archive layout, and installers from the archive.
4. Create an annotated `v3.0.0` tag on the verified commit and push the tag.
5. Create a draft GitHub Release using the highlights and compatibility notes
   above; attach the archive and `SHA256SUMS`.
6. Download the draft assets once, verify them independently, then publish.
7. Monitor installation and provider smoke checks; if a blocker appears, keep
   the release unpublished or mark it as a prerelease and fix forward from a
   new commit. Never move an already published tag.
