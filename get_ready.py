#!/usr/bin/env python3
"""
get_ready.py -- installer for `get`.

The v3.0 release package is intentionally flat:

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
    RELEASE_NOTES.md
    BUILDINFO.json
    SHA256SUMS

The installer copies the platform binary, installs the optional man page,
updates the user PATH, and optionally configures LLM settings.
"""
from __future__ import annotations

import ctypes
import getpass
import locale
import os
import platform
import shutil
import subprocess
import sys
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
DEFAULT_URL: str = "https://api.minimaxi.com/v1"
DEFAULT_MODEL: str = "minimax-m3"
WINDOWS_RUNTIME_FILES: tuple[str, ...] = (
    "libcrypto-3.dll",
    "libssl-3.dll",
    "zlib1.dll",
)

MESSAGES: dict[str, dict[str, str]] = {
    "en": {
        "api_key": "API key",
        "api_key_skip": "API key not set. Configure later with: get set key <your-key>",
        "api_url": "API endpoint URL",
        "binary_installed": "Binary installed",
        "cancelled": "Installation cancelled.",
        "check_system": "Checking system compatibility",
        "configure_advanced": "Configure advanced settings now?",
        "configure_llm": "Configure LLM connection settings now?",
        "detected_shell": "Detected shell: {shell} (configured default: {default})",
        "existing": "Existing installation found: {path}",
        "github": PROJECT_GITHUB,
        "install_get": "Install get?",
        "installing_binary": "Installing binary  -->  {path}",
        "installing_man": "Installing man page  -->  {path}",
        "installing_runtime": "Installing runtime file  -->  {path}",
        "installer": "installer",
        "keep_config": "Keep existing get configuration?",
        "leave_default_model": "leave empty for default: {value}",
        "leave_default_url": "leave empty for default: {value}",
        "leave_skip": "leave empty to skip",
        "llm_banner": "LLM configuration",
        "llm_intro": "Leave fields empty to keep defaults or skip.",
        "man_installed": "Man page installed",
        "man_missing": "get.1 not found -- man page skipped",
        "model": "Model name",
        "open_new_terminal": "Open a new terminal for PATH changes to take effect.",
        "path_already": "PATH already configured",
        "path_updated": "PATH updated",
        "proceed": "Proceed with installation?",
        "reset_config": "Resetting get configuration",
        "shell_set": "Shell set to '{shell}'",
        "source_binary": "Source binary: {path}",
        "source_missing": "Source binary not found: {path}",
        "runtime_missing": "Required runtime file not found: {path}",
        "targets": "Installation targets:",
        "title_done": "installation complete",
        "updating_path": "Updating PATH",
        "verify": "Open a new terminal and run the following to verify:",
        "xattr_done": "Quarantine attribute removed (macOS Gatekeeper)",
    },
    "zh": {
        "api_key": "API key",
        "api_key_skip": "未设置 API key。之后可运行: get set key <your-key>",
        "api_url": "API 端点 URL",
        "binary_installed": "主程序已安装",
        "cancelled": "已取消安装。",
        "check_system": "检查系统兼容性",
        "configure_advanced": "现在配置高级选项?",
        "configure_llm": "现在配置 LLM 连接参数?",
        "detected_shell": "检测到 shell: {shell} (内置默认: {default})",
        "existing": "发现已有安装: {path}",
        "github": PROJECT_GITHUB,
        "install_get": "安装 get?",
        "installing_binary": "安装主程序  -->  {path}",
        "installing_man": "安装 man page  -->  {path}",
        "installing_runtime": "安装运行时文件  -->  {path}",
        "installer": "安装器",
        "keep_config": "保留现有 get 配置?",
        "leave_default_model": "留空使用默认值: {value}",
        "leave_default_url": "留空使用默认值: {value}",
        "leave_skip": "留空跳过",
        "llm_banner": "LLM 配置",
        "llm_intro": "字段留空会保留默认值或跳过。",
        "man_installed": "man page 已安装",
        "man_missing": "未找到 get.1, 跳过 man page",
        "model": "模型名称",
        "open_new_terminal": "打开新终端后 PATH 变更生效。",
        "path_already": "PATH 已配置",
        "path_updated": "PATH 已更新",
        "proceed": "继续安装?",
        "reset_config": "重置 get 配置",
        "shell_set": "Shell 已设为 '{shell}'",
        "source_binary": "源主程序: {path}",
        "source_missing": "未找到源主程序: {path}",
        "runtime_missing": "未找到必需运行时文件: {path}",
        "targets": "安装目标:",
        "title_done": "安装完成",
        "updating_path": "更新 PATH",
        "verify": "打开新终端后运行以下命令验证:",
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
    if not sys.stdout.isatty():
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
    print(f"  {Color.RED}{Color.BOLD}error:{Color.RESET} {msg}", file=sys.stderr)


def step(msg: str) -> None:
    print(f"    {Color.BLUE}{Color.BOLD}-->{Color.RESET} {msg}")


def good(msg: str) -> None:
    print(f"    {Color.GREEN}{Color.BOLD}[ok]{Color.RESET} {msg}")


def banner(title: str) -> None:
    inner = 58
    bar = "-" * inner
    pad = inner - len(title) - 2
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
            "root": base,
            "binary": base / "get.exe",
            "man": None,
            "path_dirs": [base],
        }
    home = Path.home()
    if IS_MACOS:
        return {
            "root": home / "Library" / "Application Support" / "get",
            "binary": home / ".local" / "bin" / "get",
            "man": home / ".local" / "share" / "man" / "man1" / "get.1",
            "path_dirs": [home / ".local" / "bin"],
        }
    return {
        "root": home / ".local" / "share" / "get",
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
    paths = install_paths()
    target = paths["binary"]
    if isinstance(target, Path) and target.exists():
        return target
    found = shutil.which("get")
    if found:
        resolved = Path(found).resolve()
        if resolved.parent != SCRIPT_DIR:
            return resolved
    return None


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


def path_add_posix(dirs: Iterable[Path]) -> bool:
    lines = [RC_MARK_BEGIN]
    for directory in dirs:
        lines.append(
            f'case ":$PATH:" in *":{directory}:"*) ;; '
            f'*) export PATH="{directory}:$PATH" ;; esac'
        )
    lines.append(RC_MARK_END)
    block = "\n" + "\n".join(lines) + "\n"
    changed = False
    home = Path.home()
    for rc in (home / ".profile", home / ".bashrc", home / ".zshrc"):
        if not rc.exists() and rc.name != ".profile":
            continue
        content = rc.read_text() if rc.exists() else ""
        if RC_MARK_BEGIN in content:
            continue
        with rc.open("a", encoding="utf-8") as handle:
            handle.write(block)
        changed = True
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
        raw = os.environ.get("SHELL", "")
        return _normalize_name(raw, _LINUX_SHELLS)
    if IS_WINDOWS:
        if os.environ.get("PSModulePath"):
            return "powershell"
        return _normalize_name(os.environ.get("ComSpec", ""), _WINDOWS_SHELLS)
    return None


def configure_shell(binary: Path, keep_config: bool) -> None:
    if keep_config:
        return
    detected = detect_current_shell()
    if detected is None or detected == DEFAULT_SHELL:
        return
    print()
    info(tr("detected_shell", shell=detected, default=DEFAULT_SHELL))
    if ask_yes_no(f"Set '{detected}' as get's default shell?", default="y"):
        if run_get(binary, "set", "shell", detected):
            good(tr("shell_set", shell=detected))


def configure_model(binary: Path) -> None:
    banner(tr("llm_banner"))
    info(tr("llm_intro"))
    print()

    url = ask_input(tr("api_url"), hint=tr("leave_default_url", value=DEFAULT_URL))
    if url and run_get(binary, "set", "url", url):
        good(f"url = {url}")
    print()

    model = ask_input(tr("model"), hint=tr("leave_default_model", value=DEFAULT_MODEL))
    if model and run_get(binary, "set", "model", model):
        good(f"model = {model}")
    print()

    key = ask_secret(tr("api_key"), hint=tr("leave_skip"))
    if key and run_get(binary, "set", "key", key):
        good("key = <set>")
    elif not key:
        info(tr("api_key_skip"))


def configure_advanced(binary: Path) -> None:
    banner("Advanced configuration")
    for option, default in (
        ("double-check", "n"),
        ("manual-confirm", "n"),
        ("cache", "y"),
        ("vivid", "y"),
        ("markdown", "y"),
    ):
        enabled = ask_yes_no(f"Enable {option}?", default=default)
        run_get(binary, "set", option, str(enabled).lower())


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


def main() -> None:
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

    existing = find_installed()
    keep_config = False
    if existing:
        info(tr("existing", path=existing))
        keep_config = ask_yes_no(tr("keep_config"), default="y")

    if not ask_yes_no(tr("install_get"), default="y"):
        info(tr("cancelled"))
        sys.exit(0)

    paths = install_paths()
    binary = paths["binary"]
    man = paths["man"]
    path_dirs = paths["path_dirs"]
    assert isinstance(binary, Path)
    assert isinstance(path_dirs, list)

    print()
    info(tr("targets"))
    print(f"    binary  : {binary}")
    if isinstance(man, Path):
        print(f"    man page: {man}")
    for directory in path_dirs:
        print(f"    PATH += : {directory}")
    print()

    if not ask_yes_no(tr("proceed"), default="y"):
        info(tr("cancelled"))
        sys.exit(0)

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
        man_src = SCRIPT_DIR / "get.1"
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

    if existing and not keep_config:
        reset_config(binary)

    configure_shell(binary, keep_config=keep_config)

    print()
    if ask_yes_no(tr("configure_llm"), default="y"):
        configure_model(binary)

    print()
    if ask_yes_no(tr("configure_advanced"), default="n"):
        configure_advanced(binary)

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
