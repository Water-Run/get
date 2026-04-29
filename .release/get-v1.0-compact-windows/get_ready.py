#!/usr/bin/env python3
"""
get_ready.py -- installer / uninstaller for `get`.

Run this script to install `get` on your system.  If `get` is already
installed, running the script again provides the option to uninstall.

Expected layout next to this script:

    get_ready.py
    get              (Linux binary)
    get.exe          (Windows binary)
    get.1            (Linux man page, optional)
    bin/             (optional extra tools directory)
"""
from __future__ import annotations

import ctypes
import getpass
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Iterable

# ---------------------------------------------------------------------------
# Platform constants
# ---------------------------------------------------------------------------

IS_WINDOWS: bool = os.name == "nt"
IS_LINUX:   bool = sys.platform.startswith("linux")
SCRIPT_DIR: Path = Path(__file__).resolve().parent

RC_MARK_BEGIN: str = "# >>> get installer >>>"
RC_MARK_END:   str = "# <<< get installer <<<"

PROJECT_TAGLINE: str = "get -- get anything from your computer"
PROJECT_GITHUB:  str = "https://github.com/Water-Run/get"

DEFAULT_SHELL: str = "powershell" if IS_WINDOWS else "bash"
DEFAULT_URL:   str = "https://api.poe.com/v1"
DEFAULT_MODEL: str = "gpt-5.3-codex"

# ---------------------------------------------------------------------------
# ANSI colors
# ---------------------------------------------------------------------------


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

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------


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


def bad(msg: str) -> None:
    print(f"  {Color.RED}{Color.BOLD}[fail]{Color.RESET} {msg}")


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


def _print_github() -> None:
    print()
    print(f"  {Color.DIM}{PROJECT_GITHUB}{Color.RESET}")
    print()

# ---------------------------------------------------------------------------
# Input helpers
# ---------------------------------------------------------------------------


def ask_yes_no(prompt: str, default: str = "y") -> bool:
    suffix = "[Y/n]" if default.lower() == "y" else "[y/N]"
    while True:
        try:
            reply = input(
                f"  {Color.BOLD}?{Color.RESET} {prompt} "
                f"{Color.DIM}{suffix}{Color.RESET} "
            ).strip().lower()
        except EOFError:
            reply = ""
        if not reply:
            reply = default.lower()
        if reply in ("y", "yes"):
            return True
        if reply in ("n", "no"):
            return False


def ask_input(prompt: str, hint: str = "") -> str:
    hint_str = f" {Color.DIM}[{hint}]{Color.RESET}" if hint else ""
    try:
        reply = input(
            f"  {Color.BOLD}>{Color.RESET} {prompt}{hint_str}: "
        ).strip()
    except EOFError:
        reply = ""
    return reply


def ask_secret(prompt: str, hint: str = "") -> str:
    """Prompt for sensitive text without echoing the input."""
    hint_str = f" [{hint}]" if hint else ""
    try:
        reply = getpass.getpass(f"  > {prompt}{hint_str}: ").strip()
    except Exception:
        reply = ask_input(prompt, hint=hint)
    return reply


def ask_choice(prompt: str, options: list[tuple[str, str, str]]) -> str:
    """Present a numbered menu and return the key of the selected option."""
    print()
    print(f"  {Color.BOLD}{prompt}{Color.RESET}")
    for idx, (_, label, desc) in enumerate(options, 1):
        print(f"    {Color.BOLD}{idx}){Color.RESET} {label}")
        if desc:
            print(f"       {Color.DIM}{desc}{Color.RESET}")
    while True:
        try:
            reply = input(
                f"\n  {Color.BOLD}>{Color.RESET} "
                f"Select [1-{len(options)}]: "
            ).strip()
        except EOFError:
            reply = "1"
        if reply.isdigit() and 1 <= int(reply) <= len(options):
            return options[int(reply) - 1][0]

# ---------------------------------------------------------------------------
# System check
# ---------------------------------------------------------------------------


def check_system() -> None:
    step("Checking system compatibility")
    if IS_WINDOWS:
        v = sys.getwindowsversion()
        if v.major < 10:
            bad(f"Windows {v.major}.{v.minor} -- Windows 10 or later is required")
            sys.exit(1)
        good(f"Windows {v.major}.{v.minor} (build {v.build})")
    elif IS_LINUX:
        release = platform.release()
        try:
            major = int(release.split(".", 1)[0])
        except ValueError:
            major = 0
        if major < 6:
            bad(f"Linux kernel {release} -- kernel 6 or later is required")
            sys.exit(1)
        good(f"Linux kernel {release}")
    else:
        bad(f"Unsupported platform: {sys.platform}")
        sys.exit(1)

