# get v3 开发情况

整理日期：2026-09-07（Asia/Shanghai）。依据当前源码、Git 历史、仓库内验证报告，以及当日读取的 GitHub Release、分支和 Actions 状态。

**v3 已完成核心开发并正式发布至 v3.0.1。** v3.0.0 建立统一 Harness 架构，v3.0.1 扩展日常只读检查的可用性并加强运行安全、模型兼容和持久化。从现有证据看，项目已进入发布后维护阶段；当前需要收尾的是发布文档回填、验证记录归档和本地构建环境整理。

版本进展如下，日期均为北京时间：

| 时间 | 里程碑 | 核验结果 |
|---|---|---|
| 2026-08-24 | v3 主体开发提交集中落地 | 统一 Harness、Windows 原生验证、受限执行、发布装配与产物溯源 |
| 2026-08-25 | v3.0.0 正式发布 | 标签指向 `f70c7fd`；三平台安装包、清单与校验文件已公开 |
| 2026-08-30 | v3.0.1 正式发布 | 核心改动为 `a349bd4`，发布元数据提交为 `cde6846`；Release 为正式版，非草稿、非预发布 |
| 2026-09-07 | 当前仓库状态 | 本地 HEAD、origin/main、GitHub main 和 v3.0.1 标签所指提交均为 `cde6846`；远端仅有 main 分支，未发现开放的 Issue/PR |

