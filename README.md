# `get` — get anything from your computer

[中文](README-zh.md)

`get` turns a natural-language question into a safe, read-only local inspection. Version 3.0 replaces the old instance/agent split with one typed harness that can answer directly, run one command, continue with observations, or execute independent checks in parallel.

```bash
get "IP address of this device"
get "code structure in the current directory"
get "current git branch and uncommitted files"
```

## What changed in v3

- One provider-independent `Model → Action → Policy → Tool → Observation` state machine.
- Native function tools by default, with structured JSON and v2 Markdown compatibility fallbacks.
- `auto`, `direct`, `loop`, and `parallel` strategies over the same runtime.
- One model call for routine commands; no separate router or cache-classifier call.
- Reused HTTP connections and completion-driven waiting. Fast responses are no longer delayed by a one-second polling interval.
- Pre-response transport failures retry up to three times within the original request timeout; HTTP and parsing errors are never retried, response bodies have an 8 MiB hard cap, and bearer-bearing requests do not follow redirects.
- HTTPS verifies both the certificate chain and DNS/IP host name. Windows builds import the native Windows ROOT store into OpenSSL, so normal HTTPS use does not depend on a separately downloaded CA bundle.
- Lazy local context collection instead of eager shell-version and PATH-wide probes.
- Real bounded parallel execution for independent read-only checks.
- Per-command timeout, output cap, and cross-platform process-tree cancellation.
- A mandatory allowlist-based read-only policy that cannot be disabled, plus startup-hook-free shells and a sanitized child environment. Regex, model review, and manual confirmation are additional layers.
- Production cache: SHA-256 identities, cross-process writers, atomic durable snapshots, last-good recovery, and bounded parsing. Cached commands still pass through the same safety policy.

## Installation

