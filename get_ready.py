#!/usr/bin/env python3
"""
get_ready.py -- installer for `get`.

The release package is intentionally flat:

    get_ready.py
    get-linux-x64
    get-windows-x64.exe
    libcrypto-3.dll
    libssl-3.dll
    zlib1.dll
    get-macos-arm64
    get.1
    README.md
    README-zh.md
    LICENSE
    OPENSSL-LICENSE.txt
    ZLIB-LICENSE.txt
    THIRD_PARTY_NOTICES.md
    BUILDINFO.json
    SHA256SUMS

The installer checks the package against SHA256SUMS, copies the platform
binary, installs the optional man page, and updates the user PATH. A first
install then walks through connecting a model, with presets for common
providers. `--update` replaces the program without questions and keeps the
existing configuration.
"""
from __future__ import annotations

import argparse
import ctypes
import getpass
import hashlib
import json
import locale
import os
import platform
import shutil
import subprocess
import sys
import time
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

IS_WINDOWS: bool = os.name == "nt"
IS_LINUX: bool = sys.platform.startswith("linux")
IS_MACOS: bool = sys.platform == "darwin"
SCRIPT_DIR: Path = Path(__file__).resolve().parent

RC_MARK_BEGIN: str = "# >>> get installer >>>"
RC_MARK_END: str = "# <<< get installer <<<"

PROJECT_TAGLINE: str = "get -- get anything from your computer"
PROJECT_GITHUB: str = "https://github.com/Water-Run/get"

DEFAULT_SHELL: str = "powershell" if IS_WINDOWS else ("zsh" if IS_MACOS else "bash")
DEFAULT_URL: str = "https://api.deepseek.com"
DEFAULT_MODEL: str = "deepseek-flash"
CHECKSUM_FILE: str = "SHA256SUMS"
WINDOWS_RUNTIME_FILES: tuple[str, ...] = (
    "libcrypto-3.dll",
    "libssl-3.dll",
    "zlib1.dll",
)

# Ollama ignores the bearer token, but get requires one to be set.
OLLAMA_PLACEHOLDER_KEY: str = "ollama"
OLLAMA_TAGS_TIMEOUT_SEC: float = 2.0
WAIT_PID_TIMEOUT_SEC: float = 60.0


@dataclass(frozen=True)
class Endpoint:
    region: str
    url: str


@dataclass(frozen=True)
class Provider:
    name: str
    endpoints: tuple[Endpoint, ...]
    models: tuple[str, ...]
    console: str = ""
    local: bool = False
    aliases: tuple[str, ...] = field(default_factory=tuple)


# Regions: "cn" is the mainland China endpoint, "global" the international
# one. When a provider has both, the installer defaults by UI language.
PROVIDERS: tuple[Provider, ...] = (
    Provider(
        "DeepSeek",
        (Endpoint("", "https://api.deepseek.com"),),
        ("deepseek-flash",),
        "https://platform.deepseek.com/api_keys",
    ),
    Provider(
        "MiMo",
        (Endpoint("", "https://api.xiaomimimo.com/v1"),),
        ("mimo-v2.6-flash", "mimo-v2.6-pro"),
        "https://mimo.mi.com",
        aliases=("xiaomi",),
    ),
    Provider(
        "GLM",
        (
            Endpoint("cn", "https://open.bigmodel.cn/api/paas/v4"),
            Endpoint("global", "https://api.z.ai/api/paas/v4"),
        ),
        ("glm-5.3", "glm-5.3-flash"),
        "https://open.bigmodel.cn",
        aliases=("zhipu", "z.ai", "zai"),
    ),
    Provider(
        "Kimi",
        (
            Endpoint("cn", "https://api.moonshot.cn/v1"),
            Endpoint("global", "https://api.moonshot.ai/v1"),
        ),
        ("kimi-k2.6", "kimi-k2.7-code"),
        "https://platform.kimi.ai",
        aliases=("moonshot",),
    ),
    Provider(
        "GPT",
        (Endpoint("", "https://api.openai.com/v1"),),
        ("gpt-6-luna", "gpt-6-sol", "gpt-6-astra"),
        "https://platform.openai.com/api-keys",
        aliases=("openai", "chatgpt"),
    ),
    Provider(
        "Claude",
        (Endpoint("", "https://api.anthropic.com/v1"),),
        ("claude-sonnet-5", "claude-haiku-4-5", "claude-opus-5-5"),
        "https://console.anthropic.com",
        aliases=("anthropic",),
    ),
    Provider(
        "Qwen",
        (
            Endpoint("cn", "https://dashscope.aliyuncs.com/compatible-mode/v1"),
            Endpoint("global", "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"),
        ),
        ("qwen-plus", "qwen3.8-max"),
        "https://bailian.console.aliyun.com",
        aliases=("dashscope", "tongyi", "bailian"),
    ),
    Provider(
        "Grok",
        (Endpoint("", "https://api.x.ai/v1"),),
        ("grok-4.7", "grok-4.3"),
        "https://console.x.ai",
        aliases=("xai", "x.ai"),
    ),
    Provider(
        "Gemini",
        (Endpoint("", "https://generativelanguage.googleapis.com/v1beta/openai"),),
        ("gemini-3.8-flash", "gemini-3.5-flash-lite"),
        "https://aistudio.google.com/apikey",
        aliases=("google",),
    ),
    Provider(
        "MiniMax",
        (
            Endpoint("cn", "https://api.minimaxi.com/v1"),
            Endpoint("global", "https://api.minimax.io/v1"),
        ),
        ("MiniMax-M3",),
        "https://platform.minimaxi.com",
    ),
    Provider(
        "Ollama",
        (Endpoint("", "http://localhost:11434/v1"),),
        (),
        local=True,
    ),
)

