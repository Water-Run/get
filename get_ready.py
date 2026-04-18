#!/usr/bin/env python3
"""
get_ready.py — installer / uninstaller for `get`.

Run this script to install `get` on your system. If `get` is already
installed, running the script again switches to uninstall mode.

Expected layout next to this script:

    get_ready.py
    get            (Linux binary)
    get.exe        (Windows binary)
    get.1          (Linux man page)
    bin/           (optional, extra tools)
"""
from __future__ import annotations

import ctypes
import os
import platform
import shutil
import sys
from pathlib import Path
from typing import Iterable

# ─────────────────────────── environment flags ─────────────────────────

IS_WINDOWS: bool = os.name == "nt"
IS_LINUX:   bool = sys.platform.startswith("linux")
SCRIPT_DIR: Path = Path(__file__).resolve().parent

RC_MARK_BEGIN = "# >>> get installer >>>"
RC_MARK_END   = "# <<< get installer <<<"

PROJECT_TAGLINE = "get - get anything from your computer"
PROJECT_GITHUB  = "github: https://github.com/Water-Run/get"

# ─────────────────────────────── styling ───────────────────────────────

class Color:
    RESET  = "\033[0m"
    BOLD   = "\033[1m"
    DIM    = "\033[2m"
    RED    = "\033[31m"
    GREEN  = "\033[32m"
    YELLOW = "\033[33m"
    BLUE   = "\033[34m"
    MAGENTA= "\033[35m"
    CYAN   = "\033[36m"


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
            handle   = kernel32.GetStdHandle(-11)  # STD_OUTPUT_HANDLE
            mode     = ctypes.c_ulong()
            kernel32.GetConsoleMode(handle, ctypes.byref(mode))
            kernel32.SetConsoleMode(handle, mode.value | 0x0004)
        except Exception:
            _disable_colors()


def info(msg: str) -> None: print(f"{Color.BOLD}{Color.CYAN}info:{Color.RESET} {msg}")
def warn(msg: str) -> None: print(f"{Color.BOLD}{Color.YELLOW}warn:{Color.RESET} {msg}")
def fail(msg: str) -> None: print(f"{Color.BOLD}{Color.RED}error:{Color.RESET} {msg}", file=sys.stderr)
def step(msg: str) -> None: print(f"  {Color.BOLD}{Color.BLUE}»{Color.RESET} {msg}")
def good(msg: str) -> None: print(f"  {Color.BOLD}{Color.GREEN}✓{Color.RESET} {msg}")
def bad(msg: str)  -> None: print(f"  {Color.BOLD}{Color.RED}✗{Color.RESET} {msg}")


def ask_yes_no(prompt: str, default: str = "y") -> bool:
    suffix = "[Y/n]" if default.lower() == "y" else "[y/N]"
    while True:
        try:
            reply = input(f"{Color.BOLD}?{Color.RESET} {prompt} "
                          f"{Color.DIM}{suffix}{Color.RESET} ").strip().lower()
        except EOFError:
            reply = ""
        if not reply:
            reply = default.lower()
        if reply in ("y", "yes"):
            return True
        if reply in ("n", "no"):
            return False


def ask_choice(prompt: str, options: list[tuple[str, str, str]]) -> str:
    print()
    print(f"{Color.BOLD}{prompt}{Color.RESET}")
    for idx, (_, label, desc) in enumerate(options, 1):
        print(f"  {Color.BOLD}{idx}){Color.RESET} {Color.BOLD}{label}{Color.RESET}")
        if desc:
            print(f"     {Color.DIM}{desc}{Color.RESET}")
    while True:
        try:
            reply = input(f"\n{Color.BOLD}>{Color.RESET} "
                          f"choose [1-{len(options)}]: ").strip()
        except EOFError:
            reply = "1"
        if reply.isdigit() and 1 <= int(reply) <= len(options):
            return options[int(reply) - 1][0]


def banner(title: str) -> None:
    width = 56
    inner = width - 2
    pad   = inner - len(title)
    lp, rp = pad // 2, pad - pad // 2
    top = "╭" + "─" * inner + "╮"
    bot = "╰" + "─" * inner + "╯"
    print()
    print(f"{Color.BOLD}{Color.CYAN}{top}{Color.RESET}")
    print(f"{Color.BOLD}{Color.CYAN}│{Color.RESET}"
          f"{' ' * lp}{Color.BOLD}{title}{Color.RESET}{' ' * rp}"
          f"{Color.BOLD}{Color.CYAN}│{Color.RESET}")
    print(f"{Color.BOLD}{Color.CYAN}{bot}{Color.RESET}")
    print()


