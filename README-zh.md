# `get` — get anything from your computer

[English](README.md)

`get` 把自然语言问题转换为安全、只读的本地检查。3.0 将旧版 instance/agent 两条执行链统一为一个类型化 Harness：它可以直接回答、执行一条命令、根据观察继续推理，也可以并行执行互不依赖的检查。

```bash
get "这台设备的 IP 地址"
get "当前目录的代码结构"
get "当前 Git 分支和未提交文件"
```

## v3 的主要变化

- 统一的 `Model → Action → Policy → Tool → Observation` 状态机。
- 默认使用原生 function tools，并提供结构化 JSON 与 v2 Markdown 兼容层。
- `auto`、`direct`、`loop`、`parallel` 四种策略共用同一个运行时。
- 常规命令只需一次模型调用；不再额外调用路由器或缓存分类模型。
- 复用 HTTP 连接，请求完成即唤醒；快速响应不再被固定轮询额外拖慢一秒。
- 收到 HTTP 响应前的瞬态传输故障会在原请求超时内最多重试三次；HTTP 与解析错误不会重试，响应体有 8 MiB 硬上限，携带 Bearer 凭据的请求不会跟随重定向。
- HTTPS 同时校验证书链与 DNS/IP 主机名。Windows 版本会把系统 Windows ROOT 证书库导入 OpenSSL，正常 HTTPS 不依赖额外下载的 CA bundle。
- 本地上下文惰性采集，不再启动大量进程探测 shell 版本和 PATH 工具。
- 独立只读检查可真正并行执行。
- 每条命令都有超时和输出上限，并会跨平台终止对应的进程树。
- 不可关闭、基于白名单的强制只读策略，并禁用 Shell 启动钩子、净化子进程环境；正则、模型复核、手动确认是附加层。
- 生产级缓存：SHA-256 身份、跨进程写入、原子持久化、最近良好版本恢复和有界解析；缓存命令仍走完整安全门。

## 安装与配置