MESSAGES: dict[str, dict[str, str]] = {
    "en": {
        "api_key": "API key",
        "api_key_hint": "input is hidden",
        "api_key_skip": "API key not set. Set it later with: get set key <your-key>",
        "api_key_where": "Create a key at {url}",
        "api_url": "API endpoint URL",
        "binary_installed": "Binary installed",
        "cancelled": "Installation cancelled.",
        "check_system": "Checking system compatibility",
        "checksum_bad": "Checksum mismatch: {name}. The package is damaged; download it again.",
        "checksum_missing": "{file} not found next to the installer. Use a release package from {url}",
        "checksum_ok": "Package checksums verified",
        "checksum_unlisted": "{name} is not listed in {file}",
        "choose_model": "Model",
        "choose_model_hint": "number or name, Enter for {value}",
        "choose_provider": "Provider",
        "choose_provider_hint": "number or name, Enter to skip",
        "choose_region": "Endpoint",
        "choose_region_hint": "Enter for {value}",
        "custom": "Custom",
        "custom_note": "any OpenAI-compatible endpoint",
        "existing": "Existing installation found: {path}",
        "install_get": "Install get?",
        "installing_binary": "Installing binary  -->  {path}",
        "installing_man": "Installing man page  -->  {path}",
        "installing_runtime": "Installing runtime file  -->  {path}",
        "installer": "installer",
        "invalid_choice": "Not an option: {value}",
        "keep_config": "Keep the existing configuration?",
        "leave_default": "Enter for {value}",
        "local": "local",
        "man_installed": "Man page installed",
        "man_missing": "get.1 not found -- man page skipped",
        "model": "Model name",
        "model_required": "A model name is required.",
        "ollama_down": "Ollama is not answering at {url}. Start it with `ollama serve`, or type a model name anyway.",
        "ollama_empty": "No local models yet. Pull one with `ollama pull <model>`, then type its name.",
        "open_new_terminal": "Open a new terminal for PATH changes to take effect.",
        "path_already": "PATH already configured",
        "path_updated": "PATH updated",
        "region_cn": "China mainland",
        "region_global": "International",
        "reset_config": "Resetting get configuration",
        "runtime_missing": "Required runtime file not found: {path}",
        "setup_banner": "Connect a model",
        "setup_done": "Connected to {provider}: {model}",
        "setup_intro": "get talks to any OpenAI-compatible endpoint. Pick a provider to fill in the address and model for you.",
        "setup_later": "Skipped. Connect later with: get set url / get set model / get set key",
        "shell_set": "Shell set to '{shell}'",
        "source_binary": "Source binary: {path}",
        "source_missing": "Source binary not found: {path}",
        "targets": "Installation targets:",
        "test_now": "Test the connection now?",
        "title_done": "installation complete",
        "update_done": "get updated; configuration kept",
        "updating_path": "Updating PATH",
        "verify": "Open a new terminal and run the following to verify:",
        "waiting_pid": "Waiting for the running get ({pid}) to exit",
        "waiting_pid_timeout": "get ({pid}) is still running; close it and try again.",
        "xattr_done": "Quarantine attribute removed (macOS Gatekeeper)",
    },
    "zh": {
        "api_key": "API key",
        "api_key_hint": "输入不回显",
        "api_key_skip": "未设置 API key。之后可运行: get set key <your-key>",
        "api_key_where": "在这里创建 key: {url}",
        "api_url": "API 端点 URL",
        "binary_installed": "主程序已安装",
        "cancelled": "已取消安装。",
        "check_system": "检查系统兼容性",
        "checksum_bad": "校验和不符: {name}。安装包已损坏，请重新下载。",
        "checksum_missing": "安装器旁没有 {file}。请使用 {url} 上的发布包。",
        "checksum_ok": "安装包校验和已核对",
        "checksum_unlisted": "{file} 中没有 {name}",
        "choose_model": "模型",
        "choose_model_hint": "序号或名称，回车用 {value}",
        "choose_provider": "服务商",
        "choose_provider_hint": "序号或名称，回车跳过",
        "choose_region": "端点",
        "choose_region_hint": "回车用 {value}",
        "custom": "自定义",
        "custom_note": "任意 OpenAI 兼容端点",
        "existing": "发现已有安装: {path}",
        "install_get": "安装 get?",
        "installing_binary": "安装主程序  -->  {path}",
        "installing_man": "安装 man page  -->  {path}",
        "installing_runtime": "安装运行时文件  -->  {path}",
        "installer": "安装器",
        "invalid_choice": "没有这个选项: {value}",
        "keep_config": "保留现有配置?",
        "leave_default": "回车用 {value}",
        "local": "本地",
        "man_installed": "man page 已安装",
        "man_missing": "未找到 get.1, 跳过 man page",
        "model": "模型名称",
        "model_required": "需要填写模型名称。",
        "ollama_down": "{url} 上的 Ollama 没有响应。可用 `ollama serve` 启动，也可以直接输入模型名。",
        "ollama_empty": "本地还没有模型。先 `ollama pull <model>`，再输入模型名。",
        "open_new_terminal": "打开新终端后 PATH 变更生效。",
        "path_already": "PATH 已配置",
        "path_updated": "PATH 已更新",
        "region_cn": "中国大陆",
        "region_global": "国际",
        "reset_config": "重置 get 配置",
        "runtime_missing": "未找到必需运行时文件: {path}",
        "setup_banner": "连接模型",
        "setup_done": "已连接 {provider}: {model}",
        "setup_intro": "get 可以连接任意 OpenAI 兼容端点。选一个服务商，地址和模型会自动填好。",
        "setup_later": "已跳过。之后可用 get set url / get set model / get set key 连接。",
        "shell_set": "Shell 已设为 '{shell}'",
        "source_binary": "源主程序: {path}",
        "source_missing": "未找到源主程序: {path}",
        "targets": "安装目标:",
        "test_now": "现在测试连接?",
        "title_done": "安装完成",
        "update_done": "get 已更新，配置保留",
        "updating_path": "更新 PATH",
        "verify": "打开新终端后运行以下命令验证:",
        "waiting_pid": "等待正在运行的 get ({pid}) 退出",
        "waiting_pid_timeout": "get ({pid}) 仍在运行，请关闭后重试。",
        "xattr_done": "已移除隔离属性(macOS Gatekeeper)",
    },
}


