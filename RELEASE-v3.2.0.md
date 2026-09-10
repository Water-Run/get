# get v3.2.0 release record

The release is built from the v3.2.0 code/system usability and runtime cleanup changes. Linux x64, Windows x64 and macOS arm64 must pass their native tests, CLI integration, HTTPS and installer checks before assembly.

A no-assembly candidate supplies the canonical Linux binary. Focused real-provider replay validates those exact bytes in isolated configuration. The subsequent assembly verifies the recorded Linux digest and packages the provider attestation and native build provenance. Public platform ZIPs are verified against the flat package, with inner checksums, executable architecture checks and an outer asset manifest. An annotated v3.2.0 tag and GitHub Release publish the verified assets.

The user's active installed binary, configuration and credentials are preserved. Historical performance matrices and model-brand pass counts are not reused as v3.2.0 evidence. Results are recorded in [VALIDATION-v3.2.0.md](VALIDATION-v3.2.0.md).