def project_banner() -> None:
    """Display the project identity — shown on install and uninstall."""
    print(f"{Color.BOLD}{Color.MAGENTA}{PROJECT_TAGLINE}{Color.RESET}")
    print(f"{Color.DIM}{PROJECT_GITHUB}{Color.RESET}")
    print()

# ───────────────────────────── system check ────────────────────────────

def check_system() -> None:
    step("Checking system compatibility")
    if IS_WINDOWS:
        v = sys.getwindowsversion()
        if v.major < 10:
            bad(f"Windows {v.major}.{v.minor}  (need Windows 10 or later)")
            sys.exit(1)
        good(f"Windows {v.major}.{v.minor} (build {v.build})")
    elif IS_LINUX:
        release = platform.release()
        try:
            major = int(release.split(".", 1)[0])
        except ValueError:
            major = 0
        if major < 6:
            bad(f"Linux kernel {release}  (need kernel 6 or later)")
            sys.exit(1)
        good(f"Linux kernel {release}")
    else:
        bad(f"Unsupported platform: {sys.platform}")
        sys.exit(1)

# ───────────────────────────── path layout ─────────────────────────────

def install_paths() -> dict:
    if IS_WINDOWS:
        base = Path(os.environ.get(
            "LOCALAPPDATA", Path.home() / "AppData" / "Local"
        )) / "Programs" / "get"
        return {
            "root":      base,
            "binary":    base / "get.exe",
            "extra_bin": base / "bin",
            "man":       None,
            "path_dirs": [base, base / "bin"],
        }
    home  = Path.home()
    local = home / ".local"
    return {
        "root":      local / "share" / "get",
        "binary":    local / "bin" / "get",
        "extra_bin": local / "share" / "get" / "bin",
        "man":       local / "share" / "man" / "man1" / "get.1",
        "path_dirs": [local / "bin", local / "share" / "get" / "bin"],
    }


def find_installed() -> Path | None:
    paths = install_paths()
    if paths["binary"].exists():
        return paths["binary"]
    found = shutil.which("get")
    if found:
        resolved = Path(found).resolve()
        if resolved.parent != SCRIPT_DIR:
            return resolved
    return None

# ───────────────────────────── file helpers ────────────────────────────

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
        good("removed")
    except OSError as e:
        bad(f"failed: {e}")


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

# ─────────────────────────── PATH management ───────────────────────────

def _notify_env_change_windows() -> None:
    try:
        HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG = 0xFFFF, 0x1A, 0x0002
        result = ctypes.c_long()
        ctypes.windll.user32.SendMessageTimeoutW(
            HWND_BROADCAST, WM_SETTINGCHANGE, 0, "Environment",
            SMTO_ABORTIFHUNG, 5000, ctypes.byref(result),
        )
    except Exception:
        pass


def path_add_windows(dirs: Iterable[Path]) -> bool:
    import winreg
    changed = False
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment",
                        0, winreg.KEY_READ | winreg.KEY_WRITE) as k:
        try:
            current, _ = winreg.QueryValueEx(k, "Path")
        except FileNotFoundError:
            current = ""
        parts    = [p for p in current.split(";") if p]
        existing = {p.lower() for p in parts}
        for d in dirs:
            value = str(d)
            if value.lower() not in existing:
                parts.append(value)
                existing.add(value.lower())
                changed = True
        if changed:
            winreg.SetValueEx(k, "Path", 0, winreg.REG_EXPAND_SZ, ";".join(parts))
            _notify_env_change_windows()
    return changed


def path_remove_windows(dirs: Iterable[Path]) -> bool:
    import winreg
    targets = {str(d).lower() for d in dirs}
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment",
                        0, winreg.KEY_READ | winreg.KEY_WRITE) as k:
        try:
            current, _ = winreg.QueryValueEx(k, "Path")
        except FileNotFoundError:
            return False
        parts = [p for p in current.split(";") if p]
        kept  = [p for p in parts if p.lower() not in targets]
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
    home    = Path.home()
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
    home    = Path.home()
    for rc in (home / ".profile", home / ".bashrc", home / ".zshrc"):
        if not rc.exists():
            continue
        content = rc.read_text()
        if RC_MARK_BEGIN not in content:
            continue
        kept, skip = [], False
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

# ─────────────────────────────── install ───────────────────────────────

