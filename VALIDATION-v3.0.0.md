# get v3.0.0 validation report

Date: 2026-08-24 (Asia/Shanghai)
Status: release-candidate evidence; native release CI remains the canonical
cross-platform gate for the exact pushed commit.

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

The archive-size value in the raw pre-CI benchmark is provisional. It must be
replaced with the exact native-CI archive size before publication; no archive
size claim below relies on it.

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

Median max RSS was 9208 KiB for v2.1 and 6794 KiB for v3.0 (-26.22%). The Linux
binary changed from 1,309,192 to 1,673,832 bytes (+27.85%). The size tradeoff
includes the typed Harness, cache v3, hardened policy, bounded executor, and TLS
work.

## Correctness and stress

| Gate | Result |
|---|---:|
| Nim unit tests | 12 files, 19 suites, 98 assertions, 0 failures |
| Linux CLI E2E | 25/25 |
| Offline comprehensive suite | 168 passed, 0 failed, 98 live-only skipped |
| DeepSeek `deepseek-v4-flash` | 260/260, 0 failed, 0 skipped |
| DGX Qwen `qwen3.8-27b` | Latest full run 260/260, 0 retries used, 0 failed, 0 skipped |
| Command deadline | 20/20; median 1055.907 ms, max 1062.723 ms, exit 124 |
| 100-byte output cap | 50/50 truncated and stopped; no displayed result exceeded 100 bytes |
| Concurrent cache writers | 192/192 entries preserved (8 waves × 24 writers) |
| Cache durability after stress | Schema 3, SHA-256, valid backup, mode 0600, 0 stale locks, 0 temp files |

The local Qwen campaign also sampled the model's stochastic command choices.
One earlier full run on the same binary was 259/260 first-attempt: the lone
failure was a semantically unrelated model answer ("My name is Claude"), not a
transport, parser, policy, or executor error. The next full run was 260/260 on
first attempts. Live semantic cases permit one separately logged evaluation
retry so provider wobble cannot be mistaken for a deterministic product
regression; no retry was used in the reported 260/260 run. Twelve repeated
line-count requests passed, including three real
`wc -l < literal-file` proposals that previously caused false positives.
Policy-rejection recovery was tested deterministically and against Qwen; a
denied proposal is represented as `policy_rejected=true`, exit 126, and is
never executed.

## Read-only attack resistance

The deterministic corpus contains:

- 176 realistic safe commands;
- 328 targeted mutation/bypass attempts;
- 775 generated executable-obfuscation variants;
- 1,025 generated shell-control combinations;
- 140 dangerous GNU long-option abbreviations;
- 31 PowerShell parameter-abbreviation/script-conversion variants;
- 164 dangerous-word false-positive probes.

Total: 2,639 policy decisions, all matching the expected allow/deny result on
Linux and the Windows build under Wine. A 1,600,000-decision release
microbenchmark took 3499.988 ms: 2187.5 ns/decision, approximately 457,144
decisions/second.

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

- Linux x86_64 release build and real HTTPS request passed.
- Windows x86_64 cross-build starts under Wine; the complete policy corpus and
  Windows TLS tests pass there.
- Windows HTTPS imports the native ROOT store into OpenSSL and verifies both
  chain and DNS/IP host name without requiring `cacert.pem`.
- Native Windows Server and macOS Apple Silicon jobs are required before the
  candidate archive is considered publishable. Wine is diagnostic evidence,
  not a replacement for native Windows testing.

## Release decision

No tag or public GitHub Release should be created until the exact pushed commit
passes native Windows/Linux/macOS release-candidate CI, installer smoke tests,
package layout/version/checksum verification, credential scanning, and the
remaining checklist in `RELEASE-v3.0.0.md`.