class Color:
    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    MAGENTA = "\033[35m"
    CYAN = "\033[36m"


def _disable_colors() -> None:
    for name in list(vars(Color)):
        if not name.startswith("_"):
            setattr(Color, name, "")


def _enable_ansi() -> None:
    if not sys.stdout.isatty() or os.environ.get("NO_COLOR") or \
            os.environ.get("TERM") == "dumb":
        _disable_colors()
        return
    if IS_WINDOWS:
        try:
            kernel32 = ctypes.windll.kernel32
            handle = kernel32.GetStdHandle(-11)
            mode = ctypes.c_ulong()
            kernel32.GetConsoleMode(handle, ctypes.byref(mode))
            kernel32.SetConsoleMode(handle, mode.value | 0x0004)
        except Exception:
            _disable_colors()


def detect_language() -> str:
    if IS_WINDOWS:
        try:
            lang_id = ctypes.windll.kernel32.GetUserDefaultUILanguage()
            primary = lang_id & 0x3FF
            if primary == 0x04:
                return "zh"
        except Exception:
            pass
    for name in ("LC_ALL", "LC_MESSAGES", "LANGUAGE", "LANG"):
        raw = os.environ.get(name, "")
        if raw.lower().startswith("zh"):
            return "zh"
    try:
        loc = locale.getlocale()[0] or ""
        if loc.lower().startswith("zh"):
            return "zh"
    except Exception:
        pass
    return "en"