发布依据：[v3.0.0 Release](https://github.com/Water-Run/get/releases/tag/v3.0.0)、[v3.0.1 Release](https://github.com/Water-Run/get/releases/tag/v3.0.1)。v3.0.1 相对 v3.0.0 修改了 34 个文件，新增 6,883 行、删除 555 行，主要开发量集中在命令策略和运行时加固。

已完成的功能可以按模块归纳：

| 模块 | v3 已具备的能力 | 主要代码 |
|---|---|---|
| 统一执行框架 | `Model → Action → Policy → Tool → Observation` 类型化状态机；auto、direct、loop、parallel 四种策略；直接回答、单命令返回、继续推理和独立检查并行执行 | [类型定义](src/harness_types.nim)、[运行时](src/harness_runtime.nim)、[并行执行器](src/harness_executor.nim) |
| 模型协议与传输 | 原生 function tools、结构化 JSON、v2 Markdown 兼容；Qwen 文本工具调用归一化、异常动作恢复；连接复用、瞬态重试、TLS 主机名校验、响应尺寸限制 | [协议解析](src/harness_protocol.nim)、[HTTP 与模型接口](src/llm.nim)、[TLS](src/tls_context.nim) |
| 命令安全 | 不可关闭的语义只读策略；逐段校验管道、命令序列、参数与重定向；PATH 和环境变量净化；拒绝绕过与修改型操作；受支持 Linux/macOS 主机的原生文件写入拒绝层 | [命令策略](src/command_policy.nim)、[命令执行](src/exec.nim) |
| 实际检查兼容性 | 有界性能快照、服务、网络/DNS、硬件、日志、软件包与工具链检查；稳定用户目录路径搜索；危险词作为搜索数据时减少误拒绝 | [命令策略](src/command_policy.nim)、[提示](src/harness_prompt.nim)、[策略测试](tests/test_command_policy.nim) |
| 运行资源约束 | 模型轮次、工具数、并发数、命令超时和输出上限；跨平台进程树取消；大观察压缩；混合批次中被拒绝的命令保持不执行 | [运行时](src/harness_runtime.nim)、[命令执行](src/exec.nim) |
| 缓存与配置 | SHA-256 上下文身份、跨进程写入串行化、原子持久化、备份恢复、有界解析；缓存命令重新校验；v2 配置迁移；Windows DPAPI 密钥保护 | [缓存](src/cache.nim)、[配置](src/config.nim) |
| 发布工程 | Linux x64、Windows x64、macOS arm64 原生构建；Windows 随包运行库；安装器、构建清单和校验文件；装配时绑定真实模型验证过的 Linux 载荷 | [发布工作流](.github/workflows/release-candidate.yml)、[Windows CI](.github/workflows/windows-ci.yml)、[安装器](get_ready.py) |

默认执行预算为 3 轮模型交互、8 次工具调用、4 路并发、每条命令 30 秒和 1 MiB 输出。常规请求通常只需一次模型调用，缓存命中可省去模型调用；显式要求“不调用工具”会在请求、运行时和缓存边界生效。详见[中文 README](README-zh.md)。

验证结果应保留测试范围和时间口径。下表来自 2026-08-30 的[验证报告](VALIDATION-v3.0.1.md)及[原始基准记录](benchmark-results-v3.0.1.json)，本次未重新运行这些完整测试或真实模型请求：

| 验证项目 | 已记录结果 |
|---|---|
| Nim 测试 | Linux、原生 macOS 各 12 个文件、19 个 suite、122 项测试通过；Windows/Wine 执行了全部 12 个平台适用测试程序 |
| CLI 端到端 | Linux 32/32；macOS 32/32；Windows/Wine 31 项适用测试通过，1 项 POSIX 专用检查跳过 |
| 离线综合矩阵 | Linux、Windows/Wine 各 168 通过、0 失败、126 跳过；macOS 168 通过、0 失败、113 跳过 |
| 确定性安全策略 | Linux、Windows/Wine、原生 macOS 各 3,383/3,383 项判定符合预期 |
| 真实模型 Harness | 同一份 Linux CI 载荷上，DeepSeek deepseek-v4-flash 47/47、DGX Qwen qwen3.8-27b 47/47，均无失败或跳过 |
| 缓存压力 | 8 批 × 24 个并发写入，共 192/192 条保留；主文件和备份有效，无残留锁或临时文件 |
| 执行约束压力 | 超时 20/20、输出上限 50/50 通过 |

其中，Linux/Windows 的离线矩阵共列出 294 项，实际执行通过的是 168 项，不能写成“294 项全部通过”。v3.0.0 报告中的每家模型 261 个场景，与 v3.0.1 的 47 项 Harness 专项回放范围不同，不能直接用总数判断覆盖率升降。

本次在线核实，发布提交 `cde6846` 的[原生发布与装配流水线 33307208280](https://github.com/Water-Run/get/actions/runs/33307208280)中，Linux、Windows、macOS 三个验证任务和装配验证任务均为 success；独立的[Windows CI 33307198817](https://github.com/Water-Run/get/actions/runs/33307198817)也为 success。GitHub Release 已包含三个平台 ZIP、`SHA256SUMS-v3.0.1.txt` 和 `get-v3.0.1-assets.json`，共五个附件。

发布后的[资产与验证清单](https://github.com/Water-Run/get/releases/download/v3.0.1/get-v3.0.1-assets.json)进一步记录：三个 ZIP 的外部校验、完整性、构建身份、架构和可重现性检查均为 3/3；归档文件核对 41/41，内部载荷校验 38/38；Linux 和 macOS 的全新安装、保留配置升级均通过，本机 Linux 从 3.0.0 升级到 3.0.1 并保留 DeepSeek 配置。清单里的三个 ZIP 摘要与本次读取的 GitHub 附件摘要一致。这些是已有发布记录，本次没有再次下载所有 ZIP 或重跑安装。

性能方面，v3.0.1 的当次实测相对官方 v2.1 Linux 二进制，`get version` 启动中位数从 8.701 ms 降到 3.232 ms，下降 62.85%；`get help` 下降 61.16%。只读策略判定中位数约 3.335 微秒。代价是本地测试构建的版本查询 RSS 增加约 2.17%，二进制体积增加 56.89%。这些比例来自相同方法下的本地构建比较，不能直接视为公开 ZIP 体积变化。v3.0.1 基准文件中的网络、缓存和并行耗时沿用 v3.0.0 历史结果，并非 v3.0.1 新测结果。详见[性能方法与数据](VALIDATION-v3.0.1.md#performance-method-and-result)。

需要跟进的事项如下；优先级为本次整理建议，并非已有版本排期：

| 优先级 | 事项 | 现状与建议 |
|---|---|---|
| 高 | 回填发布状态 | [发布计划](RELEASE-v3.0.1.md)仍有 7 项未勾选，[验证报告](VALIDATION-v3.0.1.md)仍称重建、装配、打标签和发布待完成。CI、标签、Release 和分支状态已能证实其中多项完成，应记录最终运行链接与时间 |
| 高 | 归档公开安装包的最终验证记录 | Release 资产清单已有 ZIP 校验、Linux/macOS 安装升级和本机配置保留结果，应将其归档并关联到仓库报告。Windows 原生 CI 有安装器 smoke 测试，资产清单单列的是 Wine CLI 结果；公开 Windows ZIP 的独立安装证据还需明确关联 |
| 高 | 明确本地测试选用的二进制 | 仓库根目录 `./get` 报告 2.0，`.ci/get-linux-x64` 报告 3.0.0，而 PATH 中 `/home/waterrun/.local/bin/get` 是 3.0.1。CLI 测试未设置 `GET_V3_BINARY` 时默认选取 `./get`，后续验证应显式指定目标或使用新构建 |
| 中 | 对齐编译器与产物管理 | 本机 Nim 为 2.2.6，低于包声明的 2.2.8，发布 CI 固定 2.2.10；本地开发宜对齐 CI。现有 `.ci/`、macOS 二进制及测试可执行文件未被 Git 跟踪，应按用途统一归档或补充忽略规则 |
| 中 | 明确后续迭代范围 | v3.1.0 已作为 Markdown 与只读审查更新落地。v4.0.0 的主目标不再是继续收紧策略，而是修复真实项目上「任务稍微复杂一点就没法用」；见 [V4-DEVELOPMENT-GOAL.md](V4-DEVELOPMENT-GOAL.md) |

安全和分发仍有已知边界：Windows 发行包没有与 Linux/macOS 对等的原生文件系统沙箱；三个平台的二进制未做平台代码签名；允许的读取及后续模型交互可能涉及本地数据。上述边界已在[中文 README](README-zh.md#安全模型)和[发布说明](RELEASE_NOTES-v3.0.1.md#important-boundary)中说明，应作为后续产品决策的依据。

本机已安装的 3.0.1 二进制为 2,236,088 字节，SHA-256 为 `71d07ac4c9a14ec74551b64057c74aee9f488a2213e0c55da8820c512c21a1d1`，与工作流固定的、经过两家真实模型回放的 Linux 载荷一致。本次另检查了四份 Python 入口/测试文件的语法和 `git diff --check`，均通过。整理前已跟踪文件无未提交修改；本次仅新增这份状态文档。
