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
- Lazy local context collection instead of eager shell-version and PATH-wide probes.
- Real bounded parallel execution for independent read-only checks.
- Per-command timeout, output cap, and cross-platform process-tree cancellation.
- A mandatory read-only policy that cannot be disabled. Regex, model review, and manual confirmation are additional layers.
- Production cache: SHA-256 identities, cross-process writers, atomic durable snapshots, last-good recovery, and bounded parsing. Cached commands still pass through the same safety policy.

## Installation

Download a package from [GitHub Releases](https://github.com/Water-Run/get/releases), keep its files together, then run:

```bash
python get_ready.py
get version
```

The installer can retain an existing configuration while replacing the binary. A v2 configuration is migrated automatically: `instance=true` becomes `harness=direct`; otherwise the new default is `harness=auto`.

On Windows, `get-windows-x64.exe`, `libcrypto-1_1-x64.dll`, and `libssl-1_1-x64.dll` must remain beside the installer; all three are installed together.

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

## Safety model

Every model-proposed, model-revised, or cached command follows the same gate:

1. Validate the typed tool name and arguments.
2. Apply the mandatory read-only policy.
3. Apply `command-pattern` as an optional additional blocklist.
4. Optionally run the second-model review (`double-check`).
5. Re-run both deterministic checks if the reviewer changes the command.
6. Optionally request manual confirmation.
7. Execute with a deadline and output cap.

The mandatory policy rejects known mutating utilities, regular-file output redirection, in-place editor flags, mutating Git/container/cluster/package-manager commands, uploads and non-read-only curl requests, and arbitrary inline interpreter code. Clearing `command-pattern` disables only the supplemental regex; it never disables the mandatory policy.

`double-check` defaults to `false`, keeping routine requests to one model call. Enable it when an independent model review is worth the added latency and cost:

```bash
get "inspect service status" --double-check
get set manual-confirm true
```

No shell policy can prove arbitrary code harmless. Review commands and use manual confirmation in sensitive environments.

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
- `124`: command deadline exceeded
- `130`: interrupted with Ctrl+C
- Other non-zero values: terminal command exit code

## Development

Requires Nim 2.2.x.

```bash
nim c -d:release -o:get src/get.nim
python get_test.py --key dummy --skip-llm
```

Focused tests under `tests/` cover protocol parsing, native tool payloads, state transitions, configuration migration, mandatory policy, bounded execution, and real parallel execution.

`get` is licensed under AGPL-3.0-or-later. Source: [github.com/Water-Run/get](https://github.com/Water-Run/get).
