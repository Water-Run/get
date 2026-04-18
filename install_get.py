#!/usr/bin/env python3
"""
install_get.py — installer / uninstaller for `get`.

Layout expected next to this script:
    install_get.py
    get            (Linux binary)
    get.exe        (Windows binary)
    get.1          (Linux man page)
    bin/           (optional, extra tools)

No external dependencies. Python 3.12+.
"""
from __future__ import annotations

import os
import sys
import shutil
import platform
from pathlib import Path

# ────────────────────────────── constants ──────────────────────────────

IS_WINDOWS = os.name == "nt"
IS_LINUX   = sys.platform.startswith("linux")
SCRIPT_DIR = Path(__file__).resolve().parent

MARK_BEGIN = "# >>> get installer >>>"
MARK_END   = "# <<< get installer <<<"

# ─────────────────────────────── styling ───────────────────────────────

class C:
    RESET = "\033[0m"
    BOLD  = "\033[1m"
    DIM   = "\033[2m"
    RED   = "\033[31m"
    GREEN = "\033[32m"
    YELLOW= "\033[33m"
    BLUE  = "\033[34m"
    MAG   = "\033[35m"
    CYAN  = "\033[36m"

def _strip_colors() -> None:
    for k in list(vars(C)):
        if not k.startswith("_"):
            setattr(C, k, "")

def _enable_ansi() -> None:
    if not sys.stdout.isatty():
        _strip_colors()
        return
    if IS_WINDOWS:
        try:
            import ctypes
            k = ctypes.windll.kernel32
            h = k.GetStdHandle(-11)
            m = ctypes.c_ulong()
            k.GetConsoleMode(h, ctypes.byref(m))
            k.SetConsoleMode(h, m.value | 0x0004)  # ENABLE_VIRTUAL_TERMINAL_PROCESSING
        except Exception:
            _strip_colors()

def info(msg: str) -> None:  print(f"{C.BOLD}{C.CYAN}info:{C.RESET} {msg}")
def warn(msg: str) -> None:  print(f"{C.BOLD}{C.YELLOW}warn:{C.RESET} {msg}")
def err(msg: str)  -> None:  print(f"{C.BOLD}{C.RED}error:{C.RESET} {msg}", file=sys.stderr)
def step(msg: str) -> None:  print(f"  {C.BOLD}{C.BLUE}»{C.RESET} {msg}")
def ok(msg: str)   -> None:  print(f"  {C.BOLD}{C.GREEN}✓{C.RESET} {msg}")
def ko(msg: str)   -> None:  print(f"  {C.BOLD}{C.RED}✗{C.RESET} {msg}")

def ask(prompt: str, default: str = "y") -> bool:
    suffix = "[Y/n]" if default.lower() == "y" else "[y/N]"
    while True:
        try:
            a = input(f"{C.BOLD}?{C.RESET} {prompt} {C.DIM}{suffix}{C.RESET} ").strip().lower()
        except EOFError:
            a = ""
        if not a:
            a = default.lower()
        if a in ("y", "yes"): return True
        if a in ("n", "no"):  return False

def choose(prompt: str, options: list[tuple[str, str, str]]) -> str:
    print()
    print(f"{C.BOLD}{prompt}{C.RESET}")
    for i, (_, label, desc) in enumerate(options, 1):
        print(f"  {C.BOLD}{i}){C.RESET} {C.BOLD}{label}{C.RESET}")
        if desc:
            print(f"     {C.DIM}{desc}{C.RESET}")
    while True:
        try:
            a = input(f"\n{C.BOLD}>{C.RESET} choose [1-{len(options)}]: ").strip()
        except EOFError:
            a = "1"
        if a.isdigit() and 1 <= int(a) <= len(options):
            return options[int(a) - 1][0]

def banner(title: str) -> None:
    width = 56
    inner = width - 2
    pad   = inner - len(title)
    lp, rp = pad // 2, pad - pad // 2
    top = "╭" + "─" * inner + "╮"
    bot = "╰" + "─" * inner + "╯"
    print()
    print(f"{C.BOLD}{C.CYAN}{top}{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}│{C.RESET}{' ' * lp}{C.BOLD}{title}{C.RESET}{' ' * rp}{C.BOLD}{C.CYAN}│{C.RESET}")
    print(f"{C.BOLD}{C.CYAN}{bot}{C.RESET}")
    print()

# ───────────────────────────── system check ────────────────────────────

