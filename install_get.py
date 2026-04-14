#!/usr/bin/env python3
"""
get installer / uninstaller.

This script is bundled inside the release archive alongside the
get binary (and optionally the bin/ directory containing bundled
tools).  It detects the current OS and architecture, copies the
required files to the appropriate location, and configures PATH
access.

Install layout:
  Linux:   ~/.local/share/get/       (files)
           ~/.local/bin/get          (symlink)
  Windows: %LOCALAPPDATA%\\get\\       (files)
           Added to User PATH.

When get is already installed at the expected location the script
switches to uninstall mode, removing all installed files (but
preserving user configuration in ~/.config/get or %APPDATA%/get).

Requirements: Python 3.6+, no third-party packages.

Author:  WaterRun
License: AGPL-3.0
GitHub:  https://github.com/Water-Run/get
"""

import os
import platform
import shutil
import sys

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

APP_NAME = "get"

# Linux paths.
LINUX_INSTALL_DIR = os.path.expanduser("~/.local/share/get")
LINUX_BIN_LINK = os.path.expanduser("~/.local/bin/get")
LINUX_BIN_DIR = os.path.expanduser("~/.local/bin")

# Windows paths.
WINDOWS_INSTALL_DIR = os.path.join(os.environ.get("LOCALAPPDATA", ""), "get")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def is_windows():
    """Return True when running on Windows."""
    return platform.system() == "Windows"


def get_install_dir():
    """Return the platform-specific installation directory."""
    if is_windows():
        return WINDOWS_INSTALL_DIR
    return LINUX_INSTALL_DIR


def is_installed():
    """Check whether get is already installed."""
    install_dir = get_install_dir()
    if is_windows():
        return os.path.isfile(os.path.join(install_dir, "get.exe"))
    return os.path.isfile(os.path.join(install_dir, "get"))


def script_dir():
    """Return the directory containing this script."""
    return os.path.dirname(os.path.abspath(__file__))


def has_bundled_bin():
    """Check whether the release archive contains a bin/ directory."""
    return os.path.isdir(os.path.join(script_dir(), "bin"))


def get_binary_name():
    """Return the platform-specific binary name."""
    return "get.exe" if is_windows() else "get"


# ---------------------------------------------------------------------------
# Install
# ---------------------------------------------------------------------------


def install():
    """Install get to the system."""
    src = script_dir()
    dst = get_install_dir()
    binary = get_binary_name()
    binary_src = os.path.join(src, binary)

    if not os.path.isfile(binary_src):
        print("error: {} not found in {}".format(binary, src))
        sys.exit(1)

    bundled = has_bundled_bin()
    mode = "full (with bundled tools)" if bundled else "minimal"
    print("installing get ({})...".format(mode))
    print("  source:      {}".format(src))
    print("  destination: {}".format(dst))

    # Create destination directory.
    os.makedirs(dst, exist_ok=True)

    # Copy binary.
    shutil.copy2(binary_src, os.path.join(dst, binary))
    if not is_windows():
        os.chmod(os.path.join(dst, binary), 0o755)

    # Copy bin/ directory if present.
    dst_bin = os.path.join(dst, "bin")
    if bundled:
        src_bin = os.path.join(src, "bin")
        if os.path.isdir(dst_bin):
            shutil.rmtree(dst_bin)
        shutil.copytree(src_bin, dst_bin)
        # Ensure Linux binaries are executable.
        if not is_windows():
            for name in os.listdir(dst_bin):
                fpath = os.path.join(dst_bin, name)
                if os.path.isfile(fpath):
                    os.chmod(fpath, 0o755)
        print("  bundled tools installed to {}".format(dst_bin))
    else:
        print("  bin/ not found — installing without bundled tools")

    # Platform-specific PATH setup.
    if is_windows():
        _windows_add_to_path(dst)
    else:
        _linux_create_symlink()

    print()
    print("installation complete.")
    print("  run 'get help' to get started.")
    if not bundled:
        print(
            "  note: bundled tools (bat, rg, fd, ...) are not included in this install."
        )


