# `get` — get anything from your computer

[English](README.md)

用自然语言问这台计算机。`get` 去查看本机，再根据看到的内容回答。它只做查询：读取宿主，不修改宿主。模型名称只是服务标识。

```bash
get "这台设备的 IP 地址"
get "当前目录的代码结构"
get "当前 Git 分支和未提交文件"
```

## 安装

从 [GitHub Releases](https://github.com/Water-Run/get/releases) 下载，保持包内文件位于同一目录后运行：

```bash
python get_ready.py
get version
```

安装器可以保留现有配置，只替换程序。

Windows 下需让 `get-windows-x64.exe`、`libcrypto-3.dll`、`libssl-3.dll` 和
`zlib1.dll` 与安装器保持在一起；安装时会一并复制。DLL 提供 OpenSSL
3.5.7 LTS 与 zlib 1.3.2；来源与许可见包内 `THIRD_PARTY_NOTICES.md`、
`OPENSSL-LICENSE.txt` 和 `ZLIB-LICENSE.txt`。

## 配置连接

`get` 使用 OpenAI 兼容的 Chat Completions 接口。

```bash
get set model 你的模型名称
get set url https://你的服务地址/v1
get set key 你的API密钥
get isok
```

API 密钥不会被打印或写入日志。Linux 密钥文件权限为 `0600`；Windows 使用 DPAPI 保护。

## 查询如何进行

模型收到问题和一组类型化读取器，先收集证据，再作答。

普通读取走 `read_environment`、`read_file`、`search_files`。`run_process` 接收字面 argv；`run_shell` 使用已配置的 Shell。普通 Git status/diff 通过私有元数据快照查询。

文件搜索支持路径 glob、字面内容匹配、分页和常用 `.gitignore` / `.ignore` / `.rgignore` 规则。这是有界查询器，不是完整的 Git 或 ripgrep 替代品。达到扫描上限会明确返回不完整状态。

四种 Harness 策略决定如何取证：

| 策略 | 行为 | 常见模型调用数 |
|---|---|---:|
| `auto` | 读取本地证据，再回答原问题 | 1–4 |
| `direct` | 固定一次模型调用，最多一个终止工具调用 | 1 |
| `loop` | 对有依赖关系的工作串行反馈观察 | 1–4 |
| `parallel` | 允许互不依赖的只读调用并发执行 | 1–4 |

默认是 `auto`。`max-rounds` 限制取证轮次；另有一次无工具的收尾作答。如果服务无法完成，get 会给出已有证据的有界说明，并以非零状态退出。

在 `auto`、`loop`、`parallel` 中，被强制策略拒绝的命令绝不会执行；拒绝会作为类型化观察返回，模型只能在原有轮次和工具预算内改用更简单的安全命令，每个替代命令都从头校验。`direct` 对拒绝不重试。

```bash
get set harness auto
get "同时比较磁盘和内存使用" --harness parallel
get "显示当前目录" --harness direct
```

工具协议与 Harness 相互独立：

```bash
get set tool-protocol auto     # 原生工具；被拒绝时回退到 JSON
get set tool-protocol native   # 必须使用原生 function tools
get set tool-protocol json     # 显式结构化 JSON 动作
```

查询明确写出“不调用工具”“不用工具”或英文 `without tools` 时，get 会启用强制纯文本路由：请求不携带工具定义，文本形式的工具动作会被拒绝，缓存中的命令也不会执行。Markdown 代码示例始终按回答文本显示。只有显式 JSON 或原生工具调用进入执行边界。

## 查询边界

已知宿主读取器仍使用参数语义校验，读取真实进程、设备、网络和服务状态。Linux 上，完整能力探测成功后，其他计算进入 bubblewrap 命名空间、只读宿主挂载、seccomp 与资源限制：不能连接网络或 Unix 控制套接字、操作宿主进程或设备。只允许写入本次查询的私有临时区，退出后由父进程清理。没有这套能力时，不会启动无约束脚本。

| 能力 | Linux | macOS | Windows |
|---|---|---|---|
| 类型化环境/文件/搜索、已知宿主查询 | 支持 | 支持 | 支持 |
| 普通 Git status/diff 快照 | 支持 | 支持 | 支持 |
| 任意短脚本、复杂 Shell 计算 | 完整隔离探测通过时支持 | 暂不支持 | 暂不支持 |

Git 快照保留工作树、索引及基本换行/文件模式语义，不写真实索引。禁用仓库可执行 filter、textconv、fsmonitor 和子模块检查；全局忽略规则、上游分支配置及自定义过滤结果不保证与交互式 Git 一致，观察会注明快照来源。只含一条字面 Git status/diff 的 Shell 调用或直接 argv 可使用该适配器。

每个提案先校验工具参数并选择允许的后端，再应用用户显式配置的 `command-pattern`、可选 `double-check` 和 `manual-confirm`。复核改写与缓存重放重新授权。没有允许宿主修改的确认通道。`double-check` 与 `manual-confirm` 默认关闭。

普通查询失败只影响相关步骤。无匹配、缺失环境值和 diff 发现差异都有独立语义；同一查询可复用已有观察，显式 `fresh` 可重新采样。必要证据全部失败时返回非零状态；模型有文字回答不自动代表任务成功。每次查询至多进行两次失败修复。

这个边界防止查询修改宿主状态，不是数据保密隔离。查询结果可能送入所配置的模型；环境凭据值会脱敏，但文件内容不是通用秘密检测器。已知宿主读取器依赖可信程序与工具配置，读取可能产生访问时间等附带变化。HTTP 读取只允许受校验的 GET/HEAD 形式；查询语义仍依赖远端实现。

## 配置

使用 `get config` 查看全部配置，`get config --<选项>` 查看单项，`get config --reset` 恢复默认值。

| 选项 | 默认值 | 说明 |
|---|---:|---|
| `url` | `https://api.minimaxi.com/v1` | API 基础 URL |
| `model` | `minimax-m3` | 模型标识 |
| `manual-confirm` | `false` | 逐条命令手动确认 |
| `double-check` | `false` | 增加第二模型安全复核 |
| `harness` | `auto` | `auto`、`direct`、`loop`、`parallel` |
| `tool-protocol` | `auto` | `auto`、`native`、`json` |
| `timeout` | `300` | API 超时秒数；`false` 表示不限 |
| `max-token` | `20480` | 响应 token 上限；`false` 表示不传 |
| `max-rounds` | `6` | 取证轮次上限，另保留一次收尾作答 |
| `max-tool-calls` | `16` | 每次查询实际启动次数上限 |
| `max-parallel` | `4` | 最大并发工具数 |
| `query-timeout` | `120` | 整次自动查询期限（秒），包括模型和工具 |
| `diagnostics` | `false` | 向 stderr 输出结构化事件和计数 |
| `command-timeout` | `30` | 单条命令硬超时（秒） |
| `max-output-bytes` | `1048576` | 单条命令捕获字节上限 |
| `command-pattern` | 仅语义策略 | 可选的附加禁止命令正则 |
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
| `markdown` | `true` | 在交互终端渲染模型回答的 Markdown；管道保留原文 |
| `instance` | `false` | 别名：`true` 对应 `harness=direct` |

Harness 与命令安全上限必须是正整数，不能关闭。省略值可恢复默认：

```bash
get set max-parallel 6
get set command-timeout 20
get set max-output-bytes 2097152
get set max-parallel            # 恢复为 4
```

`command-pattern` 默认不启用，有三种方式：

```bash
get set command-pattern '\b(ssh|curl)\b'  # 自定义附加策略
get set command-pattern                    # 恢复仅语义策略的默认值
get set command-pattern ""                 # 清除已有附加正则
```

## 单次查询覆盖参数

```text
--no-cache / --cache
--manual-confirm / --no-manual-confirm
--double-check / --no-double-check
--harness <auto|direct|loop|parallel>
--protocol <auto|native|json>
--instance / --no-instance          分别对应 direct / loop
--hide-process / --no-hide-process
--system-proxy / --no-system-proxy
--vivid / --no-vivid
--markdown / --no-markdown
--model <名称>
--timeout <秒>
```

默认读取终端中的 `HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY`。Windows 上启用 `system-proxy=true` 后，已开启的 Internet Settings 优先；`NO_PROXY` 会绕过两类代理来源。

`NO_PROXY` / `no_proxy` 使用逗号分隔条目：域名匹配本身及其子域名，IP 地址按地址精确匹配，`*` 绕过所有代理。未指定端口的条目适用于所有端口；`example.com:443` 仅匹配目标端口 443，URL 省略端口时按 HTTP 80、HTTPS 443 判断。IPv6 可写为 `::1` 或 `[::1]`，限定端口时使用 `[::1]:8080`。端口为空、非数字或不在 1–65535 范围内的条目会被忽略，不会扩大为整台主机绕过代理。

## Markdown 输出

```bash
get set markdown true         # 开启（默认）；省略值也恢复默认
get set markdown false        # 显示 Markdown 源文本
get config --markdown
get "汇总项目结构" --markdown
get "汇总项目结构" --no-markdown
```

内置渲染器支持标题、强调、列表、引用、代码块、链接和表格（含中文列宽），无需外部渲染程序。`vivid=false` 或 `NO_COLOR` 关闭渲染颜色，但保留排版。输出重定向、管道和 `TERM=dumb` 保留源文本。命令原始输出始终按原文显示；缓存保存未渲染文本，切换配置后不必重新请求模型。

## 缓存

缓存不会额外调用模型来决定缓存策略。成功的单步骤查询会保存当前上下文中的类型化计划。

- 缓存命中为零模型调用；命令重新通过安全门并再次执行，动态信息仍保持最新。
- 明确禁用工具的请求绝不执行缓存命令；缓存的最终文本仍可在零模型、零工具调用下返回。
- 没有可复用计划时，显式 `--cache` 可以缓存最终文本，命中时显示原采样时间。
- 多步骤结果不会被猜测性缓存。
- SHA-256 缓存键包含工具和后端能力、执行限制、工作目录、服务 URL、模型、Harness、协议、Shell、自定义提示、安全配置、系统和架构。
- 写入在短期跨进程锁内完成读—改—写，多个 `get` 进程同时结束时不会互相覆盖。
- 快照刷新后原子替换；POSIX 权限为 `0600`。主文件损坏时自动读取最近良好的 `.bak` 快照。
- 文件与字段均有 Schema 校验和尺寸硬上限；过期清理、重复替换与最旧条目淘汰均为确定性行为。

配置、密钥、日志和缓存的写入会跨进程串行。

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
# 编译前确认 MemAvailable >= 6 GiB、memory full avg10 < 2。
nice -n 10 nim c --parallelBuild:1 -d:release -o:.ci/get src/get.nim
GET_V3_BINARY="$PWD/.ci/get" python tests/test_cli_v3.py -v
python get_test.py --binary .ci/get --provider-config ~/.config/get \
  --shell fish --report .ci/provider-replay.json
```

开发测试应先构建并显式选择二进制。开发二进制统一放在 `.ci/`。不会修改现用配置、密钥或已安装程序。

本地持久化测试最多四个小进程，完整原生平台测试在 CI 执行。真实模型回放使用临时配置与带嵌套产物的多语言夹具，也支持 `--real-project`。

`tests/` 中的测试覆盖协议解析、原生工具载荷、状态迁移、配置迁移、强制安全策略、受限执行和真实并行执行。

`get` 使用 AGPL-3.0-or-later 许可证。源码：[github.com/Water-Run/get](https://github.com/Water-Run/get)。
