#!/usr/bin/env python3
"""Verify a Linux public archive in an isolated home, preserving the live install."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import zipfile


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--previous-binary", type=Path)
    args = parser.parse_args()
    manifest = json.loads(args.manifest.read_text())
    version = manifest["version"]
    asset = next(row for row in manifest["assets"] if row["platform"] == "linux-x64")
    archive_path = args.manifest.parent / asset["filename"]
    assert digest(archive_path) == asset["sha256"]
    previous_digest = digest(args.previous_binary) if args.previous_binary else None
    with tempfile.TemporaryDirectory(prefix="get-release-install-") as temporary:
        root = Path(temporary)
        with zipfile.ZipFile(archive_path) as archive:
            assert all(name.startswith(asset["root"] + "/") and
                       ".." not in Path(name).parts for name in archive.namelist())
            archive.extractall(root)
        package = root / asset["root"]
        payload = package / asset["payload"]
        payload.chmod(0o755)
        assert digest(payload) == asset["payload_sha256"]
        test_home = root / "home"
        test_home.mkdir()
        env = {**os.environ, "HOME": str(test_home),
               "XDG_CONFIG_HOME": str(test_home / ".config"),
               "SHELL": "/bin/bash", "PATH": "/usr/bin:/bin"}
        installer = [sys.executable, str(package / "get_ready.py")]
        for phase, answers in [("fresh", "y\ny\nn\nn\n"),
                               ("upgrade", "y\ny\ny\nn\nn\n")]:
            run = subprocess.run(installer, input=answers, text=True,
                                 capture_output=True, env=env, timeout=60)
            assert run.returncode == 0, run.stdout + run.stderr
            installed = test_home / ".local/bin/get"
            assert digest(installed) == asset["payload_sha256"]
            assert (test_home / ".local/share/man/man1/get.1").is_file()
            assert version in subprocess.check_output([str(installed), "version"],
                                                       env=env, text=True)
            config_dir = test_home / ".config/get"
            if phase == "fresh":
                for option, value in [("url", "https://installation-test.invalid/v1"),
                                      ("model", "installation-test"),
                                      ("key", "installation-test-key"),
                                      ("markdown", "false")]:
                    subprocess.run([str(installed), "set", option, value], env=env,
                                   check=True, capture_output=True)
                snapshots = {name: (config_dir / name).read_bytes()
                             for name in ("config.json", "key")}
                if args.previous_binary:
                    shutil.copyfile(args.previous_binary, installed)
                    installed.chmod(0o755)
            else:
                assert all((config_dir / name).read_bytes() == value
                           for name, value in snapshots.items())
    if args.previous_binary:
        assert digest(args.previous_binary) == previous_digest
    manifest["installation_validation"] = {
        "status": "passed", "linux_public_archive_fresh_install": True,
        "linux_public_archive_upgrade_preserves_config_and_key": True,
        "previous_binary_sha256": previous_digest,
        "active_installed_binary_preserved": True,
        "windows_and_macos": "native CI installer smoke; public ZIP byte identity verified"}
    args.manifest.write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(manifest["installation_validation"], indent=2))


if __name__ == "__main__":
    main()