# ---------------------------------------------------------------------------
# Install paths
# ---------------------------------------------------------------------------


def install_paths() -> dict:
    if IS_WINDOWS:
        localappdata = os.environ.get("LOCALAPPDATA") or str(
            Path.home() / "AppData" / "Local"
        )
        base = Path(localappdata) / "Programs" / "get"
        return {
            "root":      base,
            "binary":    base / "get.exe",
            "extra_bin": base / "bin",
            "man":       None,
            "path_dirs": [base, base / "bin"],
        }
    home = Path.home()
    local = home / ".local"
    return {
        "root":      local / "share" / "get",
        "binary":    local / "bin" / "get",
        "extra_bin": local / "share" / "get" / "bin",
        "man":       local / "share" / "man" / "man1" / "get.1",
        "path_dirs": [local / "bin", local / "share" / "get" / "bin"],
    }


def find_installed() -> "Path | None":
    paths = install_paths()
    if paths["binary"].exists():
        return paths["binary"]
    found = shutil.which("get")
    if found:
        resolved = Path(found).resolve()
        if resolved.parent != SCRIPT_DIR:
            return resolved
    return None

# ---------------------------------------------------------------------------
# File helpers
# ---------------------------------------------------------------------------


def copy_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    if not IS_WINDOWS:
        os.chmod(dst, 0o755)


def remove_file(p: Path) -> None:
    if not p.exists():
        return
    step(f"Removing {p}")
    try:
        p.unlink()
        good("Removed")
    except OSError as e:
        bad(f"Failed: {e}")


def prune_empty_parents(start: Path, stop_at: Path) -> None:
    try:
        stop_at = stop_at.resolve()
    except OSError:
        return
    cur = start
    while cur.exists() and cur.resolve() != stop_at:
        try:
            cur.rmdir()
        except OSError:
            break
        cur = cur.parent

# ---------------------------------------------------------------------------
# PATH management
# ---------------------------------------------------------------------------


def _notify_env_change_windows() -> None:
    try:
        result = ctypes.c_long()
        ctypes.windll.user32.SendMessageTimeoutW(
            0xFFFF, 0x1A, 0, "Environment", 0x0002, 5000,
            ctypes.byref(result),
        )
    except Exception:
        pass


def path_add_windows(dirs: Iterable[Path]) -> bool:
    import winreg
    changed = False
    with winreg.OpenKey(
        winreg.HKEY_CURRENT_USER, "Environment",
        0, winreg.KEY_READ | winreg.KEY_WRITE,
    ) as k:
        try:
            current, _ = winreg.QueryValueEx(k, "Path")
        except FileNotFoundError:
            current = ""
        parts = [p for p in current.split(";") if p]
        existing = {p.lower() for p in parts}
        for d in dirs:
            value = str(d)
            if value.lower() not in existing:
                parts.append(value)
                existing.add(value.lower())
                changed = True
        if changed:
            winreg.SetValueEx(
                k, "Path", 0, winreg.REG_EXPAND_SZ, ";".join(parts))
            _notify_env_change_windows()
    return changed


def path_remove_windows(dirs: Iterable[Path]) -> bool:
    import winreg
    targets = {str(d).lower() for d in dirs}
    with winreg.OpenKey(
        winreg.HKEY_CURRENT_USER, "Environment",
        0, winreg.KEY_READ | winreg.KEY_WRITE,
    ) as k:
        try:
            current, _ = winreg.QueryValueEx(k, "Path")
        except FileNotFoundError:
            return False
        parts = [p for p in current.split(";") if p]
        kept = [p for p in parts if p.lower() not in targets]
        if len(kept) == len(parts):
            return False
        winreg.SetValueEx(k, "Path", 0, winreg.REG_EXPAND_SZ, ";".join(kept))
        _notify_env_change_windows()
    return True


