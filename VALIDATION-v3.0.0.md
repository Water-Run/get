# get v3.0.0 validation report

Date: 2026-08-25 (Asia/Shanghai)
Status: release-ready. The macOS summary-only fix passed native Linux,
Windows, and macOS CI in run `32806323023`; the exact resulting Linux payload
then passed both full provider replays. Checksum-bound final assembly remains a
hard pre-tag gate.

## Candidate and method

- Candidate: get 3.0.0, built from the working candidate with release settings.
- Local compiler: Nim 2.2.6 for preliminary Linux and MinGW/Wine checks.
- Canonical compiler: Nim 2.2.10 in GitHub Actions.
- Baseline: official public get v2.1 Linux x86_64 release binary, SHA-256
  `a3ba3c3a48bbc58163a78275af795131681a08d7f7920946a5121519d8ae5ba9`.
- Benchmark host: Linux 7.1.9 x86_64, 16 logical CPUs, Python 3.14.7; initial
  load average 0.42/1.06/1.57.
- Timing: monotonic `perf_counter_ns`, interleaved v2/v3 order, isolated config
  roots, warmups excluded, median and P95 retained.
- Provider benchmark: deterministic loopback HTTP/1.1 server. The 40 ms cases
  deliberately add 40 ms to each provider request; they measure architecture
  and request accounting, not public-provider speed.
- RSS: GNU `time -f %M`, 20 independent processes per version.

The archive-size value in the raw pre-CI evidence is provisional and is
deliberately excluded from the publishable benchmark JSON. Native release CI
independently verifies the final archive and emits its adjacent SHA-256 file;
no archive-size claim below relies on the provisional value.

## Quantitative performance

| Scenario | Samples | v2.1 median (P95) | v3.0 median (P95) | Change |
|---|---:|---:|---:|---:|
| `get version` startup | 160/version | 3.396 ms (3.791) | 1.933 ms (2.177) | -43.08%, 1.757x |
| `get help` startup | 80/version | 3.511 ms (3.887) | 2.011 ms (2.271) | -42.72%, 1.746x |
| One loopback provider response | 80/version | 1056.059 ms (1057.688) | 3.042 ms (3.507) | -99.71%, 347.141x |
| Routine command, 40 ms/provider request | 40/version | 2059.847 ms (2062.146) | 45.760 ms (46.272) | -97.78%, 45.015x |
| Two-turn continuation, 40 ms/request | 30/version | 3062.281 ms (3077.753) | 127.231 ms (132.668) | -95.85%, 24.069x |
| Forced command-cache population | 30/version | 3061.818 ms (3076.662) | 46.442 ms (51.542) | -98.48%, 65.928x |
| Cached text, zero provider calls | 120/version | 3.381 ms (3.690) | 2.056 ms (2.331) | -39.20%, 1.645x |
| Four 120 ms tools: serial vs parallel | 18/mode | 494.988 ms (495.741) | 129.135 ms (130.180) | -73.91%, 3.833x |

Request accounting explains the large end-to-end changes:

- Routine command: v2 used 2 requests/2 connections (model + reviewer); v3
  used 1 request/1 reused session connection.
- Continuation: v2 used 3 requests/3 connections; v3 used 2 requests over one
  connection.
- Cache population: v2 used model + cache classifier + reviewer (3 requests);
  v3 used one model request.
- Cached text: both versions used zero provider requests; the 39.20% change is
  local startup/cache-path improvement, not removed network latency.

Median max RSS was 9208 KiB for v2.1 and 6794 KiB for v3.0 (-26.22%). The
compatibility-corrected local Nim 2.2.6 Linux binary changed from 1,309,192 to
1,700,712 bytes (+29.91%); the compatibility rules add 1.61% over the earlier
v3 candidate. The canonical Nim 2.2.10 Linux payload is 1,833,888 bytes,
SHA-256
`2f503f42b7ec4c8cc671ae05366db246de33fa17e9d8b9402e63fd221e883d6a`.
The size tradeoff includes the typed Harness, cache v3, hardened policy,
bounded executor, compatibility parsers, and TLS work.

## Correctness and stress

| Gate | Result |
|---|---:|
| Nim unit tests | 12 files, 19 suites, 103 tests, 0 failures |
| Linux CLI E2E | 26/26 |
| Windows CLI E2E under Wine | 25/25 applicable, 1 Linux-only process audit skipped |
| Offline comprehensive suite | 168 passed, 0 failed, 99 live-only skipped |
| DeepSeek `deepseek-v4-flash` | 261 passed, 0 failed, 0 skipped |
| DGX Qwen `qwen3.8-27b` | 261 passed, 0 failed, 0 skipped |
| Command deadline | 20/20; median 1055.907 ms, max 1062.723 ms, exit 124 |
| 100-byte output cap | 50/50 truncated and stopped; no displayed result exceeded 100 bytes |
| Concurrent cache writers | 192/192 entries preserved (8 waves × 24 writers) |
| Cache durability after stress | Schema 3, SHA-256, valid backup, mode 0600, 0 stale locks, 0 temp files |

The earlier pre-compatibility payload passed 260/260 scenarios independently
with DeepSeek and DGX Qwen. It is deliberately no longer treated as release
evidence because the policy and prompt changed. The compatibility-corrected
suite adds a real platform performance-snapshot scenario, bringing the exact
payload replay requirement to 261/261 per provider. The preceding native
candidate passed 261/261 with DeepSeek and 261/261 with Qwen. Because the
macOS `top -n 0` policy branch changed afterward, its follow-up native Linux
payload was replayed again and received the pinned SHA-256 above before
assembly.

