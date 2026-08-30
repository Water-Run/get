# get v3.0.1 validation report

Date: 2026-08-30 (Asia/Shanghai)

Status: the source candidate passes local Linux, Windows/Wine, native Apple
Silicon, deterministic security, stress, and two-provider live Harness gates.
Windows CI run 33306374273 and all three native Nim 2.2.10 jobs in no-assembly
run 33306378137 are green. That run's exact Linux payload passes both canonical
provider replays. A pinned rebuild, checksum-bound assembly, archive tests, and
installation remain mandatory before a public tag or Release.

## Candidate and evidence rules

- Version: `3.0.1`.
- Official baseline: public get v2.1 Linux x86_64 binary, 1,309,192 bytes,
  SHA-256
  `a3ba3c3a48bbc58163a78275af795131681a08d7f7920946a5121519d8ae5ba9`.
- Local Linux candidate: Nim 2.2.6 release build, 2,053,936 bytes, SHA-256
  `5d1d9fe9bc5a71a38f2512e128245fbd61874cf4dd9251188b9f93e64da92698`.
- Windows candidate: Nim 2.2.6 MinGW x86_64 cross-build, 2,318,336 bytes,
  SHA-256
  `7c935f4e8c3e7efd27a3bb248b4b5324459ae4ff702c875012fc44d40225ed1f`;
  executed with Wine 11.0 Staging and the packaged OpenSSL 3 DLLs.
- macOS candidate: native arm64 build on macOS 26.5 using Nim 2.2.10,
  1,769,984 bytes, SHA-256
  `5da3dd5fe3127bfbe14ef49e78d14bb16d04e27d33a32e805c0e9272061698dd`.
- Publishable binaries are rebuilt by GitHub Actions with Nim 2.2.10. Local
  hashes above are validation provenance, not promised Release-asset hashes.
- Canonical Linux CI payload from run 33306378137 and source commit
  `a349bd4e3a2b45b46cb5b14f7419ba23fe75a981`: 2,236,088 bytes, SHA-256
  `71d07ac4c9a14ec74551b64057c74aee9f488a2213e0c55da8820c512c21a1d1`.
  This one downloaded file was used unchanged for both provider replays and is
  pinned into the assembly gate.
- A failure is never silently retried in deterministic gates. Live semantic
  checks report an evaluation attempt explicitly when the model first chooses
  an unusable but non-executed proposal.
- Credentials are injected through an environment variable from a mode-0600
  key file. Reports display only `****`; keys are not put on the process
  command line, copied to test hosts, logged, or included in artifacts.

## Resource-safety gate

The validation campaign was deliberately serialized after a previous long-run
task was killed during system-wide memory exhaustion.

Before every local compile or test, the gate required:

- at least 8 GiB `MemAvailable`;
- Linux memory PSI `full avg10 < 1`;
- one-minute load below the 16 logical CPUs;
- no residual Nim/GCC/linker/Wine/test process;
- at least 2 GiB free in `/tmp`.

The macOS gate required at least 25% system-wide memory free according to
`memory_pressure -Q`, load below 10 CPUs, 8 GiB available disk, and no
residual compiler/test process. Before its latest final-delta runs, macOS
reported 67% free and about 365 GiB available disk.

The gate caught orchestration and host-pressure issues without misclassifying
them as product failures:

1. A Windows continuation was deferred at 7.4 GiB available memory. A later
   Windows runtime gate stopped before Wine startup when PSI reached 17.04.
   Both resumed only after the original threshold passed; no external process
   was killed.
2. A macOS non-interactive PATH omitted the already installed Nim toolchain and
   `/usr/sbin/sysctl`. That source check was explicitly invalidated, then rerun
   with Nim 2.2.10, a complete PATH, and `set -euo pipefail` before any native
   test evidence was accepted.
3. Three Wine CLI cache assertions initially inspected the wrong host side of
   Windows AppData. The same binary passed all three after mapping the actual
   Wine prefix; the first evidence-path failure was retained in the audit log.
4. A policy-throughput sample taken while unrelated `tsgo`/Git jobs occupied
   the host was discarded as a complete set rather than cherry-picked. Only a
   subsequently gated set is eligible for the result below.

Every `/usr/bin/time` or macOS `/usr/bin/time -l` record in the final compile,
unit, CLI, offline, provider, and stress gates reported zero swaps. No tests
were parallelized across operating systems.

## Deterministic read-only policy

### Corpus composition

| Class | Decisions |
|---|---:|
| Realistic safe commands | 535 |
| Targeted mutation/bypass attempts | 713 |
| Generated executable-obfuscation variants | 775 |
| Generated shell-control combinations | 1,025 |
| Generated dangerous long-option abbreviations | 140 |
| Dangerous-word false-positive probes | 164 |
| Generated PowerShell abbreviation/conversion attacks | 31 |
| **Total per platform** | **3,383** |

