# get v3.1.0 release record

Version 3.1.0 is the Markdown and read-only review update. The canonical Linux payload has passed the current DeepSeek gates; its exact identity and results are recorded in [provider-validation-v3.1.0.json](provider-validation-v3.1.0.json).

The release uses native Linux x64, Windows x64, and macOS arm64 builds with Nim 2.2.10. Source checks, unit tests, CLI tests, HTTPS runtime, installer smoke tests, and applicable offline tests must pass in the same workflow before assembly. Assembly verifies the provider-tested Linux SHA-256 and rejects any mismatch. Provider results are read from the current validation record.

The canonical payload passed 47 Harness checks (44 section J checks plus 3 configuration/key restoration checks) and 8 focused DeepSeek regressions, with no failures, skips, or semantic retries. The previously used local Qwen endpoint is unavailable; its historical results are not asserted for this release. No new performance benchmark is claimed.

The first candidate run passed Linux and Windows but exposed a macOS PTY test collector issue: closing the last slave descriptor before draining the master produced an empty capture. The collector now drains output while the child runs and keeps the slave open until reading finishes. Rendering assertions are unchanged. This correction changes only the Python test; the native gates must pass after the correction before the workflow can assemble anything.

The packaged VALIDATION.md and BUILDINFO.json contain the final successful native workflow, commit, and payload identities. Public platform ZIPs are derived from that verified flat package, with independent checks of file lists, checksums, executable architectures, and byte identity. The public asset manifest records verification of fresh Linux installation, upgrade configuration preservation, and the installed payload digest.

Publication uses an annotated v3.1.0 tag on the assembled commit and five assets: three platform ZIPs, SHA256SUMS-v3.1.0.txt, and get-v3.1.0-assets.json. Release assets are downloaded and compared before publishing. Published tags and assets are immutable; a later correction requires a new release version.
