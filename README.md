# `get` — get anything from your computer

[中文](README-zh.md)

`get` turns a natural-language question into a read-only local query. v4 adds environment, file, search, and direct-process tools, ordinary Git status/diff, and isolated scripts and composition on capable Linux hosts. Model names remain opaque service identifiers. v4 validation is in progress; see the [development record](DEVELOPMENT-v4.0.0.md).

```bash
get "IP address of this device"
get "code structure in the current directory"
get "current git branch and uncommitted files"
```

## What changed in v4

- Named environment reads distinguish missing, empty, and redacted values without a four-variable limit.
- Built-in file paging, literal content search, path globs, and common ignore rules handle spaces and Unicode paths.
- Literal argv avoids shell quoting. Complex shell queries and short scripts use a fully probed Linux isolation backend.
- Git status/diff use a private metadata snapshot with executable filters, external diff, and submodule inspection disabled.
- Defaults are six inspection turns, sixteen actual starts, and four concurrent calls. Rejections and reuse count separately; local failures can recover.
- Automatic queries have a 120-second total deadline with time reserved for an answer. stdout/stderr, paging, and truncation are separate observations.
- New, reviewed, and cached plans share one authorization path and one event stream for terminal output and diagnostics.
- Native tools/JSON fallback, TLS verification, HTTP reuse, durable persistence, and Markdown output remain available.

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
| `auto` | Inspect, then answer from observations | 1–4 |
| `direct` | One model turn and at most one terminal tool call | 1 |
| `loop` | Serial observation feedback for dependent work | 1–4 |
| `parallel` | Concurrent independent read-only calls | 1–4 |

`auto` is the default. `max-rounds` limits inspection turns; a separate final turn has no tools. Tool limits stay enforced. If the provider cannot finish, get returns a bounded account of available evidence with a nonzero exit status.

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
get set tool-protocol json     # explicit structured JSON actions
```

When a query explicitly says `without tools` or `without calling a tool`, get
uses enforced text-only routing: the provider receives no tool definition,
textual tool actions are rejected, and an older cached command is ignored.

## Query boundary

`read_environment`, `read_file`, and `search_files` handle common reads directly. `run_process` accepts literal argv; `run_shell` uses the configured shell dialect. Search supports path globs, literal content matching, paging, and common `.gitignore` / `.ignore` / `.rgignore` rules. It is a bounded reader, not a complete Git/ripgrep replacement; scan limits produce an explicit incomplete result.

Known host readers retain argument checks and see real process, device, network, and service state. On Linux, other computation is enabled only after a complete isolation probe: bubblewrap namespaces, read-only host mounts, seccomp, and resource ceilings prevent network/control-socket access and host process/device control. Writes are confined to private query scratch space, cleaned by the parent. Missing capabilities never fall back to an unrestricted script.

| Capability | Linux | macOS | Windows |
|---|---|---|---|
| Typed environment/files/search and known host queries | Supported | Supported | Supported |
| Ordinary Git status/diff snapshot | Supported | Supported | Supported |
| General scripts and complex shell computation | Only after the full isolation probe | Not yet supported | Not yet supported |

Git snapshots retain the worktree, index, and basic line-ending/file-mode semantics without writing the real index. Executable filters, textconv, fsmonitor, and submodule inspection are disabled. Global excludes, upstream configuration, and custom filtered results may differ from interactive Git; observations identify the snapshot source. Use literal process arguments or a single literal Git status/diff shell call for this adapter.

Every proposal validates tool arguments and selects an allowed backend, then applies an explicitly configured `command-pattern`, optional `double-check`, and optional `manual-confirm`. Reviewed edits and cached plans are authorized again. Confirmation cannot enable host mutation. Both review and confirmation default to off.

A failed step can recover locally. No matches, missing environment values, and differences found by diff have distinct semantics. Existing observations can be reused; explicit `fresh` requests resample. Failure of all required evidence produces a nonzero exit status even if the model supplies prose. Recovery is limited to two failed-step revisions per query.

This boundary resists host mutation; it is not a confidentiality boundary. Requested observations may reach the configured model. Environment credential values are redacted, but file contents are not subject to a general secret detector. Host readers rely on trusted binaries and tool configuration; reads can update access metadata. HTTP readers accept checked GET/HEAD forms whose remote semantics remain server-dependent.

## Configuration

Run `get config` to display all settings, `get config --<option>` for one value, or `get config --reset` to restore defaults.

| Option | Default | Description |
|---|---:|---|
| `url` | `https://api.minimaxi.com/v1` | API base URL |
| `model` | `minimax-m3` | Model identifier |
| `manual-confirm` | `false` | Confirm each command interactively |
| `double-check` | `false` | Add a second model safety review |
| `harness` | `auto` | `auto`, `direct`, `loop`, or `parallel` |
| `tool-protocol` | `auto` | `auto`, `native`, or `json` |
| `timeout` | `300` | API timeout in seconds; `false` disables it |
| `max-token` | `20480` | Maximum response tokens; `false` omits it |
| `max-rounds` | `6` | Inspection-turn limit; one final answer turn is separate |
| `max-tool-calls` | `16` | Actual tool-start limit per query |
| `max-parallel` | `4` | Maximum concurrent tool calls |
| `query-timeout` | `120` | Automatic query deadline in seconds, including model and tools |
| `diagnostics` | `false` | Emit structured events and counters to stderr |
| `command-timeout` | `30` | Hard deadline per command, seconds |
| `max-output-bytes` | `1048576` | Captured bytes per command |
| `command-pattern` | semantic policy only | Optional supplemental forbidden-command regex |
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
| `markdown` | `true` | Render model Markdown in interactive terminals; pipes retain source text |
| `instance` | `false` | v2 alias for `harness=direct` |