Results: 3,383/3,383 on Linux, 3,383/3,383 on native macOS, and
3,383/3,383 for the Windows build under Wine. That is 10,149 matching
platform decisions with no unexpected allow or reject.

### History-driven positive coverage

The retained local log contained 442 historical query entries. A content-free,
non-exclusive aggregate found 44 file/code questions, 15 performance/resource
questions, 14 service/process questions, 8 network/IP/DNS questions, 4 weather
questions, and 3 disk/storage questions. Raw queries, outputs, paths, and keys
are not reproduced in this report. These categories drove the positive corpus
instead of treating a project-development workflow as the only normal use.

Representative admitted forms include:

| Real intent | Representative admitted command |
|---|---|
| System performance | `top -bn1 \| head -n 15` |
| macOS performance | `top -l 1 -n 15 -o cpu` |
| Running services | `systemctl list-units --type=service` |
| Failed services | `systemctl --failed --no-pager` |
| Device IP | `hostname -I \| awk '{print $1}'` |
| Listening ports | `ss -ltnp` or `lsof -nP -iTCP -sTCP:LISTEN` |
| Route/DNS | `ip -j route show`, `resolvectl status`, `scutil --dns` |
| Code composition | bounded `find`/`rg` plus display-only `sed`/AWK selectors |
| Home configuration | `find "$HOME" -maxdepth 3 -name '*.ini' \| head` |
| Periodic diagnostics | `sar 1 2`, `pidstat -p ALL 1 2`, `vmstat 1 2` |
| Weather HTTP read | `curl -q -fsSL https://...` |
| Package state | `dnf history list`, `brew outdated`, `winget upgrade` |
| Toolchains | `go env`, `dotnet --info`, `rustup show`, `xcodebuild -showsdks` |
| Windows host state | `Get-Service`, `Get-NetIPConfiguration`, `Get-BitLockerVolume` |
| macOS host state | `system_profiler`, `pkgutil --pkgs`, `pmset -g batt` |
| AMD GPU state | `rocm-smi --showuse --showmeminfo vram` |
| NVIDIA query namespaces | `nvidia-smi topo -p`, `nvlink -R`, `pci -gErrCnt` |

The safe corpus also verifies reader-only `;`, `&&`, and `||` sequences,
finite pipelines, one literal-file stdin redirect, quoted stable
`"$HOME"`/`"$PWD"`, pure AWK field selection, display-only `sed`, archive
listing, container/Kubernetes inspection, system logs, hardware reporters,
firewall status, Secure Boot, tmux/cron, and metadata-only Git inspection.

### Paired rejection coverage

Every newly admitted dual-use family has rejection partners. Examples:

- unbounded `yes`; `sleep 11`; oversized/zero-increment `seq`; unbounded or
  live `top`, `sar`, `pidstat`, traceroute, Docker, Kubernetes, and log forms;
- oversized `fd`/`rg` thread counts and regex-engine memory overrides; remote,
  helper-driven, multi-volume, or oversized-record tar forms; excessive `xz`
  threads, memory/filter overrides, and high-memory compression presets;
- output redirection, `tee`, tool-specific output files, in-place `sed`, AWK
  `system()`/redirection, `find -exec/-delete`, `rg --pre`, and archive create;
- shell substitution, process substitution, grouping/background execution,
  heredoc/here-string, input-descriptor duplication, unsafe output-descriptor
  targets, wrappers, scripts, and inline interpreters;
- curl/wget user configuration, upload, POST/PUT/DELETE, output files, unsafe
  protocols, credential/helper options, and bearer redirects;
- Git alias/helper/config injection, pagers, external diff/textconv/filter
  execution, worktree-content diff/status, and mutating subcommands;
- package install/update/remove, container exec/copy/run, Kubernetes apply/exec,
  firewall/network mutation, service start/stop, boot/BitLocker writes, and
  Windows registry/process/service mutation;
- PowerShell splatting, encoded/script command creation, parameter
  abbreviation, `Invoke-Expression`, .NET file writes, and cmd `%...%` or caret
  obfuscation;
- PATH shadowing and environment injection through loader, runtime, Git,
  pager, tracing, Xcode/Swift, PowerShell, and tool-specific variables.
- `file -p` timestamp writes, macOS `profiles -output` file destinations,
  interactive `nslookup`, whole-file PowerShell buffering, Git lazy fetches,
  AMD fan/clock/power/RAS/reset controls, and NVIDIA NVLink/vGPU/PCI resets or
  scheduler changes.

