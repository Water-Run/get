# `get` -- get anything from your computer

[英文](README.md)  

`get` 是一个小巧的命令行工具, 通过自然语言调用大语言模型 (LLM) 生成 Shell 命令, 并在你的设备上执行, 以获取你需要的任何信息.

`get` 以 `AGPL-3.0` 许可证在 [GitHub](https://github.com/Water-Run/get) 上开源.

使用示例:

```bash
get "系统版本"
get "当前目录下的代码"
get "https://github.com/Water-Run/get 上最新的 get 版本"
```

下载: [GitHub Release](https://github.com/Water-Run/get/releases)

## 安装与卸载

项目附带 Python 安装脚本 `get_ready.py`, 可自动完成安装和 PATH 配置:

```bash
python3 get_ready.py
```

完成后, 运行 `get version` 校验安装. 若已安装, 脚本会切换为卸载模式.

## 先决条件

使用前, 至少需要配置大语言模型的相关参数. `get` 兼容 OpenAI API 规范. 使用以下命令进行配置:

```bash
get set model 你的模型名称
get set url 你的接口地址
get set key 你的API密钥
```

配置完成后, 运行 `get isok` 进行验证.

若要取消某项配置, 将值留空即可. 例如取消 Key 设置:

```bash
get set key
```

## 快速开始

用法非常简单:

```bash
get "你的问题"
```

`get` 设计为仅执行只读操作. 每条生成的命令在执行前会经过多层安全验证 (危险命令拦截、二次审查、命令模式匹配、可选手动确认).

### 内置工具

`get` 在 `bin/` 目录中附带了多个高性能命令行工具, 生成的命令可自动使用:

| 工具                            | 说明                                      |
|---------------------------------|-------------------------------------------|
| `rg`                            | ripgrep -- 超快速正则搜索文件内容         |
| `fd`                            | 快速文件/目录查找器                       |
| `sg`                            | ast-grep -- AST 级别的结构化代码搜索      |
| `pmc`                           | pack-my-code -- 为 LLM 提示打包代码上下文 |
| `treepp` (Win) / `tree` (Linux) | 目录树展示                                |
| `tokei`                         | 代码统计工具 (按语言统计代码行数)         |
| `lua`                           | Lua 5.x 解释器, 用于计算和文本处理        |
| `bat`                           | 语法高亮的 cat 替代品                     |
| `mdcat`                         | 终端 Markdown 渲染器                      |

LLM 被告知这些工具的存在, 会在适合场景中优先使用. 内置工具的写入模式标志 (如 `pmc -o`, `treepp /o`) 在提示词中被明确禁止.

## 查询标志 (按次覆盖)

以下标志可在查询时覆盖持久化配置, 置于查询字符串之后:

| 标志                  | 说明                    |
|-----------------------|-------------------------|
| `--no-cache`          | 本次查询绕过缓存        |
| `--cache`             | 本次查询强制使用缓存    |
| `--manual-confirm`    | 执行前要求确认          |
| `--no-manual-confirm` | 跳过确认提示            |
| `--double-check`      | 启用二次安全审查        |
| `--no-double-check`   | 跳过二次安全审查        |
| `--instance`          | 快速单次调用模式        |
| `--no-instance`       | 多轮 agent 模式         |
| `--hide-process`      | 隐藏中间过程输出        |
| `--no-hide-process`   | 显示中间过程输出        |
| `--vivid`             | 启用 vivid 输出模式     |
| `--no-vivid`          | 使用纯文本输出模式      |
| `--model <名称>`      | 覆盖本次使用的 LLM 模型 |
| `--timeout <秒数>`    | 覆盖本次请求超时时间    |

示例:

```bash
get "磁盘使用情况" --no-cache
get "列出文件" --model gpt-5.3-codex --vivid
```

## `set` 选项参考

整数选项接受 `false` 以完全禁用该功能 (等同于 0).

| 选项                | 说明                                 | 值类型                | 默认值                               |
|---------------------|--------------------------------------|-----------------------|--------------------------------------|
| `key`               | LLM API 密钥                         | 字符串                | 空                                   |
| `url`               | LLM API 端点 URL                     | 字符串 (URL)          | `https://api.poe.com/v1`             |
| `model`             | LLM 模型名称                         | 字符串                | `gpt-5.3-codex`                      |
| `manual-confirm`    | 执行前是否要求手动确认               | `true` / `false`      | `false`                              |
| `double-check`      | 是否进行二次安全审查                 | `true` / `false`      | `true`                               |
| `instance`          | 是否使用单次调用快速模式             | `true` / `false`      | `false`                              |
| `timeout`           | 单次 API 请求超时时间                | 正整数 (秒) / `false` | `300`                                |
| `max-token`         | 每次请求的最大 token 消耗            | 正整数 / `false`      | `20480`                              |
| `max-rounds`        | Agent 模式的最大循环轮数             | 正整数 / `false`      | `3`                                  |
| `command-pattern`   | 禁止命令正则匹配模式                 | 正则字符串            | 空 (使用内置默认)                    |
| `system-prompt`     | 自定义系统提示词                     | 字符串                | 空                                   |
| `shell`             | 用于执行命令的 Shell                 | 字符串                | Windows: `powershell`; Linux: `bash` |
| `log`               | 是否记录每次请求和执行               | `true` / `false`      | `true`                               |
| `hide-process`      | 是否隐藏中间步骤                     | `true` / `false`      | `false`                              |
| `cache`             | 是否启用响应缓存                     | `true` / `false`      | `true`                               |
| `cache-expiry`      | 缓存条目过期天数                     | 正整数 (天) / `false` | `30`                                 |
| `cache-max-entries` | 缓存保留的最大条目数                 | 正整数 / `false`      | `1000`                               |
| `log-max-entries`   | 日志保留的最大条目数                 | 正整数 / `false`      | `1000`                               |
| `vivid`             | 是否启用 vivid 输出模式 (颜色与动画) | `true` / `false`      | `true`                               |
| `external-display`  | 是否使用 bat/mdcat 进行渲染          | `true` / `false`      | `true`                               |

禁用整数选项的示例:

```bash
get set timeout false
get set cache-expiry false
get set log-max-entries false
```

## 缓存管理

`get` 将每次查询的最终输出缓存, 键值为查询文本和执行上下文的哈希. 存储新缓存条目前, `get` 会询问 LLM 判断缓存策略:

| 缓存模式             | 说明                                                                     |
|----------------------|--------------------------------------------------------------------------|
| `RESULT` (结果缓存)  | 输出稳定, 直接缓存最终输出. 例: 系统版本、项目结构、静态配置             |
| `COMMAND` (命令缓存) | 命令可复用但输出易变, 只缓存命令, 命中时重新执行. 例: CPU 占用、当前时间 |
| `NOCACHE` (不缓存)   | 上下文依赖过强或结果瞬时, 既不缓存命令也不缓存输出                       |

常用命令:

```bash
get cache                    # 显示缓存状态
get cache --clean            # 清除所有缓存条目
get cache --unset "系统版本"  # 移除匹配查询的缓存条目
get set cache false          # 禁用缓存
```

## 日志管理

`get` 会将每次查询执行记录到本地文件. 超过 `log-max-entries` 限制时, 最旧的条目会被自动移除.

```bash
get log              # 显示日志状态
get log --clean      # 清除所有日志条目
get set log false    # 禁用日志
```

## `config` 命令参考

```bash
get config                # 显示所有当前配置
get config --reset        # 重置所有配置为默认值
get config --<选项名>     # 显示单个选项的当前值
```

`--<选项名>` 接受上方 `set` 表格中的所有选项名称. `get config --key` 显示密钥状态 (已设置/未设置), 值会被遮蔽. 禁用的整数选项显示 `false`.

## 其他命令参考

```bash
get get             # 显示 get 的基本信息
get get --intro     # 显示简介
get get --version   # 显示版本
get get --license   # 显示许可证标识
get get --github    # 显示 GitHub 链接
get version         # 显示版本
get isok            # 验证当前配置是否可用
get help            # 显示使用帮助
```

## 文件存储位置

| 文件     | Linux 路径                                     | Windows 路径                     |
|----------|------------------------------------------------|----------------------------------|
| 配置文件 | `~/.config/get/config.json`                    | `%APPDATA%/get/config.json`      |
| API 密钥 | `~/.config/get/key` (权限 0600)                | `%APPDATA%/get/key` (DPAPI 加密) |
| 执行日志 | `~/.config/get/get.log`                        | `%APPDATA%/get/get.log`          |
| 响应缓存 | `~/.config/get/cache.json`                     | `%APPDATA%/get/cache.json`       |
| 内置工具 | `<可执行文件>/bin/` 或 `<可执行文件>/src/bin/` | 同左                             |

## 退出码

| 退出码 | 含义                                                          |
|--------|---------------------------------------------------------------|
| `0`    | 成功完成                                                      |
| `1`    | 配置错误、LLM 通信失败、安全检查拒绝或一般错误                |
| `130`  | 被 Ctrl+C (SIGINT) 中断                                       |
| *N*    | 当生成的命令以非零码退出时, 该退出码会被传递为 `get` 的退出码 |
