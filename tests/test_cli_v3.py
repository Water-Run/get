#!/usr/bin/env python3
"""End-to-end tests for the get v3 CLI against a local mock provider."""

from __future__ import annotations

import os
import hashlib
import json
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

from mock_openai_provider import (
    ADVERSARIAL_COMMANDS,
    Handler,
    ProxyHandler,
)
from http.server import ThreadingHTTPServer


class GetV3CliTests(unittest.TestCase):
    """Exercise native, fallback, safety, budget, and cache CLI paths."""

    @classmethod
    def setUpClass(cls) -> None:
        configured = os.environ.get("GET_V3_BINARY", "")
        cls.binary = Path(configured) if configured else Path("./get")
        if not cls.binary.is_file():
            raise unittest.SkipTest(
                "set GET_V3_BINARY to a compiled get v3 executable")
        cls.binary = cls.binary.resolve()
        runner = shlex.split(os.environ.get("GET_V3_RUNNER", ""))
        cls.command = [*runner, str(cls.binary)]
        cls.target_os = os.environ.get(
            "GET_V3_TARGET_OS",
            "windows" if os.name == "nt" else "linux",
        ).lower()
        cls.root = Path(tempfile.mkdtemp(prefix="get_v3_cli_"))
        cls.work = cls.root / "work"
        cls.work.mkdir()
        cls.config_root = Path(os.environ.get(
            "GET_V3_CONFIG_ROOT", str(cls.root / "config")))
        cls.env = os.environ.copy()
        cls.env["XDG_CONFIG_HOME"] = str(cls.config_root)
        if cls.target_os == "windows":
            cls.env["APPDATA"] = str(cls.config_root)
        cls.env["NO_PROXY"] = "127.0.0.1,localhost"
        cls.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        cls.server_thread = threading.Thread(
            target=cls.server.serve_forever,
            daemon=True,
        )
        cls.server_thread.start()
        port = cls.server.server_address[1]
        cls.proxy_server = ThreadingHTTPServer(
            ("127.0.0.1", 0), ProxyHandler)
        cls.proxy_thread = threading.Thread(
            target=cls.proxy_server.serve_forever,
            daemon=True,
        )
        cls.proxy_thread.start()
        cls.proxy_port = cls.proxy_server.server_address[1]
        for args in [
            ("set", "key", "test-key"),
            ("set", "url", f"http://127.0.0.1:{port}/v1"),
            ("set", "model", "mock"),
            ("set", "shell", os.environ.get(
                "GET_V3_TEST_SHELL",
                "powershell" if cls.target_os == "windows" else "bash")),
            ("set", "vivid", "false"),
            ("set", "hide-process", "true"),
            ("set", "log", "false"),
            ("set", "cache", "true"),
        ]:
            result = cls.run_get(*args)
            if result.returncode != 0:
                raise RuntimeError(result.stderr)

    @classmethod
    def tearDownClass(cls) -> None:
        if cls.server_thread.is_alive():
            cls.server.shutdown()
            cls.server.server_close()
            cls.server_thread.join(timeout=2)
        if cls.proxy_thread.is_alive():
            cls.proxy_server.shutdown()
            cls.proxy_server.server_close()
            cls.proxy_thread.join(timeout=2)
        shutil.rmtree(cls.root, ignore_errors=True)

    @classmethod
    def run_get(
        cls,
        *args: str,
        env_override: dict[str, str] | None = None,
    ) -> subprocess.CompletedProcess[str]:
        """Run the compiled CLI in its isolated config and working directory."""

        env = cls.env.copy()
        if env_override:
            env.update(env_override)
        return subprocess.run(
            [*cls.command, *args],
            cwd=cls.work,
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
            encoding="utf-8",
            errors="replace",
            check=False,
        )

    def test_01_native_terminal_call(self) -> None:
        result = self.run_get("native cli")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "native-ok")

    def test_02_native_continuation(self) -> None:
        result = self.run_get("continue cli", "--no-cache")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "continued-ok")

    def test_02b_explicit_no_tools_is_enforced_in_the_request(self) -> None:
        result = self.run_get(
            "Explicit no tools: without calling a tool, answer directly",
            "--no-cache",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "no-tools-ok")

    def test_03_automatic_protocol_fallback(self) -> None:
        result = self.run_get("fallback cli", "--no-cache")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "fallback-ok")

    def test_04_parallel_native_calls(self) -> None:
        result = self.run_get(
            "parallel cli", "--harness", "parallel", "--no-cache")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("parallel-a", result.stdout)
        self.assertIn("parallel-b", result.stdout)

    def test_04b_qwen_textual_tool_call(self) -> None:
        result = self.run_get("qwen textual cli", "--no-cache")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "qwen-text-ok")

    def test_05_mandatory_policy_blocks_redirection(self) -> None:
        result = self.run_get("unsafe policy cli", "--no-cache")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("read-only policy", result.stderr.lower())
        self.assertFalse((self.work / "never-run").exists())

    def test_05b_textual_tool_call_cannot_bypass_policy(self) -> None:
        result = self.run_get("qwen textual unsafe cli", "--no-cache")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("read-only policy", result.stderr.lower())
        self.assertFalse((self.work / "never-run").exists())

    def test_05c_adversarial_commands_fail_closed(self) -> None:
        for case_name in ADVERSARIAL_COMMANDS:
            with self.subTest(case_name=case_name):
                result = self.run_get(
                    f"adversarial policy {case_name}", "--no-cache")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("read-only policy", result.stderr.lower())
                self.assertFalse((self.work / "never-run").exists())

    def test_05d_untrusted_shell_configuration_is_rejected(self) -> None:
        untrusted = (
            r"C:\Temp\powershell.exe"
            if self.target_os == "windows" else "/tmp/bash"
        )
        result = self.run_get("set", "shell", untrusted)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unsupported shell", result.stderr.lower())

    def test_05e_auto_harness_recovers_from_policy_rejection(self) -> None:
        result = self.run_get("policy recovery cli", "--no-cache")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "policy-recovered")
        self.assertFalse((self.work / "never-run").exists())

    def test_06_reviewer_revision_is_rechecked(self) -> None:
        result = self.run_get(
            "force unsafe review", "--double-check", "--no-cache")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("read-only policy", result.stderr.lower())
        self.assertFalse((self.work / "never-run").exists())

    def test_06b_reviewer_rejection_accepts_punctuation(self) -> None:
        result = self.run_get(
            "review rejects punctuation", "--double-check", "--no-cache")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("deemed unsafe", result.stderr.lower())

    def test_06c_transient_transport_is_retried_three_times(self) -> None:
        Handler.transient_failures = 0
        result = self.run_get("transient transport", "--no-cache")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "native-ok")
        self.assertEqual(Handler.transient_failures, 3)

    def test_06d_oversized_provider_response_is_rejected(self) -> None:
        result = self.run_get("oversized response", "--no-cache")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("response exceeds", result.stderr.lower())

    def test_06e_bearer_request_does_not_follow_redirects(self) -> None:
        Handler.redirect_targets = 0
        result = self.run_get("redirect response", "--no-cache")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(Handler.redirect_targets, 0)

    def test_07_command_deadline_returns_124(self) -> None:
        self.assertEqual(
            self.run_get("set", "command-timeout", "1").returncode, 0)
        started = time.monotonic()
        result = self.run_get("slow command cli", "--no-cache")
        elapsed = time.monotonic() - started
        self.assertEqual(result.returncode, 124, result.stderr)
        self.assertLess(elapsed, 2.0)
        self.assertEqual(
            self.run_get("set", "command-timeout").returncode, 0)

    def test_08_output_cap_stops_capture(self) -> None:
        self.assertEqual(
            self.run_get("set", "max-output-bytes", "100").returncode, 0)
        result = self.run_get("large output cli", "--no-cache")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("truncated", result.stderr.lower())
        self.assertEqual(
            self.run_get("set", "max-output-bytes").returncode, 0)

    def test_09_http_proxy_uses_the_reusable_transport(self) -> None:
        ProxyHandler.request_count = 0
        proxy_url = f"http://127.0.0.1:{self.proxy_port}"
        proxy_env = {
            "HTTP_PROXY": proxy_url,
            "HTTPS_PROXY": "",
            "ALL_PROXY": "",
            "NO_PROXY": "",
        }
        if self.target_os != "windows":
            proxy_env.update({
                "http_proxy": "",
                "https_proxy": "",
                "all_proxy": "",
                "no_proxy": "",
            })
        result = self.run_get(
            "proxy cli",
            "--no-cache",
            env_override=proxy_env,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "native-ok")
        self.assertGreater(ProxyHandler.request_count, 0)

    def test_10_cached_command_retains_output_cap(self) -> None:
        first = self.run_get("large output cached cli")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(
            self.run_get("set", "max-output-bytes", "100").returncode,
            0,
        )
        second = self.run_get("large output cached cli")
        self.assertNotEqual(second.returncode, 0)
        self.assertIn("truncated", second.stderr.lower())
        self.assertEqual(
            self.run_get("set", "max-output-bytes").returncode,
            0,
        )

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux process audit")
    def test_11_ctrl_c_stops_the_active_process_tree(self) -> None:
        if self.target_os != "linux":
            self.skipTest("Linux target process audit")
        process = subprocess.Popen(
            [*self.command, "slow command interrupt", "--no-cache"],
            cwd=self.work,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        child_pid = 0
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and child_pid == 0:
            found = subprocess.run(
                ["ps", "-o", "pid=", "--ppid", str(process.pid)],
                capture_output=True,
                text=True,
                check=False,
            ).stdout.strip()
            if found:
                child_pid = int(found.splitlines()[0].strip())
                break
            time.sleep(0.02)
        self.assertGreater(child_pid, 0)
        process.send_signal(signal.SIGINT)
        stdout, stderr = process.communicate(timeout=3)
        self.assertEqual(
            process.returncode,
            130,
            f"stdout={stdout!r} stderr={stderr!r}",
        )
        for _ in range(50):
            if not Path(f"/proc/{child_pid}").exists():
                break
            time.sleep(0.02)
        self.assertFalse(Path(f"/proc/{child_pid}").exists())

    def test_12_text_only_request_ignores_a_cached_command(self) -> None:
        reference_query = "cache hash reference"
        reference = self.run_get(reference_query)
        self.assertEqual(reference.returncode, 0, reference.stderr)

        cache_path = self.config_root / "get" / "cache.json"
        config_path = self.config_root / "get" / "config.json"
        payload = json.loads(cache_path.read_text(encoding="utf-8"))
        config = json.loads(config_path.read_text(encoding="utf-8"))
        reference_entry = next(
            entry for entry in payload["entries"]
            if entry["query"] == reference_query
        )
        self.assertEqual(reference_entry["cacheMode"], "command")

        pattern_result = self.run_get("config", "--command-pattern")
        self.assertEqual(pattern_result.returncode, 0, pattern_result.stderr)
        pattern_line = pattern_result.stdout.strip()
        prefix = "command-pattern = "
        suffix = " (default: built-in)"
        self.assertTrue(pattern_line.startswith(prefix), pattern_line)
        self.assertTrue(pattern_line.endswith(suffix), pattern_line)
        pattern = pattern_line[len(prefix):-len(suffix)]

        def nim_json_hash(values: list[str]) -> str:
            encoded = json.dumps(
                values,
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")
            return hashlib.sha256(encoded).hexdigest()

        host_os = {
            "linux": "linux",
            "windows": "windows",
            "macos": "macosx",
        }[self.target_os]
        host_cpu = "arm64" if self.target_os == "macos" else "amd64"
        query = (
            "Explicit no tools cached: without calling a tool, "
            "answer directly"
        )
        global_hash = nim_json_hash([
            "get-v3",
            query,
            config["shell"],
            config["model"],
            config["url"],
            config["harness"],
            config["toolProtocol"],
            "",
            "built-in:" + pattern,
            host_os,
            host_cpu,
        ])
        context_hash = nim_json_hash([
            "get-v3-context",
            global_hash,
            str(self.work),
        ])
        forged = dict(reference_entry)
        forged.update({"hash": context_hash, "query": query})
        payload["entries"].append(forged)
        cache_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )

        result = self.run_get(query)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "no-tools-ok")
        self.assertNotEqual(result.stdout, reference.stdout)

    def test_15_cache_hit_needs_no_provider(self) -> None:
        first = self.run_get("cache zero model")
        self.assertEqual(first.returncode, 0, first.stderr)
        self.server.shutdown()
        self.server.server_close()
        self.server_thread.join(timeout=2)
        started = time.monotonic()
        second = self.run_get("cache zero model")
        elapsed = time.monotonic() - started
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertEqual(second.stdout, first.stdout)
        self.assertLess(elapsed, 0.5)

    def test_13_concurrent_cache_writers_keep_every_entry(self) -> None:
        self.assertEqual(
            self.run_get("cache", "--clean").returncode, 0)
        queries = [f"answer-only concurrent cache {i}" for i in range(12)]
        processes = [subprocess.Popen(
            [*self.command, query, "--cache"],
            cwd=self.work,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
        ) for query in queries]
        results = [process.communicate(timeout=20) for process in processes]
        self.assertTrue(all(process.returncode == 0 for process in processes),
                        results)
        cache_path = self.config_root / "get" / "cache.json"
        payload = json.loads(cache_path.read_text(encoding="utf-8"))
        self.assertEqual(payload["schemaVersion"], 3)
        self.assertEqual(payload["hashAlgorithm"], "sha256")
        stored_queries = {entry["query"] for entry in payload["entries"]}
        self.assertTrue(set(queries).issubset(stored_queries))
        self.assertFalse(Path(str(cache_path) + ".lock").exists())
        self.assertFalse(list(cache_path.parent.glob("cache.json.tmp.*")))
        if self.target_os != "windows":
            self.assertEqual(cache_path.stat().st_mode & 0o777, 0o600)

    def test_14_corrupt_primary_recovers_from_last_good_copy(self) -> None:
        cache_path = self.config_root / "get" / "cache.json"
        backup_path = cache_path.with_name(cache_path.name + ".bak")
        self.assertTrue(backup_path.is_file())
        previous = json.loads(backup_path.read_text(encoding="utf-8"))
        cache_path.write_text("{damaged", encoding="utf-8")
        result = self.run_get(
            "answer-only cache recovery", "--cache")
        self.assertEqual(result.returncode, 0, result.stderr)
        healed = json.loads(cache_path.read_text(encoding="utf-8"))
        self.assertGreater(
            len(healed["entries"]), len(previous["entries"]))


if __name__ == "__main__":
    unittest.main(verbosity=2)
