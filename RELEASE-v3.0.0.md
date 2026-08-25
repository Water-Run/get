# get v3.0.0 release plan

Status: release-ready. All required gates below passed on the exact candidate
payload; the tag and public release are created only from that verified commit.

## Release highlights

- Unified provider-independent `Model -> Action -> Policy -> Tool ->
  Observation` runtime with `auto`, `direct`, `loop`, and `parallel` harnesses.
- Native function tools with strict JSON fallback and an isolated v2 Markdown
  compatibility decoder.
- Bounded parallel command execution with deterministic ordering, deadlines,
  output limits, process-tree cancellation, and an allowlist-based read-only
  grammar with per-tool, per-shell, repository-filter, option-abbreviation,
  glob-injection, and child-environment hardening.
- Non-executing policy-denial observations let budgeted Harness strategies ask
  for a fully revalidated safe replacement without widening the allowlist.
- History-driven compatibility rules admit bounded Linux/macOS `top`, native
  Windows performance readers, additional system reporters, pure AWK field
  selection, and display-only `sed` address expressions while retaining
  semantic rejection of their write, execute, and unbounded forms.
- Reusable HTTP transport with transient pre-HTTP retries, response-size caps,
  redirect blocking for bearer requests, proxy controls, and robust DeepSeek /
  Qwen response normalization.
- Cache schema v3 with SHA-256 context identities, deterministic eviction,
  cross-process writer locking, atomic durable snapshots, and backup recovery.
- Faster direct-first prompts and removal of router/cache-classifier model
  requests; cached answers require zero provider calls.
- Explicit no-tool intent is enforced at prompt, request, runtime, and cache
  boundaries; providers never receive a tool schema for those requests.
- Windows production hardening: DPAPI key storage, PowerShell/cmd guidance,
  process-tree termination, output decoding, pinned OpenSSL 3.5.7 LTS runtime,
  native ROOT-store import, DNS/IP hostname verification, and native Windows CI
  coverage.

## Compatibility notes

- Configuration is migrated to schema v3. The v2 `instance` option maps to the
  new harness setting.
- Cache schema v3 intentionally rejects incompatible or malformed snapshots;
  old cache data is not reused across incompatible provider, policy, shell, or
  working-directory contexts.
- The mandatory read-only policy cannot be disabled. `command-pattern` remains
  an optional additional blocklist.
- A single literal-file stdin redirect is accepted only for validated data
  readers. Shell expansion, heredocs, descriptor forms, process substitution,
  multiple input redirects, and `<>` remain rejected.
- `git status` and worktree-content diff are intentionally rejected; documented
  metadata-only and cached Git queries disable external diff and textconv
  helpers. The policy is a mutation-resistance gate, not a confidentiality or
  operating-system sandbox boundary.
- Windows release builds use Nim `refc` while Nim 2.2's ARC/ORC Windows runtime
  remains unsafe for the async-HTTP-to-osproc-thread sequence. Linux and macOS
  retain ORC.

## Required release gates

- [x] GitHub `Windows CI / Windows amd64` passes on the candidate commit.
- [x] Linux amd64: release build, all Nim unit tests, CLI E2E tests, and the
  full offline suite pass with zero failures.
- [x] Windows amd64: release build starts with packaged OpenSSL 3 DLLs; all
  Nim unit tests, Windows CLI E2E, DPAPI, PowerShell, proxy, timeout,
  output-cap, parallel-execution, and concurrent-cache tests pass on native
  Windows.
- [x] macOS arm64: release build and smoke tests pass on native Apple Silicon.
- [x] DeepSeek and local Qwen live smoke tests pass on the exact candidate
  binary for all 261 scenarios without logging or persisting credentials.
- [x] Positive compatibility and paired mutation cases pass identically on
  Linux, Windows, and macOS; Wine is supplementary, not a native substitute.
- [x] Installer smoke tests pass on clean Linux, Windows 10/11, and macOS user
  accounts with no pre-existing get configuration.
- [x] Repository credential scan, `git diff --check`, man-page rendering,
  Python byte-compilation, and package validation pass.
- [x] Every release archive is unpacked, checksummed, and its binary reports
  `3.0.0` on the target operating system.

## Canonical release package

Create `get-v3.0.0.zip` with this flat layout:

```text
get_ready.py
get-linux-x64
get-windows-x64.exe
libcrypto-3.dll
libssl-3.dll
zlib1.dll
get-macos-arm64
get.1
README.md
README-zh.md
LICENSE
OPENSSL-LICENSE.txt
ZLIB-LICENSE.txt
THIRD_PARTY_NOTICES.md
RELEASE_NOTES.md
BUILDINFO.json
SHA256SUMS
VALIDATION.md
benchmark-results.json
```

Build all binaries from the same commit with Nim 2.2.10. Windows binaries must
be compiled with `sslVersion=3`. The OpenSSL 3.5.7-1 and zlib 1.3.2-1
packages are pinned to the Cygwin repository metadata and verified before
extraction. Generate `SHA256SUMS` only after the final archive contents are
frozen. Do not reuse an older binary or DLL by filename alone; record its
source and checksum.

## Publish sequence

1. Freeze the candidate commit and wait for every required gate.
2. Build in clean environments and assemble the canonical archive.
3. Verify checksums, versions, archive layout, and installers from the archive.
4. Create an annotated `v3.0.0` tag on the verified commit and push the tag.
5. Create a draft GitHub Release using `RELEASE_NOTES-v3.0.0.md`; attach the
   archive and `get-v3.0.0.zip.sha256`.
6. Download the draft assets once, verify them independently, then publish.
7. Monitor installation and provider smoke checks; if a blocker appears, keep
   the release unpublished or mark it as a prerelease and fix forward from a
   new commit. Never move an already published tag.