Dangerous words inside a quoted search pattern are treated as data. The 164
false-positive probes ensure that looking for strings such as `rm`, `drop`,
`delete`, `exec`, or `shutdown` is not confused with invoking them.
The built-in semantic policy is therefore the default by itself; an explicit
`command-pattern` remains a supplemental organization rule. Missing and
explicitly cleared supplemental patterns normalize to one cache identity.

### Runtime enforcement

The executor suite creates fake `bash` and `uname` programs in a temporary PATH
and proves neither is called. It also verifies profile-hook suppression,
`BASH_ENV` removal, Git external-diff/filter suppression, capture limits,
deadlines, pre-deadline output retention, process-tree cancellation, and native
filesystem write denial. Linux bubblewrap and macOS Seatbelt both preserve
ordinary reads and reject a filesystem write in the test. macOS additionally
verifies the narrow launchctl compatibility path. Harness tests also prove that
an executor cannot substitute the call ID, tool name, or command in a returned
observation.

The design follows the layered principle in OpenAI's official
[Codex sandboxing](https://learn.chatgpt.com/docs/sandboxing) and
[agent approvals/security](https://learn.chatgpt.com/docs/agent-approvals-security)
documentation and Anthropic's official
[Claude Code sandboxing](https://code.claude.com/docs/en/sandboxing) and
[permissions](https://code.claude.com/docs/en/permissions) documentation:
semantic admission/permission is separate from OS-native enforcement, and a
compound command is safe only when every component is safe. `get` is smaller
and optimized for local host inspection, so its grammar and documented reader
semantics are explicit rather than a general development-agent permission
language.

The AMD query/control split is checked against AMD's official
[ROCm SMI CLI documentation](https://rocm.docs.amd.com/projects/rocm_smi_lib/en/docs-6.1.0/python_usage.html):
`--show*` and display formats are observational; set/reset, fan, clock, power,
partition, RAS injection, load, and save operations are not.

## Functional and platform gates

| Gate | Linux x86_64 | Windows x86_64 / Wine | macOS arm64 native |
|---|---:|---:|---:|
| Nim test files | 12/12 | 12/12 | 12/12 |
| Nim suites/tests | 19 suites, 122 Linux tests | platform conditionals | 19 suites, 122 tests |
| Policy decisions | 3,383/3,383 | 3,383/3,383 | 3,383/3,383 |
| CLI E2E | 32/32 | 31/31 applicable; 1 POSIX audit skipped | 32/32 |
| Offline comprehensive | 168 pass, 0 fail, 126 skip | 168 pass, 0 fail, 126 skip | 168 pass, 0 fail, 113 skip |
| Release binary version | 3.0.1 | 3.0.1 | 3.0.1 |

The Windows suite actually executes every cross-compiled `.exe` with its
packaged OpenSSL runtime; it is not compile-only evidence. It covers refc,
DPAPI key round trips, cmd/PowerShell policy branches, Windows paths, output
limits, deadlines, concurrent cache writers, and TLS construction. The final
cache-path-corrected CLI evidence has 31 applicable passes and one deliberate
POSIX-only skip. A focused post-durability-fix offline cache/log gate passed
21/21 with 28,860 KiB peak RSS and zero swaps. The broader Wine offline matrix
has 168 passes and no failures; Wine remains supplementary, while native
Windows Server CI is the publication gate.

The native macOS campaign ran on macOS 26.5 arm64. The largest recorded unit
compile/test RSS was 253,804,544 bytes; the release compile peaked at
271,400,960 bytes, and every suite reported zero swaps. CLI E2E completed in
2.99 seconds with 35,078,144 bytes maximum RSS. The offline matrix completed
in 1.28 seconds with 34,062,336 bytes maximum RSS.

Linux CLI E2E completed in 8.60 seconds with 27,208 KiB maximum RSS. The Linux
offline matrix completed in 1.53 seconds with 27,608 KiB maximum RSS. The final
release compile peaked at 262,108 KiB.

## Live provider validation

The exact canonical Nim 2.2.10 Linux CI payload identified above was exercised
independently against two OpenAI-compatible providers with isolated
configuration and `--stop-on-fail`:

| Provider/model | Passed | Failed | Skipped | Elapsed | Max RSS | Swaps |
|---|---:|---:|---:|---:|---:|---:|
| DeepSeek `deepseek-v4-flash` | 47 | 0 | 0 | 230.00 s | 46,296 KiB | 0 |
| DGX Qwen `qwen3.8-27b` | 47 | 0 | 0 | 406.76 s | 46,564 KiB | 0 |

The 47 cases cover deterministic file facts plus realistic Chinese host tasks:
IP address, weather derived from host timezone rather than proxy egress,
running/failed services, code composition, bounded performance diagnosis, safe
Git change summary, recent errors, largest files, hardware, container state,
and SSH diagnosis. They also cover ordinary reader exit 1, missing paths,
silent `cmp` success, multi-source evidence, Harness budgets, visible progress,
custom prompts, and command-pattern restoration.

Qwen's earlier compatibility baseline was 41/47. Parser normalization,
tool-call recovery, prompt precision, finite reader compatibility, and typed
nonzero handling bring the final run to 47/47: six additional cases and
12.8 percentage points. No Qwen-specific bypass of policy or execution was
introduced; every parsed action converges on the same deterministic gate.

Neither canonical replay needed its one permitted independent semantic retry.
DeepSeek started with 10,726,880 KiB available memory, PSI full avg10 0.03, and
load 3.56/16. Qwen started with 14,044,940 KiB available locally, PSI 0.16,
load 3.97/16, plus 38,771,720 KiB available and PSI 0.00 on DGX Spark. Both
reported zero task-local swaps. The Qwen SSH tunnel was bound to loopback,
verified after use, and its exact task-owned nested process was terminated;
the pre-existing model service was not changed.

The workflow now pins this payload's SHA-256. Final assembly refuses a
different Linux payload, so a nondeterministic or source-changing rebuild
stops publication rather than silently substituting a binary.

## Cache and executor stress

The current cache implementation, not an older v3 binary, was tested with
eight waves of 24 simultaneous processes. Windows separately uses a named
kernel mutex and a CRT-descriptor-to-Win32-handle conversion before
`FlushFileBuffers`; both the PE cache suite and concurrent CLI cache test pass
with that path:

- 192/192 unique result entries preserved;
- 0 process or content failures;
- 677.847 ms for the writer phase;
- schema version 3 and SHA-256 identities;
- valid primary and backup JSON;
- mode `0600`;
- no stale `.lock` and no `cache.json.tmp.*` files.

Executor stress used the deterministic local provider:

- 20/20 ten-second commands stopped by a one-second deadline and returned 124;
  median 1056.631 ms, range 1055.070–1059.212 ms, all below 1800 ms.
- 50/50 finite large-output commands hit the 100-byte cap and reported
  truncation; median 77.589 ms, range 68.605–89.769 ms.

## Performance method and result

Fresh startup timing uses Linux 7.1.10 x86_64, Python 3.14.7, one CPU affinity,
30 warmups, interleaved version order, and monotonic nanosecond timing.

| Scenario | Samples/version | v2.1 median (P95) | v3.0.1 median (P95) | Change |
|---|---:|---:|---:|---:|
| `get version` | 300 | 8.701 ms (10.149) | 3.232 ms (4.355) | -62.85%, 2.692× |
| `get help` | 160 | 9.172 ms (10.842) | 3.562 ms (4.859) | -61.16%, 2.575× |

Thirty interleaved GNU-time samples put version-only median max RSS at
6,188 KiB for v2.1 and 6,322 KiB for v3.0.1: +134 KiB/+2.17%. The local
Linux binary is 56.89% larger. These regressions are documented; no claim of a
fresh RSS reduction is made.

Policy throughput used a 16-command mixed workload, 1,600,000 decisions per
run, and five CPU-9-pinned runs. CPU 9 was 95.32% idle before and 91.97% idle
after the complete set; memory PSI remained zero. Results were
3184.0–3410.8 ns/decision; the median is 3335.4 ns/decision or about 299,816
decisions/second. All five runs are retained.

The loopback/provider/cache/parallel measurements in
`benchmark-results-v3.0.1.json` are copied from the published v3.0.0 Harness
architecture benchmark and labeled as historical reference. They demonstrate
the request-count architecture but are not passed off as fresh 3.0.1 timing.

## Boundary and remaining publication gates

The policy is a mutation-resistance boundary under the documented semantics of
trusted readers, not a confidentiality boundary. An admitted command may read
requested secrets, process/environment state, URLs, or other local information,
and a continuing Harness can send its output to the configured provider. The
boundary includes retained administrator-controlled tool directories, the
kernel, operator-controlled tool configuration, remote GET/HEAD semantics, and
access-time/incidental cache effects. A compromised reader, server, sandbox, or
host is outside the guarantee.

Completed publication gates are the initial native Linux/Windows/macOS CI run,
47/47 canonical replay with each provider, and the pinned Linux payload hash.
Before publishing, the pinned commit's native jobs and checksum-bound assembly
must pass; all three platform archives must then be unpacked,
checksum-verified, and installer-tested. Only after those checks may `v3.0.1`
be tagged and the GitHub Release published.
