# get v4.0.0 validation — in progress

Development snapshots have passed the full native Linux and macOS suites. Windows
passed its full suite after focused verification of CRLF reads and Git index timestamp
preservation. Raw development records remain in the task's private `.ci/v4/` directory.
These are not attestations for a final release binary.

The provider gate compares v3.2.0 with v4 using 40 independent natural-language tasks,
eight each for system, environment, files, Git and diagnostics, repeated three times.
Synthetic fixtures and OS-derived facts supply the expected answers. All attempts,
including errors and wrong answers, remain in the denominator. Completion must reach
95%; the conservative task-level policy rejection bound must be at most 2%. Host fixture,
provider configuration and binary preservation are checked.

DeepSeek pilot runs encountered HTTP 402 and are retained as failed provider attempts.
At the user's direction, validation continues against the existing Qwen 3.8 service on
DGX Spark, without changing the live get installation or model service configuration.

Final native CI, the complete provider gate and the payload SHA-256 binding remain
pending. `provider-validation-v4.0.0.json` intentionally has status `pending`; package
assembly must fail until a completed matching attestation replaces it.