Download a package from [GitHub Releases](https://github.com/Water-Run/get/releases), keep its files together, then run:

```bash
python get_ready.py
get version
```

The installer can retain an existing configuration while replacing the binary. A v2 configuration is migrated automatically: `instance=true` becomes `harness=direct`; otherwise the new default is `harness=auto`.

On Windows, `get-windows-x64.exe`, `libcrypto-3.dll`, `libssl-3.dll`, and
`zlib1.dll` must remain beside the installer; all four are installed together.
The DLLs provide OpenSSL 3.5.7 LTS and zlib 1.3.2; their provenance and licenses
are included in `THIRD_PARTY_NOTICES.md`, `OPENSSL-LICENSE.txt`, and
`ZLIB-LICENSE.txt`.

## Setup

`get` uses an OpenAI-compatible Chat Completions endpoint.

```bash
get set model your-model-name
get set url https://your-provider.example/v1
get set key your-api-key
get isok
```

API keys are never printed or logged. On Linux the key file is mode `0600`; on Windows it is protected with DPAPI.

## Harness strategies

| Strategy | Behavior | Typical model calls |
|---|---|---:|
| `auto` | Direct-first; continues or batches only when requested | 1 |
| `direct` | One model turn and at most one terminal tool call | 1 |
| `loop` | Serial observation feedback for dependent work | 1–3 |
| `parallel` | Concurrent independent read-only calls | 1–3 |

`auto` is the default.

In `auto`, `loop`, and `parallel`, a command denied by the mandatory policy is
not executed. The denial is returned as a typed observation so the model can
propose a simpler safe command within the existing turn/tool budget; every
replacement is validated from scratch. `direct` never retries a denial.

```bash
get set harness auto
get "compare disk and memory usage" --harness parallel
get "show the current directory" --harness direct
```

The tool protocol is configured separately:

```bash
get set tool-protocol auto     # native tools, fallback on provider rejection
get set tool-protocol native   # require native function tools
get set tool-protocol legacy   # structured JSON plus v2 Markdown compatibility
```

When a query explicitly says `without tools` or `without calling a tool`, get
uses enforced text-only routing: the provider receives no tool definition,
textual tool actions are rejected, and an older cached command is ignored.

## Safety model

Every model-proposed, model-revised, or cached command follows the same gate:

1. Validate the typed tool name and arguments.
2. Apply the mandatory read-only policy.
3. Apply `command-pattern` as an optional additional blocklist.
4. Optionally run the second-model review (`double-check`).
5. Re-run both deterministic checks if the reviewer changes the command.
6. Optionally request manual confirmation.
7. Execute with a deadline and output cap.

The mandatory policy parses only simple commands and reader pipelines, then validates every executable and its state-changing options. Unknown syntax and executables fail closed. It blocks command substitution, chaining, regular-file output redirection, scripts and wrappers, inline interpreters, PowerShell splatting/script conversion, option abbreviations and glob-to-option injection, helper/config injection, mutating Git/container/cluster/package-manager operations, uploads, and unsafe short-option variants. A single literal-file `<` stdin redirect is accepted only for a small set of validated data readers; heredocs, here-strings, process substitution, descriptor duplication, expansion, multiple redirects, and read/write `<>` remain rejected. Shell aliases and null devices are checked per platform; only trusted supported shells can be configured. Child processes start without profile hooks and without loader, language-runtime, Git, pager, tracing, or tool-config injection variables. Cached and reviewer-rewritten commands pass through the identical gate.

The allowlist includes practical cross-platform inspection, not just trivial
file readers. Bounded `top` snapshots are accepted as `top -b -n 1` on Linux
and `top -l 1` on macOS (`-n 0` is valid for a summary-only snapshot); Windows
uses native readers such as `Get-Process`,
`Get-CimInstance`, and `tasklist`. Common hardware/process reporters and pure
AWK field selectors are accepted. `sed` is admitted for display-only address
expressions such as `sed -n '1,80p' file`; in-place mode, output commands,
external program files, and command execution remain denied. This keeps normal
diagnostics usable while validating dual-use tools by semantics rather than by
executable name alone.

For HTTP inspection, use `curl -q ...`; the leading `-q` prevents `.curlrc` from changing the operation, and only GET/HEAD with an explicit read protocol is accepted. `wget` is accepted only with `--no-config --no-hsts -O-`. Prefix unquoted POSIX globs with `./` or place `--` before them. `$HOME`, `$USER`, `$LOGNAME`, and `$PWD` are accepted only for pure terminal output. Clearing `command-pattern` disables only the supplemental regex; it never disables the mandatory policy.

`git status` and worktree-content `git diff` are deliberately rejected: repository-owned clean/textconv/filter configuration can execute helpers even for commands that appear read-only. Use `git branch --show-current`; `git diff-files --name-only --no-ext-diff --no-textconv` for modified tracked names; `git ls-files --others --exclude-standard` for untracked names; and `git diff --cached --no-ext-diff --no-textconv` for staged content. `git show` and patch-rendering `git log` also require both disabling flags.

`double-check` defaults to `false`, keeping routine requests to one model call. Enable it when an independent model review is worth the added latency and cost:

```bash
get "inspect service status" --double-check
get set manual-confirm true
```

This policy is a fail-closed mutation-resistance gate under the documented semantics of trusted reader binaries; it is not a confidentiality boundary or an OS sandbox. An allowed reader can expose requested files, process/environment data, URLs, or command output to the configured model provider when the harness continues. The boundary includes the resolved binaries and absolute directories retained in `PATH`, the kernel, administrator/operator-controlled tool configuration, and the remote semantics of an allowed HTTP GET/HEAD. Reads may also update filesystem access metadata or tool/OS caches. A compromised binary, writable trusted path, hostile server, or compromised host is outside the guarantee. Review commands and use manual confirmation or an external sandbox in sensitive environments.

## Configuration

Run `get config` to display all settings, `get config --<option>` for one value, or `get config --reset` to restore defaults.

| Option | Default | Description |
|---|---:|---|
| `url` | `https://api.minimaxi.com/v1` | API base URL |
| `model` | `minimax-m3` | Model identifier |
| `manual-confirm` | `false` | Confirm each command interactively |
| `double-check` | `false` | Add a second model safety review |
| `harness` | `auto` | `auto`, `direct`, `loop`, or `parallel` |
| `tool-protocol` | `auto` | `auto`, `native`, or `legacy` |
| `timeout` | `300` | API timeout in seconds; `false` disables it |
| `max-token` | `20480` | Maximum response tokens; `false` omits it |
| `max-rounds` | `3` | Hard model-turn limit |
| `max-tool-calls` | `8` | Hard tool-call limit per run |
| `max-parallel` | `4` | Maximum concurrent tool calls |
| `command-timeout` | `30` | Hard deadline per command, seconds |
| `max-output-bytes` | `1048576` | Captured bytes per command |
| `command-pattern` | built-in | Supplemental forbidden-command regex |
| `system-prompt` | empty | Additional model instruction |
| `shell` | `bash` / `powershell` | Command shell |
| `log` | `true` | Store execution logs |
| `hide-process` | `false` | Suppress progress and observations |
| `system-proxy` | `false` | Prefer Windows Internet Settings over terminal proxy variables |
| `cache` | `true` | Enable deterministic caching |
| `cache-expiry` | `30` | Cache lifetime; `false` disables expiry |
| `cache-max-entries` | `1000` | Cache cap; `false` disables the cap |
| `log-max-entries` | `1000` | Log cap; `false` disables the cap |
| `vivid` | `true` | ANSI colors and progress animation |
| `instance` | `false` | v2 alias for `harness=direct` |

Harness and command safety limits require positive integers and cannot be disabled. Omit a value to reset it:

```bash
get set max-parallel 6
get set command-timeout 20
get set max-output-bytes 2097152
get set max-parallel            # reset to 4
```

`command-pattern` has three forms:

```bash
get set command-pattern '\b(ssh|curl)\b'  # custom supplemental policy
get set command-pattern                    # restore built-in pattern
get set command-pattern ""                 # mandatory policy still remains
```

## Per-query flags

```text
--no-cache / --cache
--manual-confirm / --no-manual-confirm
--double-check / --no-double-check
--harness <auto|direct|loop|parallel>
--protocol <auto|native|legacy>
--instance / --no-instance          compatibility aliases
--hide-process / --no-hide-process
--system-proxy / --no-system-proxy
--vivid / --no-vivid
--model <name>
--timeout <seconds>
```

Terminal `HTTP_PROXY`, `HTTPS_PROXY`, and `ALL_PROXY` variables are honored by default. On Windows, `system-proxy=true` makes enabled Internet Settings take precedence; `NO_PROXY` bypasses either source.

## Cache behavior

v3 caching never spends another model call deciding what to cache.

- A successful terminal run with one command stores a context-specific command.
- A cache hit performs zero model calls, revalidates the command, and re-executes it so dynamic information stays current.
- Explicit text-only requests never execute a cached command; a cached final
  text result may still be returned without a provider or tool call.
- `--cache` may store a final text result when there is no reusable command.
- Multi-step results are not guessed into a cache entry.
- SHA-256 keys include v3, working directory, provider URL, model, harness, protocol, shell, custom prompt, command policy, OS, and architecture. v2 entries cannot collide.
- Writers hold a short cross-process lock around read-modify-write, so simultaneous `get` processes do not lose entries.
- Snapshots are flushed and atomically replaced with mode `0600` on POSIX. A last-good `.bak` snapshot is used automatically if the primary is damaged.
- Files and fields are schema-validated and size-bounded; expiry, duplicate replacement, and oldest-entry eviction are deterministic.

```bash
get cache
get cache --clean
get cache --unset "system version"
```

## Files and exit codes

- Config: Linux `~/.config/get/config.json`; Windows `%APPDATA%/get/config.json`
- Key: Linux `~/.config/get/key`; Windows `%APPDATA%/get/key`
- Log and cache: `get.log` and `cache.json` in the same directory

Exit codes:

- `0`: success
- `1`: configuration, provider, protocol, policy, or general failure
- `126`: a tool proposal was rejected before execution and no safe revision fit the Harness budget
- `124`: command deadline exceeded
- `130`: interrupted with Ctrl+C
- Other non-zero values: terminal command exit code

## Development

Requires Nim 2.2.8 or newer; release CI uses Nim 2.2.10.

```bash
nim c -d:release -o:get src/get.nim
python get_test.py --key dummy --skip-llm
```

Focused tests under `tests/` cover protocol parsing, native tool payloads, state transitions, configuration migration, mandatory policy, bounded execution, and real parallel execution.

`get` is licensed under AGPL-3.0-or-later. Source: [github.com/Water-Run/get](https://github.com/Water-Run/get).