def path_add_linux(dirs: Iterable[Path]) -> bool:
    lines = [RC_MARK_BEGIN]
    for d in dirs:
        lines.append(
            f'case ":$PATH:" in *":{d}:"*) ;; '
            f'*) export PATH="{d}:$PATH" ;; esac'
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
        with rc.open("a") as f:
            f.write(block)
        changed = True
    return changed


def path_remove_linux() -> bool:
    changed = False
    home = Path.home()
    for rc in (home / ".profile", home / ".bashrc", home / ".zshrc"):
        if not rc.exists():
            continue
        content = rc.read_text()
        if RC_MARK_BEGIN not in content:
            continue
        kept: list[str] = []
        skip = False
        for line in content.splitlines(keepends=True):
            if RC_MARK_BEGIN in line:
                skip = True
                continue
            if RC_MARK_END in line:
                skip = False
                continue
            if not skip:
                kept.append(line)
        rc.write_text("".join(kept).rstrip() + "\n")
        changed = True
    return changed


def add_to_path(dirs: list[Path]) -> bool:
    return path_add_windows(dirs) if IS_WINDOWS else path_add_linux(dirs)


def remove_from_path(dirs: list[Path]) -> bool:
    return path_remove_windows(dirs) if IS_WINDOWS else path_remove_linux()

# ---------------------------------------------------------------------------
# get binary invocation
# ---------------------------------------------------------------------------


def run_get(binary: Path, *args: str) -> bool:
    """
    Invoke the installed get binary and return True on success.
    The value following a 'key' argument is masked in diagnostic output.
    """
    display_args: list[str] = []
    for i, a in enumerate(args):
        if i > 0 and args[i - 1] == "key":
            display_args.append("<hidden>")
        else:
            display_args.append(a)
    cmd_display = "get " + " ".join(display_args)

    try:
        result = subprocess.run(
            [str(binary), *args],
            capture_output=True,
            text=True,
            timeout=15,
        )
        if result.returncode == 0:
            return True
        raw = result.stderr.strip() or result.stdout.strip() or "(no output)"
        bad(f"'{cmd_display}' returned non-zero: {raw}")
        return False
    except FileNotFoundError:
        bad(f"Binary not found: {binary}")
        return False
    except subprocess.TimeoutExpired:
        bad(f"'{cmd_display}' timed out")
        return False
    except Exception as exc:
        bad(f"Unexpected error: {exc}")
        return False

# ---------------------------------------------------------------------------
# Shell detection
# ---------------------------------------------------------------------------


# Only these shells are auto-detected. Anything else -> return None ->
# configure_shell() keeps the built-in default and makes no changes.
_LINUX_SHELLS = ("bash", "zsh", "fish")
_WINDOWS_SHELLS = ("powershell", "pwsh", "cmd")


def _normalize_name(raw: str, allowed: tuple) -> "str | None":
    """Map a raw process/executable name to an allowed shell identifier."""
    if not raw:
        return None
    name = Path(raw.strip()).name.lower()
    # Strip leading dash from login shells, e.g. "-bash"
    name = name.lstrip("-")
    # Strip Windows .exe suffix
    if name.endswith(".exe"):
        name = name[:-4]
    # Handle version-suffixed names, e.g. "bash-5.2"
    base = name.split("-", 1)[0].split(".", 1)[0]
    for known in allowed:
        if name == known or base == known:
            return known
    return None


def _linux_shell_from_parent() -> "str | None":
    """Read /proc/<ppid>/comm to identify the running interactive shell."""
    try:
        ppid = os.getppid()
        comm = Path(f"/proc/{ppid}/comm")
        if comm.exists():
            name = _normalize_name(comm.read_text(), _LINUX_SHELLS)
            if name:
                return name
        exe = Path(f"/proc/{ppid}/exe")
        if exe.exists():
            name = _normalize_name(os.readlink(exe), _LINUX_SHELLS)
            if name:
                return name
    except Exception:
        pass
    return None


def _linux_shell_from_env() -> "str | None":
    return _normalize_name(os.environ.get("SHELL", ""), _LINUX_SHELLS)


def _linux_shell_from_passwd() -> "str | None":
    try:
        import pwd
        entry = pwd.getpwuid(os.getuid())
        return _normalize_name(entry.pw_shell, _LINUX_SHELLS)
    except Exception:
        return None


def _windows_shell_from_parent() -> "str | None":
    """Identify the parent shell on Windows via WMI / tasklist."""
    try:
        ppid = os.getppid()
    except Exception:
        return None

    # Try PowerShell's CIM query first -- accurate and usually available.
    try:
        result = subprocess.run(
            [
                "powershell", "-NoProfile", "-Command",
                f"(Get-CimInstance Win32_Process -Filter 'ProcessId={ppid}')"
                ".Name",
            ],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            name = _normalize_name(result.stdout, _WINDOWS_SHELLS)
            if name:
                return name
    except Exception:
        pass

    # Fallback: tasklist
    try:
        result = subprocess.run(
            ["tasklist", "/FI", f"PID eq {ppid}", "/FO", "CSV", "/NH"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0 and result.stdout.strip():
            # CSV: "image","pid",...
            first = result.stdout.strip().splitlines()[0]
            image = first.split(",", 1)[0].strip().strip('"')
            name = _normalize_name(image, _WINDOWS_SHELLS)
            if name:
                return name
    except Exception:
        pass
    return None


def _windows_shell_from_env() -> "str | None":
    # PowerShell sets PSModulePath; pwsh 7+ also sets POSH_* vars in some setups.
    if os.environ.get("PSModulePath"):
        # Can't reliably distinguish powershell vs pwsh from env alone,
        # assume Windows PowerShell (more common as default shell).
        return "powershell"
    # ComSpec typically points to cmd.exe when running inside cmd.
    comspec = os.environ.get("ComSpec", "")
    if comspec and _normalize_name(comspec, _WINDOWS_SHELLS) == "cmd":
        return "cmd"
    return None


def detect_current_shell() -> "str | None":
    """
    Return one of the auto-detectable shells, or None if unknown.

    Linux   : bash, zsh, fish
    Windows : powershell, pwsh, cmd

    Any other shell (sh, dash, ksh, tcsh, nushell, xonsh, ...) returns None
    so that the caller keeps the built-in default and makes no changes.
    """
    if IS_LINUX:
        # Parent process is the most reliable source -- correctly handles
        # `exec fish` or stale $SHELL after `chsh` without re-login.
        return (
            _linux_shell_from_parent()
            or _linux_shell_from_env()
            or _linux_shell_from_passwd()
        )
    if IS_WINDOWS:
        return (
            _windows_shell_from_parent()
            or _windows_shell_from_env()
        )
    return None

# ---------------------------------------------------------------------------
# Post-install configuration
# ---------------------------------------------------------------------------


def configure_shell(binary: Path) -> None:
    detected = detect_current_shell()
    if detected is None or detected == DEFAULT_SHELL:
        return
    print()
    info(
        f"Detected shell: {Color.BOLD}{detected}{Color.RESET}  "
        f"(configured default: {DEFAULT_SHELL})"
    )
    if not ask_yes_no(
        f"Set '{detected}' as get's default shell?",
        default="y",
    ):
        return
    step(f"Running: get set shell {detected}")
    if run_get(binary, "set", "shell", detected):
        good(f"Shell set to '{detected}'")
    else:
        warn(
            f"Shell configuration failed. Run manually: get set shell {detected}")


def configure_model(binary: Path) -> None:
    banner("LLM configuration")
    info("Configure the LLM connection parameters.")
    info("Leave a field empty to retain its built-in default or to skip.")
    print()

    url = ask_input(
        "API endpoint URL",
        hint=f"leave empty for default: {DEFAULT_URL}",
    )
    if url:
        step(f"Running: get set url {url}")
        if run_get(binary, "set", "url", url):
            good(f"URL set to '{url}'")
    print()

    model = ask_input(
        "Model name",
        hint=f"leave empty for default: {DEFAULT_MODEL}",
    )
    if model:
        step(f"Running: get set model {model}")
        if run_get(binary, "set", "model", model):
            good(f"Model set to '{model}'")
    print()

    key = ask_secret("API key", hint="leave empty to skip")
    if key:
        step("Running: get set key <hidden>")
        if run_get(binary, "set", "key", key):
            good("API key configured")
    else:
        info("API key not set. Configure later with: get set key <your-key>")


def configure_advanced(binary: Path) -> None:
    banner("Advanced configuration")
    info("Defaults are shown in brackets. Press Enter to accept the default.")
    print()

    # double-check (default: true)
    info(
        "double-check: Secondary LLM safety review of generated commands."
        f" {Color.DIM}[default: true]{Color.RESET}"
    )
    double_check = ask_yes_no("Enable double-check?", default="y")
    step(f"Running: get set double-check {str(double_check).lower()}")
    if run_get(binary, "set", "double-check", str(double_check).lower()):
        good(f"double-check = {str(double_check).lower()}")
    print()

    # manual-confirm (default: false)
    info(
        "manual-confirm: Require manual confirmation before executing each command."
        f" {Color.DIM}[default: false]{Color.RESET}"
    )
    manual_confirm = ask_yes_no("Enable manual-confirm?", default="n")
    step(f"Running: get set manual-confirm {str(manual_confirm).lower()}")
    if run_get(binary, "set", "manual-confirm", str(manual_confirm).lower()):
        good(f"manual-confirm = {str(manual_confirm).lower()}")
    print()

    # instance: only offered when both safety checks are disabled
    if not double_check and not manual_confirm:
        info(
            "instance: Fast single-call mode; disables multi-round agent behavior."
            f" {Color.DIM}[default: false]{Color.RESET}"
        )
        warn(
            "In instance mode, performance and security will degrade."
        )
        instance = ask_yes_no("Enable instance?", default="n")
        step(f"Running: get set instance {str(instance).lower()}")
        if run_get(binary, "set", "instance", str(instance).lower()):
            good(f"instance = {str(instance).lower()}")
        print()

    # system-prompt (default: empty)
    info(
        "system-prompt: Custom instruction prepended to every LLM request."
        f" {Color.DIM}[default: empty]{Color.RESET}"
    )
    system_prompt = ask_input("System prompt", hint="leave empty to skip")
    if system_prompt:
        step("Running: get set system-prompt <value>")
        if run_get(binary, "set", "system-prompt", system_prompt):
            good("system-prompt configured")
    print()

    # cache (default: true)
    info(
        "cache: Enable the cache system for repeated queries."
        f" {Color.DIM}[default: true]{Color.RESET}"
    )
    warn(
        "After the first execution is recorded, repeating the same query may trigger "
        "one extra LLM request to decide whether and how to cache it. "
        "Cache may causes occasional issues."
    )
    info("Clear cache with: get cache --clean")
    cache_enabled = ask_yes_no("Enable cache?", default="y")
    step(f"Running: get set cache {str(cache_enabled).lower()}")
    if run_get(binary, "set", "cache", str(cache_enabled).lower()):
        good(f"cache = {str(cache_enabled).lower()}")
    print()

    # vivid (default: true)
    info(
        "vivid: Colored output and animations in terminal display."
        f" {Color.DIM}[default: true]{Color.RESET}"
    )
    vivid = ask_yes_no("Enable vivid?", default="y")
    step(f"Running: get set vivid {str(vivid).lower()}")
    if run_get(binary, "set", "vivid", str(vivid).lower()):
        good(f"vivid = {str(vivid).lower()}")
    print()

    if not vivid:
        # hide-process (default: false)
        info(
            "hide-process: Suppress intermediate step output during execution."
            f" {Color.DIM}[default: false]{Color.RESET}"
        )
        hide_process = ask_yes_no("Enable hide-process?", default="n")
        step(f"Running: get set hide-process {str(hide_process).lower()}")
        if run_get(binary, "set", "hide-process", str(hide_process).lower()):
            good(f"hide-process = {str(hide_process).lower()}")
        print()

        # external-display (default: true)
        info(
            "external-display: Use external tools (bat, mdcat) for rendering output."
            f" {Color.DIM}[default: true]{Color.RESET}"
        )
        external_display = ask_yes_no("Enable external-display?", default="y")
        step(
            f"Running: get set external-display {str(external_display).lower()}")
        if run_get(binary, "set", "external-display", str(external_display).lower()):
            good(f"external-display = {str(external_display).lower()}")
        print()

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------


def do_uninstall(existing: Path) -> None:
    paths = install_paths()
    print()

    remove_file(existing)
    if paths["binary"].resolve() != existing.resolve():
        remove_file(paths["binary"])

    if paths["extra_bin"].exists():
        step(f"Removing extra tools: {paths['extra_bin']}")
        try:
            shutil.rmtree(paths["extra_bin"])
            good("Extra tools removed")
        except OSError as e:
            bad(f"Failed: {e}")

    if paths["man"]:
        remove_file(paths["man"])
        prune_empty_parents(paths["man"].parent, stop_at=Path.home())

    if paths["root"].exists():
        try:
            paths["root"].rmdir()
        except OSError:
            pass

    step("Cleaning PATH entries")
    if remove_from_path(paths["path_dirs"]):
        good("PATH entries removed")
    else:
        good("PATH entries already absent")

    print()
    banner("uninstallation complete")
    if IS_LINUX:
        info("Restart your shell to refresh the environment.")
    else:
        info("Open a new terminal for PATH changes to take effect.")

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------


def main() -> None:
    _enable_ansi()

    print()
    print(f"{Color.BOLD}{Color.MAGENTA}{PROJECT_TAGLINE}{Color.RESET}")
    print()

    existing = find_installed()

    # ------------------------------------------------------------------
    # Uninstall branch
    # ------------------------------------------------------------------
    if existing:
        banner("uninstaller")
        info(
            f"Existing installation found: {Color.BOLD}{existing}{Color.RESET}")
        print()
        if not ask_yes_no("Uninstall get?", default="n"):
            _print_github()
            sys.exit(0)
        do_uninstall(existing)
        print()
        if not ask_yes_no("Reinstall get?", default="n"):
            _print_github()
            sys.exit(0)

    # ------------------------------------------------------------------
    # Install branch
    # ------------------------------------------------------------------
    banner("installer")
    check_system()
    print()

    src_bin = SCRIPT_DIR / ("get.exe" if IS_WINDOWS else "get")
    if not src_bin.exists():
        fail(f"Source binary not found: {src_bin}")
        _print_github()
        sys.exit(1)

    info(f"Source binary: {src_bin}")
    print()
    if not ask_yes_no("Install get?", default="y"):
        info("Installation cancelled.")
        _print_github()
        sys.exit(0)

    # Installation type selection
    extra_src = SCRIPT_DIR / "bin"
    has_extra = extra_src.is_dir() and any(extra_src.iterdir())

    if has_extra:
        mode = ask_choice(
            "Select installation type:",
            [
                (
                    "full",
                    "Full installation",
                    "Install get, extra tools from bin/, and (Linux) man page.",
                ),
                (
                    "minimal",
                    "Minimal installation",
                    "Install get and (Linux) man page only.",
                ),
            ],
        )
    else:
        mode = "minimal"
        info("No bin/ directory found -- performing minimal installation.")

    paths = install_paths()
    binary = paths["binary"]
    path_dirs = paths["path_dirs"][:1] if mode == "minimal" else paths["path_dirs"]

    # Confirm targets
    print()
    info("Installation targets:")
    print(f"    binary    : {binary}")
    if mode == "full":
        print(f"    extra bin : {paths['extra_bin']}")
    if paths["man"]:
        print(f"    man page  : {paths['man']}")
    for d in path_dirs:
        print(f"    PATH +=   : {d}")
    print()

    if not ask_yes_no("Proceed with installation?", default="y"):
        info("Installation cancelled.")
        _print_github()
        sys.exit(0)

    print()

    # Binary
    step(f"Installing binary  -->  {binary}")
    copy_file(src_bin, binary)
    good("Binary installed")

    # Man page
    if paths["man"]:
        man_src = SCRIPT_DIR / "get.1"
        if man_src.exists():
            step(f"Installing man page  -->  {paths['man']}")
            copy_file(man_src, paths["man"])
            good("Man page installed")
        else:
            warn("get.1 not found -- man page skipped")

    # Extra tools
    if mode == "full":
        step(f"Installing extra tools  -->  {paths['extra_bin']}")
        paths["extra_bin"].mkdir(parents=True, exist_ok=True)
        count = 0
        for item in extra_src.iterdir():
            if item.is_file():
                copy_file(item, paths["extra_bin"] / item.name)
                count += 1
        good(f"{count} extra tool(s) installed")

    # PATH
    step("Updating PATH")
    if add_to_path(path_dirs):
        good("PATH updated")
    else:
        good("PATH already configured")

    # Shell
    configure_shell(binary)

    # LLM settings
    print()
    if ask_yes_no("Configure LLM connection settings now?", default="y"):
        configure_model(binary)

    # Advanced settings
    print()
    if ask_yes_no("Configure advanced settings now?", default="n"):
        configure_advanced(binary)

    # Completion
    print()
    banner("installation complete")
    info("Open a new terminal and run the following to verify:")
    print(f"    {Color.BOLD}get version{Color.RESET}"
          f"  {Color.DIM}-- verify installation{Color.RESET}")
    print(f"    {Color.BOLD}get isok{Color.RESET}"
          f"     {Color.DIM}-- verify configuration{Color.RESET}")
    print()
    if IS_LINUX:
        info(
            "To reload PATH in the current session: "
            f"{Color.BOLD}source ~/.profile{Color.RESET}"
        )
    else:
        info("Open a new terminal for PATH changes to take effect.")

    _print_github()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
        fail("Interrupted.")
        sys.exit(130)
