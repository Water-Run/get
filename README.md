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

After downloading, you can use `get version` to verify the installation.
You can also use `get help` to get help.

## Prerequisites

Before getting started, you need to configure at least your large language model settings. `get` is compatible with the OpenAI API specification.
Use the following commands to configure:

```bash
get set model your-model-name
get set url your-url
get set key your-key
```

Once done, you can run `get ready` to verify.
To unset a configuration item, simply leave the value empty (i.e., omit the "your-" part above). For example, the following command unsets the Key:

```bash
get set key
```

## Getting Started

Usage is very straightforward:

```bash
get "your command"
```

`get` is designed to perform read-only operations only.

## `set` Options Reference

The full list of `set` options is shown in the table below:

| Option            | Description                                                                                                          | Value                       | Default                              |
|-------------------|----------------------------------------------------------------------------------------------------------------------|-----------------------------|--------------------------------------|
| `key`             | LLM API key                                                                                                          | String                      | Empty                                |
| `url`             | LLM API endpoint URL                                                                                                 | String (URL)                | Empty                                |
| `model`           | LLM model name                                                                                                       | String                      | Empty                                |
| `manual-confirm`  | Whether to require manual confirmation before executing generated commands                                           | `true` / `false`            | `true`                               |
| `double-check`    | Whether to invoke the model for a second review of the generated command before execution                            | `true` / `false`            | `false`                              |
| `quick`           | Whether to ask the model to reply as quickly as possible                                                             | `true` / `false`            | `false`                              |
| `cautious`        | Whether to ask the model to generate commands in a more cautious manner                                              | `true` / `false`            | `false`                              |
| `timeout`         | Timeout for a single API request                                                                                     | Positive integer (seconds)  | `300`                                |
| `max-token`       | Maximum token consumption per request                                                                                | Positive integer            | `20480`                              |
| `command-pattern` | Regex pattern to match against the generated command; execution is rejected if it does not match                     | Regex string                | Empty (no matching)                  |
| `system-prompt`   | System prompt used to constrain model behavior, declare available tool calls, etc.                                   | String                      | Empty                                |
| `shell`           | The shell used to execute commands                                                                                   | String (shell path or name) | Windows: `powershell`; Linux: `bash` |
| `log`             | Whether to log each request and execution                                                                            | `true` / `false`            | `true`                               |
| `allow-temp-file` | Whether to allow creation of temporary directories and files (may not be cleaned up properly if not closed normally) | `true` / `false`            | `false`                              |

## Other Command Reference

- `get config`: Display the current configuration
- `get github`: Return the GitHub link for `get`
- `get license`: Return the LICENSE for `get`