def install() -> None:
    paths   = install_paths()
    src_bin = SCRIPT_DIR / ("get.exe" if IS_WINDOWS else "get")

    if not src_bin.exists():
        fail(f"source binary not found: {src_bin}")
        sys.exit(1)

    extra_src = SCRIPT_DIR / "bin"
    has_extra = extra_src.is_dir() and any(extra_src.iterdir())

    mode = "minimal"
    if has_extra:
        mode = ask_choice(
            "Installation type",
            [
                ("full",    "Full installation",
                 "Install get, additional tools from bin/, and (Linux) man page."),
                ("minimal", "Minimal installation",
                 "Install get and (Linux) man page only."),
            ],
        )
    else:
        info("no bin/ directory found — minimal installation will be performed")

    path_dirs = paths["path_dirs"][:1] if mode == "minimal" else paths["path_dirs"]

    print()
    info("The following paths will be used:")
    print(f"     {Color.DIM}binary   :{Color.RESET} {paths['binary']}")
    if mode == "full":
        print(f"     {Color.DIM}extra bin:{Color.RESET} {paths['extra_bin']}")
    if paths["man"]:
        print(f"     {Color.DIM}man page :{Color.RESET} {paths['man']}")
    for d in path_dirs:
        print(f"     {Color.DIM}PATH  +=  {Color.RESET} {d}")
    print()

    if not ask_yes_no("Proceed with installation?"):
        info("installation cancelled")
        sys.exit(0)

    print()
    step(f"Installing binary  →  {paths['binary']}")
    copy_file(src_bin, paths["binary"])
    good("binary installed")

    if paths["man"]:
        man_src = SCRIPT_DIR / "get.1"
        if man_src.exists():
            step(f"Installing man page →  {paths['man']}")
            copy_file(man_src, paths["man"])
            good("man page installed")
        else:
            warn("get.1 not found, skipping man page")

    if mode == "full":
        step(f"Installing extras  →  {paths['extra_bin']}")
        paths["extra_bin"].mkdir(parents=True, exist_ok=True)
        count = 0
        for item in extra_src.iterdir():
            if item.is_file():
                copy_file(item, paths["extra_bin"] / item.name)
                count += 1
        good(f"installed {count} extra tool(s)")

    step("Configuring PATH")
    if add_to_path(path_dirs):
        good("PATH updated")
    else:
        good("PATH already configured")

    _finish_install(paths)


def _finish_install(paths: dict) -> None:
    print()
    banner("get is installed — enjoy! 🎉")
    project_banner()

    info("To get started, open a new terminal and run:")
    print(f"     {Color.BOLD}get version{Color.RESET}"
          f"    {Color.DIM}# verify installation{Color.RESET}")
    print(f"     {Color.BOLD}get help{Color.RESET}"
          f"       {Color.DIM}# show command help{Color.RESET}")
    if IS_LINUX:
        print(f"     {Color.BOLD}man get{Color.RESET}"
              f"        {Color.DIM}# read the manual{Color.RESET}")
    print()

    if IS_LINUX:
        info(f"current shell users can reload the PATH with:  "
             f"{Color.BOLD}source ~/.profile{Color.RESET}")
    else:
        info("open a new terminal window so the updated PATH takes effect.")

    print()
    info("To remove get later, run this script again:")
    print(f"     {Color.BOLD}python {Path(__file__).name}{Color.RESET}")
    print()

# ────────────────────────────── uninstall ──────────────────────────────

def uninstall(existing: Path) -> None:
    paths = install_paths()

    print()
    info(f"Found existing installation at: "
         f"{Color.BOLD}{existing}{Color.RESET}")
    if not ask_yes_no("Uninstall get?"):
        info("uninstall cancelled")
        sys.exit(0)

    print()
    remove_file(existing)
    if paths["binary"] != existing:
        remove_file(paths["binary"])

    if paths["extra_bin"].exists():
        step(f"Removing {paths['extra_bin']}")
        try:
            shutil.rmtree(paths["extra_bin"])
            good("extra bin removed")
        except OSError as e:
            bad(f"failed: {e}")

    if paths["man"]:
        remove_file(paths["man"])
        prune_empty_parents(paths["man"].parent, stop_at=Path.home())

    if paths["root"].exists():
        try:
            paths["root"].rmdir()
        except OSError:
            pass

    step("Cleaning PATH")
    if remove_from_path(paths["path_dirs"]):
        good("PATH cleaned")
    else:
        good("PATH already clean")

    print()
    banner("get has been uninstalled")
    project_banner()
    if IS_LINUX:
        info("restart your shell to refresh the environment.")
    else:
        info("open a new terminal so the updated PATH takes effect.")
    print()

# ─────────────────────────────── entry ─────────────────────────────────

def main() -> None:
    _enable_ansi()

    existing = find_installed()
    title    = "get uninstaller" if existing else "get installer"
    banner(title)
    project_banner()

    check_system()

    if existing:
        uninstall(existing)
    else:
        install()


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
        fail("interrupted")
        sys.exit(130)