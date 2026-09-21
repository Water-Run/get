#!/usr/bin/env python3
"""Run native validation in an isolated source snapshot, with serial compilations."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import sys
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--nim', required=True)
    parser.add_argument('--shell', default='powershell' if os.name == 'nt' else 'bash')
    parser.add_argument('--tests', nargs='*')
    parser.add_argument('--skip-cli', action='store_true')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    output = root / '.ci' / 'native'
    output.mkdir(parents=True, exist_ok=True)
    extension = '.exe' if os.name == 'nt' else ''
    report = {'platform': platform.platform(), 'compiler': args.nim, 'started': time.time(), 'checks': []}

    def record(name, command, timeout=900, env=None):
        started = time.monotonic()
        with (output / (name + '.log')).open('w', encoding='utf-8') as log:
            try:
                run = subprocess.run(command, cwd=root, stdout=log, stderr=subprocess.STDOUT,
                                     timeout=timeout, env=env)
                code = run.returncode
            except subprocess.TimeoutExpired:
                code = 124
        report['checks'].append({'name': name, 'code': code, 'seconds': time.monotonic() - started})
        (output / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
        print(name, code, flush=True)
        return code == 0

    files = [root / 'tests' / (test + '.nim') for test in args.tests] if args.tests else sorted((root / 'tests').glob('test_*.nim'))
    for source in files:
        name = source.stem
        binary = output / (name + extension)
        built = record(name + '-build', [sys.executable, 'scripts/build_local.py', '--validation-host', str(source),
                       '--out', str(binary), '--nim', args.nim])
        if built:
            record(name, [str(binary)], timeout=300)
    binary = output / ('get' + extension)
    if record('get-build', [sys.executable, 'scripts/build_local.py', '--validation-host', 'src/get.nim',
                           '--out', str(binary), '--nim', args.nim]):
        report['binary_sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        record('version', [str(binary), '--version'])
        if not args.skip_cli:
            env = os.environ.copy()
            env.update(GET_V3_BINARY=str(binary), GET_V3_TEST_SHELL=args.shell,
                       GET_V3_TARGET_OS=platform.system().lower())
            record('cli', [sys.executable, 'tests/test_cli_v3.py', '-v'], timeout=2400, env=env)
    report['finished'] = time.time()
    (output / 'report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    return int(any(check['code'] for check in report['checks']))


if __name__ == '__main__':
    raise SystemExit(main())
