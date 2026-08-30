# get v3.0.1 — usable read-only safety, production hardening

`get` 3.0.1 is the production-hardening release of the v3 architecture. It
keeps the small, direct-first command-line design, but substantially revises
the read-only boundary after auditing real `get` history: system performance,
IP and DNS state, services, package/toolchain state, code composition, logs,
hardware, containers, routes, firewall status, and ordinary home-directory
searches must work without turning a natural-language query into a policy
fight.

The goal of this release is precise: reject commands that can change state or
escape the boundary, while admitting finite inspection by documented reader
semantics. It does not solve false positives by weakening the mandatory gate.

## What changed

### A practical semantic read-only policy

- Parses simple commands, reader pipelines, and short reader-only
  `;`/`&&`/`||` sequences. Every stage, option, redirect, expansion, and
  executable is validated independently.
- Admits bounded Linux `top -b -n 1`, macOS `top -l 1`, and native Windows
  process readers. The former rejection of a normal `top -bn1 | head -n 15`
  system-performance request is fixed.
- Adds exact or bounded readers for services, sockets, IP/routes/DNS, storage,
  system logs, `sar`/`pidstat`, traceroute, tmux/cron/Secure Boot, macOS
  metadata and packages, Windows boot/BitLocker/WSL/SMB/Defender/network
  state, and Go/.NET/Rust/Swift/Xcode/Java environment inspection.
- Accepts stable `~`, quoted `"$HOME"`, and quoted `"$PWD"` paths for the
  dual-use search tools that need them. Unstable or unquoted expansion in a
  dual-use tool remains rejected.
- Keeps finite-output rules: `sleep` is limited to 10 seconds, `seq` to
  bounded integer ranges, periodic reporters to bounded sample counts, and
  traceroute to bounded hops/waits. Unbounded `yes` is no longer admitted.
- Bounds `fd`/`rg` worker counts, rejects regex-engine memory overrides, limits
  `xz` threads and high-memory compression modes, and validates tar blocking,
  record-size, multi-volume, helper, and remote-archive forms. Ordinary local
  archive listing and bounded compression-to-stdout remain available.
- Treats dangerous words as data when they are search text. Searching source
  for `rm`, `delete`, or `drop` no longer looks like executing those actions.
- Uses the semantic policy alone by default. `command-pattern` is now an
  explicit supplemental organization regex; an absent pattern and an
  explicitly cleared pattern share the same cache identity and behavior.
- Supports one literal-file `<` redirect for a small set of data readers.
  Heredocs, here-strings, process substitution, input-descriptor duplication,
  expansion, `<>`, and multiple input redirects remain closed. Output
  descriptor duplication is limited to existing stdout/stderr.
- Validates PowerShell parameter names without abbreviation, rejects splatting
  and script conversion, and handles cmd `%...%` expansion and platform
  aliases explicitly.
- Keeps ordinary `Get-Content` streaming, but rejects `-Raw`, custom
  `-Delimiter`, zero/oversized `-ReadCount`, and `-Wait`, which can buffer an
  entire file or remain live before the parent output cap can intervene.
- Makes DNS lookup finite (`nslookup` requires an explicit name), admits
  `rocm-smi` display/query families, and validates NVIDIA `dmon`, `pmon`,
  topology, NVLink, vGPU, PCI, PRM, and power-hint options in their own
  namespaces. Query flags such as `topo -p`, `nvlink -R`, and `prm -f` are no
  longer confused with top-level setters; counter resets, scheduler changes,
  output files, and hardware controls remain blocked.
- Rejects timestamp-restoring `file -p` and non-stdout macOS `profiles
  -output`, while preserving normal file identification and stdout/XML query
  output.

### Defense against bypass, not only obvious writes

- The configured shell and every bare reader resolve through a system-first
  sanitized PATH. The current workspace and temporary directories are removed,
  so a local fake `bash`, `uname`, or other reader cannot shadow the trusted
  executable.
