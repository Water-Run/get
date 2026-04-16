# `get` — Get Anything from Your Computer

`get` is a compact command-line tool that uses natural language to invoke a Large Language Model (LLM), generates shell commands, and executes them on your device to retrieve any information you need.

`get` is open-sourced under the `AGPL-3.0` license on [GitHub](https://github.com/Water-Run/get).

Usage examples:

```bash
get "system version"
get "code in the current directory"
get "latest get version on https://github.com/Water-Run/get"
```

Download: [GitHub Release](https://github.com/Water-Run/get/releases)

After downloading, place the `get` executable alongside the bundled `bin/` directory (containing `rg`, `fd`, `sg`, `pmc`, `tree`/`treepp`, `tokei`, `lua`, `bat`, `mdcat`, and other tools). Then run `get version` to verify the installation and `get help` to view help.

> A lightweight version without the `bin/` directory is also available. In that case, only tools already installed on your system will be available to generated commands.

## Installation & Uninstallation

The project includes a Python installer script `install_get.py` (requires Python 3.6+, no third-party dependencies) that automates installation and PATH configuration:

```bash
python3 install_get.py
```

The install path is `~/.local/share/get/` on Linux (with a symlink created at `~/.local/bin/`), and `%LOCALAPPDATA%\get\` on Windows (automatically added to the user PATH). If already installed, the script automatically switches to uninstall mode; uninstallation preserves user configuration files.

## Prerequisites

Before use, you must configure at least the LLM-related parameters. `get` is compatible with the OpenAI API specification. Use the following commands to configure:

```bash
get set model your-model-name
get set url your-api-endpoint
get set key your-api-key
```

After configuration, run `get isok` to verify.

To clear a configuration value, omit the value (i.e., leave out the "your-" part in the commands above). For example, to clear the key:

```bash
get set key
```

### Model Capability Requirements

`get` executes LLM-generated shell commands on your device, so a sufficiently capable model is the foundation of safety. At startup, `get` compares the configured model name against a built-in whitelist of known high-performance models and displays a warning if the model is not recognized.

Known strong models include: GPT 5+ (including CodeX variants), Claude Opus/Sonnet 3.5+, Claude 3.7+ (by version number), Gemini 3+, Grok 4+, GLM 4.7+, MiniMax 2.7+, DeepSeek (full versions), and OpenAI o-series 3+. Reduced-capability variants (Mini, Nano, Lite, Haiku, Flash, etc.) and unsupported model families will trigger a warning. The warning is advisory only and does not block execution.

Model names are normalized before comparison — differences in case and between underscores and hyphens are handled transparently (`Claude_Opus_4.6` is equivalent to `claude-opus-4.6`).

### System Requirements

`get` requires a 64-bit platform (amd64 or arm64) running Windows 10+ or Linux kernel 6.0+. A warning is displayed at startup if the runtime environment does not meet these requirements.

### Static Build

To build a fully statically linked binary (no dynamic library dependencies), use the `staticBuild` flag. This requires OpenSSL static libraries to be available on the system:

```bash
nim c -d:release -d:staticBuild src/get.nim
```

## Quick Start

Usage is straightforward:

```bash
get "your question"
```

`get` is designed to perform read-only operations exclusively. The LLM is strictly constrained by its system prompt to read-only mode, and every generated command goes through multiple layers of validation before execution:

1. **Dangerous Command Check** — A built-in safety check rejects commands containing known destructive operations (rm, del, mv, cp, mkdir, kill, shutdown, etc.) before execution.
2. **Double-Check** (default: enabled) — A second safety review of the generated command is performed by the LLM.
3. **Command Pattern Validation** — A regex match can be configured via `command-pattern`.
4. **Manual Confirmation** — An interactive y/N confirmation prompt can be enabled via `manual-confirm`.

### Output Modes

By default, `get` instructs the LLM to annotate whether the command output is self-explanatory (`DIRECT`) or requires interpretation (`INTERPRET`). Most queries produce direct output — the raw command result is displayed without any additional LLM call. Only when the output needs to be summarized or analyzed does `get` invoke the LLM again. In `instance` mode, output is always displayed directly.

### Built-in Tools

`get` ships with several high-performance command-line tools in the `bin/` directory that generated commands can use automatically:

| Tool                            | Description                                                       |
|---------------------------------|-------------------------------------------------------------------|
| `rg`                            | ripgrep — blazing-fast regex search through file contents         |
| `fd`                            | fast file/directory finder                                        |
| `sg`                            | ast-grep — AST-level structured code search                       |
| `pmc`                           | pack-my-code — packages code context for LLM prompts              |
| `treepp` (Win) / `tree` (Linux) | tree++ (Win) / classic Unix tree (Linux) — directory tree display |
| `tokei`                         | code statistics tool (lines of code by language)                  |
| `lua`                           | Lua 5.x interpreter for computation and text processing           |
| `bat`                           | syntax-highlighting cat replacement                               |
| `mdcat`                         | terminal Markdown renderer                                        |

The LLM is informed of these tools' existence and will prefer them in appropriate scenarios. Write-mode flags for built-in tools (e.g. `pmc -o`, `treepp /O`) are explicitly prohibited in the system prompt.

### Output Styles

`get` supports three output styles, configured via `get set style <mode>`:

| Style   | Description                                                           |
|---------|-----------------------------------------------------------------------|
| `simp`  | Plain text, no formatting. Sections separated by blank lines.         |
| `std`   | Dividers and basic ANSI colors (default).                             |
| `vivid` | Animated loading indicator, bold colors, Markdown rendered via mdcat. |

**vivid** mode is experimental. It requires the bundled `mdcat` binary for Markdown rendering; if unavailable, a warning is shown suggesting `get set style std`. An experimental notice is displayed on each invocation.

When `external-display` is enabled (default), `bat` is used for syntax-highlighted output and `mdcat` for Markdown rendering (effective in `std` and `vivid` modes).

### Bypassing the Cache

By default, `get` caches results so that repeated identical queries in the same context return instantly without any API calls. Before caching a result, `get` asks the LLM whether the output is stable enough to cache; volatile results (e.g. live metrics, the current time) are not cached. To bypass the cache for a single query, use the `--no-cache` flag:

```bash
get "your question" --no-cache
```

## Per-Query Flags (One-Time Overrides)

The following flags override persistent configuration for the current query and are placed after the query string:

| Flag                         | Description                             |
|------------------------------|-----------------------------------------|
| `--no-cache`                 | Bypass cache for this query             |
| `--cache`                    | Force cache use for this query          |
| `--manual-confirm`           | Require confirmation before execution   |
| `--no-manual-confirm`        | Skip confirmation prompt                |
| `--double-check`             | Enable second safety review             |
| `--no-double-check`          | Skip second safety review               |
| `--instance`                 | Fast single-call mode                   |
| `--no-instance`              | Multi-step mode                         |
| `--hide-process`             | Hide intermediate process output        |
| `--no-hide-process`          | Show intermediate process output        |
| `--model <name>`             | Override the LLM model for this query   |
| `--style <simp\|std\|vivid>` | Override output style for this query    |
| `--timeout <seconds>`        | Override request timeout for this query |

Examples:

```bash
get "disk usage" --no-cache
get "list files" --model gpt-5.3-codex --style vivid
```

## `set` Options Reference

The table below lists all `set` options. Integer options accept `false` to disable the feature entirely (equivalent to setting it to 0).

| Option              | Description                                                                                  | Value Type                           | Default                              |
|---------------------|----------------------------------------------------------------------------------------------|--------------------------------------|--------------------------------------|
| `key`               | LLM API key                                                                                  | String                               | Empty                                |
| `url`               | LLM API endpoint URL                                                                         | String (URL)                         | `https://api.poe.com/v1`             |
| `model`             | LLM model name                                                                               | String                               | `gpt-5.3-codex`                      |
| `manual-confirm`    | Require manual confirmation before execution                                                 | `true` / `false`                     | `false`                              |
| `double-check`      | Perform a second safety review of generated commands                                         | `true` / `false`                     | `true`                               |
| `instance`          | Ask the model to reply as quickly as possible (single-call mode)                             | `true` / `false`                     | `false`                              |
| `timeout`           | Timeout for a single API request                                                             | Positive integer (seconds) / `false` | `300`                                |
| `max-token`         | Maximum token consumption per request                                                        | Positive integer / `false`           | `20480`                              |
| `command-pattern`   | Regex pattern for prohibited commands; generated commands matching this pattern are rejected | Regex string                         | Empty (uses built-in defaults)       |
| `system-prompt`     | Custom system prompt                                                                         | String                               | Empty                                |
| `shell`             | Shell used to execute commands                                                               | String (path or name)                | Windows: `powershell`; Linux: `bash` |
| `log`               | Whether to log each request and execution                                                    | `true` / `false`                     | `true`                               |
| `hide-process`      | Whether to hide intermediate steps and show only the final result                            | `true` / `false`                     | `false`                              |
| `cache`             | Whether to enable response caching                                                           | `true` / `false`                     | `true`                               |
| `cache-expiry`      | Number of days before cache entries expire                                                   | Positive integer (days) / `false`    | `30`                                 |
| `cache-max-entries` | Maximum number of cache entries to retain                                                    | Positive integer / `false`           | `1000`                               |
| `log-max-entries`   | Maximum number of log entries to retain                                                      | Positive integer / `false`           | `1000`                               |
| `style`             | Output style                                                                                 | `simp` / `std` / `vivid`             | `std`                                |
| `external-display`  | Whether to use bat/mdcat for syntax highlighting and Markdown rendering                      | `true` / `false`                     | `true`                               |

Examples of disabling integer options:

```bash
get set timeout false            # No request timeout
get set max-token false          # Let the API decide the token limit
get set cache-expiry false       # Cache entries never expire
get set cache-max-entries false  # No limit on cache size
get set log-max-entries false    # No limit on log entries
```

### Dangerous Command Safety Check

`get` has a built-in safety check that rejects commands containing known destructive operations before execution. This check runs independently of the `command-pattern` configuration.

Intercepted commands include: `rm`, `rmdir`, `del`, `rd`, `erase`, `mv`, `move`, `cp`, `copy`, `mkdir`, `md`, `touch`, `chmod`, `chown`, `chgrp`, `mkfs`, `dd`, `format`, `fdisk`, `kill`, `killall`, `pkill`, `shutdown`, `reboot`, `halt`, `poweroff`, `passwd`, `useradd`, `userdel`, `usermod`, `groupadd`, `groupdel`, `Set-Content`, `New-Item`, `Remove-Item`, `Move-Item`, `Rename-Item`, `Clear-Content`, `Add-Content`, and others.

When a custom `command-pattern` is set, `get` checks whether the pattern covers common dangerous commands and displays a warning if it does not.

## Cache Management

`get` caches the final output of each query, keyed by a hash of the query text and execution context (working directory, shell, model, instance mode, system prompt, and command pattern). When the same query is run in the same context, the cached result is returned immediately.

Before storing a new cache entry, `get` sends a lightweight LLM request to determine whether the result is stable (cacheable) or volatile (non-cacheable). Volatile results (e.g. current time, CPU usage, running processes) are not cached even when caching is enabled.

### View Cache Status

```bash
get cache
```

Displays whether caching is enabled, the number of cached entries, the configured limits, and the cache file location.

### Clear All Cache

```bash
get cache --clean
```

### Remove Cache for a Specific Query

```bash
get cache --unset "system version"
```

Removes all cache entries whose query text matches the given string (case-insensitive).

### Disable Caching

```bash
get set cache false
```

When disabled, no cache lookups or writes are performed. Existing cache entries on disk are retained until explicitly cleared.

### Adjust Cache Parameters

```bash
get set cache-expiry 7
get set cache-max-entries 500
get set cache-expiry false        # Entries never expire
get set cache-max-entries false   # No limit on entries
```

## Log Management

`get` logs each query execution (query text, generated command, exit code, and output preview) to a local file. When the number of entries exceeds the `log-max-entries` limit (unless set to `false` to disable), the oldest entries are automatically removed.

### View Log Status

```bash
get log
```

Displays whether logging is enabled, the configured maximum entries, the current entry count, the file location, and the file size.

### Clear Logs

```bash
get log --clean
```

### Adjust Log Parameters

```bash
get set log-max-entries 500
get set log-max-entries false  # No limit on log entries
```

### Disable Logging

```bash
get set log false
```

## `config` Command Reference

```bash
get config                  # Show all current configuration
get config --reset          # Reset all configuration to defaults
get config --<option-name>  # Show the current value of a single option
```

`--<option-name>` accepts all option names from the `set` table above. Examples:

```bash
get config --key
get config --url
get config --model
get config --manual-confirm
get config --double-check
get config --instance
get config --timeout
get config --max-token
get config --command-pattern
get config --system-prompt
get config --shell
get config --log
get config --hide-process
get config --cache
get config --cache-expiry
get config --cache-max-entries
get config --log-max-entries
get config --style
get config --external-display
```

Note: `get config --key` shows the key status (set/not set) with the value masked. Disabled integer options display `false`.

## Other Commands Reference

```bash
get get                   # Show basic information about get
get get --intro           # Show an introduction to get
get get --version         # Show version (equivalent to get version)
get get --license         # Show the license identifier
get get --github          # Show the GitHub link
get version               # Show version
get isok                  # Verify the current configuration (checks key, url, model and sends a probe request)
get help                  # Show usage help
get log                   # Show log status
get log --clean           # Clear all log entries
get cache                 # Show cache status
get cache --clean         # Clear all cache entries
get cache --unset "query" # Remove cache entries matching the query
```

## File Storage Locations

Configuration and data files are stored at the following locations:

| File               | Linux Path                                     | Windows Path                          |
|--------------------|------------------------------------------------|---------------------------------------|
| Configuration file | `~/.config/get/config.json`                    | `%APPDATA%/get/config.json`           |
| API key            | `~/.config/get/key` (permissions 0600)         | `%APPDATA%/get/key` (DPAPI encrypted) |
| Execution log      | `~/.config/get/get.log`                        | `%APPDATA%/get/get.log`               |
| Response cache     | `~/.config/get/cache.json`                     | `%APPDATA%/get/cache.json`            |
| Built-in tools     | `<executable>/bin/` or `<executable>/src/bin/` | Same as Linux                         |

## Exit Codes

| Exit Code | Meaning                                                                                                |
|-----------|--------------------------------------------------------------------------------------------------------|
| `0`       | Completed successfully                                                                                 |
| `1`       | Configuration error, LLM communication failure, safety check rejection, or general error               |
| `130`     | Interrupted by Ctrl+C (SIGINT)                                                                         |
| *N*       | When a generated command exits with a non-zero code, that exit code is propagated as `get`'s exit code |