def check_system() -> None:
    step("Checking system compatibility")
    if IS_WINDOWS:
        v = sys.getwindowsversion()
        if v.major < 10:
            ko(f"Windows {v.major}.{v.minor}  (need Windows 10 or later)")
            sys.exit(1)
        ok(f"Windows {v.major}.{v.minor} (build {v.build})")
    elif IS_LINUX:
        rel = platform.release()
        try:
            major = int(rel.split(".", 1)[0])
        except ValueError:
            major = 0
        if major < 6:
            ko(f"Linux kernel {rel}  (need kernel 6 or later)")
            sys.exit(1)
        ok(f"Linux kernel {rel}")
    else:
        ko(f"Unsupported platform: {sys.platform}")
        sys.exit(1)

# ───────────────────────────── path layout ─────────────────────────────

def install_paths() -> dict:
    if IS_WINDOWS:
        base = Path(os.environ.get("LOCALAPPDATA",
                                   Path.home() / "AppData" / "Local")) / "Programs" / "get"
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

def find_installed() -> Path | None:
    p = install_paths()
    if p["binary"].exists():
        return p["binary"]
    found = shutil.which("get")
    if found:
        fp = Path(found).resolve()
        # Ignore the copy that lives next to this script.
        if fp.parent != SCRIPT_DIR:
            return fp
    return None

# ───────────────────────────── file helpers ────────────────────────────

def copy_file(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)
    if not IS_WINDOWS:
        os.chmod(dst, 0o755)

# ─────────────────────────── PATH management ───────────────────────────

def _notify_env_change_windows() -> None:
    try:
        import ctypes
        HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG = 0xFFFF, 0x1A, 0x0002
        res = ctypes.c_long()
        ctypes.windll.user32.SendMessageTimeoutW(
            HWND_BROADCAST, WM_SETTINGCHANGE, 0, "Environment",
            SMTO_ABORTIFHUNG, 5000, ctypes.byref(res),
        )
    except Exception:
        pass

def path_add_windows(dirs: list[Path]) -> bool:
    import winreg
    changed = False
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment",
                        0, winreg.KEY_READ | winreg.KEY_WRITE) as k:
        try:
            cur, _ = winreg.QueryValueEx(k, "Path")
        except FileNotFoundError:
            cur = ""
        parts = [p for p in cur.split(";") if p]
        low = {p.lower() for p in parts}
        for d in dirs:
            s = str(d)
            if s.lower() not in low:
                parts.append(s)
                low.add(s.lower())
                changed = True
        if changed:
            winreg.SetValueEx(k, "Path", 0, winreg.REG_EXPAND_SZ, ";".join(parts))
            _notify_env_change_windows()
    return changed

def path_remove_windows(dirs: list[Path]) -> bool:
    import winreg
    rm = {str(d).lower() for d in dirs}
    with winreg.OpenKey(winreg.HKEY_CURRENT_USER, "Environment",
                        0, winreg.KEY_READ | winreg.KEY_WRITE) as k:
        try:
            cur, _ = winreg.QueryValueEx(k, "Path")
        except FileNotFoundError:
            return False
        parts = [p for p in cur.split(";") if p]
        new = [p for p in parts if p.lower() not in rm]
        if len(new) == len(parts):
            return False
        winreg.SetValueEx(k, "Path", 0, winreg.REG_EXPAND_SZ, ";".join(new))
        _notify_env_change_windows()
    return True

def path_add_linux(dirs: list[Path]) -> bool:
    lines = [MARK_BEGIN]
    for d in dirs:
        lines.append(
            f'case ":$PATH:" in *":{d}:"*) ;; *) export PATH="{d}:$PATH" ;; esac'
        )
    lines.append(MARK_END)
    block = "\n" + "\n".join(lines) + "\n"

    changed = False
    home = Path.home()
    for rc in (home / ".profile", home / ".bashrc", home / ".zshrc"):
        if not rc.exists() and rc.name != ".profile":
            continue
        content = rc.read_text() if rc.exists() else ""
        if MARK_BEGIN in content:
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
        if MARK_BEGIN not in content:
            continue
        out, skip = [], False
        for line in content.splitlines(keepends=True):
            if MARK_BEGIN in line:
                skip = True
                continue
            if MARK_END in line:
                skip = False
                continue
            if not skip:
                out.append(line)
        # trim orphan blank lines at end
        text = "".join(out).rstrip() + "\n"
        rc.write_text(text)
        changed = True
    return changed

def add_to_path(dirs: list[Path]) -> bool:
    return path_add_windows(dirs) if IS_WINDOWS else path_add_linux(dirs)

def remove_from_path(dirs: list[Path]) -> bool:
    return path_remove_windows(dirs) if IS_WINDOWS else path_remove_linux()

# ─────────────────────────────── install ───────────────────────────────