The first canonical DeepSeek replay scored 260/261 only because its two valid,
successful `ps` CPU/memory snapshots did not contain the `top`-specific text
required by the initial semantic checker. The live checker was corrected to
accept equivalent bounded process snapshots, while deterministic policy and
CLI tests continue to require exact Linux/macOS `top` forms. The full replay
then passed 261/261. This was a test false negative, not a policy, parser,
transport, or executor failure.

The first Qwen replay of the follow-up payload similarly scored 260/261 only
because it returned a valid, bounded `/proc/loadavg` record for the performance
snapshot while the semantic checker recognized only `top` and `ps` output.
The checker now validates the five-field load-average record structurally; no
product-policy rule was widened. The Harness-only replay then passed 20/20 and
the complete Qwen replay passed 261/261. DeepSeek independently passed the same
complete suite 261/261.

The earlier local Qwen campaign also sampled the model's stochastic command
choices. One pre-compatibility full run was 259/260 first-attempt: the lone
failure was a semantically unrelated model answer ("My name is Claude"), not a
transport, parser, policy, or executor error. The next full run was 260/260 on
first attempts. Live semantic cases permit one separately logged evaluation
retry so provider wobble cannot be mistaken for a deterministic product
regression; no retry was used in its later 260/260 run. Twelve repeated
line-count requests passed, including three real
`wc -l < literal-file` proposals that previously caused false positives.
Policy-rejection recovery was tested deterministically and against Qwen; a
denied proposal is represented as `policy_rejected=true`, exit 126, and is
never executed.

## Read-only attack resistance

The compatibility-expanded deterministic corpus contains:

- 224 realistic safe commands;
- 364 targeted mutation/bypass attempts;
- 775 generated executable-obfuscation variants;
- 1,025 generated shell-control combinations;
- 140 dangerous GNU long-option abbreviations;
- 31 PowerShell parameter-abbreviation/script-conversion variants;
- 164 dangerous-word false-positive probes.

Total: 2,723 policy decisions, all matching the expected allow/deny result on
Linux and the Windows build under Wine. The compatibility-specific matrix
separately verifies bounded Linux and macOS `top`, Windows native performance
commands, system/hardware reporters, pure AWK selectors, and display-only
`sed`, with paired rejection cases for unbounded sampling, threshold writes,
external programs, command execution, pipes, and output files.

On the currently loaded validation host, a fixed-CPU five-run median over
1,600,000 decisions was 4,383.0 ns/decision (228,154 decisions/second), versus
4,499.2 ns/decision for the pre-compatibility v3 policy binary in the same
session. The -2.58% paired difference is within host-load variance, but rules
out a material policy-throughput regression; every decision remains in the
low-microsecond range.

Coverage includes shell substitution/chaining, quote and escape obfuscation,
glob option injection, output and advanced input redirection, interpreters and
wrappers, startup/environment injection, Git filters/helpers/config, network
method overrides and uploads, package/container/cluster mutation, PowerShell
splatting/abbreviations, cmd expansion, per-tool output operands, timeouts,
output limits, and cache/reviewer revalidation.

This is not a claim of absolute sandboxing. The guarantee is fail-closed
mutation resistance under the documented behavior of trusted, allowlisted
reader binaries. Confidentiality, hostile local binaries or writable absolute
`PATH` directories, compromised kernels/hosts, administrator-controlled tool
configuration, remote servers that mutate on GET/HEAD, filesystem access-time
updates, and incidental OS/tool caches are outside the boundary. Tool
observations may be sent to the configured model provider.

## Platform and transport validation

- The provider-bound candidate was built with Nim 2.2.10. Its Linux
  amd64, Windows amd64, and macOS arm64 jobs all passed complete unit, HTTPS,
  CLI, offline, and installer gates in GitHub Actions run `32806323023`. The
  no-assembly phase intentionally stopped after publishing the three native
  payloads so the Linux identity could be replayed against both providers.
- Linux x86_64 release build and real HTTPS request passed.
- A remote macOS 26.5 arm64 smoke on `yymac06` executed the documented
  `top -l 1 -n 3`, `vm_stat`, `sw_vers`, and display-only `sed` forms
  successfully. A later real performance request exposed a safe
  `top -l 1 -n 0` summary-only revision that the positive-integer parser
  rejected. The system man page defines `-n` only as the maximum displayed
  process count, and direct execution returned a complete summary with exit 0.
  The follow-up accepts 0..200 for macOS `-n`, keeps `-l` at 1..5, rejects
  negative/oversized counts. The native Apple Silicon follow-up job passed.
- Windows x86_64 cross-build starts under Wine; all 2,723 deterministic policy
  decisions pass, and the Windows-target CLI suite passes 25/25 applicable
  cases (the Linux `/proc` process-tree audit is intentionally skipped).
- Windows HTTPS imports the native ROOT store into OpenSSL and verifies both
  chain and DNS/IP host name without requiring `cacert.pem`.
- Native Windows Server and macOS Apple Silicon jobs passed for the follow-up
  payload. Wine remains supplementary diagnostic evidence, not a replacement
  for native Windows testing.

## Release decision

The native and exact-provider gates are complete. Do not create the tag or
public release until the checksum-bound assembly dispatch and independent
three-archive installation checks also pass.
