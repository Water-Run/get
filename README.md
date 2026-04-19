# `get` -- get anything from your computer

[中文](README.zh.md)

`get` is a compact command-line binary tool that calls a Large Language Model (LLM) via natural language to generate shell commands, then executes them on your device to retrieve any information you need.

`get` is open-sourced under the `AGPL-3.0` license on [GitHub](https://github.com/Water-Run/get).

Usage examples:

```bash
get "IP address of this device"
get "code structure in the current directory"
get "latest get version at https://github.com/Water-Run/get"
```

## Installation

Download from [GitHub Release](https://github.com/Water-Run/get/releases). After extracting, run the bundled Python installation script `get_ready.py` to automatically complete installation and PATH configuration:

```bash
python get_ready.py
```

Follow the on-screen instructions. Once done, run `get version` to verify the installation.

> After installation, run `get_ready.py` again to uninstall.

## Prerequisites

Before use, you must configure at least the LLM-related parameters. `get` is compatible with the OpenAI API specification. Use the following commands to configure:

```bash
get set model your-model-name
get set url your-api-endpoint
get set key your-api-key
```

After configuration, run `get isok` to verify.

To clear a configuration value, leave the value empty. For example, to clear the key:

```bash
get set key
```

## Quick Start

Usage is straightforward:

```bash
get "your question"
```

> `get` is designed to perform read-only operations only. Every generated command goes through multiple layers of security validation before execution (built-in dangerous command regex blocking, plus optional double-check and manual confirmation).

## `set` Options Reference

Integer options accept `false` to disable the feature entirely (equivalent to 0).

| Option              | Description                                    | Value Type                        | Default                              |
|---------------------|------------------------------------------------|-----------------------------------|--------------------------------------|
| `key`               | LLM API key                                    | String                            | Empty                                |
| `url`               | LLM API endpoint URL                           | String (URL)                      | `https://api.poe.com/v1`             |
| `model`             | LLM model name                                 | String                            | `gpt-5.3-codex`                      |
| `manual-confirm`    | Require manual confirmation before execution   | `true` / `false`                  | `false`                              |
| `double-check`      | Enable secondary safety review of commands     | `true` / `false`                  | `true`                               |
| `instance`          | Use single-call fast mode                      | `true` / `false`                  | `false`                              |
| `timeout`           | Timeout per API request                        | Positive integer (s) / `false`    | `300`                                |
| `max-token`         | Maximum token consumption per request          | Positive integer / `false`        | `20480`                              |
| `max-rounds`        | Maximum loop rounds in agent mode              | Positive integer / `false`        | `3`                                  |
| `command-pattern`   | Regex pattern to block commands                | Regex string                      | Built-in blocklist (omit value to restore; `""` to disable) |
| `system-prompt`     | Custom system prompt                           | String                            | Empty                                |
| `shell`             | Shell used to execute commands                 | String                            | Windows: `powershell`; Linux: `bash` |
| `log`               | Log each request and execution                 | `true` / `false`                  | `true`                               |
| `hide-process`      | Hide intermediate steps                        | `true` / `false`                  | `false`                              |
| `cache`             | Enable response caching                        | `true` / `false`                  | `true`                               |
| `cache-expiry`      | Cache entry expiry in days                     | Positive integer (days) / `false` | `30`                                 |
| `cache-max-entries` | Maximum number of cache entries to retain      | Positive integer / `false`        | `1000`                               |
| `log-max-entries`   | Maximum number of log entries to retain        | Positive integer / `false`        | `1000`                               |
| `vivid`             | Enable vivid output mode (colors & animations) | `true` / `false`                  | `true`                               |
| `external-display`  | Use bat/mdcat for rendering                    | `true` / `false`                  | `true`                               |

Examples of disabling integer options:

```bash
get set timeout false
get set cache-expiry false
get set log-max-entries false
```

### Per-Query Overrides

The following flags can override persistent configuration for a single query, placed after the query string:

| Flag                  | Description                             |
|-----------------------|-----------------------------------------|
| `--no-cache`          | Bypass cache for this query             |
| `--cache`             | Force cache use for this query          |
| `--manual-confirm`    | Require confirmation before execution   |
| `--no-manual-confirm` | Skip confirmation prompt                |
| `--double-check`      | Enable secondary safety review          |
| `--no-double-check`   | Skip secondary safety review            |
| `--instance`          | Fast single-call mode                   |
| `--no-instance`       | Multi-round agent mode                  |
| `--hide-process`      | Hide intermediate process output        |
| `--no-hide-process`   | Show intermediate process output        |
| `--vivid`             | Enable vivid output mode                |
| `--no-vivid`          | Use plain text output mode              |
| `--model <name>`      | Override the LLM model for this query   |
| `--timeout <seconds>` | Override the request timeout this query |

Examples:

```bash
get "disk usage" --no-cache
get "list files" --model gpt-5.3-codex --vivid
```

### `config` Command

The `config` command is used to inspect the current configuration.

```bash
get config                # Show all current configuration
get config --reset        # Reset all configuration to defaults
get config --<option>     # Show the current value of a single option
```

`--<option>` accepts all option names from the `set` table above. `get config --key` shows whether a key is configured. The stored value is encrypted and cannot be retrieved. Disabled integer options display `false`.

```bash
get config --command-pattern   # View active pattern (full regex when default)
get set command-pattern        # Restore built-in default
get set command-pattern ""     # Disable pattern filtering
```

## Command Reference

### Cache

`get` uses a deferred-decision caching mechanism. Queries are not cached on first execution. Only when a query is repeated (or `--cache` is explicitly passed) does `get` invoke the LLM to determine the optimal caching strategy. Five strategies are supported: `GLOBAL_COMMAND` (cache the command globally, re-execute on hit), `GLOBAL_RESULT` (cache the output globally, return directly), `CONTEXT_COMMAND` (cache the command for the current directory context, re-execute on hit), `CONTEXT_RESULT` (cache the output for the current directory context, return directly), or `NOCACHE` (do not cache).

Global entries work across any working directory; context entries are tied to the directory where the query was originally executed.

```bash
get cache                       # Show cache status
get cache --clean               # Clear all cache entries and seen records
get cache --unset "system version"  # Remove cache entries matching the query
get set cache false             # Disable caching (disables all cache logic)
```

### Log

`get` records each query execution to a local file. When the number of entries exceeds the `log-max-entries` limit, the oldest entries are automatically removed.

```bash
get log              # Show log status
get log --clean      # Clear all log entries
get set log false    # Disable logging
```

### Miscellaneous

```bash
get get             # Show basic information about get (name, version, author, ...)
get get --intro     # Show introduction
get get --version   # Show version (equivalent to get version)
get get --license   # Show license identifier
get get --github    # Show GitHub link
get isok            # Verify that the current configuration is usable
get help            # Show usage help
```

## File Storage & Exit Codes

### File Storage Locations

- **Config file**: Linux `~/.config/get/config.json` / Windows `%APPDATA%/get/config.json`
- **API key**: Linux `~/.config/get/key` (permissions 0600) / Windows `%APPDATA%/get/key` (DPAPI encrypted)
- **Execution log**: Linux `~/.config/get/get.log` / Windows `%APPDATA%/get/get.log`
- **Response cache**: Linux `~/.config/get/cache.json` / Windows `%APPDATA%/get/cache.json`
- **Built-in tools**: `<executable>/bin/` or `<executable>/src/bin/`

### Exit Codes

- `0`: Completed successfully
- `1`: Configuration error, LLM communication failure, security check rejection, or general error
- `130`: Interrupted by Ctrl+C (SIGINT)
- `N`: When a generated command exits with a non-zero code, that exit code is passed through as `get`'s exit code
