#!/usr/bin/env python3
"""Replay a small set of observable user tasks with any compatible provider.

Select the exact development/CI binary with --binary. Connection settings may
be read from --provider-config; all test state is written to a temporary root.
The model identifier is passed through unchanged, without name-based rules.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def json_answer(output: str):
    decoder = json.JSONDecoder()
    for index, char in enumerate(output):
        if char == "{":
            try:
                value, _ = decoder.raw_decode(output[index:])
                return value
            except ValueError:
                pass
    raise ValueError("answer did not contain a JSON object")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--provider-config", type=Path)
    parser.add_argument("--url")
    parser.add_argument("--model")
    parser.add_argument("--shell", default="bash")
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--real-project", type=Path)
    args = parser.parse_args()
    binary = args.binary.resolve(strict=True)
    settings = {}
    preserved = {}
    key = os.environ.get("GET_TEST_API_KEY", "")
    if args.provider_config:
        settings = json.loads((args.provider_config / "config.json").read_text())
        for name in ("config.json", "key"):
            path = args.provider_config / name
            preserved[path] = digest(path)
        if not key:
            key = (args.provider_config / "key").read_text().strip()
    url = args.url or settings.get("url", "")
    model = args.model or settings.get("model", "")
    if not key or not url or not model:
        parser.error("provide URL, model and GET_TEST_API_KEY or --provider-config")
    payload_digest = digest(binary)
    started = time.monotonic()
    cases = []
    with tempfile.TemporaryDirectory(prefix="get-replay-") as temporary:
        root = Path(temporary)
        work = root / "project"
        work.mkdir()
        for name in ["src/main.rs", "src/lib.rs", "src/app.py", "src/util.py",
                     "src/auth.py", "src/main.nim"]:
            path = work / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("// fixture\n" if name.endswith("rs") else "# fixture\n")
        (work / "src/auth.py").write_text(
            'def verify_user(enabled, token):\n'
            '    return enabled and token == "replay-marker"\n')
        (work / "README.md").write_text("# Mixed language project\n")
        for directory in ("systems/one/build", "systems/two/.venv",
                          "systems/three/node_modules", "systems/four/_deps",
                          "systems/five/target"):
            path = work / directory
            path.mkdir(parents=True)
            for index in range(12):
                (path / f"generated-{index}.py").write_text("# generated\n")
        config_root = root / "config"
        config_dir = config_root / "get"
        config_dir.mkdir(parents=True)
        config = {"schemaVersion": 3, "url": url, "model": model,
                  "shell": args.shell, "harness": "auto", "toolProtocol": "auto",
                  "hideProcess": True, "vivid": False, "markdown": False,
                  "cache": False, "log": True, "maxRounds": 3,
                  "maxToolCalls": 8, "maxParallel": 4,
                  "commandTimeout": 30, "maxOutputBytes": 1048576}
        (config_dir / "config.json").write_text(json.dumps(config))
        key_path = config_dir / "key"
        key_path.touch(mode=0o600)
        key_path.write_text(key)
        env = dict(os.environ, XDG_CONFIG_HOME=str(config_root),
                   GET_REPLAY_LABEL="replay-environment-marker")
        env.pop("GET_TEST_API_KEY", None)
        if os.name == "nt":
            env["APPDATA"] = str(config_root)
        version = subprocess.check_output([str(binary), "version"], env=env,
                                          text=True).strip()
        tasks = [
            ("code_composition", "统计项目中 rs、py、nim 三种源代码扩展名的文件数，"
             "排除各层构建、依赖和虚拟环境目录。只返回以 rs、py、nim 为键、文件数为值的 JSON 对象，"
             "必须实际检查后填写。", {"rs": 2, "py": 3, "nim": 1}, []),
            ("code_lookup", "读取 src/auth.py，说明 verify_user 的两个通过条件。"
             "只返回 JSON {\"enabled_required\":true,\"token\":\"实际值\"}。",
             {"enabled_required": True, "token": "replay-marker"}, []),
            ("environment", "读取 GET_REPLAY_LABEL 环境变量，只返回 JSON {\"value\":\"实际值\"}。",
             {"value": "replay-environment-marker"}, []),
            ("no_match", "查找 src 里字面字符串 ABSENT_REPLAY_NEEDLE 的匹配行数。"
             "只返回 JSON {\"matches\":整数}。", {"matches": 0}, []),
            ("answer_budget", "读取 src/auth.py 中的 token 常量，"
             "只返回 JSON {\"token\":\"实际值\"}。", {"token": "replay-marker"},
             []),
            ("code_answer", "不调用工具，给出一个 Python 两数相加函数示例。"
             "函数名为 add，使用 Markdown 代码块。", None, []),
        ]
        if Path("/proc/meminfo").is_file():
            memory = int(next(line.split()[1] for line in
                             Path("/proc/meminfo").read_text().splitlines()
                             if line.startswith("MemTotal:")))
            tasks.append(("system_memory", "读取 /proc/meminfo 中的 MemTotal，"
                          "只返回 JSON {\"MemTotal_kB\":整数}。",
                          {"MemTotal_kB": memory}, []))
        for name, query, expected, flags in tasks:
            config["maxRounds"] = 1 if name == "answer_budget" else 3
            config["maxToolCalls"] = 1 if name == "answer_budget" else 8
            (config_dir / "config.json").write_text(json.dumps(config))
            log_path = config_dir / "get.log"
            if log_path.exists():
                log_path.unlink()
            case_started = time.monotonic()
            result = subprocess.run([str(binary), query, "--no-cache", *flags],
                                    cwd=work, env=env, capture_output=True,
                                    text=True, timeout=180)
            log = log_path.read_text() if log_path.exists() else ""
            commands = [json.loads(line.split("] command: ", 1)[1])
                        for line in log.splitlines() if "] command: " in line]
            actual_commands = [value for value in commands if value != "(none)"]
            exit_codes = [int(line.split("] exit: ", 1)[1])
                          for line in log.splitlines() if "] exit: " in line]
            try:
                valid = (json_answer(result.stdout) == expected if expected is not None
                         else "def add(" in result.stdout and not actual_commands)
                passed = result.returncode == 0 and valid
                if expected is not None:
                    passed = passed and bool(actual_commands) and 0 in exit_codes
            except ValueError:
                passed = False
            row = {"name": name, "passed": passed, "exit_code": result.returncode,
                   "tool_observations": len(actual_commands),
                   "seconds": round(time.monotonic() - case_started, 2)}
            cases.append(row)
            print(json.dumps(row), flush=True)
            if not passed:
                # Provider outputs stay in a local diagnostic file, never in the
                # public attestation; queries can refer to private source code.
                args.report.with_suffix(f".{name}.log").write_text(
                    result.stdout + "\n" + result.stderr + "\n" + log)
        if args.real_project:
            result = subprocess.run([str(binary), "项目的语言组成", "--no-cache"],
                                    cwd=args.real_project, env=env, capture_output=True,
                                    text=True, timeout=240)
            answer = result.stdout.lower()
            passed = result.returncode == 0 and len(answer) > 100 and sum(
                language in answer for language in ("rust", "python", "c#", "java", "c++")) >= 3
            cases.append({"name": "real_project_composition", "passed": passed,
                          "exit_code": result.returncode,
                          "verification": "successful answer naming at least three observed languages"})
            args.report.with_suffix(".real-project.log").write_text(
                result.stdout + "\n" + result.stderr)
            print(json.dumps(cases[-1]), flush=True)
    preserved_ok = all(digest(path) == value for path, value in preserved.items())
    assert digest(binary) == payload_digest
    report = {"schema_version": 1, "version": version.removeprefix("get "),
              "status": "passed" if all(row["passed"] for row in cases) and preserved_ok else "failed",
              "linux_payload_sha256": payload_digest,
              "providers": {"configured": {"model": model, "replay": {
                  "expected": len(cases), "passed": sum(row["passed"] for row in cases),
                  "failed": sum(not row["passed"] for row in cases), "skipped": 0}}},
              "cases": cases, "live_configuration_preserved": preserved_ok,
              "elapsed_seconds": round(time.monotonic() - started, 2)}
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
