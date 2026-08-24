#!/usr/bin/env python3
"""Deterministic local OpenAI-compatible provider for get v3 integration tests."""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict
from urllib.parse import urlsplit


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
                self._completion(content="```sh\nprintf reviewed-ok\n```")
            return
        if "fallback" in user_text and has_tools:
            self._write(400, {"error": {"message": "unknown field tools"}})
            return
        if "answer-only" in user_text:
            self._completion(content="answer-only-ok")
            return
        if "continue" in user_text and any(
                message.get("role") == "tool" for message in messages):
            self._completion(content="continued-ok")
            return
        if "parallel" in user_text and has_tools:
            self._tool_completion([
                ("parallel-a", "printf parallel-a", "return_raw"),
                ("parallel-b", "printf parallel-b", "return_raw"),
            ])
            return
        if "continue" in user_text and has_tools:
            self._tool_completion([
                ("continue-1", "printf evidence", "continue"),
            ])
            return
        if "unsafe policy" in user_text and has_tools:
            self._tool_completion([
                ("unsafe-1", "printf unsafe > ./never-run", "return_raw"),
            ])
            return
        if "slow command" in user_text and has_tools:
            self._tool_completion([
                ("slow-1", "sleep 10", "return_raw"),
            ])
            return
        if "large output" in user_text and has_tools:
            self._tool_completion([
                ("large-1", "yes x | head -c 5000", "return_raw"),
            ])
            return
        if "fallback" in user_text:
            content = json.dumps({
                "type": "tool_calls",
                "calls": [{
                    "id": "fallback-1",
                    "command": "printf fallback-ok",
                    "result_mode": "return_raw",
                }],
            })
            self._completion(content=content)
            return
        self._tool_completion([
            ("native-1", "printf native-ok", "return_raw"),
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