- Shell profiles are disabled. Loader, language runtime, Git, pager, tracing,
  Xcode/Swift, PowerShell, and tool-specific configuration injection variables
  are removed before execution.
- PowerShell reconstructs module discovery from its own installation and
  administrator-controlled Windows module directories, preventing an absent
  `PSModulePath` from silently restoring user-controlled autoload locations.
  Git lazy fetching is disabled in addition to optional locks and helpers.
- Linux uses bubblewrap and macOS uses Seatbelt for native filesystem write
  denial when available. macOS Apple set-id readers use only a narrow,
  revalidated compatibility path. Windows retains the semantic policy,
  environment hardening, deadlines, output limits, and process-tree control.
- Output redirection, command substitution, background/group execution,
  wrappers, inline interpreters, helper/config injection, uploads, and
  mutation-capable Git/container/cluster/package-manager forms fail closed.
- `git status` and a normal worktree `git diff` remain intentionally rejected:
  repository-controlled filters, textconv, and external diff helpers can run
  code. The documentation provides metadata-only replacements with
  `--no-ext-diff` and `--no-textconv` where needed.
- A mixed batch executes each approved sibling but never executes a rejected
  sibling. Unknown tools, malformed actions, and duplicate calls remain inert
  and are returned as typed observations within the existing Harness budget.

### Harness and provider robustness

- One typed `Model → Action → Policy → Tool → Observation` runtime still
  powers `auto`, `direct`, `loop`, and `parallel`.
- Routine work stays direct-first and normally uses one provider request.
- Native function tools are preferred, with strict structured JSON and the
  isolated v2 Markdown decoder as compatibility fallbacks.
- Qwen textual tool-call parsing now handles quoted arguments, command commas,
  bare answer objects, orphan template tags, and malformed-action recovery
  without creating a second execution path.
- Nonzero reader exits are interpreted when useful; raw timeouts are not
  blindly repeated; large observations are compacted before provider feedback.
- Explicit no-tool requests expose no tool schema, reject textual tool calls,
  and ignore cached commands.
- Transport retains verified TLS, hostname checks, connection reuse, bounded
  pre-response retry, an 8 MiB response cap, and no credential-bearing
  redirects.

### Cache and long-run reliability

- Cache identities remain SHA-256 over provider, model, Harness, protocol,
  policy, shell, platform, architecture, working directory, and custom prompt.
- Writers serialize the complete read-modify-write transaction. Snapshots are
  flushed and atomically replaced, mode `0600` on POSIX, with a last-good
  backup used after corruption.
- Windows uses a crash-releasing named mutex and converts the CRT file
  descriptor to a real Win32 handle before `FlushFileBuffers`; the final Wine
  regression caught and closed that platform-specific durability error.
- Parsing and individual fields are size-bounded; malformed schema, wrong hash
  algorithm, duplicate replacement, expiry, and capacity eviction are
  deterministic.
- Tool feedback, model turns, tool calls, parallelism, command duration, and
  captured output all have hard budgets. Process-tree cancellation is applied
  across Linux, macOS, and Windows.
- Test orchestration now checks memory availability, memory pressure, load,
  residual compilers/tests, and temporary-disk headroom before heavy gates;
  the complete release campaign ran serially with zero test-process swaps.

## Measured results

Fresh v3.0.1 measurements against the official v2.1 Linux binary on the same
16-CPU host, with both processes pinned to CPU 0:

| Scenario | v2.1 median | v3.0.1 median | Change |
|---|---:|---:|---:|
| `get version` startup, 300/version | 8.701 ms | 3.232 ms | -62.85%, 2.69× |
| `get help` startup, 160/version | 9.172 ms | 3.562 ms | -61.16%, 2.57× |
| Policy decision, five-run median | — | 3,335 ns | 299,816 decisions/s |

The fresh version-only RSS median is 6,188 KiB for v2.1 and 6,322 KiB for the
local v3.0.1 build (+134 KiB, +2.17%). The final local Nim 2.2.6 Linux binary
is 2,053,936 bytes versus 1,309,192 bytes for v2.1 (+56.89%). These costs are
reported rather than hidden: they cover the typed Harness, much broader
semantic policy, native sandbox integration, hardened executor, provider
normalization, cache durability, and TLS functionality.