def _linux_create_symlink():
    """Create a symlink in ~/.local/bin/ pointing to the installed binary."""
    os.makedirs(LINUX_BIN_DIR, exist_ok=True)
    target = os.path.join(LINUX_INSTALL_DIR, "get")
    link = LINUX_BIN_LINK

    if os.path.islink(link):
        os.remove(link)
    elif os.path.exists(link):
        print(
            "  warning: {} exists and is not a symlink, skipping link creation".format(
                link
            )
        )
        return

    os.symlink(target, link)
    print("  symlink: {} -> {}".format(link, target))

    # Check if ~/.local/bin is on PATH.
    path_dirs = os.environ.get("PATH", "").split(":")
    if LINUX_BIN_DIR not in path_dirs:
        print()
        print("  note: {} is not in your PATH.".format(LINUX_BIN_DIR))
        print("  add the following to your shell profile (~/.bashrc, ~/.zshrc, etc.):")
        print('    export PATH="$HOME/.local/bin:$PATH"')


def _windows_add_to_path(install_dir):
    """Add the install directory to the Windows User PATH."""
    try:
        import winreg

        key = winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Environment",
            0,
            winreg.KEY_ALL_ACCESS,
        )
        try:
            current, _ = winreg.QueryValueEx(key, "Path")
        except FileNotFoundError:
            current = ""

        paths = [p.strip() for p in current.split(";") if p.strip()]
        if install_dir not in paths:
            paths.append(install_dir)
            new_path = ";".join(paths)
            winreg.SetValueEx(key, "Path", 0, winreg.REG_EXPAND_SZ, new_path)
            print("  added {} to User PATH".format(install_dir))
            # Broadcast environment change.
            try:
                import ctypes

                HWND_BROADCAST = 0xFFFF
                WM_SETTINGCHANGE = 0x001A
                ctypes.windll.user32.SendMessageTimeoutW(
                    HWND_BROADCAST,
                    WM_SETTINGCHANGE,
                    0,
                    "Environment",
                    0x0002,
                    5000,
                    None,
                )
            except Exception:
                pass
            print(
                "  note: you may need to restart your terminal "
                "for PATH changes to take effect"
            )
        else:
            print("  {} is already in User PATH".format(install_dir))
        winreg.CloseKey(key)
    except ImportError:
        print(
            "  note: could not modify PATH automatically. "
            "Please add {} to your PATH manually.".format(install_dir)
        )


# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------


def uninstall():
    """Uninstall get from the system."""
    install_dir = get_install_dir()
    print("get is already installed at: {}".format(install_dir))
    print()
    try:
        answer = input("uninstall? (y/N): ").strip().lower()
    except (EOFError, KeyboardInterrupt):
        print("\naborted.")
        return
    if answer != "y":
        print("aborted.")
        return

    print("uninstalling...")

    # Remove symlink (Linux).
    if not is_windows():
        if os.path.islink(LINUX_BIN_LINK):
            os.remove(LINUX_BIN_LINK)
            print("  removed symlink: {}".format(LINUX_BIN_LINK))

    # Remove install directory.
    if os.path.isdir(install_dir):
        shutil.rmtree(install_dir)
        print("  removed: {}".format(install_dir))

    # Remove from PATH (Windows).
    if is_windows():
        _windows_remove_from_path(install_dir)

    print()
    print("uninstall complete.")
    print("  note: configuration files were preserved.")
    if is_windows():
        config_dir = os.path.join(os.environ.get("APPDATA", ""), "get")
    else:
        config_dir = os.path.expanduser("~/.config/get")
    print("  to remove config: delete {}".format(config_dir))


def _windows_remove_from_path(install_dir):
    """Remove the install directory from the Windows User PATH."""
    try:
        import winreg

        key = winreg.OpenKey(
            winreg.HKEY_CURRENT_USER,
            r"Environment",
            0,
            winreg.KEY_ALL_ACCESS,
        )
        try:
            current, _ = winreg.QueryValueEx(key, "Path")
        except FileNotFoundError:
            winreg.CloseKey(key)
            return

        paths = [p.strip() for p in current.split(";") if p.strip()]
        if install_dir in paths:
            paths.remove(install_dir)
            new_path = ";".join(paths)
            winreg.SetValueEx(key, "Path", 0, winreg.REG_EXPAND_SZ, new_path)
            print("  removed {} from User PATH".format(install_dir))
        winreg.CloseKey(key)
    except ImportError:
        print(
            "  note: could not modify PATH automatically. "
            "Please remove {} from your PATH manually.".format(install_dir)
        )


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    """Entry point: install or uninstall based on current state."""
    print("get installer v1.0.0")
    print("platform: {} {}".format(platform.system(), platform.machine()))
    print()

    if is_installed():
        uninstall()
    else:
        install()


if __name__ == "__main__":
    main()
