# get v4.0.0 validation

Validated on 2026-09-21. The candidate source is `243a4d351593bd8cd90896a2fabccac65ea5e57b`.
[Native CI 35559722629](https://github.com/Water-Run/get/actions/runs/35559722629)
provides Linux amd64, macOS arm64 and Windows amd64 binaries. The final package's
BUILDINFO and appended attestation identify its packaging commit and verification run.
No live get installation or provider settings were changed.

## Real-provider gate

The exact Linux CI payload, SHA-256
`955d72ad2f1a0ccad39d7b479707570ef78b3faab8c7644092e578aecf80eaa0`,
was compared with v3.2.0 using the configured `deepseek-flash` service on Linux/fish.
The model name is service configuration metadata, not independently verified model identity.

The corpus has 40 natural-language tasks: eight each for system, environment,
files/code, Git and diagnostics. Every task ran three times per version, alternating
baseline and candidate against the same fixtures and supplied configuration. OS facts
and independently constructed fixtures supply exact JSON ground truth; answering
without execution evidence does not pass. All 240 attempts remain in the report,
including incorrect answers, unavailable tools and provider/runtime errors.

| Measure | v3.2.0 | v4.0.0 |
|---|---:|---:|
| Completed tasks | 117/120 (97.50%) | 120/120 (100.00%) |
| Tasks with a policy rejection | 26/120 | 0/120 |
| Total latency p50 / p95 | 1.896 / 19.038 s | 1.876 / 3.376 s |

The candidate must complete at least 95% of tasks and encounter policy rejections in
at most 2% of tasks. The rejection measure is a conservative upper bound: any rejected
proposal in a normal task counts, even when the model proposed an invalid command.
It is distinct from the fraction of rejected proposals, shown below.

| Per-task measure (unless specified) | v3.2.0 | v4.0.0 |
|---|---:|---:|
| Model requests, mean | 2.575 | 2.125 |
| Actual starts, mean (total) | 2.142 (257) | 1.708 (205) |
| Rejected proposals / all proposals | 48/305 | 0/205 |
| Recovery rounds, total | not instrumented | 0 |
| Tokens, mean / p95 | 5581.675 / 24082.0 | 5988.483 / 10323.0 |
| First observation p50 / p95, seconds | 1.063 / 2.441 | 1.13 / 1.942 |
| Sampled peak RSS p50 / p95, MiB | 7.426 / 21.203 | 7.633 / 19.246 |
| Largest sampled RSS, MiB | 35.938 | 21.434 |

Supplied limits for both versions: six inspection rounds, sixteen calls, four-way
parallelism and thirty seconds per command. v4 additionally enforces a 120-second
whole-query deadline; v3.2 ignores that configuration field. Both are externally
bounded at 145 seconds. These are query measurements including provider/network latency,
not an isolated CPU benchmark. Simple system-query model requests are 2.13 per task for v3.2 versus 2.00 for v4 (kernel name/release, architecture, hostname and page size; 15 attempts each).

v4 starts and recovery rounds come from runtime events. Baseline execution counts come
from command logs after removing non-executed policy/argument rejections and answer-only
entries; v3.2 has no equivalent recovery-round counter. Baseline proposals count native
calls and valid structured call responses. Token usage comes from provider responses.
First-observation timing is the runtime completion event in v4 and an upper bound at the
next provider request in v3.2. Memory is CLI process-tree RSS sampled every 30 ms, excluding the provider server; shared pages
are counted per process and short-lived peaks can be missed.

Final candidate failures: none. Baseline failures: `baseline-1-unicode_environment`, `baseline-3-unicode_environment`, `baseline-3-metachar_environment`. Failed attempts remain in the completion denominator.

The recorded fixtures, including a protected marker, Git index and malicious executable
helpers, remained unchanged in every attempt. Provider configuration/key copies and
both replay binaries also retained their hashes. Full per-attempt summaries and payload
binding are in `provider-validation-v4.0.0.json` (`PROVIDER_VALIDATION.json` in packages).
Request/response traces remain in the task's private validation directory.

## Qwen compatibility and earlier attempts

The same final Linux payload was exercised against the existing DGX Spark `qwen3.8-27b` service: six selected cases × three repeats, 16/18 completed; 0/18 tasks had a policy rejection. Latency p50/p95: 16.777/119.009 seconds. This is complementary compatibility coverage, not a forty-case provider gate. Failures: `candidate-1-source_composition`, `candidate-3-source_composition`. Incomplete provider token accounting is retained for 2 attempt(s); their numeric token field is not a complete measurement. The first and third source-composition attempts timed out after 119 seconds waiting for the initial model response, before any tool execution; the second completed in 60 seconds.

Earlier evidence is retained separately and is not substituted into the final denominator:

- Initial DeepSeek pilot: HTTP 402 interrupted testing; the supplied account was later restored.
- Qwen six-task v3.2/v4 pilot: both 5/6 completed; tasks with policy rejections 4/6 versus 0/6.
  The v4 missing-file failure led to an ENOENT/no-match fix; its subsequent three Qwen trials passed.
- Development Qwen forty-task pilot: 39/40 completed, zero tasks with policy rejection.
  An unnecessary required Git hash/filter check caused the remaining failure.
- Development DeepSeek forty-task pilot: 40/40 completed, zero tasks with policy rejection.
- CI 35558448177 DeepSeek full comparison: baseline 119/120, candidate 117/120;
  rejection tasks 30/120 versus 1/120. Candidate failures were a changed repair identity,
  a failed corroboration overwriting successful CPU evidence, and using an isolated network view.
- CI 35558448177 Qwen six-task pilot: 5/6 completed, zero policy rejection tasks;
  a compound Git command retried executable filters instead of using the snapshot reader.

CI 35557896366 passed macOS/Windows but failed the Linux fish CLI checks because
older fish wrote startup state. CI 35558448177 passed after private startup storage
was added. Runs 35557669024 and 35559618494 were canceled for source corrections,
not counted as passes.

Those findings produced the successful-evidence merge, explicit repair identity and
clearer host-query tool descriptions in the final candidate. The failed attempts remain
available; they are not relabeled as successful after a code change.

## Native and boundary validation

Full Nim suites, verified HTTPS and installer smoke tests passed on Linux amd64, macOS arm64 and Windows amd64. CLI results: Linux Bash 51/51 and fish 51/51; macOS 50 passed with one Linux-only skip; Windows 47 passed with four inapplicable platform skips. The five Linux native-reader tests with computation unavailable and five provider-attestation verifier tests also passed. Skipped cases are not counted as passes.

Coverage includes typed tool argument validation, original Bash/fish environment expansion,
Unicode/space paths, file paging and no-match evidence, Git worktree/index snapshots,
malicious Git helper suppression, shared authorization for review/cache paths,
local recovery, required evidence, duplicate reuse and fresh observations, output limits,
whole-query/provider deadlines, cancellation/process cleanup, configuration migration,
private state and serialized persistence. Linux also exercises native readers with
computation unavailable, and isolated scripts with file/symlink, network/socket,
host-process and resource-limit boundaries.

Development full native suites also ran on the supplied Linux, macOS and Windows machines.
Windows DPAPI was verified in the user's existing interactive login context: SSH batch
logon independently returned Win32 error 5. Task-owned scheduled tasks were removed;
no desktop session or extension was changed. The remote Linux test kernel lacked PSI
counters, which the validation script recorded; local development retained the required
memory checks, serial low-priority compilation and `.ci/` outputs.

## Original system-overview query

The exact original question, `系统的信息情况`, was also run outside the formal corpus on the final payload. DeepSeek completed in 11.43 seconds and Qwen in 98.83 seconds; both exited successfully with zero policy rejections. Manual comparison found OS, kernel, architecture, logical CPU count and memory consistent with the collected host evidence.

This is an execution/usability smoke, not a claim that every generated sentence is accurate. The DeepSeek answer correctly listed four cores/eight threads in its hardware table, but called the eight logical CPUs “cores” in another section and inferred a longer-term memory-pressure pattern from cumulative daemon CPU time. That inference is not established by a single snapshot. The Qwen answer kept the four-core/eight-thread distinction and explicitly limited its health conclusion to the snapshot. These model-output limitations and raw traces are retained.

## Scope and packaging

Linux general computation is enabled only after the complete namespace/bubblewrap/backend
probe succeeds. macOS and Windows provide typed readers and supported host diagnostics;
this version does not claim arbitrary script isolation there. Isolated process/network/device
views are explicitly labeled. Git snapshot readers disable executable filters and submodule
inspection; they do not reproduce arbitrary custom-filter semantics. Models can still choose
unavailable commands, misunderstand evidence or exhaust a deadline.

The release-candidate assembly recomputes the provider population gates and rejects a Linux
payload hash mismatch. Its appended attestation covers each native payload, HTTPS, installers,
archive layout, architecture and checksums. Platform ZIPs are derived byte-for-byte from that
flat package and independently checked. Linux fresh-install and v3.2 upgrade checks use a
private temporary home and verify configuration/key preservation. This validation does not
publish a release or replace the active installed binary.