The unchanged v3 Harness architecture was previously measured with a
deterministic loopback provider: a routine command with 40 ms provider delay
fell from 2,059.847 to 45.760 ms (-97.78%); command-cache population from
3,061.818 to 46.442 ms (-98.48%); a zero-provider cached text result from
3.381 to 2.056 ms (-39.20%); and four 120 ms tools from 494.988 ms serial to
129.135 ms parallel (-73.91%, 3.833×). These are explicitly retained as v3.0
architecture reference measurements, not relabeled as fresh v3.0.1 results.

See `benchmark-results-v3.0.1.json` for samples, P95 values, hashes, methods,
and that provenance distinction.

## Validation summary

- 3,383/3,383 deterministic allow/deny decisions on Linux, native macOS, and
  the Windows build under Wine: 535 realistic safe commands, 713 targeted
  attacks, and 2,135 generated obfuscation/control/abbreviation/false-positive
  probes.
- 12 Nim test files, 19 suites, and 122 tests pass on Linux and native Apple
  Silicon; all 12 platform-conditional PE suites execute under Wine. Native
  Windows/macOS/Linux CI rebuilds remain release gates.
- CLI E2E: Linux 32/32, macOS 32/32, Windows/Wine 31 applicable passes plus
  one intentionally skipped POSIX signal audit.
- Offline comprehensive matrix: Linux 168 passed/0 failed/126 live-only
  skipped; Windows/Wine the same; macOS 168 passed/0 failed/113 platform/live
  skipped.
- Live pre-canonical Harness: DeepSeek `deepseek-v4-flash` 47/47 and DGX Qwen
  `qwen3.8-27b` 47/47, zero failures and zero skips. Qwen improved from an
  earlier 41/47 compatibility run to 47/47: +6 cases, +12.8 percentage points.
- Cache stress: 192/192 concurrent writes preserved across 8 waves × 24
  writers; valid primary and backup, schema 3/SHA-256, mode `0600`, no stale
  lock, and no temporary files; the writer phase took 677.847 ms.
- Executor stress: 20/20 one-second deadlines returned 124 in
  1055.070–1059.212 ms;
  50/50 finite large-output runs triggered the 100-byte cap.
- Every measured compile/test process reported zero task-local swaps. The
  latest Linux release compile peaked at 262,108 KiB; the native macOS release
  compile peaked at 265,040 KiB. System-wide pressure and swap counters were
  gated separately.

Full methods and limitations are in `VALIDATION-v3.0.1.md`.

## Installation

Download the archive for the target operating system, extract it, keep the
files together, and run:

```bash
python get_ready.py
get version
```

Release assets:

- `get-v3.0.1-linux-x64.zip`
- `get-v3.0.1-windows-x64.zip`
- `get-v3.0.1-macos-arm64.zip`
- `SHA256SUMS-v3.0.1.txt`
- `get-v3.0.1-assets.json`

The Windows archive includes `libcrypto-3.dll`, `libssl-3.dll`, and
`zlib1.dll`; keep them beside the installer and executable. Existing v2/v3
configuration is retained unless reset. Cache schema v3 is compatible, but
every cached command is revalidated by the new policy before execution.

## Important boundary

This is a fail-closed mutation-resistance gate under the documented behavior
of trusted reader binaries, not a confidentiality guarantee. An allowed reader
can expose requested files, processes, environment data, URLs, or command
output to the configured model provider. Administrator-controlled retained
tool directories, the kernel, tool configuration, remote GET/HEAD semantics,
filesystem access metadata, a compromised trusted binary, an unavailable
native sandbox, or a compromised host remain outside the guarantee.

The binaries are distributed without platform code signing. Windows
SmartScreen or macOS Gatekeeper may show an unrecognized-publisher warning.
