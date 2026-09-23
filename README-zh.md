# `get` — get anything from your computer

[English](README.md)

用自然语言向这台电脑提问，`get` 查看本机后根据看到的内容作答。它是一个查询工具：设计上只做读取，不改动你的系统。

```bash
get "这台设备的 IP 地址"
get "当前目录的代码结构"
get "当前 Git 分支和未提交文件"
```

## 安装

从 [GitHub Releases](https://github.com/Water-Run/get/releases) 下载安装包，保持包内文件在同一目录，然后运行：

```bash
python get_ready.py
get version
```

替换程序时会保留你已有的配置。

> **Windows：** `get-windows-x64.exe` 必须与 `libcrypto-3.dll`、`libssl-3.dll`、`zlib1.dll` 放在一起，安装时会整套复制。许可与来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 连接模型

`get` 兼容任何 OpenAI 风格的 Chat Completions 接口。

```bash
get set model 你的模型名称
get set url https://你的服务地址/v1
get set key 你的API密钥
get isok        # 检查连接
```

密钥设计上不会打印或写入日志：Linux 上密钥文件权限为 `0600`，Windows 上使用 DPAPI 保护。

## 查询如何工作

模型会拿到你的问题和一组类型化读取器——环境、文件、搜索、进程、Git status/diff——并根据返回的内容作答。取证方式由 *harness* 控制：

| Harness | 行为 |
|---|---|
| `auto`（默认） | 先查看，再回答 |
| `direct` | 固定一次模型调用，最多一个工具调用 |
| `loop` | 对有依赖关系的步骤串行观察、逐步推进 |
| `parallel` | 互不依赖的只读调用并发执行 |

```bash
get "同时比较磁盘和内存使用" --harness parallel
get "显示当前目录"          --harness direct
```

工具默认以原生 function calling 发送，被拒时自动回退到 JSON；也可强制指定：`get set tool-protocol auto|native|json`。

查询中写明“不用工具”时，`get` 会切换到纯文本模式：不提供任何工具，也不会执行任何命令。

## 安全

- 每条命令在执行前都要通过强制安全策略——被拒绝的命令设计上不会执行。
- 想更谨慎？`get set manual-confirm true` 会在每条命令前询问，`get set double-check true` 会增加一次模型复核。两者默认关闭，也无法解锁对宿主的修改。
- Linux 上，自由脚本在隔离沙箱中运行（bubblewrap 命名空间、只读宿主挂载、seccomp、资源限制），设计上不能联网。沙箱建立不起来时，脚本就不会运行。

| 能力 | Linux | macOS | Windows |
|---|---|---|---|
| 类型化环境 / 文件 / 搜索读取、宿主查询 | ✓ | ✓ | ✓ |
| Git status & diff 快照 | ✓ | ✓ | ✓ |
| 自由脚本与 Shell 计算 | 沙箱内支持 | — | — |

> **隐私：** `get` 读取到的内容会发送给你配置的模型服务来生成回答——请把它视为与该服务商共享，而不是保密边界。环境变量中的凭据值会被脱敏。

## 配置

`get config` 查看全部配置；`get config --<选项>` 查看单项；`get config --reset` 恢复默认。设置时省略值即可恢复该项默认：

```bash
get set model minimax-m3
get set max-parallel 6
get set max-parallel      # 恢复默认
```

<details>
<summary><b>完整配置项</b></summary>

| 选项 | 默认值 | 说明 |
|---|---:|---|
| `url` | `https://api.minimaxi.com/v1` | API 基础 URL |
| `model` | `minimax-m3` | 模型标识 |
| `manual-confirm` | `false` | 逐条命令手动确认 |
| `double-check` | `false` | 增加一次模型安全复核 |
| `harness` | `auto` | `auto`、`direct`、`loop`、`parallel` |
| `tool-protocol` | `auto` | `auto`、`native`、`json` |
| `timeout` | `300` | API 超时（秒）；`false` 表示不限 |
| `max-token` | `20480` | 响应 token 上限；`false` 表示不传 |
| `max-rounds` | `6` | 取证轮次上限（收尾作答单独计） |
| `max-tool-calls` | `16` | 每次查询工具启动上限 |
| `max-parallel` | `4` | 最大并发工具数 |
| `query-timeout` | `120` | 整次查询期限（秒） |
| `diagnostics` | `false` | 向 stderr 输出结构化事件和计数 |
| `command-timeout` | `30` | 单条命令硬超时（秒） |
| `max-output-bytes` | `1048576` | 单条命令捕获字节上限 |
| `command-pattern` | 关闭 | 附加禁止命令正则，如 `get set command-pattern '\b(ssh|curl)\b'` |
| `system-prompt` | 空 | 附加模型指令 |
| `shell` | `bash` / `powershell` | 命令 Shell |
| `log` | `true` | 记录执行日志 |
| `hide-process` | `false` | 隐藏进度和中间观察 |
| `system-proxy` | `false` | 优先使用 Windows 系统代理而非终端变量 |
| `cache` | `true` | 确定性缓存 |
| `cache-expiry` | `30` | 缓存有效期（天）；`false` 表示不过期 |
| `cache-max-entries` | `1000` | 缓存条数上限；`false` 表示不限 |
| `log-max-entries` | `1000` | 日志条数上限；`false` 表示不限 |
| `vivid` | `true` | ANSI 色彩和进度动画 |
| `markdown` | `true` | 交互终端渲染 Markdown；管道保留原文 |
| `instance` | `false` | 别名：`true` 对应 `harness=direct` |

</details>

## 单次查询参数

```text
--harness <auto|direct|loop|parallel>   --protocol <auto|native|json>
--model <名称>                          --timeout <秒>
--instance / --no-instance              分别对应 direct / loop
--cache / --no-cache                    --markdown / --no-markdown
--manual-confirm / --no-manual-confirm  --vivid / --no-vivid
--double-check / --no-double-check      --hide-process / --no-hide-process
                                        --system-proxy / --no-system-proxy
```

**代理：** 默认读取 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`。Windows 上 `system-proxy=true` 时优先使用系统代理设置。`NO_PROXY` 支持逗号分隔的域名、子域名、IP 地址和 `*`，也可带端口（如 `example.com:443`）。

## Markdown 输出

在交互终端中，`get` 会用内置渲染器显示模型回答的 Markdown——标题、列表、表格、代码——无需外部程序。管道和重定向保留原始文本，`NO_COLOR` 关闭颜色。可用 `get set markdown false` 或 `--no-markdown` 关闭。

## 缓存

可复现的查询会被缓存，且不额外消耗模型调用。缓存命中时会重新校验并执行保存的命令，因此“当前内存使用量”这类动态答案仍然新鲜。多步骤结果不会被缓存。

```bash
get cache
get cache --clean
get cache --unset "系统版本"
```

`get set cache false` 关闭缓存；`cache-expiry` 设置有效期（天）。

## 文件与退出码

配置、密钥、日志和缓存在 Linux 上位于 `~/.config/get/`，Windows 上位于 `%APPDATA%\get\`，文件名分别为 `config.json`、`key`、`get.log`、`cache.json`。

| 退出码 | 含义 |
|---:|---|
| 0 | 成功 |
| 1 | 配置、服务、策略或一般错误 |
| 124 | 命令超时 |
| 126 | 工具提案被拒绝，且没有安全的替代方案 |
| 130 | Ctrl+C 中断 |
| 其他 | 终止命令的退出码 |

## 开发

需要 Nim ≥ 2.2.8。构建开发版二进制：

```bash
nim c -d:release -o:.ci/get src/get.nim
```

构建与测试约定（包括 CI 矩阵）见 [AGENTS.md](AGENTS.md)，测试套件在 `tests/` 下。欢迎提交 issue 和 PR。

## 许可

[AGPL-3.0-or-later](LICENSE)。内置的 OpenSSL 和 zlib 保留各自许可，见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
