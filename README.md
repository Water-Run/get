# `get` -- get anything from your computer

`get` is a small, simple binary tool that allows you to use natural language to invoke a large language model to generate commands, and attempt to retrieve any information you need from your device.  
`get` is open-sourced on [GitHub](https://github.com/Water-Run/get) under the `AGPL-3.0` license.

Examples:

```bash
get "system version"
get "code in the directory"
get "the latest get version at https://github.com/Water-Run/get"
```

Download: [GitHub Release](https://github.com/Water-Run/get/releases)

After downloading, place the `get` executable alongside the bundled `bin/` directory (which contains `rg`, `fd`, `sg`, `pmc`, and `treepp`/`tree`). You can then use `get version` to verify the installation and `get help` to get help.

## Prerequisites

Before getting started, you need to configure at least your large language model settings. `get` is compatible with the OpenAI API specification.  
Use the following commands to configure:

```bash
get set model your-model-name
get set url your-url
get set key your-key
```

Once done, you can run `get isok` to verify.  
To unset a configuration item, simply leave the value empty (i.e., omit the "your-" part above). For example, the following command unsets the Key:

```bash
get set key
```

### System Requirements

`get` requires a 64-bit platform running Windows 10+ or Linux with kernel 6.0+. A startup warning is shown if the runtime environment does not meet these requirements.

### Static Builds

To produce a fully statically linked binary (no dynamic library dependencies), build with the `staticBuild` flag. This requires static OpenSSL libraries to be available on the system:

```bash
nim c -d:release -d:staticBuild src/get.nim
```

## Getting Started

Usage is very straightforward:

```bash
get "your query"
```

`get` is designed to perform read-only operations only.

### Bundled Tools

`get` ships with several high-performance command-line tools in the `bin/` directory. These tools are automatically available to generated commands:

| Tool              | Description                                           |
|-------------------|-------------------------------------------------------|
| `rg`              | ripgrep — ultra-fast regex search in files            |
| `fd`              | Fast file/directory finder                            |
| `sg`              | ast-grep — AST-level structural code search           |
| `pmc`             | pack-my-code — code context packaging for LLM prompts |
| `treepp` / `tree` | tree++ — enhanced directory tree listing              |

The LLM is made aware of these tools and will prefer them when they fit the task.

### Skipping the Cache

By default, `get` caches results so that repeated identical queries in the same context return instantly without making any API calls. To bypass the cache for a single query, use the `--no-cache` flag:

```bash
get "your query" --no-cache
```

## `set` Options Reference

The full list of `set` options is shown in the table below:

| Option              | Description                                                                                      | Value                       | Default                              |
|---------------------|--------------------------------------------------------------------------------------------------|-----------------------------|--------------------------------------|
| `key`               | LLM API key                                                                                      | String                      | Empty                                |
| `url`               | LLM API endpoint URL                                                                             | String (URL)                | `https://api.poe.com/v1`             |
| `model`             | LLM model name                                                                                   | String                      | `gpt-5.3-codex`                      |
| `manual-confirm`    | Whether to require manual confirmation before executing generated commands                       | `true` / `false`            | `false`                              |
| `double-check`      | Whether to invoke the model for a second review of the generated command before execution        | `true` / `false`            | `false`                              |
| `instance`          | Whether to ask the model to reply as quickly as possible                                         | `true` / `false`            | `false`                              |
| `timeout`           | Timeout for a single API request                                                                 | Positive integer (seconds)  | `300`                                |
| `max-token`         | Maximum token consumption per request                                                            | Positive integer            | `20480`                              |
| `command-pattern`   | Regex pattern to match against the generated command; execution is rejected if it does not match | Regex string                | Empty (no matching)                  |
| `system-prompt`     | System prompt used to constrain model behavior, declare available tool calls, etc.               | String                      | Empty                                |
| `shell`             | The shell used to execute commands                                                               | String (shell path or name) | Windows: `powershell`; Linux: `bash` |
| `log`               | Whether to log each request and execution                                                        | `true` / `false`            | `true`                               |
| `hide-process`      | Whether to hide intermediate steps and only output the final result                              | `true` / `false`            | `false`                              |
| `cache`             | Whether to enable response caching                                                               | `true` / `false`            | `true`                               |
| `cache-expiry`      | Number of days before a cache entry expires                                                      | Positive integer (days)     | `30`                                 |
| `cache-max-entries` | Maximum number of entries retained in the cache                                                  | Positive integer            | `1000`                               |
| `log-max-entries`   | Maximum number of entries retained in the log                                                    | Positive integer            | `1000`                               |

## Cache Management

`get` caches the final output of each query keyed by a hash of the query text and execution context (working directory, shell, model, instance mode, system prompt, and command pattern). When the same query is run under the same context, the cached result is returned immediately.

### Viewing Cache Status

```bash
get cache
```

Displays whether caching is enabled, the number of cached entries, configured limits, and the cache file location.

### Clearing All Cache

```bash
get cache --clean
```

Removes every entry from the cache.

### Removing a Specific Cached Query

```bash
get cache --unset "system version"
```

Removes all cache entries whose query text matches the given string (case-insensitive).

### Disabling the Cache

```bash
get set cache false
```

When disabled, no cache lookups or writes are performed. Existing cache entries are preserved on disk until explicitly cleaned.

### Tuning Cache Parameters

```bash
get set cache-expiry 7
get set cache-max-entries 500
```

## Log Management

`get` logs each query execution (query text, generated command, exit code, and output preview) to a local file. When the entry count exceeds the `log-max-entries` limit, the oldest entries are automatically removed.

### Viewing Log Status

```bash
get log
```

Displays whether logging is enabled, the configured maximum entries, entry count, file location, and file size.

### Clearing the Log

```bash
get log --clean
```

Removes all entries from the log file.

### Tuning Log Parameters

```bash
get set log-max-entries 500
```

### Disabling Logging

```bash
get set log false
```

When disabled, no log writes are performed. Existing log content is preserved until explicitly cleaned.

## `config` Command Reference

- `get config`: Display the current configuration (all options).
- `get config --reset`: Reset all configuration to default values.
- `get config --<option>`: Display the current value of a single option.

The `--<option>` flag accepts every option name from the `set` table above. Examples:

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
```

Note: `get config --key` displays the key status (set/not set) with the value masked for security.

## Other Command Reference

- `get get`: Return basic information for `get`
- `get get --intro`: Return introduction for `get`
- `get get --version`: Return version for `get` (equivalent to `get version`)
- `get get --license`: Return the LICENSE for `get`
- `get get --github`: Return the GitHub link for `get`
- `get version`: Return version for `get`
- `get isok`: Verify whether current configuration is ready to use (checks key, url, model, and sends a probe request)
- `get help`: Display usage help
- `get log`: Display log status
- `get log --clean`: Clear all log entries
