# `get` — get anything from your computer

[中文](README-zh.md)

Ask this computer a question in ordinary language. `get` inspects the machine and answers from what it finds. It is a query tool: it reads the host, it does not change it. Model names are opaque service identifiers.

```bash
get "IP address of this device"
get "code structure in the current directory"
get "current git branch and uncommitted files"
```

## Install

Download a package from [GitHub Releases](https://github.com/Water-Run/get/releases), keep its files together, then run:

```bash
python get_ready.py
get version
```

The installer can keep an existing configuration while replacing the binary.

On Windows, `get-windows-x64.exe`, `libcrypto-3.dll`, `libssl-3.dll`, and
`zlib1.dll` must remain beside the installer; all four are installed together.
The DLLs provide OpenSSL 3.5.7 LTS and zlib 1.3.2. Provenance and licenses are
in `THIRD_PARTY_NOTICES.md`, `OPENSSL-LICENSE.txt`, and `ZLIB-LICENSE.txt`.

## Setup

`get` uses an OpenAI-compatible Chat Completions endpoint.

```bash
get set model your-model-name
get set url https://your-provider.example/v1
get set key your-api-key
get isok
```

API keys are never printed or logged. On Linux the key file is mode `0600`; on Windows it is protected with DPAPI.

## How a query works

The model receives your question and a set of typed readers. It gathers evidence, then answers.

`read_environment`, `read_file`, and `search_files` handle common reads. `run_process` takes a literal argv; `run_shell` uses the configured shell. Ordinary Git status and diff use a private metadata snapshot.

Search supports path globs, literal content matching, paging, and common `.gitignore` / `.ignore` / `.rgignore` rules. It is a bounded reader, not a complete Git or ripgrep replacement; hitting a scan limit returns an explicit incomplete result.

Four harness strategies control how evidence is gathered:

| Strategy | Behavior | Typical model calls |
|---|---|---:|
| `auto` | Inspect, then answer from observations | 1–4 |
| `direct` | One model turn and at most one terminal tool call | 1 |
| `loop` | Serial observation feedback for dependent work | 1–4 |
| `parallel` | Concurrent independent read-only calls | 1–4 |

`auto` is the default. `max-rounds` limits inspection turns; a separate final turn has no tools. If the provider cannot finish, get returns a bounded account of available evidence with a nonzero exit status.

In `auto`, `loop`, and `parallel`, a command denied by the mandatory policy is not executed. The denial is returned as a typed observation so the model can propose a simpler safe command within the existing turn and tool budget; every replacement is validated from scratch. `direct` never retries a denial.

```bash
get set harness auto
get "compare disk and memory usage" --harness parallel
get "show the current directory" --harness direct
```

Tool encoding is independent of the harness:

```bash
get set tool-protocol auto     # native tools; JSON fallback if the provider rejects them
get set tool-protocol native   # require native function tools
get set tool-protocol json     # explicit structured JSON actions
```

When a query explicitly says `without tools` or `without calling a tool`, get uses text-only routing: the provider receives no tool definition, textual tool actions are rejected, and a cached command is ignored. Markdown code examples are always answer text. Only explicit JSON or native tool actions enter the execution boundary.

## Query boundary

Known host readers check their arguments and see real process, device, network, and service state. On Linux, general scripts and complex shell computation run only after a complete isolation probe: bubblewrap namespaces, read-only host mounts, seccomp, and resource ceilings. That backend cannot reach the network or control sockets, and cannot control host processes or devices. Writes stay in private query scratch space, which the parent process cleans. Missing capabilities never fall back to an unrestricted script.

| Capability | Linux | macOS | Windows |
|---|---|---|---|
| Typed environment, files, search, and known host queries | Supported | Supported | Supported |
| Ordinary Git status/diff snapshot | Supported | Supported | Supported |
| General scripts and complex shell computation | After the full isolation probe | Not yet supported | Not yet supported |

Git snapshots keep the worktree, index, and basic line-ending and file-mode semantics without writing the real index. Executable filters, textconv, fsmonitor, and submodule inspection are disabled. Global excludes, upstream configuration, and custom filtered results may differ from interactive Git; observations name the snapshot source. Use literal process arguments or a single literal Git status/diff shell call for this adapter.

Every proposal validates tool arguments and selects an allowed backend, then applies an explicitly configured `command-pattern`, optional `double-check`, and optional `manual-confirm`. Reviewed edits and cached plans are authorized again. Confirmation cannot enable host mutation. Review and confirmation default to off.

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
| `cache-expiry` | `30` | Cache lifetime in days; `false` disables expiry |
| `cache-max-entries` | `1000` | Cache cap; `false` disables the cap |
| `log-max-entries` | `1000` | Log cap; `false` disables the cap |
| `vivid` | `true` | ANSI colors and progress animation |
| `markdown` | `true` | Render model Markdown in interactive terminals; pipes retain source text |
| `instance` | `false` | Alias: `true` selects `harness=direct` |

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
--instance / --no-instance          aliases for direct / loop
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

Use `get set markdown true` (default), `get set markdown false`, or per-query `--markdown` / `--no-markdown`. Inspect it with `get config --markdown`; omitting the value resets the default.

The built-in renderer handles headings, emphasis, lists, quotes, code fences, links, and tables with Chinese column widths. It requires no external program. `vivid=false` or `NO_COLOR` disables rendering colors while retaining layout. Pipes, redirected output, and `TERM=dumb` retain the Markdown source. Raw command output is never interpreted as Markdown. Cached answers keep their source text and respect the current rendering setting.

## Cache

Caching does not spend a model call deciding what to cache. A successful single-step query stores a typed plan for the current context.

- A cache hit performs zero model calls, revalidates the command, and re-executes it so dynamic information stays current.
- Explicit text-only requests never execute a cached command; a cached final text result may still be returned without a provider or tool call.
- `--cache` may store a final text result when there is no reusable plan; hits show its original sample time.
- Multi-step results are not guessed into a cache entry.
- SHA-256 keys include tool and backend capabilities, execution limits, working directory, provider URL, model, harness, protocol, shell, custom prompt, command policy, OS, and architecture.
- Writers hold a short cross-process lock around read-modify-write, so simultaneous `get` processes do not lose entries.
- Snapshots are flushed and atomically replaced with mode `0600` on POSIX. A last-good `.bak` snapshot is used automatically if the primary is damaged.
- Files and fields are schema-validated and size-bounded; expiry, duplicate replacement, and oldest-entry eviction are deterministic.

Configuration, key, log, and cache writes are serialized across processes.

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

Always select the newly built binary explicitly. Development binaries belong in `.ci/`. Live configuration, credentials, and the installed program are left unchanged.

Local persistence workers are capped at four. Full native platform suites run in CI. The provider replay uses isolated configuration, a mixed-language fixture with nested build/dependency directories, exact observable answers, and an optional `--real-project` replay.

Focused tests under `tests/` cover protocol parsing, native tool payloads, state transitions, configuration migration, mandatory policy, bounded execution, and real parallel execution.

`get` is licensed under AGPL-3.0-or-later. Source: [github.com/Water-Run/get](https://github.com/Water-Run/get).