Harness and command safety limits require positive integers and cannot be disabled. Omit a value to reset it:

```bash
get set max-parallel 6
get set command-timeout 20
get set max-output-bytes 2097152
get set max-parallel            # reset to 4
```

`command-pattern` is opt-in and has three forms:

```bash
get set command-pattern '\b(ssh|curl)\b'  # custom supplemental policy
get set command-pattern                    # restore semantic-only default
get set command-pattern ""                 # clear an existing supplemental regex
```

## Per-query flags

```text
--no-cache / --cache
--manual-confirm / --no-manual-confirm
--double-check / --no-double-check
--harness <auto|direct|loop|parallel>
--protocol <auto|native|json>
--instance / --no-instance          compatibility aliases
--hide-process / --no-hide-process
--system-proxy / --no-system-proxy
--vivid / --no-vivid
--markdown / --no-markdown
--model <name>
--timeout <seconds>
```

Terminal `HTTP_PROXY`, `HTTPS_PROXY`, and `ALL_PROXY` variables are honored by default. On Windows, `system-proxy=true` makes enabled Internet Settings take precedence; `NO_PROXY` bypasses either source.

`NO_PROXY` / `no_proxy` accepts comma-separated entries: domains match themselves and their subdomains, IP literals match the exact address, and `*` bypasses all proxies. Entries without a port apply to every port; `example.com:443` applies only to destination port 443, with HTTP 80 and HTTPS 443 used when the URL omits a port. IPv6 may use `::1` or `[::1]`; a port requires brackets, as in `[::1]:8080`. Entries with empty, nonnumeric, or out-of-range ports (outside 1–65535) are ignored instead of bypassing the proxy for the whole host.

## Markdown output

Use `get set markdown true` (default), `get set markdown false`, or per-query
`--markdown` / `--no-markdown`. Inspect it with `get config --markdown`;
omitting the value resets the default.

The built-in renderer handles headings, emphasis, lists, quotes, code fences,
links, and tables with Chinese column widths. It requires no external program.
`vivid=false` or `NO_COLOR` disables rendering colors while retaining layout.
Pipes, redirected output, and `TERM=dumb` retain the Markdown source. Raw
command output is never interpreted as Markdown. Cached answers keep their
source text and respect the current rendering setting.

Markdown code examples and old HTML action markers are always answer text. `legacy` configuration values migrate to `json`; explicit JSON/native tool actions still pass the safety gate.

## Cache behavior

Caching does not spend a model call deciding what to cache. Schema 4 stores typed query plans; old entries do not share the new capability context.

- A successful single-step raw query stores a context-specific typed plan.
- A cache hit performs zero model calls, revalidates the command, and re-executes it so dynamic information stays current.
- Explicit text-only requests never execute a cached command; a cached final
  text result may still be returned without a provider or tool call.
- `--cache` may store a final text result when there is no reusable plan; hits show its original sample time.
- Multi-step results are not guessed into a cache entry.
- SHA-256 keys include v4, tool/backend capabilities, execution limits, working directory, provider URL, model, harness, protocol, shell, custom prompt, command policy, OS, and architecture. Older entries cannot collide.
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
# Check MemAvailable >= 6 GiB and memory full avg10 < 2 before compiling.
nice -n 10 nim c --parallelBuild:1 -d:release -o:.ci/get src/get.nim
GET_V3_BINARY="$PWD/.ci/get" python tests/test_cli_v3.py -v
python get_test.py --binary .ci/get --provider-config ~/.config/get \
  --shell bash --report .ci/provider-replay.json
```

Always select the newly built binary explicitly: historical executables in the
working tree or on PATH may belong to a different release.

Local persistence workers are capped at four. Full native platform suites run in CI. The provider replay uses isolated configuration, a mixed-language fixture with nested build/dependency directories, exact observable answers and an optional `--real-project` replay.

Focused tests under `tests/` cover protocol parsing, native tool payloads, state transitions, configuration migration, mandatory policy, bounded execution, and real parallel execution.

`get` is licensed under AGPL-3.0-or-later. Source: [github.com/Water-Run/get](https://github.com/Water-Run/get).
