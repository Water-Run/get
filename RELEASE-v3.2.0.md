# get v3.2.0 release record

The release is built from the v3.2.0 code/system usability and runtime cleanup changes. Linux x64, Windows x64 and macOS arm64 passed their native tests, CLI integration, HTTPS and installer checks in [candidate run 34459041437](https://github.com/Water-Run/get/actions/runs/34459041437), from source commit `3defeab1785c71c7ebdae5750bdd5e3297ead4eb`.

That candidate supplied the canonical Linux binary, SHA-256 `757b984d66252a014cedfec71527c7d7788f6936c1b20a05ee2a7f8b6adf8fce`. Focused real-provider replay passed all nine cases with the configured `deepseek-flash` model using those exact bytes in isolated configuration.

The assembly workflow repeats all three native gates, verifies the recorded Linux digest and packages the provider attestation and native build provenance. Public platform ZIPs are verified against the flat package, with inner checksums, executable architecture checks and an outer asset manifest. Linux fresh installation and an upgrade from a copy of the previous installed binary are tested in a temporary home. The manifest records these results. An annotated v3.2.0 tag and GitHub Release publish the verified assets after uploaded-byte verification.

The user's active installed binary, configuration and credentials are preserved. Historical performance matrices and model-brand pass counts are not reused as v3.2.0 evidence. Results are recorded in [VALIDATION-v3.2.0.md](VALIDATION-v3.2.0.md).
