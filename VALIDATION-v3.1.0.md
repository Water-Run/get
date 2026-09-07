# get v3.1.0 validation

Date: 2026-09-07. Canonical provider validation passed. Native release gates are enforced by the assembly workflow; the packaged copy of this report adds the final successful workflow, commit, and native payload identities.

The whole-program review changes passed 14 Nim test files (137 tests), Bash and fish CLI suites (37 each), and the Linux offline matrix (172 passed, 0 failed, 126 intentionally skipped). Those earlier local review builds still reported version 3.0.1; these results describe the reviewed changes, not the identity of the v3.1.0 release payload.

## Current version provider evidence

The Linux x64 payload downloaded from the successful Linux job in [candidate run 34077459271](https://github.com/Water-Run/get/actions/runs/34077459271) reports version 3.1.0 and has SHA-256 `09886915f4bfef39cb5f2c5d7f8c6bd657ed05f013ff6e305711da46a1eb37ed`.

| DeepSeek deepseek-v4-flash suite | Passed | Failed | Skipped |
|---|---:|---:|---:|
| Harness: 44 section J checks plus 3 configuration/key restoration checks | 47 | 0 | 0 |
| Focused read-only, Markdown, double-check, and connectivity scenarios | 8 | 0 | 0 |

No semantic retry was needed. The focused scenarios use the current fish shell configuration. Live tests used isolated configuration and credentials; the active configuration and key remained byte-for-byte unchanged. Results and payload provenance are stored in [provider-validation-v3.1.0.json](https://github.com/Water-Run/get/blob/v3.1.0/provider-validation-v3.1.0.json) and copied into the package as PROVIDER_VALIDATION.json. The old local Qwen endpoint is unavailable; no fresh Qwen result is claimed.

## Native and package requirements

| Target | Required checks before assembly |
|---|---|
| Linux x64 | All Nim unit files, Bash CLI suite, HTTPS, installer, offline matrix |
| Windows x64 | All Nim unit files, PowerShell CLI suite, packaged OpenSSL HTTPS, installer, offline matrix |
| macOS arm64 | All Nim unit files, zsh CLI suite, HTTPS, installer |
| Flat package | Exact provider-tested Linux digest, all file checksums, executable architectures, version, installer syntax, archive integrity |

The first candidate passed Linux and Windows but failed macOS terminal output capture. The Python PTY collector was corrected to drain output before closing its slave descriptor; assertions were retained. A subsequent successful native workflow is mandatory for assembly. The attestation appended to the packaged report identifies that workflow.

Public ZIPs contain BUILDINFO.json, PROVIDER_VALIDATION.json, and SHA256SUMS. The outer checksum file and public asset manifest bind the ZIP bytes to this evidence. The manifest records separate public-package and installation checks, including fresh Linux installation, upgrade preservation, and the installed Linux payload. Windows/macOS native installer smoke checks do not imply a separate local installation from their public ZIPs.

No new performance benchmark is claimed. The review and remaining trust, platform, and concurrency boundaries are documented in [CODE_REVIEW-v3.md](https://github.com/Water-Run/get/blob/v3.1.0/CODE_REVIEW-v3.md).