从 [GitHub Releases](https://github.com/Water-Run/get/releases) 下载，保持包内文件位于同一目录后运行：

```bash
python get_ready.py
get set model 你的模型名称
get set url https://你的服务地址/v1
get set key 你的API密钥
get isok
```

安装器可以保留旧配置。v2 配置会自动迁移：`instance=true` 转换为 `harness=direct`；其他情况使用新的默认值 `harness=auto`。

Windows 下需让 `get-windows-x64.exe`、`libcrypto-3.dll`、`libssl-3.dll` 和
`zlib1.dll` 与安装器保持在一起；安装时会一并复制。DLL 提供 OpenSSL
3.5.7 LTS 与 zlib 1.3.2；来源与许可见包内 `THIRD_PARTY_NOTICES.md`、
`OPENSSL-LICENSE.txt` 和 `ZLIB-LICENSE.txt`。

API 密钥不会被打印或写入日志。Linux 密钥文件权限为 `0600`；Windows 使用 DPAPI 保护。

## Harness 策略

| 策略 | 行为 | 常见模型调用数 |
|---|---|---:|
| `auto` | 直接优先，仅在确实需要时继续或批量执行 | 1 |
| `direct` | 固定一次模型调用，最多一个终止工具调用 | 1 |
| `loop` | 对有依赖关系的工作串行反馈观察 | 1–3 |
| `parallel` | 允许互不依赖的只读调用并发执行 | 1–3 |

在 `auto`、`loop`、`parallel` 中，被强制策略拒绝的命令绝不会执行；拒绝会作为类型化观察返回，模型只能在原有轮次/工具预算内改用更简单的安全命令，每个替代命令都从头校验。`direct` 对拒绝不重试。

```bash
get set harness auto
get "同时比较磁盘和内存使用" --harness parallel
get "显示当前目录" --harness direct
```

工具协议与 Harness 相互独立：

```bash
get set tool-protocol auto     # 原生工具被拒绝时兼容回退
get set tool-protocol native   # 必须使用原生 function tools
get set tool-protocol legacy   # 结构化 JSON，并接受 v2 Markdown
```

查询明确写出“不调用工具”“不用工具”或英文 `without tools` 时，get 会启用强制纯文本路由：请求不携带工具定义，文本形式的工具动作会被拒绝，旧缓存中的命令也不会执行。

## 安全模型

每条由模型生成、模型修改或缓存取出的命令，都经过同一个安全门：

1. 校验类型化工具名称和参数。
2. 执行不可关闭的强制只读策略。
3. 执行 `command-pattern` 附加黑名单。
4. 可选第二模型复核（`double-check`）。
5. 如果复核模型修改命令，再次执行两层确定性检查。
6. 可选手动确认。
7. 在超时和输出上限内执行。

强制策略只解析简单命令和只读管道，再逐一校验可执行文件及其可能修改状态的参数；未知语法和未知程序一律关闭失败。它会拦截命令替换、串联、普通文件输出重定向、脚本与包装器、内联解释器、PowerShell splatting/脚本转换、参数缩写与通配符参数注入、辅助程序/配置注入、修改型 Git/容器/集群/包管理操作、上传，以及危险短参数变体。仅有一组经过验证的纯数据读取器可以使用一次、目标为字面文件路径的 `<` 标准输入重定向；heredoc、here-string、进程替换、文件描述符复制、展开、多重重定向及会读写文件的 `<>` 仍一律拒绝。Shell 别名与空设备按平台判断，只允许配置受支持且位于可信路径的 Shell。子进程不加载 profile，并移除动态加载器、语言运行时、Git、分页器、跟踪和工具配置等注入变量；缓存命令和复核模型改写后的命令仍经过同一安全门。

HTTP 检查应使用 `curl -q ...`，首个 `-q` 用于阻止 `.curlrc` 改写操作；策略仅接受 GET/HEAD 和明确的只读协议。`wget` 仅接受同时带有 `--no-config --no-hsts -O-` 的形式。POSIX 下未引用的通配符应加 `./` 前缀，或先写 `--`。`$HOME`、`$USER`、`$LOGNAME`、`$PWD` 只允许用于纯终端输出。清空 `command-pattern` 只会关闭附加正则，不会关闭强制策略。

`git status` 与读取工作树内容的普通 `git diff` 会被有意拒绝：仓库自身的 clean/textconv/filter 配置可能让表面只读的 Git 命令执行辅助程序。请用 `git branch --show-current` 查看分支，用 `git diff-files --name-only --no-ext-diff --no-textconv` 查看已修改的跟踪文件名，用 `git ls-files --others --exclude-standard` 查看未跟踪文件，用 `git diff --cached --no-ext-diff --no-textconv` 查看暂存内容。`git show` 与输出补丁的 `git log` 同样必须带两个禁用参数。

`double-check` 在 v3 中默认是 `false`，因此日常请求只需一次模型调用。需要独立模型复核时可显式开启：

```bash
get "检查服务状态" --double-check
get set manual-confirm true
```

该策略是在可信读取程序的文档语义下关闭失败的“状态修改抵抗门”，不是数据保密边界，也不是操作系统沙箱。允许的读取命令仍可访问请求涉及的文件、进程/环境信息、URL；Harness 需要继续推理时，命令输出会发送给所配置的模型提供商。边界还包含最终解析到的程序、`PATH` 中保留的绝对目录、内核、管理员/操作者控制的工具配置，以及远端对 GET/HEAD 的实际语义；读取本身也可能更新文件访问时间或工具/系统缓存。已被攻陷的程序、可写的可信路径、恶意服务端或主机不在保证范围内。敏感环境中请检查命令，并启用手动确认或外部沙箱。

## 配置

使用 `get config` 查看全部配置，`get config --<选项>` 查看单项，`get config --reset` 恢复默认值。

| 选项 | 默认值 | 说明 |
|---|---:|---|
| `url` | `https://api.minimaxi.com/v1` | API 基础 URL |
| `model` | `minimax-m3` | 模型标识 |
| `manual-confirm` | `false` | 逐条命令手动确认 |
| `double-check` | `false` | 增加第二模型安全复核 |
| `harness` | `auto` | `auto`、`direct`、`loop`、`parallel` |
| `tool-protocol` | `auto` | `auto`、`native`、`legacy` |
| `timeout` | `300` | API 超时秒数；`false` 表示不限 |
| `max-token` | `20480` | 响应 token 上限；`false` 表示不传 |
| `max-rounds` | `3` | 模型轮次硬上限 |
| `max-tool-calls` | `8` | 每次运行工具调用硬上限 |
| `max-parallel` | `4` | 最大并发工具数 |
| `command-timeout` | `30` | 单条命令硬超时（秒） |
| `max-output-bytes` | `1048576` | 单条命令捕获字节上限 |
| `command-pattern` | 内置 | 附加禁止命令正则 |
| `system-prompt` | 空 | 附加模型指令 |
| `shell` | `bash` / `powershell` | 命令 Shell |
| `log` | `true` | 记录执行日志 |
| `hide-process` | `false` | 隐藏进度和中间观察 |
| `system-proxy` | `false` | 优先使用 Windows Internet Settings，而不是终端代理变量 |
| `cache` | `true` | 启用确定性缓存 |
| `cache-expiry` | `30` | 缓存天数；`false` 表示不过期 |
| `cache-max-entries` | `1000` | 缓存上限；`false` 表示不限 |
| `log-max-entries` | `1000` | 日志上限；`false` 表示不限 |
| `vivid` | `true` | ANSI 色彩和进度动画 |
| `instance` | `false` | v2 兼容别名，对应 `harness=direct` |

Harness 与命令安全上限必须是正整数，不能关闭。省略值可恢复默认：

```bash
get set max-parallel 6
get set command-timeout 20
get set max-output-bytes 2097152
get set max-parallel            # 恢复为 4
```

`command-pattern` 有三种方式：

```bash
get set command-pattern '\b(ssh|curl)\b'  # 自定义附加策略
get set command-pattern                    # 恢复内置正则
get set command-pattern ""                 # 强制策略仍然有效
```

## 单次查询覆盖参数

```text
--no-cache / --cache
--manual-confirm / --no-manual-confirm
--double-check / --no-double-check
--harness <auto|direct|loop|parallel>
--protocol <auto|native|legacy>
--instance / --no-instance          兼容别名
--hide-process / --no-hide-process
--system-proxy / --no-system-proxy
--vivid / --no-vivid
--model <名称>
--timeout <秒>
```

默认读取终端中的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`。Windows 上启用 `system-proxy=true` 后，已开启的 Internet Settings 优先；`NO_PROXY` 会绕过两类代理来源。

## 缓存

v3 不会再花费一次模型调用判断缓存策略。

- 成功的单命令终止运行会缓存当前上下文中的命令。
- 缓存命中为零模型调用；命令重新通过安全门并再次执行，动态信息仍保持最新。
- 明确禁用工具的请求绝不执行缓存命令；缓存的最终文本仍可在零模型、零工具调用下返回。
- 没有可复用命令时，显式 `--cache` 可以缓存最终文本。
- 多步骤结果不会被猜测性缓存。
- SHA-256 缓存键包含 v3、工作目录、服务 URL、模型、Harness、协议、Shell、自定义提示、安全配置、系统和架构；v2 条目不会碰撞。
- 写入在短期跨进程锁内完成读—改—写，多个 `get` 进程同时结束时不会互相覆盖。
- 快照刷新后原子替换；POSIX 权限为 `0600`。主文件损坏时自动读取最近良好的 `.bak` 快照。
- 文件与字段均有 Schema 校验和尺寸硬上限；过期清理、重复替换与最旧条目淘汰均为确定性行为。

```bash
get cache
get cache --clean
get cache --unset "系统版本"
```

## 文件与退出码

- 配置：Linux `~/.config/get/config.json`；Windows `%APPDATA%/get/config.json`
- 密钥：Linux `~/.config/get/key`；Windows `%APPDATA%/get/key`
- 日志与缓存：同目录下 `get.log`、`cache.json`

- `0`：成功
- `1`：配置、服务、协议、安全策略或一般错误
- `126`：工具提案在执行前被拒绝，且 Harness 预算内没有得到安全替代
- `124`：命令超时
- `130`：Ctrl+C 中断
- 其他非零值：终止命令的退出码

## 开发

需要 Nim 2.2.8 或更新版本；发布 CI 使用 Nim 2.2.10。

```bash
nim c -d:release -o:get src/get.nim
python get_test.py --key dummy --skip-llm
```

`tests/` 中的测试覆盖协议解析、原生工具载荷、状态迁移、配置迁移、强制安全策略、受限执行和真实并行执行。

`get` 使用 AGPL-3.0-or-later 许可证。源码：[github.com/Water-Run/get](https://github.com/Water-Run/get)。
