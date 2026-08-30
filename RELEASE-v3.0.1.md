# get v3.0.1 release plan

Status: provider-validated release candidate. Source commit
`a349bd4e3a2b45b46cb5b14f7419ba23fe75a981` is on `main`; Windows CI run
33306374273 and the three native Nim 2.2.10 gates in no-assembly run
33306378137 are green. The run's 2,236,088-byte Linux payload, SHA-256
`71d07ac4c9a14ec74551b64057c74aee9f488a2213e0c55da8820c512c21a1d1`,
passed both canonical provider replays. Pinned rebuild, checksum-bound assembly,
archive installation, tagging, and publication remain ordered release gates.

## Release purpose

v3.0.1 is a production hardening update to the v3 Harness. Its primary change
is a history-driven semantic read-only boundary that admits realistic host
inspection while closing PATH/environment/helper/config and shell-grammar
bypasses. It also finishes provider parsing, Harness state handling, cache
durability, resource-aware test orchestration, and cross-platform coverage.

## Required gates

- [x] Version metadata is consistently `3.0.1`.
- [x] `nimble check`, Python byte-compilation, `git diff --check`, man-page
  rendering, and tracked-file credential scan pass.
- [x] Linux: 12 Nim test files, 32 CLI tests, and 294-case offline matrix pass.
- [x] Windows/Wine: 12 actual PE test executables pass; 31 applicable CLI tests
  pass with one POSIX-only skip; the post-fix cache/log matrix is 21/21 and the
  broader 294-case offline matrix has zero failures.
- [x] Native macOS arm64: 12 Nim test files, 32 CLI tests, and 281-case offline
  matrix pass.
- [x] Read-only policy: 3,383/3,383 decisions match on Linux, Windows/Wine, and
  native macOS.
- [x] Cache stress preserves 192/192 concurrent writes with valid backup and no
  stale lock/temp files.
- [x] Executor stress passes 20/20 deadlines and 50/50 output caps.
- [x] Local candidate: DeepSeek `deepseek-v4-flash` 47/47.
- [x] Local candidate: DGX Qwen `qwen3.8-27b` 47/47.
- [x] Push the reviewed source commit to the sole `main` branch.
- [x] Native GitHub Actions Linux/Windows/macOS jobs pass with Nim 2.2.10.
- [x] Download one canonical Linux artifact and replay 47/47 independently with
  DeepSeek and Qwen, without rebuilding between providers.
- [x] Pin the exact canonical Linux SHA-256 in the metadata-only release commit.
- [ ] The pinned native CI run is green and reproduces the validated Linux payload.
- [ ] Dispatch checksum-bound assembly and verify the attested flat package.
- [ ] Derive and independently install-test all three platform archives.
- [ ] Install the packaged Linux archive on this system while preserving config.
- [ ] Create immutable annotated tag `v3.0.1` on the verified `main` commit.
- [ ] Publish the GitHub Release and attach archives, outer checksums, and manifest.
- [ ] Confirm the remote repository exposes only `main` as a branch.

## Canonical flat package

The assembly job creates `get-v3.0.1.zip` as an internal attestation package:

```text
BUILDINFO.json
LICENSE
OPENSSL-LICENSE.txt
README-zh.md
README.md
RELEASE_NOTES.md
SHA256SUMS
THIRD_PARTY_NOTICES.md
VALIDATION.md
ZLIB-LICENSE.txt
benchmark-results.json
get-linux-x64
get-macos-arm64
get-windows-x64.exe
get.1
get_ready.py
libcrypto-3.dll
libssl-3.dll
zlib1.dll
```

All native payloads come from one Git commit and Nim 2.2.10 CI jobs. Assembly
fails unless the Linux binary is byte-identical to the provider-replayed hash.
`SHA256SUMS` is generated only after the package content is frozen.

## Public archives

Derive these archives byte-for-byte from the verified flat package:

- `get-v3.0.1-linux-x64.zip`
- `get-v3.0.1-windows-x64.zip`
- `get-v3.0.1-macos-arm64.zip`

Each archive contains only its selected native payload plus the installer,
README files, license, release notes, validation report, benchmark JSON,
`BUILDINFO.json`, and an internal `SHA256SUMS`. The Windows archive additionally
contains the three pinned runtime DLLs and OpenSSL/zlib license notices.

Publish alongside them:

- `SHA256SUMS-v3.0.1.txt` — SHA-256 of the three public ZIP files;
- `get-v3.0.1-assets.json` — filename, bytes, SHA-256, platform, architecture,
  version, commit, and required payload files.

## Independent archive verification

For each public ZIP:

1. extract into a new directory;
2. compare exact filenames with the platform manifest;
3. run `sha256sum --check SHA256SUMS` (or the platform equivalent);
4. confirm the binary format and architecture;
5. confirm `get version` is `3.0.1`;
6. byte-compare the payload against the attested flat package;
7. run the installer with an isolated clean home/profile;
8. confirm the installed binary and Windows DLLs/man page;
9. repeat once with an existing configuration and prove its URL/model/key-set
   state is preserved without printing the key.

Native Windows CI and native Apple Silicon validation remain authoritative;
Wine and the remote macOS host are independent supplementary checks.

## Publish sequence

1. Review all tracked diffs and commit source/docs/tests on `main`.
2. Push `main`; wait for every native job in the no-assembly workflow.
3. Download and hash the canonical Linux payload.
4. Run the 47 live Harness cases independently with DeepSeek and Qwen against
   that exact file. Do not rebuild between replays.
5. Update only the workflow's pinned hash and validation provenance; commit and
   push. Confirm the rebuilt Linux payload is identical.
6. Dispatch `assemble_release=true`. Download and verify its attested flat ZIP.
7. Derive the three public archives in one release folder, create outer
   checksums/manifest, and independently unpack/install each.
8. Install the Linux public archive on the operator's current system, preserving
   the existing DeepSeek configuration.
9. Create annotated `v3.0.1` at the verified commit; never move the tag.
10. Create a draft Release with `RELEASE_NOTES-v3.0.1.md` and all five public
    files, download them once, verify hashes, then publish.
11. Open the local release folder in the graphical file manager for manual
    upload/inspection handoff.
12. Verify the Release URL, asset counts/sizes/checksums, default branch, and
    absence of non-main remote branches.

## Stop conditions

Do not tag or publish if any native CI job fails, a provider replay is not
47/47, the canonical payload hash changes, an archive differs from the flat
package, an installer changes or exposes configuration, a checksum fails, or a
resource gate is below threshold. Fix forward with a new commit; never weaken a
test expectation solely to make a failing gate green.

If a problem is found after publication, preserve the immutable tag and Release
evidence, mark the Release appropriately, and issue a new patch version rather
than replacing an existing asset under the same filename.
