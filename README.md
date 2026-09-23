# `get` — get anything from your computer

[中文](README-zh.md)

Ask this machine a question in plain language. `get` looks at the host and answers from what it finds — it's a query tool, so it reads your system without changing it.

```bash
get "IP address of this device"
get "code structure in the current directory"
get "current git branch and uncommitted files"
```

## Install

Download a package from [GitHub Releases](https://github.com/Water-Run/get/releases) and keep its files in one directory. Either way leaves an existing configuration in place.

If Python is available, the installer copies the program and updates your PATH:

```bash
python get_ready.py
get version
```

Without Python, copy the binary yourself and make sure its directory is on `PATH`:

| System | From the package | Install as |
|---|---|---|
| Linux | `get-linux-x64` | `~/.local/bin/get` |
| macOS | `get-macos-arm64` | `~/.local/bin/get` |
| Windows | `get-windows-x64.exe` | `%LOCALAPPDATA%\Programs\get\get.exe` |

On Linux and macOS, `chmod +x` the installed file. On macOS, also run `xattr -d com.apple.quarantine ~/.local/bin/get`. The manual page is optional: copy `get.1` to `~/.local/share/man/man1/get.1`.

> **Windows:** `libcrypto-3.dll`, `libssl-3.dll`, and `zlib1.dll` stay in the same folder as `get.exe`. Licenses and provenance: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Connect a model

`get` works with any OpenAI-compatible Chat Completions endpoint.

```bash
get set model your-model-name
get set url https://your-provider.example/v1
get set key your-api-key
get isok        # check the connection
```

Your key isn't printed or written to logs: the key file is `0600` on Linux and DPAPI-protected on Windows.

## How a query works

The model gets your question plus typed readers — environment, files, search, processes, Git status/diff — and answers from what they return. How it gathers evidence is controlled by the *harness*:

| Harness | Behavior |
|---|---|
| `auto` (default) | Look around, then answer |
| `direct` | One model turn, at most one tool call |
| `loop` | Serial observe-and-refine for dependent work |
| `parallel` | Concurrent independent read-only calls |

```bash
get "compare disk and memory usage" --harness parallel
get "show the current directory"    --harness direct
```

Tools are sent as native function calling by default, with an automatic JSON fallback; force one with `get set tool-protocol auto|native|json`.

If your query says "without tools", `get` switches to text-only mode: no tools are offered and nothing is executed.

## Safety

- Every command passes a mandatory safety policy before it runs — a denied command doesn't execute.
- Want more oversight? `get set manual-confirm true` asks before each command, and `get set double-check true` adds a second model review. Both are off by default, and neither can unlock host mutation.
- On Linux, free-form scripts run inside an isolated sandbox (bubblewrap namespaces, read-only host mounts, seccomp, resource limits) with no network access. If the sandbox can't be established, the script simply doesn't run.

| Capability | Linux | macOS | Windows |
|---|---|---|---|
| Typed environment / file / search readers, host queries | ✓ | ✓ | ✓ |
| Git status & diff snapshot | ✓ | ✓ | ✓ |
| Free-form scripts and shell computation | sandboxed | — | — |

> **Privacy:** whatever `get` reads is sent to your configured provider to be answered — treat it as shared with that provider, not as a secrecy boundary. Environment credential values are redacted.

## Configuration

`get config` shows every setting; `get config --<option>` shows one; `get config --reset` restores defaults. Omit the value to reset a setting:

```bash
get set model deepseek-flash
get set max-parallel 6
get set max-parallel      # back to the default
```

<details>
<summary><b>Full option list</b></summary>

| Option | Default | Description |
|---|---:|---|
| `url` | `https://api.deepseek.com` | API base URL |
| `model` | `deepseek-flash` | DeepSeek-V4.1-Flash |
| `manual-confirm` | `false` | Confirm each command interactively |
| `double-check` | `false` | Add a second model safety review |
| `harness` | `auto` | `auto`, `direct`, `loop`, or `parallel` |
| `tool-protocol` | `auto` | `auto`, `native`, or `json` |
| `timeout` | `300` | API timeout (seconds); `false` disables |
| `max-token` | `20480` | Response token limit; `false` omits it |
| `max-rounds` | `6` | Inspection-turn limit (final answer turn is separate) |
| `max-tool-calls` | `16` | Tool-start limit per query |
| `max-parallel` | `4` | Maximum concurrent tool calls |
| `query-timeout` | `120` | Whole-query deadline (seconds) |
| `diagnostics` | `false` | Structured events and counters on stderr |
| `command-timeout` | `30` | Hard deadline per command (seconds) |
| `max-output-bytes` | `1048576` | Captured bytes per command |
| `command-pattern` | off | Extra forbidden-command regex, e.g. `get set command-pattern '\b(ssh|curl)\b'` |
| `system-prompt` | empty | Additional model instruction |
| `shell` | `bash` / `powershell` | Command shell |
| `log` | `true` | Store execution logs |
| `hide-process` | `false` | Suppress progress and observations |
| `system-proxy` | `false` | Prefer Windows system proxy over terminal variables |
| `cache` | `true` | Deterministic caching |
| `cache-expiry` | `30` | Cache lifetime (days); `false` disables expiry |
| `cache-max-entries` | `1000` | Cache cap; `false` disables the cap |
| `log-max-entries` | `1000` | Log cap; `false` disables the cap |
| `vivid` | `true` | ANSI colors and progress animation |
| `markdown` | `true` | Render Markdown in interactive terminals; pipes keep source text |
| `instance` | `false` | Alias: `true` selects `harness=direct` |

</details>

## Per-query flags

```text
--harness <auto|direct|loop|parallel>   --protocol <auto|native|json>
--model <name>                          --timeout <seconds>
--instance / --no-instance              aliases for direct / loop
--cache / --no-cache                    --markdown / --no-markdown
--manual-confirm / --no-manual-confirm  --vivid / --no-vivid
--double-check / --no-double-check      --hide-process / --no-hide-process
                                        --system-proxy / --no-system-proxy
```

**Proxies:** `HTTP_PROXY`, `HTTPS_PROXY`, and `ALL_PROXY` are honored by default. On Windows, `system-proxy=true` prefers system settings. `NO_PROXY` takes comma-separated domains, subdomains, IP literals, and `*`, with optional ports (`example.com:443`).

## Markdown output

In an interactive terminal, `get` renders the model's Markdown — headings, lists, tables, code — with its own renderer; no external pager needed. Pipes, redirects, and `TERM=dumb` keep the raw source text, and `NO_COLOR` drops the colors. Toggle with `get set markdown false` or `--no-markdown`.

## Cache

Repeatable queries are cached without extra model calls. A cache hit revalidates and re-executes the stored command, so dynamic answers like "current memory usage" stay fresh. Multi-step results aren't cached.

```bash
get cache
get cache --clean
get cache --unset "system version"
```

`get set cache false` disables caching; `cache-expiry` sets the lifetime in days.

## Files & exit codes

Config, key, log, and cache live in `~/.config/get/` on Linux and `%APPDATA%\get\` on Windows: `config.json`, `key`, `get.log`, `cache.json`.

| Code | Meaning |
|---:|---|
| 0 | success |
| 1 | configuration, provider, policy, or general failure |
| 124 | command timeout |
| 126 | tool proposal rejected, no safe revision found |
| 130 | interrupted (Ctrl+C) |
| other | exit code of the terminating command |

## Development

Requires Nim ≥ 2.2.8. Build a development binary with:

```bash
nim c -d:release -o:.ci/get src/get.nim
```

Build and test conventions (including CI matrices) are in [AGENTS.md](AGENTS.md); test suites live in `tests/`. Issues and pull requests are welcome.

## License

[AGPL-3.0-or-later](LICENSE). Bundled OpenSSL and zlib keep their own licenses — see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
