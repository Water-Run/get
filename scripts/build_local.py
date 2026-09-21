#!/usr/bin/env python3
"""Build one development target under .ci without overloading the desktop."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("--out", required=True, type=Path)
    parser.add_argument("--nim", default=os.environ.get("GET_NIM", "nim"))
    parser.add_argument("--run", action="store_true")
    parser.add_argument("--validation-host", action="store_true",
                        help="allow a remote test kernel without PSI counters")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    destination = args.out.resolve()
    if not destination.is_relative_to(root / ".ci"):
        parser.error("development executables must be inside .ci/")
    destination.parent.mkdir(parents=True, exist_ok=True)
    lock_file = (root / ".ci" / "local-build.lock").open("a")
    if sys.platform.startswith("linux"):
        import fcntl
        try:
            fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            parser.error("another local compilation is running")
        available = next(int(line.split()[1]) for line in
                         Path("/proc/meminfo").read_text().splitlines()
                         if line.startswith("MemAvailable:"))
        pressure_path = Path("/proc/pressure/memory")
        if not pressure_path.exists() and args.validation_host:
            print("remote validation kernel has no PSI memory counters", file=sys.stderr)
            pressure = 0
        else:
            pressure = next(float(word.split("=")[1]) for line in
                            pressure_path.read_text().splitlines()
                            if line.startswith("full ") for word in line.split()
                            if word.startswith("avg10="))
        if available < 6 * 1024 * 1024 or pressure >= 2:
            parser.error("memory constraint: defer compilation to CI")
    compiler = shutil.which(args.nim)
    if not compiler:
        parser.error(f"Nim compiler not found: {args.nim}")
    command = (["nice", "-n", "10"] if sys.platform.startswith("linux") else [])
    command += [compiler, "c", "-d:release"]
    if args.source.name != "get.nim":
        command.append("-d:getTest")
    command += ["--parallelBuild:1",
                "--path:src", f"--nimcache:{destination.parent / (destination.name + '-cache')}",
                f"--out:{destination}", str(args.source)]
    result = subprocess.run(command, cwd=root)
    if result.returncode == 0 and args.run:
        result = subprocess.run([str(destination)], cwd=root)
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
