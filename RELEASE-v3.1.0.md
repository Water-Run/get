# get v3.1.0 release record

Version 3.1.0 is explicitly requested for the Markdown and read-only review update. Status: preparing native candidate validation.

The release uses native Linux x64, Windows x64, and macOS arm64 builds with Nim 2.2.10. Source, unit tests, CLI tests, HTTPS runtime, installer smoke tests, and applicable offline tests must pass before assembly. A canonical downloaded Linux payload must pass all 47 current Harness cases and the 8 focused DeepSeek regressions without failed or skipped cases. The previously used local Qwen endpoint is unavailable; its historical results are not asserted for this release.

Assembly verifies the exact provider-tested SHA-256 and the completed `provider-validation-v3.1.0.json` record. Provider counts are read from that record rather than copied from the preceding release. Public platform ZIPs are derived from the verified flat package, with independently checked payload hashes, architectures, file lists, and build provenance.

- [x] Review fixes and configurable Markdown implemented.
- [x] Version selected: 3.1.0.
- [ ] Native candidate CI passes for all three targets.
- [ ] Canonical Linux payload passes current provider gates.
- [ ] Pinned rebuild and assembly reproduce the validated payload.
- [ ] Public ZIPs and checksums independently verified.
- [ ] Packaged Linux binary installed into the existing system account installation with configuration preserved.
- [ ] Annotated immutable v3.1.0 tag and GitHub release published with five verified assets.

No failed validation is hidden or replaced by a historical pass. Published tags and assets are immutable; a later correction requires a new release version.
