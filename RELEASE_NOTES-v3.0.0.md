# get v3.0.0 — fast, modern, production-ready

Version 3.0 is the largest runtime update in `get` so far. It replaces the
separate instance/agent paths with one provider-independent Harness, removes
avoidable model calls and polling delays, and hardens execution, transport,
cache persistence, and Windows support.

## Highlights

- One typed `Model → Action → Policy → Tool → Observation` runtime.
- Four strategies over the same core: `auto`, `direct`, `loop`, and
  `parallel`.
- Native function tools, strict structured-JSON fallback, and isolated v2
  Markdown compatibility parsing.
- One model call for routine work; cache hits require zero provider calls.
- Enforced text-only routing for explicit no-tool requests: no tool schema is
  sent, textual tool actions are denied, and cached commands cannot bypass it.
- Reused HTTP connections, immediate completion wakeups, bounded retries,
  response-size limits, redirect protection, and robust provider parsing.
- Real bounded parallel execution with deterministic result ordering.
- Mandatory allowlist-based read-only grammar with per-tool option validation,
  shell-specific alias/device handling, option-abbreviation and glob-injection
  resistance, PowerShell/cmd parsing hardening, repository-filter-safe Git
  queries, startup-hook suppression, sanitized child environments, command
  deadlines, output caps, and cross-platform process-tree cancellation.
- Practical read-only compatibility after history-driven false-positive
  review: bounded procps/macOS `top`, native Windows performance readers,
  additional hardware/process reporters, pure AWK selectors, and a narrowly
  parsed display-only `sed` subset. Unbounded `top`, `sensors --set`, AWK
  execution/redirection, and every `sed` write/execute path remain blocked.
- Auto/loop/parallel policy recovery: rejected proposals are never executed;
  a typed denial observation lets the model propose a safe replacement that is
  fully revalidated. Direct mode remains single-turn and fail-closed.
- Narrow literal-file stdin support for validated data readers, without
  enabling heredocs, expansion, descriptor tricks, process substitution, or
  read/write redirection.
- Hardened provider compatibility for native tools, strict/relaxed structured
  actions, Qwen textual tool calls, and orphan template tags, with every path
  converging on the same mandatory policy.
- Cache schema v3 with SHA-256 context identities, cross-process locking,
  durable atomic snapshots, deterministic eviction, and backup recovery.
- Native Windows hardening: DPAPI-protected API keys, PowerShell/cmd support,
  native CI, bundled OpenSSL 3.5.7 LTS runtime libraries, Windows ROOT-store
  import, and certificate-chain plus DNS/IP hostname verification.

## Measured validation

Against the official v2.1 Linux binary on the same x86_64 host, median `version`
startup fell from 3.396 ms to 1.933 ms (-43.08%), a zero-provider cache hit
from 3.381 ms to 2.056 ms (-39.20%), a routine command with simulated 40 ms
provider latency from 2059.847 ms to 45.760 ms (-97.78%), and four 120 ms tools
from 494.988 ms serial to 129.135 ms parallel (-73.91%, 3.833x). Median
one-request RSS fell from 9208 KiB to 6794 KiB (-26.22%). The
compatibility-corrected local Nim 2.2.6 Linux binary is 1,700,712 bytes,
29.91% larger than v2.1. The canonical Nim 2.2.10 Linux payload is 1,833,888
bytes (40.08% larger than v2.1), SHA-256
`00bb41bf74bc0bd6ac3d5c789cba55fafe949e9566d50c57aa64bece24d42ad5`.
The tradeoff covers the new runtime, policy, cache, transport, and practical
compatibility functionality.

The compatibility-expanded deterministic policy corpus performs 2,721
allow/deny decisions with zero mismatches on Linux and the Windows build under
Wine. Stress validation preserved 192/192 concurrent cache writes, enforced
20/20 command deadlines and 50/50 output caps. The exact native Linux payload
identified above passed all 261 live scenarios independently with DeepSeek and
local Qwen. Release assembly rejects any payload whose SHA-256 differs from
that provider-tested binary. See
`VALIDATION-v3.0.0.md` for methods, exact results, and boundaries.

## Install

The release archive contains Linux x86_64, Windows x86_64, and macOS arm64
binaries in one flat package:

```bash
python get_ready.py
get version
```

Keep all files together while running the installer. Windows requires the two
bundled OpenSSL DLLs and `zlib1.dll`; the installer copies all three beside
`get.exe`.

Before installation, compare the archive with `get-v3.0.0.zip.sha256`. The
archive also contains `SHA256SUMS` for every payload file.

## Upgrade notes

- Existing v2 configuration is migrated to schema v3.
- `instance=true` becomes `harness=direct`; otherwise `auto` is the default.
- Cache schema v3 intentionally does not reuse incompatible v2 entries.
- The mandatory read-only command policy cannot be disabled.
- Bounded `top`, display-only `sed`, and pure-selector AWK forms are now
  explicitly supported; their unbounded, write-capable, external-program, and
  command-execution forms remain denied.
- Unsupported or untrusted shell paths are normalized/rejected. HTTP readers
  must disable user config (`curl -q`; `wget --no-config --no-hsts -O-`).
- `git status` and worktree-content `git diff` are no longer admitted because
  repository clean/textconv/filter configuration can execute helpers. Use the
  documented metadata-only `git diff-files`, cached diff, and `git ls-files`
  forms instead.
- The deterministic policy resists state changes; it is not a confidentiality
  boundary or an operating-system sandbox. Continued tool observations may be
  sent to the configured provider, and trusted executables/`PATH` remain in the
  boundary.
- A rejected tool proposal may use exit code 126 when no safe replacement fits
  the configured Harness budget.
- Windows builds use Nim `refc` while Linux and macOS retain ORC.
- Windows now requires the bundled `libcrypto-3.dll`, `libssl-3.dll`, and
  `zlib1.dll`; v2 OpenSSL 1.1 DLLs are not used.

## Compatibility

- Linux x86_64
- Windows 10/11 x86_64
- macOS Apple Silicon (arm64)

The binaries are currently distributed without platform code signing. Windows
SmartScreen or macOS Gatekeeper may therefore display an unrecognized
publisher warning.

Full documentation is in `README.md` and `README-zh.md`.
