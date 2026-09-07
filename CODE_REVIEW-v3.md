# get v3 代码审查与修复记录

审查日期：2026-09-07。后续 v3.1.0 的原生验证与发布进展见 [发布验证记录](https://github.com/Water-Run/get/blob/v3.1.0/VALIDATION-v3.1.0.md)。源码基线：`cde6846`，版本 `3.0.1`。本文记录本轮工作区改动及重新执行的验证，不替代历史发布报告，也不表示这些改动已经发布。

**结论：原版本存在可以复现的只读策略绕过和执行流程问题，不能直接判定为 OK。本轮已修复下列问题，并验证 Linux 上的 Bash、当前配置的 fish 和 DeepSeek 日常查询。** 保留强制语义检查、执行预算及可用的原生文件写入限制；没有用关闭安全策略的方式解决可用性问题。

审查覆盖整个程序的调用链及构建入口。动态验证以本机 Linux 为准，Windows/macOS 的本轮结果为 Nim 静态检查。

| 范围 | 核对内容与本轮处理 |
|---|---|
| `get.nim`、`config.nim`、`utils.nim` | 参数解析、配置迁移与覆盖、就绪检查、密钥与配置持久化；接入 Markdown，修复审核批准与 `isok` 判断 |
| `harness_types/protocol/runtime/executor.nim` | 原生/文本协议、动作识别、审核改写、观察身份、错误恢复、工具禁用、预算与并发；修复代码块误执行及命令身份不匹配 |
| `command_policy.nim` | Shell 词法、引号、展开、重定向、通配符、工具参数与子命令；补充多条绕过路径和允许/拒绝配对样例 |
| `exec.nim` | Shell 启动参数、PATH/环境净化、stdin、输出捕获、超时、进程树、原生沙箱；修复 EOF 等待与后代进程终止 |
| `llm.nim`、`tls_context.nim` | 请求/响应、连接复用、重试、代理、重定向与响应上限、证书/主机名校验；运行对应单元及本地服务端集成测试 |
| `cache.nim`、`logger.nim` | 缓存身份、命令重新校验、并发写入与损坏恢复、日志条目保留；保存 Markdown 来源类型，修复多行日志切分 |
| `style.nim`、新增 `markdown_render.nim` | 终端/管道区分、颜色、模型与命令输出边界、缓存显示、终端控制序列；新增内置 Markdown 渲染 |
| `sysinfo.nim`、`prompt.nim`、`harness_prompt.nim` | 环境收集、提示体积、平台命令指引、无工具意图、复核提示；保留原有提示长度约束 |
| Python 入口、测试、工作流、Windows 运行库脚本、文档 | 安装配置选项、测试二进制选择、依赖版本、CI 校验与产物管理；更新文档及忽略规则，检查 Python、包元数据和 man 页面 |

本轮确认并修复的问题按影响排列如下。安全复现采用旧策略判定和隔离临时目录中的原生命令；标记文件仅用于证明行为，原生沙箱的阻断能力另行验证。

**P1 · 引号转义与参数终止符造成策略和 Shell 理解不一致。**

旧解析器在处理双引号内的反斜杠前就判断引号闭合，`echo "\""; touch marker #"` 被判断为安全；Bash 实际在临时目录创建了标记文件。fish 单引号转义也有同类边界。另有 `rg -e -- *`：这里的 `--` 是 `-e` 的参数，不能作为“后续通配符不会注入选项”的依据。

修复位于 [command_policy.nim](src/command_policy.nim) 的词法解析及选项终止符判断：先按 Shell 规则处理转义，再判断引号；根据前置选项确定 `--` 的真实作用。未指定 Shell 时拒绝有歧义的引号转义。保留正常转义文本、带限定路径的通配符和真正的 `--` 用法。[配对测试](tests/test_command_policy.nim) 覆盖 Bash/sh/zsh/fish。

**P1 · 表面查询命令仍可执行辅助程序或额外动作。**

| 路径 | 复现或审查依据 | 修复 |
|---|---|---|
| `git blame file.txt` | 临时仓库的 `.gitattributes` clean filter 实际执行并创建标记；仅关闭 textconv 不足以防止工作树过滤器 | 要求 `git blame --no-textconv REV -- FILE`，拒绝 `--contents`/`--reverse`，并检查 REV 不是前一选项的参数 |
| `rpm -qE '宏表达式'` | 旧策略允许；隔离测试中的 RPM Lua 宏实际创建标记 | 拒绝短选项组合中的 `E`/`D` 以及宏定义、加载、spec 文件等可执行入口 |
| `tmux list-sessions ';' run-shell ...` | 在单独创建并清理的 tmux 服务上，查询后续命令实际创建标记 | 拒绝独立/尾部分号及换行，保留格式字符串中间的普通分号 |
| `nft list ruleset ';' add ...` | nft 内部语法可在单次 Shell 调用里附加动作；本轮只测策略拒绝，未修改主机防火墙 | 拒绝内部分隔符、块与加载入口，限定全局查询参数 |
| `ip l s lo down`、`ip a a ...` | 原有完整单词匹配遗漏子命令缩写；本轮未修改主机网络 | 按对象/动作白名单判定，保留 `ip a`、`ip -br addr`、`ip route get ...` |
| `yq -s ...`、`lsof -D...`、`git --help status` | 分别涉及拆分文件输出、设备缓存写入、帮助查看器启动 | 拒绝相应入口，保留普通读取与简单版本/帮助查询 |

对应实现及回归均位于 [命令策略](src/command_policy.nim)、[策略测试](tests/test_command_policy.nim)、[CLI 对抗样例](tests/mock_openai_provider.py)。本轮也校对并排除了两个初始疑点：当前 Git 的 `branch -l` 是列表操作；带 `--show-origin` 的所测配置写入形式被 Git 拒绝。它们没有被计入已证实漏洞。

参数语义同时对照了 [RPM 官方通用选项文档](https://rpm.org/docs/6.0.x/man/rpm-common.8)中的宏定义/预定义/求值入口，以及 [tmux 官方手册](https://man.openbsd.org/tmux.1#PARSING_SYNTAX)对独立、尾部和普通分号的区分，避免将安全格式字符串一并禁用。Git 文件名查询路径可查阅 [git-diff-files 官方文档](https://git-scm.com/docs/git-diff-files)。

**P1 · 超时可能留下忽略 TERM 的后代进程。**

旧实现发送 TERM 后，只有主进程仍在运行才继续向进程组发送 KILL；主进程先退出时，后代可能存活。[exec.nim](src/exec.nim) 现在在回收主进程前对进程组完成终止。新增测试让后代忽略 TERM，并检查超时后延迟标记文件不会出现。

**P2 · 空设备名称不能跨系统或大小写混用。**

POSIX 的 `/dev/NULL` 不能被当作 `/dev/null`。PowerShell 在 POSIX 上的 `nul` 也会成为普通文件。策略现在使用精确 POSIX 路径，并按宿主平台区分 PowerShell 的 `nul`；`$null` 和 Windows cmd 的原生 NUL 语义保留。

**P2 · 双重审核改写后，执行成功仍被观察身份检查判为错误。**

审核后的安全命令与模型原提案不同，旧运行时要求二者字符串完全相等。现在 [ToolObservation](src/harness_types.nim) 分别记录 `proposedCommand` 和实际 `command`；运行时核对提案身份，日志、反馈和缓存使用实际执行内容。审核没有返回明确命令批准时会拒绝执行。[CLI 回归](tests/test_cli_v3.py) 覆盖安全改写、实际命令缓存重放、危险改写及不明确审核。

**P2 · 普通 Markdown 代码块误入旧工具协议。**

真实 DeepSeek 在原版本上回答“**不调用工具，用 Markdown 给出标题、列表和 printf 示例代码块**”时，CLI 退出 1，提示 `tool calls are disabled for this request`。问题是普通回答里的代码块被旧协议识别成了命令。

[协议解析](src/harness_protocol.nim) 与 [运行时](src/harness_runtime.nim) 现在在 `auto/native` 中保留普通代码示例；只有显式 `legacy` 模式接受裸代码块命令。有效的显式类型化动作及旧动作标记仍进入工具检查，无工具请求仍禁止它们。JSON 数据、JSON Schema、数组和 Python 字典代码示例均有回归。原真实请求修复后退出 0，无工具执行。

**P2 · stdin 与 stdout EOF 处理影响正常读命令和超时语义。**

执行 API 没有交互输入，却保留 stdin 写端，导致 `cat` 等读取器等待。另一路在 stdout 提前关闭后改用独立的退出等待时间，可能早于配置期限停止进程。现在及时关闭 stdin，让读取器看到 EOF；stdout EOF 后继续等待进程并执行同一个总期限。测试覆盖立即 EOF、关闭输出后仍存活、超时及输出上限。

**P2 · 密钥/配置直接覆盖及日志多行切分。**

密钥旧实现先写入再调整权限，配置直接截断原文件。[writePrivateFile](src/utils.nim) 改为同目录独占创建私有临时文件，写完后替换目标；POSIX 在写入前确保 `0600`。测试验证目标符号链接不被跟随、原目标保持完整、配置往返和临时文件清理。该实现提供原子替换，没有宣称断电后的 fsync 持久性。

旧日志以空行分段，在保留最近 N 条时会拆散多段输出。现在按时间戳查询头划分旧条目，新查询、命令和输出使用 JSON 字符串转义，保证多行值不会引入新条目头。[持久化回归](tests/test_persistence.nim) 覆盖新旧格式混合和保留条数。

**P2 · `get isok` 将 `not ok` 误认为成功。**

旧条件接受长度小于 10 且包含 `ok` 的任意文本。现在要求去除首尾空白、转为小写后恰好为 `ok`，与探测提示契约一致。本地服务端验证 `ok` 成功、`not ok` 失败；真实 DeepSeek 的 `isok` 也成功。状态输出位于 stderr，真实测试脚本据此判定。

**P2 · 本地旧二进制混用容易产生错误测试结论。**

开始审查时，仓库 `./get`、`.ci/get-linux-x64` 和 PATH 安装副本版本不同。本轮使用已校验下载摘要的 Nim 2.2.10，所有 CLI 验证显式选择本轮构建。工作树 `./get` 最终更新为本轮通过测试的产物，旧文件备份保留在忽略目录。开发文档给出 `GET_V3_BINARY` 和 PATH 的明确选取方式；`.ci/`、本地测试可执行文件和 macOS 构建产物已加入忽略规则。

Markdown 功能的最终约定如下：

```bash
./get set markdown true        # 默认开启；省略值恢复默认
./get set markdown false
./get config --markdown
./get "汇总项目结构" --markdown
./get "汇总项目结构" --no-markdown
```

配置文件字段为 `markdown`，兼容没有该字段的旧配置。内置渲染器处理常见标题、强调、列表、引用、围栏代码块、链接和管道表格，包含中文列宽计算。它是轻量终端渲染器，复杂嵌套语法、完整 CommonMark 和语法高亮不属于本轮实现。

仅交互终端中的模型回答进入渲染；管道、文件重定向、`TERM=dumb` 和命令原始输出保留原文。`vivid=false` / `NO_COLOR` 保留排版并关闭渲染颜色。渲染器去除模型传入的终端控制序列，不执行代码、不打开链接。缓存保存源文本和来源类型，显示时应用当前配置；缓存行为身份也已更新，旧语义缓存不会命中新身份。配置、CLI 帮助、安装器高级设置、中英文 README 和 man 页面已同步。

本轮重新运行的验证记录保存在 [`.ci/review-20260907/`](.ci/review-20260907/)，该目录不纳入 Git；[构建与验证摘要](.ci/review-20260907/validation-summary.json)记录最终二进制的 SHA-256。工作树 `./get` 与该构建逐字节一致。

| 验证 | 结果及证据 |
|---|---|
| 修复前单元基线 | 12 个 Nim 文件，122 项测试通过；说明原测试没有覆盖本次发现的边界 |
| 修复前 CLI 基线 | 32/32；另行执行真实 DeepSeek 3 个场景，其中 Markdown 无工具场景失败 |
| 修复后 Nim | 14 个文件，137 项测试通过；[汇总](.ci/review-20260907/unit-results.json)；策略基础语料为 535 条允许、713 条拒绝，另有变体与配对检查 |
| 修复后 Bash CLI | 37/37，包括原生/回退协议、安全门、预算、缓存并发与恢复、Markdown PTY 显示；[日志](.ci/review-20260907/final-cli.log) |
| 修复后 fish CLI | 37/37，使用本机已配置 Shell 对应的 fish；[日志](.ci/review-20260907/final-cli-fish.log) |
| 离线综合矩阵 | 172 通过，0 失败，126 跳过，共列出 298 项；[日志](.ci/review-20260907/final-offline.log)；跳过项没有算作通过 |
| 真实 DeepSeek | 当前 `deepseek-v4-flash` 配置，8/8 场景成功：cwd、结构、两种无工具代码示例、Git 状态计数、性能快照、双重审核、isok；[原始记录](.ci/review-20260907/final-ds.json) |
| 最终构建关键场景复测 | cwd 和无工具 Markdown 示例 2/2；[记录](.ci/review-20260907/final-ds-smoke.json)同时绑定最终二进制摘要 |
| 本机原生文件写入限制 | 程序探测确认 bubblewrap 可用；读取成功、文件写入被拒绝及超时检查通过；[能力探测](.ci/review-20260907/sandbox-status.log)、[执行器日志](.ci/review-20260907/final-test_exec_bounded.log) |
| 平台与构建检查 | Nim 2.2.10 release 构建、`nimble check`、Windows/macOS 目标 `nim check`、Python 语法、groff man 渲染、`git diff --check` 通过 |

真实模型请求使用临时配置目录，复制当前服务参数与密钥进行测试；临时密钥从创建时即为 `0600`，结束后清理，并校验原配置和密钥摘要未变。8 个场景不等于 8 次 HTTP 调用，继续推理和双重审核会追加模型调用。真实结果中目录值按本地事实校验；汇总类场景核对了执行成功、所用命令及观察结果，不将模型对负载的全部解释当作确定性断言。

审查后仍需明确以下边界和后续事项：

- **中优先级：多进程日志与配置修改没有跨进程事务。** 缓存已有写锁并通过并发测试；配置原子替换防止半文件，但同时执行两个 `get set` 仍可能后写覆盖前写。日志 append/trim 也可能在并发进程间竞争。这是现有持久化边界，本轮没有将其改造成事务存储。
- **中优先级：`NO_PROXY` 的端口限定未完整实现。** 当前解析会移除条目中的单个端口，按主机/域名匹配，`host:port` 因而可能扩大为整台主机绕过代理。普通主机/域名场景有集成测试；端口限定需要后续接口和配对测试补齐。
- **平台验证：本轮没有原生 Windows/macOS 运行环境。** 静态目标检查不能替代原生进程树、控制台渲染、Windows DPAPI、文件替换和 macOS Seatbelt 回归。历史版本报告的原生通过结果不作为本轮新改动的证明。
- **只读控制有信任前提。** 语义策略依赖可信工具及其参数语义；Linux 沙箱不可用时会回到强制语义门，macOS 有已文档化的原生读取器兼容路径，Windows 没有等价文件系统沙箱。读取不构成数据保密边界，也不能约束远端服务对 GET/HEAD 的实际副作用。完整边界见 [README](README-zh.md#安全模型)。
- **发布仍需独立完成。** 版本号和发布流水线中的提供商验证摘要属于已发布 3.0.1。下一次发布应在新的原生构建及提供商验证后更新版本、摘要和发布文档；本轮不修改历史验证结论。