def install() -> None:
    paths = install_paths()

    src_bin = SCRIPT_DIR / ("get.exe" if IS_WINDOWS else "get")
    if not src_bin.exists():
        err(f"source binary not found: {src_bin}")
        sys.exit(1)

    extra_src = SCRIPT_DIR / "bin"
    has_extra = extra_src.is_dir() and any(extra_src.iterdir())

    mode = "minimal"
    if has_extra:
        mode = choose(
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
    print(f"     {C.DIM}binary   :{C.RESET} {paths['binary']}")
    if mode == "full":
        print(f"     {C.DIM}extra bin:{C.RESET} {paths['extra_bin']}")
    if paths["man"]:
        print(f"     {C.DIM}man page :{C.RESET} {paths['man']}")
    for d in path_dirs:
        print(f"     {C.DIM}PATH  +=  {C.RESET} {d}")
    print()

    if not ask("Proceed with installation?"):
        info("installation cancelled")
        sys.exit(0)

    print()
    step(f"Installing binary  →  {paths['binary']}")
    copy_file(src_bin, paths["binary"])
    ok("binary installed")

    if paths["man"]:
        man_src = SCRIPT_DIR / "get.1"
        if man_src.exists():
            step(f"Installing man page →  {paths['man']}")
            copy_file(man_src, paths["man"])
            ok("man page installed")
        else:
            warn("get.1 not found, skipping man page")

    if mode == "full":
        step(f"Installing extras  →  {paths['extra_bin']}")
        paths["extra_bin"].mkdir(parents=True, exist_ok=True)
        n = 0
        for item in extra_src.iterdir():
            if item.is_file():
                copy_file(item, paths["extra_bin"] / item.name)
                n += 1
        ok(f"installed {n} extra tool(s)")

    step("Configuring PATH")
    if add_to_path(path_dirs):
        ok("PATH updated")
    else:
        ok("PATH already configured")

    _finish_install(paths)

def _finish_install(paths: dict) -> None:
    print()
    banner("get is installed — enjoy! 🎉")

    info("To get started, open a new terminal and run:")
    print(f"     {C.BOLD}get version{C.RESET}    {C.DIM}# verify installation{C.RESET}")
    print(f"     {C.BOLD}get help{C.RESET}       {C.DIM}# show command help{C.RESET}")
    if IS_LINUX:
        print(f"     {C.BOLD}man get{C.RESET}        {C.DIM}# read the manual{C.RESET}")
    print()

    if IS_LINUX:
        info(f"current shell users can reload the PATH with:  "
             f"{C.BOLD}source ~/.profile{C.RESET}")
    else:
        info("open a new terminal window so the updated PATH takes effect.")

    print()
    info(f"To remove get later, run this script again:")
    print(f"     {C.BOLD}python {Path(__file__).name}{C.RESET}")
    print()

# ────────────────────────────── uninstall ──────────────────────────────

def uninstall(existing: Path) -> None:
    paths = install_paths()

    print()
    info(f"Found existing installation at: {C.BOLD}{existing}{C.RESET}")
    if not ask("Uninstall get?"):
        info("uninstall cancelled")
        sys.exit(0)

    print()
    _try_remove_file(existing)
    if paths["binary"] != existing:
        _try_remove_file(paths["binary"])

    if paths["extra_bin"].exists():
        step(f"Removing {paths['extra_bin']}")
        try:
            shutil.rmtree(paths["extra_bin"])
            ok("extra bin removed")
        except OSError as e:
            ko(f"failed: {e}")

    if paths["man"]:
        _try_remove_file(paths["man"])
        _try_remove_empty_parents(paths["man"].parent, stop_at=Path.home())

    if paths["root"].exists():
        try:
            # remove only if empty
            paths["root"].rmdir()
        except OSError:
            pass

    step("Cleaning PATH")
    if remove_from_path(paths["path_dirs"]):
        ok("PATH cleaned")
    else:
        ok("PATH already clean")

    print()
    banner("get has been uninstalled")
    if IS_LINUX:
        info("restart your shell to refresh the environment.")
    else:
        info("open a new terminal so the updated PATH takes effect.")
    print()

def _try_remove_file(p: Path) -> None:
    if not p.exists():
        return
    step(f"Removing {p}")
    try:
        p.unlink()
        ok("removed")
    except OSError as e:
        ko(f"failed: {e}")

def _try_remove_empty_parents(start: Path, stop_at: Path) -> None:
    cur = start
    try:
        stop_at = stop_at.resolve()
    except OSError:
        return
    while cur.exists() and cur.resolve() != stop_at:
        try:
            cur.rmdir()
        except OSError:
            break
        cur = cur.parent

# ─────────────────────────────── entry ─────────────────────────────────

def main() -> None:
    _enable_ansi()

    existing = find_installed()
    title = "get uninstaller" if existing else "get installer"
    banner(title)

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
        err("interrupted")
        sys.exit(130)