# `get` -- get anything from your computer

[中文](README-zh.md)

`get` is a small command-line tool that uses a Large Language Model (LLM) to generate shell commands from natural language, then executes them on your device to retrieve whatever information you need.

`get` is open-sourced under the `AGPL-3.0` license on [GitHub](https://github.com/Water-Run/get).

Usage examples:

```bash
get "system version"
get "code in the current directory"
get "latest version of get on https://github.com/Water-Run/get"
```

Download: [GitHub Release](https://github.com/Water-Run/get/releases)

## Installation and Uninstallation

The project ships with a Python installer script `get_ready.py` that handles installation and PATH configuration automatically:

```bash
python3 get_ready.py
```

After installation, run `get version` to verify. If already installed, the script switches to uninstall mode.

## Prerequisites

Before use, you need to configure the LLM parameters at minimum. `get` is compatible with the OpenAI API specification. Configure it with:

```bash
get set model YOUR_MODEL_NAME
get set url YOUR_API_ENDPOINT
get set key YOUR_API_KEY
```

After configuration, run `get isok` to validate.

To clear a setting, leave the value empty. For example, to clear the key:

```bash
get set key
```

## Quick Start

Usage is very simple:

```bash
get "your question"
```

`get` is designed to perform read-only operations only. Every generated command goes through multiple layers of safety validation before execution (dangerous-command blocking, double-check review, command-pattern matching, and optional manual confirmation).

### Built-in Tools

`get` ships with a set of high-performance command-line tools in the `bin/` directory that generated commands can use automatically:

| Tool                            | Description                                             |
|---------------------------------|---------------------------------------------------------|
| `rg`                            | ripgrep -- ultra-fast regex content search              |
| `fd`                            | Fast file/directory finder                              |
| `sg`                            | ast-grep -- AST-level structural code search            |
| `pmc`                           | pack-my-code -- packs code context for LLM prompts      |
| `treepp` (Win) / `tree` (Linux) | Directory tree display                                  |
| `tokei`                         | Code statistics tool (lines of code by language)        |
| `lua`                           | Lua 5.x interpreter for computation and text processing |
| `bat`                           | Syntax-highlighted replacement for `cat`                |
| `mdcat`                         | Terminal Markdown renderer                              |

The LLM is informed of these tools and prefers them in suitable scenarios. Write-mode flags of the built-in tools (such as `pmc -o`, `treepp /o`) are explicitly forbidden in the prompt.

## Query Flags (Per-Invocation Overrides)

The following flags override persistent configuration for a single query and are placed after the query string:

| Flag                  | Description                                      |
|-----------------------|--------------------------------------------------|
| `--no-cache`          | Bypass the cache for this query                  |
| `--cache`             | Force cache usage for this query                 |
| `--manual-confirm`    | Require confirmation before execution            |
| `--no-manual-confirm` | Skip the confirmation prompt                     |
| `--double-check`      | Enable the second safety review                  |
| `--no-double-check`   | Skip the second safety review                    |
| `--instance`          | Fast single-shot mode                            |
| `--no-instance`       | Multi-round agent mode                           |
| `--hide-process`      | Hide intermediate process output                 |
| `--no-hide-process`   | Show intermediate process output                 |
| `--vivid`             | Enable vivid output mode                         |
| `--no-vivid`          | Use plain-text output mode                       |
| `--model <name>`      | Override the LLM model for this invocation       |
| `--timeout <seconds>` | Override the request timeout for this invocation |

Examples:

```bash
get "disk usage" --no-cache
get "list files" --model gpt-5.3-codex --vivid
```

## `set` Option Reference

Integer options accept `false` to disable the feature entirely (equivalent to 0).

| Option              | Description                                      | Value type                 | Default                              |
|---------------------|--------------------------------------------------|----------------------------|--------------------------------------|
| `key`               | LLM API key                                      | string                     | empty                                |
| `url`               | LLM API endpoint URL                             | string (URL)               | `https://api.poe.com/v1`             |
| `model`             | LLM model name                                   | string                     | `gpt-5.3-codex`                      |
| `manual-confirm`    | Require manual confirmation before execution     | `true` / `false`           | `false`                              |
| `double-check`      | Perform a second safety review                   | `true` / `false`           | `true`                               |
| `instance`          | Use single-shot fast mode                        | `true` / `false`           | `false`                              |
| `timeout`           | Single API request timeout                       | positive int (s) / `false` | `300`                                |
| `max-token`         | Maximum tokens per request                       | positive int / `false`     | `20480`                              |
| `max-rounds`        | Maximum loop rounds in agent mode                | positive int / `false`     | `3`                                  |
| `command-pattern`   | Forbidden-command regex pattern                  | regex string               | empty (built-in defaults)            |
| `system-prompt`     | Custom system prompt                             | string                     | empty                                |
| `shell`             | Shell used to execute commands                   | string                     | Windows: `powershell`; Linux: `bash` |
| `log`               | Log each request and execution                   | `true` / `false`           | `true`                               |
| `hide-process`      | Hide intermediate steps                          | `true` / `false`           | `false`                              |
| `cache`             | Enable response caching                          | `true` / `false`           | `true`                               |
| `cache-expiry`      | Cache entry expiry in days                       | positive int (d) / `false` | `30`                                 |
| `cache-max-entries` | Maximum number of cache entries                  | positive int / `false`     | `1000`                               |
| `log-max-entries`   | Maximum number of log entries                    | positive int / `false`     | `1000`                               |
| `vivid`             | Enable vivid output mode (colors and animations) | `true` / `false`           | `true`                               |
| `external-display`  | Use bat/mdcat for rendering                      | `true` / `false`           | `true`                               |

Examples of disabling integer options:

```bash
get set timeout false
get set cache-expiry false
get set log-max-entries false
```

## Cache Management

`get` caches the final output of each query, keyed by a hash of the query text and execution context. Before storing a new cache entry, `get` asks the LLM to decide the caching policy:

| Cache mode           | Description                                                                                                                   |
|----------------------|-------------------------------------------------------------------------------------------------------------------------------|
| `RESULT` (result)    | Output is stable; cache the final output directly. E.g., system version, project structure, static config.                    |
| `COMMAND` (command)  | Command is reusable but output is volatile; only the command is cached and re-executed on hit. E.g., CPU usage, current time. |
| `NOCACHE` (no cache) | Context-dependent or transient; neither command nor output is cached.                                                         |

Common commands:

```bash
get cache                       # Show cache status
get cache --clean               # Clear all cache entries
get cache --unset "system version"  # Remove cache entries matching the query
get set cache false             # Disable the cache
```

## Log Management

`get` records each query execution to a local file. When the number of entries exceeds `log-max-entries`, the oldest entries are removed automatically.

```bash
get log              # Show log status
get log --clean      # Clear all log entries
get set log false    # Disable logging
```

## `config` Command Reference

```bash
get config                # Show all current configuration
get config --reset        # Reset all configuration to defaults
get config --<option>     # Show the current value of a single option
```

`--<option>` accepts any option name from the `set` table above. `get config --key` displays the key status (set/unset) with the value masked. Disabled integer options display as `false`.

## Other Command Reference

```bash
get get             # Show basic information about get
get get --intro     # Show the introduction
get get --version   # Show the version
get get --license   # Show the license identifier
get get --github    # Show the GitHub link
get version         # Show the version
get isok            # Validate whether the current configuration works
get help            # Show usage help
```

## File Locations

| File           | Linux path                                     | Windows path                          |
|----------------|------------------------------------------------|---------------------------------------|
| Config file    | `~/.config/get/config.json`                    | `%APPDATA%/get/config.json`           |
| API key        | `~/.config/get/key` (mode 0600)                | `%APPDATA%/get/key` (DPAPI-encrypted) |
| Execution log  | `~/.config/get/get.log`                        | `%APPDATA%/get/get.log`               |
| Response cache | `~/.config/get/cache.json`                     | `%APPDATA%/get/cache.json`            |
| Built-in tools | `<executable>/bin/` or `<executable>/src/bin/` | same as Linux                         |

## Exit Codes

| Exit code | Meaning                                                                                           |
|-----------|---------------------------------------------------------------------------------------------------|
| `0`       | Successful completion                                                                             |
| `1`       | Configuration error, LLM communication failure, safety-check rejection, or general error          |
| `130`     | Interrupted by Ctrl+C (SIGINT)                                                                    |
| *N*       | When a generated command exits with a non-zero code, that code is propagated as `get`'s exit code |
