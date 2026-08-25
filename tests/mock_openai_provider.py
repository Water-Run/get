#!/usr/bin/env python3
"""Deterministic local OpenAI-compatible provider for get v3 integration tests."""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict
from urllib.parse import urlsplit


ADVERSARIAL_COMMANDS = {
    "quoted-name": "r''m -f never-run",
    "redirection": "printf unsafe > never-run",
    "shell-wrapper": "sh -c 'touch never-run'",
    "interpreter": "python3 -c 'open(\"never-run\",\"w\").write(\"x\")'",
    "find-exec": "find . -exec touch never-run +",
    "rg-pre": "rg --pre 'touch never-run' value .",
    "sort-output": "sort -o never-run README.md",
    "git-alias": "git -c alias.x='!touch never-run' x",
    "curl-output": "curl -o never-run https://example.com",
    "tar-create": "tar -cf never-run README.md",
    "powershell-pipe": "Get-Content README.md | Set-Content never-run",
    "powershell-dotnet": "[IO.File]::WriteAllText('never-run','x')",
    "cmd-expansion": "%ComSpec% /c echo x > never-run",
    "cmd-caret": "to^uch never-run",
    "relative-script": "./read-looking-script",
    "network-state": "ip link set lo down",
}


class Handler(BaseHTTPRequestHandler):
    """Serve deterministic chat-completions responses over persistent HTTP."""

    protocol_version = "HTTP/1.1"
    transient_failures = 0
    redirect_targets = 0

    def _write(self, status: int, payload: Dict[str, Any]) -> None:
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def _write_oversized_header(self) -> None:
        """Advertise an oversized body without allocating one."""

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(8 * 1024 * 1024 + 1))
        self.send_header("Connection", "close")
        self.end_headers()
        self.close_connection = True

    def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
        if self.path == "/should-not-follow":
            Handler.redirect_targets += 1
            self._write(200, {"error": "redirect followed"})
            return
        if self.path != "/v1/chat/completions":
            self._write(404, {"error": "not found"})
            return
        length = int(self.headers.get("Content-Length", "0"))
        body = json.loads(self.rfile.read(length))
        messages = body.get("messages", [])
        user_text = " ".join(
            str(message.get("content") or "")
            for message in messages
            if message.get("role") == "user"
        ).lower()
        system_text = " ".join(
            str(message.get("content") or "")
            for message in messages
            if message.get("role") == "system"
        ).lower()
        has_tools = bool(body.get("tools"))
        is_windows = "os=windows" in system_text
        is_macos = "os=macos" in system_text or "os=darwin" in system_text
        is_cmd = "cmd.exe:" in system_text

        def output(text: str) -> str:
            """Return a deterministic command for the requested test shell."""
            return f"echo {text}" if is_windows else f"printf {text}"

        if "transient transport" in user_text \
                and Handler.transient_failures < 3:
            Handler.transient_failures += 1
            self.close_connection = True
            return
        if "oversized response" in user_text:
            self._write_oversized_header()
            return
        if "redirect response" in user_text:
            port = self.server.server_address[1]
            self.send_response(307)
            self.send_header(
                "Location", f"http://127.0.0.1:{port}/should-not-follow")
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if "review this command." in user_text:
            if "review rejects punctuation" in system_text:
                self._completion(content="UNSAFE: command changes state.")
            elif "force unsafe review" in system_text:
                self._completion(content="```sh\nrm -rf ./never-run\n```")
            else:
                self._completion(
                    content=f"```sh\n{output('reviewed-ok')}\n```")
            return
        if "fallback" in user_text and has_tools:
            self._write(400, {"error": {"message": "unknown field tools"}})
            return
        if "answer-only" in user_text:
            self._completion(content="answer-only-ok")
            return
        if "explicit no tools" in user_text:
            if has_tools or "no tools are available" not in system_text:
                self._write(400, {
                    "error": {"message": "text-only routing was bypassed"},
                })
            else:
                self._completion(content="no-tools-ok")
            return
        if "adversarial policy" in user_text and has_tools:
            for case_name, command in ADVERSARIAL_COMMANDS.items():
                if case_name in user_text:
                    self._tool_completion([
                        ("attack-1", command, "return_raw"),
                    ])
                    return
        if "qwen textual unsafe" in user_text and has_tools:
            self._completion(content=(
                "[Tool call] run_readonly_shell "
                "{command: echo unsafe > never-run, "
                "purpose: integration safety test, "
                "result_mode: return_raw}"
            ))
            return
        if "qwen textual" in user_text and has_tools:
            self._completion(content=(
                "[Tool call] run_readonly_shell "
                f"{{command: {output('qwen-text-ok')}, "
                "purpose: integration compatibility test, "
                "result_mode: return_raw}"
            ))
            return
        if "performance snapshot" in user_text and has_tools:
            command = (
                "tasklist" if is_cmd else
                "Get-Process | Sort-Object CPU -Descending | "
                "Select-Object -First 5" if is_windows else
                "top -l 1 -n 15" if is_macos else
                "top -bn1 | head -n 15"
            )
            self._tool_completion([
                ("performance-1", command, "return_raw"),
            ])
            return
        if "continue" in user_text and any(
                message.get("role") == "tool" for message in messages):
            self._completion(content="continued-ok")
            return
        if "policy recovery" in user_text and any(
                message.get("role") == "tool"
                and '"policy_rejected":true' in
                str(message.get("content", "")).replace(" ", "").lower()
                for message in messages):
            self._tool_completion([
                ("recovered-2", output("policy-recovered"), "return_raw"),
            ])
            return
        if "parallel" in user_text and has_tools:
            self._tool_completion([
                ("parallel-a", output("parallel-a"), "return_raw"),
                ("parallel-b", output("parallel-b"), "return_raw"),
            ])
            return
        if "continue" in user_text and has_tools:
            self._tool_completion([
                ("continue-1", output("evidence"), "continue"),
            ])
            return
        if "unsafe policy" in user_text and has_tools:
            self._tool_completion([
                ("unsafe-1", "printf unsafe > ./never-run", "return_raw"),
            ])
            return
        if "policy recovery" in user_text and has_tools:
            self._tool_completion([
                ("rejected-1", "printf unsafe > ./never-run", "return_raw"),
            ])
            return
        if "slow command" in user_text and has_tools:
            slow_command = (
                "ping -n 11 127.0.0.1 >NUL" if is_cmd else
                "ping -n 11 127.0.0.1 | Out-Null" if is_windows else
                "sleep 10"
            )
            self._tool_completion([
                ("slow-1", slow_command, "return_raw"),
            ])
            return
        if "large output" in user_text and has_tools:
            self._tool_completion([
                ("large-1",
                 "systeminfo" if is_cmd else
                 "Get-Process | Format-List *" if is_windows else
                 "yes x | head -c 5000",
                 "return_raw"),
            ])
            return
        if "fallback" in user_text:
            content = json.dumps({
                "type": "tool_calls",
                "calls": [{
                    "id": "fallback-1",
                    "command": output("fallback-ok"),
                    "result_mode": "return_raw",
                }],
            })
            self._completion(content=content)
            return
        self._tool_completion([
            ("native-1", output("native-ok"), "return_raw"),
        ])

    def _completion(self, content: str) -> None:
        self._write(200, {
            "choices": [{
                "finish_reason": "stop",
                "message": {"role": "assistant", "content": content},
            }],
            "usage": {"total_tokens": 7},
        })

    def _tool_completion(self, calls: list[tuple[str, str, str]]) -> None:
        tool_calls = []
        for call_id, command, result_mode in calls:
            tool_calls.append({
                "id": call_id,
                "type": "function",
                "function": {
                    "name": "run_readonly_shell",
                    "arguments": json.dumps({
                        "command": command,
                        "purpose": "integration test",
                        "result_mode": result_mode,
                    }),
                },
            })
        self._write(200, {
            "choices": [{
                "finish_reason": "tool_calls",
                "message": {
                    "role": "assistant",
                    "content": None,
                    "tool_calls": tool_calls,
                },
            }],
            "usage": {"total_tokens": 9},
        })

    def log_message(self, format: str, *args: object) -> None:
        """Suppress request logs to keep test output deterministic."""


class ProxyHandler(Handler):
    """Accept absolute-form proxy requests and serve mock responses locally."""

    request_count = 0

    def do_POST(self) -> None:  # noqa: N802 - stdlib handler API
        type(self).request_count += 1
        parsed = urlsplit(self.path)
        if parsed.scheme:
            self.path = parsed.path
            if parsed.query:
                self.path += "?" + parsed.query
        super().do_POST()


def main() -> None:
    """Start the local provider on the requested loopback port."""

    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=18765)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.serve_forever()


if __name__ == "__main__":
    main()
