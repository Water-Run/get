# `get` —— 从你的电脑获取一切

`get` 是一个小巧的命令行工具，通过自然语言调用大语言模型（LLM）生成 Shell 命令，并在你的设备上执行，以获取你需要的任何信息。

`get` 以 `AGPL-3.0` 许可证在 [GitHub](https://github.com/Water-Run/get) 上开源。

使用示例：

```bash
get "系统版本"
get "当前目录下的代码"
get "https://github.com/Water-Run/get 上最新的 get 版本"
```

下载：[GitHub Release](https://github.com/Water-Run/get/releases)

下载后，将 `get` 可执行文件与附带的 `bin/` 目录（包含 `rg`、`fd`、`sg`、`pmc`、`tree`/`treepp`、`tokei`、`lua`、`bat`、`mdcat` 等工具）放在一起。然后运行 `get version` 验证安装，运行 `get help` 查看帮助。

> 也提供不含 `bin/` 目录的轻量版。此时仅系统已安装的工具可供生成的命令使用。

## 安装与卸载

项目附带 Python 安装脚本 `install_get.py`（需要 Python 3.6+，无第三方依赖），可自动完成安装和 PATH 配置：

```bash
python3 install_get.py
```

安装路径为 Linux 下 `~/.local/share/get/`（并在 `~/.local/bin/` 创建符号链接），Windows 下 `%LOCALAPPDATA%\get\`（自动添加到用户 PATH）。若已安装则脚本自动切换为卸载模式，卸载时会保留用户配置文件。

## 前提条件

使用前，至少需要配置大语言模型的相关参数。`get` 兼容 OpenAI API 规范。使用以下命令进行配置：

```bash
get set model 你的模型名称
get set url 你的接口地址
get set key 你的API密钥
```

配置完成后，运行 `get isok` 进行验证。

若要取消某项配置，将值留空即可（即省略上述命令中 "你的" 部分）。例如取消 Key 设置：

```bash
get set key
```

### 模型强度要求

`get` 会在你的设备上执行由 LLM 生成的 Shell 命令，因此足够强大的模型是安全的基础。启动时，`get` 会将配置的模型名称与内置的已知高性能模型白名单进行比对，若未识别则显示警告。

已知的强模型包括：GPT 5+（含 CodeX 变体）、Claude Opus/Sonnet 3.5+、Claude 3.7+（按版本号）、Gemini 3+、Grok 4+、GLM 4.7+、MiniMax 2.7+、DeepSeek（完整版）及 OpenAI o 系列 3+。缩减能力的变体（Mini、Nano、Lite、Haiku、Flash 等）和不支持的模型家族会触发警告。该警告仅为建议性提示，不会阻止执行。

模型名称在比对前会进行规范化处理——大小写差异、下划线与连字符之间的差异均透明处理（`Claude_Opus_4.6` 与 `claude-opus-4.6` 等价）。

### 系统要求

`get` 需要 64 位平台（amd64 或 arm64），运行 Windows 10+ 或 Linux 内核 6.0+。若运行环境不满足要求，启动时会显示警告。

### 静态构建

若需构建完全静态链接的二进制文件（无动态库依赖），使用 `staticBuild` 标志。此操作要求系统上有可用的 OpenSSL 静态库：

```bash
nim c -d:release -d:staticBuild src/get.nim
```

## 快速开始

用法非常简单：

```bash
get "你的问题"
```

`get` 设计为仅执行只读操作。LLM 被提示词严格约束为只读模式，并且每条生成的命令在执行前都要经过多层验证：

1. **危险命令检查** —— 内置安全检查会在执行前拒绝包含已知破坏性操作的命令（rm、del、mv、cp、mkdir、kill、shutdown 等）。
2. **二次审查**（默认：开启）—— 由 LLM 对生成的命令进行第二次安全审查。
3. **命令模式验证** —— 可通过 `command-pattern` 配置正则表达式匹配。
4. **手动确认** —— 可通过 `manual-confirm` 开启交互式 y/N 确认提示。

### 输出模式

默认情况下，`get` 指示 LLM 标注命令输出是自明的（`DIRECT`）还是需要解读的（`INTERPRET`）。大多数查询会直接输出——原始命令结果直接显示，无需额外的 LLM 调用。仅当输出需要总结或分析时，`get` 才会再次调用 LLM。在 `instance` 模式下，输出始终直接显示。

### 内置工具

`get` 在 `bin/` 目录中附带了多个高性能命令行工具，生成的命令可自动使用这些工具：

| 工具 | 说明 |
|---|---|
| `rg` | ripgrep —— 超快速正则搜索文件内容 |
| `fd` | 快速文件/目录查找器 |
| `sg` | ast-grep —— AST 级别的结构化代码搜索 |
| `pmc` | pack-my-code —— 为 LLM 提示打包代码上下文 |
| `treepp`（Win）/ `tree`（Linux） | tree++（Win）/ 经典 Unix tree（Linux）—— 目录树展示 |
| `tokei` | 代码统计工具（按语言统计代码行数） |
| `lua` | Lua 5.x 解释器，用于计算和文本处理 |
| `bat` | 语法高亮的 cat 替代品 |
| `mdcat` | 终端 Markdown 渲染器 |

LLM 被告知这些工具的存在，并会在适合的场景中优先使用它们。内置工具的写入模式标志（如 `pmc -o`、`treepp /O`）在提示词中被明确禁止。

### 输出风格

`get` 支持三种输出风格，通过 `get set style <模式>` 配置：

| 风格 | 说明 |
|---|---|
| `simp` | 纯文本，无格式。各段以空行分隔。 |
| `std` | 分隔线和基本 ANSI 颜色（默认）。 |
| `vivid` | 动画加载指示器、粗体颜色、通过 mdcat 渲染 Markdown。 |

**vivid** 模式为实验性功能。它需要内置的 `mdcat` 二进制文件用于 Markdown 渲染；若不可用，会显示警告建议使用 `get set style std`。每次调用时会显示实验性提示。

当 `external-display` 启用时（默认），`bat` 用于语法高亮输出，`mdcat` 用于 Markdown 渲染（在 `std` 和 `vivid` 模式下生效）。

### 跳过缓存

默认情况下，`get` 会缓存结果，使得在相同上下文中重复的相同查询可以即时返回，无需进行任何 API 调用。在缓存结果之前，`get` 会询问 LLM 输出是否足够稳定以进行缓存；易变的结果（如实时指标、当前时间）不会被缓存。若要对单次查询绕过缓存，使用 `--no-cache` 标志：

```bash
get "你的问题" --no-cache
```

## 查询标志（按次覆盖）

以下标志可在查询时覆盖持久化配置，置于查询字符串之后：

| 标志 | 说明 |
|---|---|
| `--no-cache` | 本次查询绕过缓存 |
| `--cache` | 本次查询强制使用缓存 |
| `--manual-confirm` | 执行前要求确认 |
| `--no-manual-confirm` | 跳过确认提示 |
| `--double-check` | 启用二次安全审查 |
| `--no-double-check` | 跳过二次安全审查 |
| `--instance` | 快速单次调用模式 |
| `--no-instance` | 多步模式 |
| `--hide-process` | 隐藏中间过程输出 |
| `--no-hide-process` | 显示中间过程输出 |
| `--model <名称>` | 覆盖本次使用的 LLM 模型 |
| `--style <simp\|std\|vivid>` | 覆盖本次输出风格 |
| `--timeout <秒数>` | 覆盖本次请求超时时间 |

示例：

```bash
get "磁盘使用情况" --no-cache
get "列出文件" --model gpt-5.3-codex --style vivid
```

## `set` 选项参考

下表列出了所有 `set` 选项。整数选项接受 `false` 以完全禁用该功能（等同于设为 0）。

| 选项 | 说明 | 值类型 | 默认值 |
|---|---|---|---|
| `key` | LLM API 密钥 | 字符串 | 空 |
| `url` | LLM API 端点 URL | 字符串（URL） | `https://api.poe.com/v1` |
| `model` | LLM 模型名称 | 字符串 | `gpt-5.3-codex` |
| `manual-confirm` | 执行前是否要求手动确认 | `true` / `false` | `false` |
| `double-check` | 是否对生成的命令进行二次安全审查 | `true` / `false` | `true` |
| `instance` | 是否要求模型尽快回复（单次调用模式） | `true` / `false` | `false` |
| `timeout` | 单次 API 请求超时时间 | 正整数（秒）/ `false` | `300` |
| `max-token` | 每次请求的最大 token 消耗 | 正整数 / `false` | `20480` |
| `command-pattern` | 禁止命令正则匹配模式；生成的命令匹配则拒绝执行 | 正则字符串 | 空（使用内置默认） |
| `system-prompt` | 自定义系统提示词 | 字符串 | 空 |
| `shell` | 用于执行命令的 Shell | 字符串（路径或名称） | Windows: `powershell`；Linux: `bash` |
| `log` | 是否记录每次请求和执行 | `true` / `false` | `true` |
| `hide-process` | 是否隐藏中间步骤仅输出最终结果 | `true` / `false` | `false` |
| `cache` | 是否启用响应缓存 | `true` / `false` | `true` |
| `cache-expiry` | 缓存条目过期天数 | 正整数（天）/ `false` | `30` |
| `cache-max-entries` | 缓存保留的最大条目数 | 正整数 / `false` | `1000` |
| `log-max-entries` | 日志保留的最大条目数 | 正整数 / `false` | `1000` |
| `style` | 输出风格 | `simp` / `std` / `vivid` | `std` |
| `external-display` | 是否使用 bat/mdcat 进行语法高亮和 Markdown 渲染 | `true` / `false` | `true` |

禁用整数选项的示例：

```bash
get set timeout false          # 不设请求超时
get set max-token false        # 由 API 决定 token 上限
get set cache-expiry false     # 缓存条目永不过期
get set cache-max-entries false  # 不限制缓存大小
get set log-max-entries false    # 不限制日志条目数
```

### 危险命令安全检查

`get` 内置安全检查，会在执行前拒绝包含已知破坏性操作的命令。此检查独立于 `command-pattern` 配置运行。

被拦截的命令包括：`rm`、`rmdir`、`del`、`rd`、`erase`、`mv`、`move`、`cp`、`copy`、`mkdir`、`md`、`touch`、`chmod`、`chown`、`chgrp`、`mkfs`、`dd`、`format`、`fdisk`、`kill`、`killall`、`pkill`、`shutdown`、`reboot`、`halt`、`poweroff`、`passwd`、`useradd`、`userdel`、`usermod`、`groupadd`、`groupdel`、`Set-Content`、`New-Item`、`Remove-Item`、`Move-Item`、`Rename-Item`、`Clear-Content`、`Add-Content` 等。

设置自定义 `command-pattern` 时，`get` 会检查该模式是否覆盖了常见危险命令，若未覆盖则显示警告。

## 缓存管理

`get` 将每次查询的最终输出缓存，键值为查询文本和执行上下文（工作目录、Shell、模型、instance 模式、系统提示词、命令模式）的哈希。当在相同上下文中运行相同查询时，缓存结果将立即返回。

存储新缓存条目前，`get` 会发送一个轻量级 LLM 请求，判断结果是稳定的（可缓存）还是易变的（不可缓存）。易变的结果（如当前时间、CPU 使用率、运行中的进程）即使启用了缓存也不会被缓存。

### 查看缓存状态

```bash
get cache
```

显示缓存是否启用、已缓存条目数、配置的限制以及缓存文件位置。

### 清除所有缓存

```bash
get cache --clean
```

### 移除指定查询的缓存

```bash
get cache --unset "系统版本"
```

移除所有查询文本匹配给定字符串的缓存条目（不区分大小写）。

### 禁用缓存

```bash
get set cache false
```

禁用后不执行任何缓存查找或写入。磁盘上的现有缓存条目在明确清除前会保留。

### 调整缓存参数

```bash
get set cache-expiry 7
get set cache-max-entries 500
get set cache-expiry false        # 条目永不过期
get set cache-max-entries false   # 不限制条目数
```

## 日志管理

`get` 会将每次查询执行（查询文本、生成的命令、退出码和输出预览）记录到本地文件。当条目数超过 `log-max-entries` 限制时（除非设为 `false` 禁用），最旧的条目会被自动移除。

### 查看日志状态

```bash
get log
```

显示日志是否启用、配置的最大条目数、条目数量、文件位置和文件大小。

### 清除日志

```bash
get log --clean
```

### 调整日志参数

```bash
get set log-max-entries 500
get set log-max-entries false  # 不限制日志条目数
```

### 禁用日志

```bash
get set log false
```

## `config` 命令参考

```bash
get config                  # 显示所有当前配置
get config --reset          # 重置所有配置为默认值
get config --<选项名>       # 显示单个选项的当前值
```

`--<选项名>` 接受上方 `set` 表格中的所有选项名称。示例：

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

注意：`get config --key` 显示密钥状态（已设置/未设置），值会被遮蔽。禁用的整数选项显示 `false`。

## 其他命令参考

```bash
get get                  # 显示 get 的基本信息
get get --intro          # 显示 get 的简介
get get --version        # 显示版本（等同于 get version）
get get --license        # 显示许可证标识
get get --github         # 显示 GitHub 链接
get version              # 显示版本
get isok                 # 验证当前配置是否可用（检查 key、url、model 并发送探测请求）
get help                 # 显示使用帮助
get log                  # 显示日志状态
get log --clean          # 清除所有日志条目
get cache                # 显示缓存状态
get cache --clean        # 清除所有缓存条目
get cache --unset "查询"  # 移除匹配查询的缓存条目
```

## 文件存储位置

配置和数据文件的存储位置如下：

| 文件 | Linux 路径 | Windows 路径 |
|---|---|---|
| 配置文件 | `~/.config/get/config.json` | `%APPDATA%/get/config.json` |
| API 密钥 | `~/.config/get/key`（权限 0600） | `%APPDATA%/get/key`（DPAPI 加密） |
| 执行日志 | `~/.config/get/get.log` | `%APPDATA%/get/get.log` |
| 响应缓存 | `~/.config/get/cache.json` | `%APPDATA%/get/cache.json` |
| 内置工具 | `<可执行文件>/bin/` 或 `<可执行文件>/src/bin/` | 同左 |

## 退出码

| 退出码 | 含义 |
|---|---|
| `0` | 成功完成 |
| `1` | 配置错误、LLM 通信失败、安全检查拒绝或一般错误 |
| `130` | 被 Ctrl+C（SIGINT）中断 |
| *N* | 当生成的命令以非零码退出时，该退出码会被传递为 `get` 的退出码 |