LANG: str = detect_language()


def tr(key: str, **kwargs: object) -> str:
    text = MESSAGES.get(LANG, MESSAGES["en"]).get(key, MESSAGES["en"][key])
    return text.format(**kwargs)


def info(msg: str) -> None:
    print(f"  {Color.CYAN}{Color.BOLD}info:{Color.RESET}  {msg}")


def warn(msg: str) -> None:
    print(f"  {Color.YELLOW}{Color.BOLD}warn:{Color.RESET}  {msg}")


def fail(msg: str) -> None:
    sys.stdout.flush()
    print(f"  {Color.RED}{Color.BOLD}error:{Color.RESET} {msg}", file=sys.stderr)


def step(msg: str) -> None:
    print(f"    {Color.BLUE}{Color.BOLD}-->{Color.RESET} {msg}")


def good(msg: str) -> None:
    print(f"    {Color.GREEN}{Color.BOLD}[ok]{Color.RESET} {msg}")


def banner(title: str) -> None:
    inner = 58
    bar = "-" * inner
    pad = inner - _display_width(title) - 2
    lp = max(pad // 2, 0)
    rp = max(pad - lp, 0)
    print()
    print(f"{Color.CYAN}{Color.BOLD}+{bar}+{Color.RESET}")
    print(
        f"{Color.CYAN}{Color.BOLD}|{Color.RESET}"
        f"{' ' * (lp + 1)}{Color.BOLD}{title}{Color.RESET}{' ' * (rp + 1)}"
        f"{Color.CYAN}{Color.BOLD}|{Color.RESET}"
    )
    print(f"{Color.CYAN}{Color.BOLD}+{bar}+{Color.RESET}")
    print()


def _display_width(text: str) -> int:
    # CJK text occupies two terminal cells per character.
    return sum(2 if ord(ch) >= 0x1100 else 1 for ch in text)


def _pad(text: str, width: int) -> str:
    return text + " " * max(width - _display_width(text), 0)


def ask_yes_no(prompt: str, default: str = "y") -> bool:
    suffix = "[Y/n]" if default.lower() == "y" else "[y/N]"
    while True:
        try:
            reply = input(
                f"  {Color.BOLD}?{Color.RESET} {prompt} "
                f"{Color.DIM}{suffix}{Color.RESET} "
            ).strip().lower()
        except EOFError:
            return False
        if not reply:
            reply = default.lower()
        if reply in ("y", "yes", "是", "好"):
            return True
        if reply in ("n", "no", "否", "不"):
            return False


def ask_input(prompt: str, hint: str = "") -> str:
    hint_str = f" {Color.DIM}[{hint}]{Color.RESET}" if hint else ""
    try:
        return input(f"  {Color.BOLD}>{Color.RESET} {prompt}{hint_str}: ").strip()
    except EOFError:
        return ""


def ask_secret(prompt: str, hint: str = "") -> str:
    if not sys.stdin.isatty():
        return ask_input(prompt, hint=hint)
    hint_str = f" [{hint}]" if hint else ""
    try:
        return getpass.getpass(f"  > {prompt}{hint_str}: ").strip()
    except Exception:
        return ask_input(prompt, hint=hint)


def check_system() -> None:
    step(tr("check_system"))
    if IS_WINDOWS:
        version = sys.getwindowsversion()
        if version.major < 10:
            fail(f"Windows {version.major}.{version.minor} is too old")
            sys.exit(1)
        good(f"Windows {version.major}.{version.minor} (build {version.build})")
    elif IS_LINUX:
        good(f"Linux kernel {platform.release()}")
    elif IS_MACOS:
        version = platform.mac_ver()[0] or "unknown"
        if platform.machine() != "arm64":
            warn(f"non-arm64 architecture detected: {platform.machine()}")
        good(f"macOS {version} ({platform.machine()})")
    else:
        fail(f"Unsupported platform: {sys.platform}")
        sys.exit(1)


def install_paths() -> dict[str, object]:
    if IS_WINDOWS:
        localappdata = os.environ.get("LOCALAPPDATA") or str(
            Path.home() / "AppData" / "Local"
        )
        base = Path(localappdata) / "Programs" / "get"
        return {
            "binary": base / "get.exe",
            "man": None,
            "path_dirs": [base],
        }
    home = Path.home()
    return {
        "binary": home / ".local" / "bin" / "get",
        "man": home / ".local" / "share" / "man" / "man1" / "get.1",
        "path_dirs": [home / ".local" / "bin"],
    }


def source_binary() -> Path:
    if IS_WINDOWS:
        candidates = ["get-windows-x64.exe", "get.exe"]
    elif IS_MACOS:
        candidates = ["get-macos-arm64", "get"]
    else:
        candidates = ["get-linux-x64", "get"]
    for name in candidates:
        path = SCRIPT_DIR / name
        if path.exists():
            return path
    return SCRIPT_DIR / candidates[0]


def source_runtime_files() -> list[Path]:
    if not IS_WINDOWS:
        return []
    return [SCRIPT_DIR / name for name in WINDOWS_RUNTIME_FILES]


def find_installed() -> Path | None:
    target = install_paths()["binary"]
    if isinstance(target, Path) and target.exists():
        return target
    found = shutil.which("get")
    if found:
        resolved = Path(found).resolve()
        if resolved.parent != SCRIPT_DIR:
            return resolved
    return None


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_checksums() -> dict[str, str]:
    sums = SCRIPT_DIR / CHECKSUM_FILE
    if not sums.is_file():
        fail(tr("checksum_missing", file=CHECKSUM_FILE, url=PROJECT_GITHUB + "/releases"))
        sys.exit(1)
    table: dict[str, str] = {}
    for line in sums.read_text(encoding="utf-8").splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2:
            table[parts[1].lstrip("*")] = parts[0].lower()
    return table


def verify_package(files: Iterable[Path]) -> None:
    table = read_checksums()
    for path in files:
        expected = table.get(path.name)
        if expected is None:
            fail(tr("checksum_unlisted", name=path.name, file=CHECKSUM_FILE))
            sys.exit(1)
        if _sha256(path) != expected:
            fail(tr("checksum_bad", name=path.name))
            sys.exit(1)
    good(tr("checksum_ok"))


def copy_file(src: Path, dst: Path, executable: bool = False) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    if executable and not IS_WINDOWS:
        os.chmod(dst, 0o755)


def _notify_env_change_windows() -> None:
    try:
        result = ctypes.c_long()
        ctypes.windll.user32.SendMessageTimeoutW(
            0xFFFF, 0x1A, 0, "Environment", 0x0002, 5000, ctypes.byref(result)
        )
    except Exception:
        pass


def path_add_windows(dirs: Iterable[Path]) -> bool:
    import winreg
    changed = False
    with winreg.OpenKey(
        winreg.HKEY_CURRENT_USER,
        "Environment",
        0,
        winreg.KEY_READ | winreg.KEY_WRITE,
    ) as key:
        try:
            current, _ = winreg.QueryValueEx(key, "Path")
        except FileNotFoundError:
            current = ""
        parts = [p for p in current.split(";") if p]
        existing = {p.lower() for p in parts}
        for directory in dirs:
            value = str(directory)
            if value.lower() not in existing:
                parts.append(value)
                existing.add(value.lower())
                changed = True
        if changed:
            winreg.SetValueEx(key, "Path", 0, winreg.REG_EXPAND_SZ, ";".join(parts))
            _notify_env_change_windows()
    return changed


def _append_block(rc: Path, lines: list[str]) -> bool:
    content = rc.read_text(encoding="utf-8") if rc.exists() else ""
    if RC_MARK_BEGIN in content:
        return False
    rc.parent.mkdir(parents=True, exist_ok=True)
    block = "\n".join([RC_MARK_BEGIN, *lines, RC_MARK_END]) + "\n"
    with rc.open("a", encoding="utf-8") as handle:
        if content and not content.endswith("\n"):
            handle.write("\n")
        handle.write("\n" + block)
    return True


def path_add_posix(dirs: Iterable[Path]) -> bool:
    dirs = list(dirs)
    sh_lines = [
        f'case ":$PATH:" in *":{d}:"*) ;; *) export PATH="{d}:$PATH" ;; esac'
        for d in dirs
    ]
    changed = False
    home = Path.home()
    for rc in (home / ".profile", home / ".bashrc", home / ".zshrc"):
        if not rc.exists() and rc.name != ".profile":
            continue
        changed |= _append_block(rc, sh_lines)
    if detect_current_shell() == "fish":
        fish_lines: list[str] = []
        for d in dirs:
            fish_lines += [
                f'if not contains -- "{d}" $PATH',
                f'    set -gx PATH "{d}" $PATH',
                "end",
            ]
        config_home = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
        changed |= _append_block(config_home / "fish" / "config.fish", fish_lines)
    return changed


def add_to_path(dirs: list[Path]) -> bool:
    return path_add_windows(dirs) if IS_WINDOWS else path_add_posix(dirs)


def run_get(binary: Path, *args: str) -> bool:
    display_args: list[str] = []
    for i, arg in enumerate(args):
        display_args.append("<hidden>" if i > 0 and args[i - 1] == "key" else arg)
    try:
        result = subprocess.run(
            [str(binary), *args],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if result.returncode == 0:
            return True
        raw = result.stderr.strip() or result.stdout.strip() or "(no output)"
        warn(f"'get {' '.join(display_args)}' returned non-zero: {raw}")
    except Exception as exc:
        warn(f"Could not run get {' '.join(display_args)}: {exc}")
    return False


_LINUX_SHELLS = ("bash", "zsh", "fish")
_WINDOWS_SHELLS = ("powershell", "pwsh", "cmd")


def _normalize_name(raw: str, allowed: tuple[str, ...]) -> str | None:
    if not raw:
        return None
    name = Path(raw.strip()).name.lower().lstrip("-")
    if name.endswith(".exe"):
        name = name[:-4]
    base = name.split("-", 1)[0].split(".", 1)[0]
    for known in allowed:
        if name == known or base == known:
            return known
    return None


def detect_current_shell() -> str | None:
    if IS_LINUX or IS_MACOS:
        return _normalize_name(os.environ.get("SHELL", ""), _LINUX_SHELLS)
    if IS_WINDOWS:
        if os.environ.get("PSModulePath"):
            return "powershell"
        return _normalize_name(os.environ.get("ComSpec", ""), _WINDOWS_SHELLS)
    return None


def configure_shell(binary: Path) -> None:
    detected = detect_current_shell()
    if detected is None or detected == DEFAULT_SHELL:
        return
    if run_get(binary, "set", "shell", detected):
        good(tr("shell_set", shell=detected))


# ---------------------------------------------------------------------------
# Model setup
# ---------------------------------------------------------------------------

def _host(url: str) -> str:
    return url.split("://", 1)[-1].split("/", 1)[0]


def _default_endpoint(provider: Provider) -> Endpoint:
    preferred = "cn" if LANG == "zh" else "global"
    for endpoint in provider.endpoints:
        if endpoint.region == preferred:
            return endpoint
    return provider.endpoints[0]


def _pick(choices: list[str], reply: str) -> int | None:
    """Resolve a reply to a 0-based index by number, exact name or prefix."""
    if reply.isdigit():
        index = int(reply) - 1
        return index if 0 <= index < len(choices) else None
    lowered = reply.lower()
    for index, choice in enumerate(choices):
        if choice.lower() == lowered:
            return index
    matches = [i for i, c in enumerate(choices) if c.lower().startswith(lowered)]
    return matches[0] if len(matches) == 1 else None


def _match_provider(reply: str) -> int | None:
    lowered = reply.lower()
    if lowered in ("custom", tr("custom").lower()):
        return len(PROVIDERS)
    index = _pick([p.name for p in PROVIDERS] + [tr("custom")], reply)
    if index is not None:
        return index
    for i, provider in enumerate(PROVIDERS):
        if lowered in provider.aliases:
            return i
    return None


def show_providers() -> None:
    rows: list[tuple[str, str, str]] = []
    for provider in PROVIDERS:
        endpoint = _default_endpoint(provider)
        note = tr("local") if provider.local else _host(endpoint.url)
        rows.append((provider.name, provider.models[0] if provider.models else "", note))
    rows.append((tr("custom"), "", tr("custom_note")))
    name_w = max(_display_width(r[0]) for r in rows) + 2
    model_w = max(_display_width(r[1]) for r in rows) + 2
    for number, (name, model, note) in enumerate(rows, start=1):
        print(
            f"    {Color.CYAN}{number:>2}{Color.RESET}  "
            f"{Color.BOLD}{_pad(name, name_w)}{Color.RESET}"
            f"{_pad(model, model_w)}{Color.DIM}{note}{Color.RESET}"
        )
    print()


def choose_provider() -> Provider | None | bool:
    """Return a provider, None for custom, or False to skip setup."""
    while True:
        reply = ask_input(tr("choose_provider"), hint=tr("choose_provider_hint"))
        if not reply:
            return False
        index = _match_provider(reply)
        if index is None:
            warn(tr("invalid_choice", value=reply))
            continue
        return PROVIDERS[index] if index < len(PROVIDERS) else None


def choose_endpoint(provider: Provider) -> str:
    if len(provider.endpoints) == 1:
        return provider.endpoints[0].url
    default = _default_endpoint(provider)
    labels = [tr("region_" + e.region) for e in provider.endpoints]
    print()
    for number, (label, endpoint) in enumerate(zip(labels, provider.endpoints), 1):
        print(f"    {Color.CYAN}{number:>2}{Color.RESET}  "
              f"{_pad(label, 16)}{Color.DIM}{_host(endpoint.url)}{Color.RESET}")
    while True:
        reply = ask_input(tr("choose_region"),
                          hint=tr("choose_region_hint", value=tr("region_" + default.region)))
        if not reply:
            return default.url
        index = _pick(labels + [e.region for e in provider.endpoints], reply)
        if index is not None:
            return provider.endpoints[index % len(provider.endpoints)].url
        warn(tr("invalid_choice", value=reply))


def ollama_models(url: str) -> list[str] | None:
    """List local Ollama models; None when the server is unreachable."""
    tags = url.rsplit("/v1", 1)[0] + "/api/tags"
    try:
        with urllib.request.urlopen(tags, timeout=OLLAMA_TAGS_TIMEOUT_SEC) as response:
            data = json.loads(response.read().decode("utf-8"))
    except Exception:
        return None
    return [m["name"] for m in data.get("models", []) if m.get("name")]


def choose_model(suggestions: list[str]) -> str:
    if not suggestions:
        while True:
            model = ask_input(tr("model"))
            if model:
                return model
            warn(tr("model_required"))
    print()
    for number, model in enumerate(suggestions, 1):
        print(f"    {Color.CYAN}{number:>2}{Color.RESET}  {model}")
    reply = ask_input(tr("choose_model"), hint=tr("choose_model_hint", value=suggestions[0]))
    if not reply:
        return suggestions[0]
    if reply.isdigit() and 1 <= int(reply) <= len(suggestions):
        return suggestions[int(reply) - 1]
    # Anything else is taken as a model name the provider knows.
    return reply


def configure_model(binary: Path) -> None:
    banner(tr("setup_banner"))
    info(tr("setup_intro"))
    print()
    show_providers()

    provider = choose_provider()
    if provider is False:
        info(tr("setup_later"))
        return

    if provider is None:
        name = tr("custom")
        url = ask_input(tr("api_url"), hint=tr("leave_default", value=DEFAULT_URL)) or DEFAULT_URL
        model = ask_input(tr("model"), hint=tr("leave_default", value=DEFAULT_MODEL)) or DEFAULT_MODEL
        console = ""
    else:
        name = provider.name
        url = choose_endpoint(provider)
        suggestions = list(provider.models)
        if provider.local:
            local = ollama_models(url)
            if local is None:
                warn(tr("ollama_down", url=_host(url)))
            elif not local:
                warn(tr("ollama_empty"))
            suggestions = local or []
        model = choose_model(suggestions)
        console = provider.console

    print()
    ok = run_get(binary, "set", "url", url)
    ok = run_get(binary, "set", "model", model) and ok
    if ok:
        good(f"url   = {url}")
        good(f"model = {model}")

    if provider is not None and provider.local:
        key = OLLAMA_PLACEHOLDER_KEY
    else:
        print()
        if console:
            info(tr("api_key_where", url=console))
        key = ask_secret(tr("api_key"), hint=tr("api_key_hint"))
    if key and run_get(binary, "set", "key", key):
        good("key   = <set>")
    elif not key:
        info(tr("api_key_skip"))
        return

    if ok:
        print()
        good(tr("setup_done", provider=name, model=model))
    print()
    if ask_yes_no(tr("test_now"), default="y"):
        print()
        try:
            subprocess.run([str(binary), "isok"], timeout=120)
        except Exception as exc:
            warn(f"Could not run get isok: {exc}")


def reset_config(binary: Path) -> None:
    step(tr("reset_config"))
    run_get(binary, "config", "--reset")


def strip_macos_quarantine(paths: Iterable[Path]) -> None:
    if not IS_MACOS:
        return
    for path in paths:
        try:
            subprocess.run(
                ["xattr", "-d", "com.apple.quarantine", str(path)],
                capture_output=True,
                check=False,
            )
        except Exception:
            pass
    good(tr("xattr_done"))


def _pid_alive(pid: int) -> bool:
    if IS_WINDOWS:
        synchronize, still_active = 0x00100000 | 0x1000, 259
        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(synchronize, False, pid)
        if not handle:
            return False
        try:
            code = ctypes.c_ulong()
            kernel32.GetExitCodeProcess(handle, ctypes.byref(code))
            return code.value == still_active
        finally:
            kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_for_pid(pid: int) -> None:
    """`get update` hands over to the installer, then exits; wait for it."""
    if not _pid_alive(pid):
        return
    step(tr("waiting_pid", pid=pid))
    deadline = time.monotonic() + WAIT_PID_TIMEOUT_SEC
    while _pid_alive(pid):
        if time.monotonic() > deadline:
            fail(tr("waiting_pid_timeout", pid=pid))
            sys.exit(1)
        time.sleep(0.2)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Install or update get.")
    parser.add_argument("--update", action="store_true",
                        help="replace the program without questions; keep the configuration")
    parser.add_argument("--wait-pid", type=int, metavar="PID",
                        help="wait for this process to exit before replacing files")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    _enable_ansi()
    print()
    print(f"{Color.BOLD}{Color.MAGENTA}{PROJECT_TAGLINE}{Color.RESET}")

    banner(tr("installer"))
    check_system()
    print()

    src_bin = source_binary()
    if not src_bin.exists():
        fail(tr("source_missing", path=src_bin))
        print(f"\n  {Color.DIM}{PROJECT_GITHUB}{Color.RESET}\n")
        sys.exit(1)
    info(tr("source_binary", path=src_bin))
    runtime_files = source_runtime_files()
    for runtime_file in runtime_files:
        if not runtime_file.exists():
            fail(tr("runtime_missing", path=runtime_file))
            print(f"\n  {Color.DIM}{PROJECT_GITHUB}{Color.RESET}\n")
            sys.exit(1)
    man_src = SCRIPT_DIR / "get.1"
    verify_package([src_bin, *runtime_files, *([man_src] if man_src.exists() else [])])

    paths = install_paths()
    binary = paths["binary"]
    man = paths["man"]
    path_dirs = paths["path_dirs"]
    assert isinstance(binary, Path)
    assert isinstance(path_dirs, list)

    existing = find_installed()
    if existing:
        info(tr("existing", path=existing))

    print()
    info(tr("targets"))
    print(f"    binary  : {binary}")
    if isinstance(man, Path):
        print(f"    man page: {man}")
    for directory in path_dirs:
        print(f"    PATH += : {directory}")
    print()

    if not args.update and not ask_yes_no(tr("install_get"), default="y"):
        info(tr("cancelled"))
        sys.exit(0)
    keep_config = args.update or (
        existing is not None and ask_yes_no(tr("keep_config"), default="y"))

    if args.wait_pid:
        wait_for_pid(args.wait_pid)

    step(tr("installing_binary", path=binary))
    copy_file(src_bin, binary, executable=True)
    good(tr("binary_installed"))
    strip_macos_quarantine([binary])

    for runtime_file in runtime_files:
        runtime_target = binary.parent / runtime_file.name
        step(tr("installing_runtime", path=runtime_target))
        copy_file(runtime_file, runtime_target)
        good(runtime_file.name)

    if isinstance(man, Path):
        if man_src.exists():
            step(tr("installing_man", path=man))
            copy_file(man_src, man)
            good(tr("man_installed"))
        else:
            warn(tr("man_missing"))

    step(tr("updating_path"))
    if add_to_path(path_dirs):
        good(tr("path_updated"))
    else:
        good(tr("path_already"))

    if keep_config:
        print()
        good(tr("update_done"))
        print()
        return

    if existing:
        reset_config(binary)
    configure_shell(binary)
    configure_model(binary)

    banner(tr("title_done"))
    info(tr("verify"))
    print(f"    {Color.BOLD}get version{Color.RESET}")
    print(f"    {Color.BOLD}get isok{Color.RESET}")
    print()
    info(tr("open_new_terminal"))
    print(f"\n  {Color.DIM}{PROJECT_GITHUB}{Color.RESET}\n")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
        fail("Interrupted.")
        sys.exit(130)
