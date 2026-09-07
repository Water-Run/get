# get v3.1.0 validation

Date: 2026-09-07. Status: native candidate and canonical provider gates pending.

The whole-program review changes passed 14 Nim test files (137 tests), Bash and fish CLI suites (37 each), and the Linux offline matrix (172 passed, 0 failed, 126 intentionally skipped). Eight focused scenarios succeeded with the configured DeepSeek model, including no-tool Markdown and safe double-check review. Those earlier local review builds still reported version 3.0.1; their results explain the reviewed changes, not the identity of the v3.1.0 release payload.

Release-specific evidence will be recorded after the following gates run on the versioned candidate:

| Gate | Status |
|---|---|
| Native Linux x64 unit/CLI/HTTPS/installer/offline | Pending |
| Native Windows x64 unit/CLI/HTTPS/installer/offline | Pending |
| Native macOS arm64 unit/CLI/HTTPS/installer | Pending |
| Canonical Linux DeepSeek Harness | Pending, expected 47/47 |
| Canonical Linux DeepSeek focused regressions | Pending, expected 8/8 |
| Checksum-bound native rebuild and flat package | Pending |
| Public platform ZIP verification and installed Linux smoke | Pending |

Live tests use isolated configuration and credentials without recording the key in reports. The current release validates DeepSeek; the old local Qwen endpoint is unavailable and no fresh Qwen result is claimed. Counts, canonical run URL, and Linux payload digest are stored in `provider-validation-v3.1.0.json` and are checked at assembly time.

The packaged report adds the successful native CI run and the digest/size of each native payload. Public ZIPs carry BUILDINFO.json, PROVIDER_VALIDATION.json, and SHA256SUMS. An outer checksum file and public asset manifest bind the ZIP bytes to that evidence. Installation retains the active configuration and key byte-for-byte.

No new performance benchmark is claimed. The review and remaining trust/platform/concurrency boundaries are documented in [CODE_REVIEW-v3.md](CODE_REVIEW-v3.md).
