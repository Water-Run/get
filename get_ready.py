#!/usr/bin/env python3
"""get_test.py -- Comprehensive test suite for the `get` CLI tool.

Usage:
    python get_test.py --key <API_KEY> [--url URL] [--model NAME]
                       [--skip-llm] [--verbose]

Assumes `get` is already installed and on PATH.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from typing import List, Optional, Tuple, Dict

# ---------------------------------------------------------------------------
# ANSI / output
# ---------------------------------------------------------------------------

ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def strip_ansi(s: str) -> str:
    return ANSI_RE.sub("", s)


class C:
    R = "\033[0m"
    G = "\033[32m"
    RED = "\033[31m"
    Y = "\033[33m"
    CY = "\033[36m"
    B = "\033[1m"
    D = "\033[2m"
    MAG = "\033[35m"


if not sys.stdout.isatty():
    for k in list(vars(C)):
        if not k.startswith("_"):
            setattr(C, k, "")


VERBOSE = False


def ok(name: str) -> None:
    print(f"  {C.G}PASS{C.R}  {name}")


def err(name: str, reason: str) -> None:
    print(f"  {C.RED}FAIL{C.R}  {name}"
          + (f"  {C.D}-- {reason}{C.R}" if reason else ""))


def sk(name: str, reason: str) -> None:
    print(f"  {C.Y}SKIP{C.R}  {name}"
          + (f"  {C.D}-- {reason}{C.R}" if reason else ""))


def hdr(title: str) -> None:
    print(f"\n{C.B}{C.CY}>> {title}{C.R}")


def dbg(msg: str) -> None:
    if VERBOSE:
        print(f"    {C.D}{msg}{C.R}")


# ---------------------------------------------------------------------------
# Process runner
# ---------------------------------------------------------------------------

def run_get(*args: str, timeout: int = 60,
            stdin: Optional[str] = None
            ) -> Tuple[int, str, str]:
    dbg(f"$ get {' '.join(args)}")
    try:
        r = subprocess.run(
            ["get", *args],
            capture_output=True, text=True, timeout=timeout,
            input=stdin, encoding="utf-8", errors="replace",
        )
        return r.returncode, r.stdout, r.stderr
    except subprocess.TimeoutExpired:
        return 124, "", "<timeout>"
    except FileNotFoundError:
        print(f"{C.RED}fatal: 'get' not found on PATH.{C.R}",
              file=sys.stderr)
        sys.exit(2)


def parse_kv(text: str) -> Dict[str, str]:
    d: Dict[str, str] = {}
    for line in strip_ansi(text).splitlines():
        if " = " in line:
            k, v = line.split(" = ", 1)
            d[k.strip()] = v.rstrip()
    return d


def get_cfg(opt: str) -> str:
    rc, o, _ = run_get("config", f"--{opt}")
    if rc != 0:
        return "<ERROR>"
    return parse_kv(o).get(opt, "")


def set_opt(opt: str, *values: str) -> bool:
    rc, _, _ = run_get("set", opt, *values)
    return rc == 0


def clear_opt(opt: str) -> bool:
    rc, _, _ = run_get("set", opt)
    return rc == 0


def cache_entries() -> int:
    rc, o, _ = run_get("cache")
    if rc != 0:
        return -1
    try:
        return int(parse_kv(o).get("entries", "-1"))
    except ValueError:
        return -1


def log_entries() -> int:
    rc, o, _ = run_get("log")
    if rc != 0:
        return -1
    try:
        return int(parse_kv(o).get("entries", "-1"))
    except ValueError:
        return -1


# ---------------------------------------------------------------------------
# Stats
# ---------------------------------------------------------------------------

@dataclass
class Stats:
    passed: int = 0
    failed: int = 0
    skipped: int = 0
    failures: List[Tuple[str, str]] = field(default_factory=list)

    def pass_(self, name: str) -> None:
        self.passed += 1
        ok(name)

    def fail(self, name: str, reason: str = "") -> None:
        self.failed += 1
        self.failures.append((name, reason))
        err(name, reason)

    def skip(self, name: str, reason: str = "") -> None:
        self.skipped += 1
        sk(name, reason)


# ---------------------------------------------------------------------------
# Assert helpers
# ---------------------------------------------------------------------------

def assert_eq(s: Stats, name: str, got, expected) -> None:
    if got == expected:
        s.pass_(name)
    else:
        s.fail(name, f"got={got!r} expected={expected!r}")


def assert_cfg(s: Stats, name: str, opt: str, expected: str) -> None:
    got = get_cfg(opt)
    if got == expected:
        s.pass_(f"{name} [{opt}={expected!r}]")
    else:
        s.fail(f"{name} [{opt}]",
               f"got={got!r} expected={expected!r}")


def assert_cfg_has(s: Stats, name: str, opt: str,
                   needle: str) -> None:
    got = get_cfg(opt)
    if needle in got:
        s.pass_(f"{name} [{opt}~{needle!r}]")
    else:
        s.fail(f"{name} [{opt}]",
               f"got={got!r} expected contains {needle!r}")


def assert_exit0(s: Stats, name: str, *argv: str,
                 timeout: int = 30) -> Tuple[int, str, str]:
    rc, o, e = run_get(*argv, timeout=timeout)
    if rc == 0:
        s.pass_(name)
    else:
        s.fail(name,
               f"exit={rc} err={strip_ansi(e).strip()[:100]!r}")
    return rc, o, e


def assert_exit_nonzero(s: Stats, name: str, *argv: str,
                        timeout: int = 30) -> None:
    rc, _, e = run_get(*argv, timeout=timeout)
    if rc != 0:
        s.pass_(f"{name} [exit={rc}]")
    else:
        s.fail(name, "unexpected exit 0")


# ===========================================================================
# Test blocks
# ===========================================================================

def t_info(s: Stats) -> None:
    hdr("[1] Info & help")

    # 1-4
    rc, o, _ = run_get("version")
    if rc == 0 and len(strip_ansi(o).strip()) > 0:
        s.pass_("get version")
    else:
        s.fail("get version", f"exit={rc}")

    for cmd in ["help", "--help", "-h"]:
        rc, o, _ = run_get(cmd)
        low = strip_ansi(o).lower()
        if rc == 0 and "usage" in low and "options" in low:
            s.pass_(f"get {cmd}")
        else:
            s.fail(f"get {cmd}", f"exit={rc}")

    # 5
    rc, o, _ = run_get("get")
    low = strip_ansi(o).lower()
    if rc == 0 and all(k in low for k in
                       ["name", "version", "author",
                        "license", "github"]):
        s.pass_("get get (all fields)")
    else:
        s.fail("get get (all fields)", f"exit={rc}")

    # 6
    checks = [
        ("--intro", lambda v: len(v.strip()) > 0),
        ("--version", lambda v: len(v.strip()) > 0
         and any(c.isdigit() for c in v)),
        ("--license", lambda v: "agpl" in v.lower()),
        ("--github", lambda v: "github.com" in v.lower()),
    ]
    for flag, ck in checks:
        rc, o, _ = run_get("get", flag)
        if rc == 0 and ck(strip_ansi(o)):
            s.pass_(f"get get {flag}")
        else:
            s.fail(f"get get {flag}", f"exit={rc}")

    # 7
    assert_exit_nonzero(s, "get get --unknown", "get", "--unknown")


def t_boolean_options(s: Stats) -> None:
    hdr("[2] Boolean options (set / readback)")
    opts = ["manual-confirm", "double-check", "instance",
            "log", "hide-process", "cache", "vivid",
            "external-display"]
    for opt in opts:
        for v in ["true", "false"]:
            if not set_opt(opt, v):
                s.fail(f"set {opt} {v}", "set returned non-zero")
                continue
            assert_cfg(s, f"bool {opt}={v}", opt, v)


def t_integer_options(s: Stats) -> None:
    hdr("[3] Integer options (int / false / default)")
    table = {
        "timeout": "300",
        "max-token": "20480",
        "max-rounds": "3",
        "cache-expiry": "30",
        "cache-max-entries": "1000",
        "cache-trigger-threshold": "1",
        "log-max-entries": "1000",
    }
    for opt, default in table.items():
        set_opt(opt, "42")
        assert_cfg(s, f"int set {opt}=42", opt, "42")
        set_opt(opt, "false")
        assert_cfg(s, f"int disable {opt}", opt, "false")
        clear_opt(opt)
        assert_cfg(s, f"int reset {opt}", opt, default)


def t_strings(s: Stats) -> None:
    hdr("[4] String options & command-pattern semantics")

    # 45
    test_url = "https://example.test/v1"
    set_opt("url", test_url)
    assert_cfg(s, "string set url", "url", test_url)

    # 46
    set_opt("model", "test-model-name")
    assert_cfg(s, "string set model", "model",
               "test-model-name")

    # 47
    set_opt("system-prompt", "hello world prompt")
    assert_cfg(s, "string set system-prompt",
               "system-prompt", "hello world prompt")

    # 48
    clear_opt("system-prompt")
    assert_cfg(s, "string clear system-prompt",
               "system-prompt", "")

    # 49
    clear_opt("command-pattern")
    v = get_cfg("command-pattern")
    if "built-in" in v and r"\b" in v:
        s.pass_("command-pattern: omit -> built-in default")
    else:
        s.fail("command-pattern default", v[:80])

    # 50
    set_opt("command-pattern", "")
    v = get_cfg("command-pattern")
    if "disabled" in v.lower():
        s.pass_('command-pattern: "" -> (disabled)')
    else:
        s.fail("command-pattern disable", v[:80])

    # 51
    set_opt("command-pattern", r"\bdangerous\b")
    v = get_cfg("command-pattern")
    if r"\bdangerous\b" in v:
        s.pass_("command-pattern: custom value")
    else:
        s.fail("command-pattern custom", v[:80])

    # 52 -- weak pattern still accepted (warning is side-effect only)
    rc, _, e = run_get("set", "command-pattern", "^ls$")
    if rc == 0:
        s.pass_("command-pattern: weak pattern accepted")
    else:
        s.fail("command-pattern weak accept", f"exit={rc}")

    # cleanup
    clear_opt("command-pattern")


def t_key_and_config(s: Stats, args) -> None:
    hdr("[5] Key handling & config view")

    # 53
    set_opt("key", args.key)
    v = get_cfg("key")
    if "set" in v.lower() and args.key not in v:
        s.pass_("config --key shows 'set', no leak")
    else:
        s.fail("config --key isolation", v[:60])

    # 54
    clear_opt("key")
    v = get_cfg("key")
    if "not set" in v.lower():
        s.pass_("clear key -> config --key shows 'not set'")
    else:
        s.fail("clear key", v[:60])

    # restore
    set_opt("key", args.key)

    # 55
    rc, o, _ = run_get("config")
    cfg = parse_kv(o)
    if rc == 0 and len(cfg) >= 18:
        s.pass_(f"get config full ({len(cfg)} fields)")
    else:
        s.fail("get config full", f"exit={rc} fields={len(cfg)}")

    # 56
    set_opt("timeout", "777")
    rc, _, _ = run_get("config", "--reset")
    if rc == 0:
        s.pass_("get config --reset exit 0")
    else:
        s.fail("get config --reset", f"exit={rc}")
    assert_cfg(s, "post-reset timeout default",
               "timeout", "300")

    # 57
    assert_exit_nonzero(s, "config --nonexistent",
                        "config", "--nonexistent")

    # re-apply test credentials after reset
    set_opt("key", args.key)
    if args.url:
        set_opt("url", args.url)
    if args.model:
        set_opt("model", args.model)


def t_invalid(s: Stats) -> None:
    hdr("[6] Invalid inputs")
    cases = [
        ("invalid bool",       ["set", "double-check", "maybe"]),
        ("invalid int",        ["set", "timeout", "abc"]),
        ("negative int",       ["set", "timeout", "-5"]),
        ("unknown set opt",    ["set", "nonexistent-opt", "x"]),
        ("missing opt name",   ["set"]),
        ("unknown top cmd",    ["nosuchcommand"]),
        ("--model no value",
         ["query-text", "--model"]),
        ("--timeout no value",
         ["query-text", "--timeout"]),
        ("--timeout invalid",
         ["query-text", "--timeout", "notanumber"]),
        ("cache --unset missing arg",
         ["cache", "--unset"]),
    ]
    for name, argv in cases:
        assert_exit_nonzero(s, name, *argv, timeout=15)


def t_cache_log_mgmt(s: Stats) -> None:
    hdr("[7] Cache & log management")

    # 68
    rc, _, _ = run_get("cache", "--clean")
    if rc == 0:
        s.pass_("cache --clean exit 0")
    else:
        s.fail("cache --clean", f"exit={rc}")
    n = cache_entries()
    if n == 0:
        s.pass_(f"cache entries after clean = {n}")
    else:
        s.fail("cache entries after clean",
               f"got {n}")

    # 69
    rc, o, _ = run_get("cache")
    keys = parse_kv(o)
    required = ["cache", "entries", "max entries", "file"]
    missing = [k for k in required if k not in keys]
    if rc == 0 and not missing:
        s.pass_("cache display has required fields")
    else:
        s.fail("cache display fields", f"missing={missing}")

    # 70
    rc, o, _ = run_get("cache", "--unset", "definitely-no-such-query-xyz")
    low = strip_ansi(o).lower()
    if rc == 0:
        s.pass_("cache --unset no-match exit 0")
    else:
        s.fail("cache --unset no-match", f"exit={rc}")

    # 71
    rc, _, _ = run_get("log", "--clean")
    if rc == 0:
        s.pass_("log --clean exit 0")
    else:
        s.fail("log --clean", f"exit={rc}")
    n = log_entries()
    if n == 0:
        s.pass_(f"log entries after clean = {n}")
    else:
        s.fail("log entries after clean", f"got {n}")

    # 72
    rc, o, _ = run_get("log")
    keys = parse_kv(o)
    required = ["log", "entries", "file", "file size"]
    missing = [k for k in required if k not in keys]
    if rc == 0 and not missing:
        s.pass_("log display has required fields")
    else:
        s.fail("log display fields", f"missing={missing}")


def t_cache_disabled_warning(s: Stats, args) -> None:
    hdr("[7b] Cache-disabled warning & log-disabled behaviour")

    if args.skip_llm:
        s.skip("cache-disabled warning", "requires LLM")
        s.skip("log-disabled no append", "requires LLM")
        s.skip("log-max-entries enforcement", "requires LLM")
        return

    # 74 -- cache=false produces warning on query
    set_opt("cache", "false")
    set_opt("hide-process", "false")
    set_opt("vivid", "false")
    set_opt("double-check", "false")
    set_opt("instance", "true")
    rc, _, e = run_get(
        "reply with 'x' only", timeout=120
    )
    low = strip_ansi(e).lower()
    if "cache is disabled" in low:
        s.pass_("cache-disabled warning emitted")
    else:
        s.fail("cache-disabled warning",
               f"stderr={low.strip()[:120]!r}")
    set_opt("cache", "true")

    # 73 -- log=false -> no new entries
    run_get("log", "--clean")
    before = log_entries()
    set_opt("log", "false")
    run_get("reply with 'y' only", "--instance",
            "--no-cache", "--hide-process", timeout=120)
    after = log_entries()
    if after == before:
        s.pass_(f"log=false: no append (entries={after})")
    else:
        s.fail("log=false no append",
               f"before={before} after={after}")
    set_opt("log", "true")

    # 75 -- log-max-entries=3 enforcement
    run_get("log", "--clean")
    set_opt("log-max-entries", "3")
    for i in range(5):
        run_get(f"reply with '{i}' only", "--instance",
                "--no-cache", "--hide-process", timeout=120)
    n = log_entries()
    if n <= 3:
        s.pass_(f"log-max-entries=3 enforced (entries={n})")
    else:
        s.fail("log-max-entries enforced", f"entries={n}")
    clear_opt("log-max-entries")


def t_isok(s: Stats, args) -> None:
    hdr("[8] isok connectivity")

    # 77
    if args.skip_llm:
        s.skip("get isok", "--skip-llm")
    else:
        rc, o, e = run_get("isok", timeout=90)
        combined = strip_ansi(o + e).lower()
        if rc == 0 and "ok" in combined:
            s.pass_("get isok exit 0 with 'ok'")
        else:
            s.fail("get isok",
                   f"exit={rc} combined="
                   f"{combined.strip()[:120]!r}")

    # 78 -- missing key
    clear_opt("key")
    rc, _, _ = run_get("isok", timeout=30)
    if rc != 0:
        s.pass_(f"get isok without key -> exit {rc}")
    else:
        s.fail("get isok without key", "unexpected exit 0")
    set_opt("key", args.key)


# ---------------------------------------------------------------------------
# LLM queries
# ---------------------------------------------------------------------------

Q_SHORT = "reply with the single word 'pong' and nothing else"
Q_SHORT2 = "reply with the single word 'ping' and nothing else"
Q_NUM = "reply with the single digit '7' and nothing else"


def t_instance_mode(s: Stats, args) -> None:
    hdr("[9] LLM query -- instance mode")
    if args.skip_llm:
        for i in range(6):
            s.skip(f"instance test {i + 1}", "--skip-llm")
        return

    set_opt("instance", "true")
    set_opt("double-check", "false")
    set_opt("cache", "true")
    set_opt("log", "true")
    run_get("cache", "--clean")

    # 79
    rc, o, e = run_get(Q_SHORT, "--no-cache",
                       "--hide-process", timeout=120)
    if rc == 0 and len(strip_ansi(o).strip()) > 0:
        s.pass_("instance simple query exit 0")
    else:
        s.fail("instance simple query",
               f"exit={rc} err={strip_ansi(e)[:120]!r}")

    # 80 -- --no-cache explicitly
    rc, _, _ = run_get(Q_SHORT, "--no-cache",
                       "--hide-process", timeout=120)
    if rc == 0:
        s.pass_("instance --no-cache")
    else:
        s.fail("instance --no-cache", f"exit={rc}")

    # 81 -- --hide-process suppresses intermediate
    rc, o, e = run_get(Q_SHORT, "--no-cache",
                       "--hide-process", timeout=120)
    merged = strip_ansi(e)
    if rc == 0 and "executing" not in merged.lower():
        s.pass_("--hide-process suppresses intermediate")
    else:
        s.fail("--hide-process",
               f"stderr={merged.strip()[:120]!r}")

    # 82 -- --no-vivid: no ANSI
    rc, o, _ = run_get(Q_SHORT, "--no-cache", "--no-vivid",
                       "--hide-process", timeout=120)
    if rc == 0 and ANSI_RE.search(o) is None:
        s.pass_("--no-vivid: no ANSI escapes in stdout")
    else:
        any_ansi = bool(ANSI_RE.search(o))
        s.fail("--no-vivid",
               f"exit={rc} has_ansi={any_ansi}")

    # 83 -- --model override
    mdl = args.model or "gpt-5.3-codex"
    rc, _, _ = run_get(Q_SHORT, "--no-cache", "--hide-process",
                       "--model", mdl, timeout=120)
    if rc == 0:
        s.pass_(f"--model {mdl} override")
    else:
        s.fail("--model override", f"exit={rc}")

    # 84 -- --timeout override
    rc, _, _ = run_get(Q_SHORT, "--no-cache", "--hide-process",
                       "--timeout", "120", timeout=140)
    if rc == 0:
        s.pass_("--timeout override")
    else:
        s.fail("--timeout override", f"exit={rc}")


def t_agent_mode(s: Stats, args) -> None:
    hdr("[10] LLM query -- agent mode")
    if args.skip_llm:
        for i in range(4):
            s.skip(f"agent test {i + 1}", "--skip-llm")
        return

    set_opt("instance", "false")
    set_opt("double-check", "false")
    run_get("log", "--clean")
    run_get("cache", "--clean")

    before = log_entries()

    # 85
    rc, o, e = run_get(Q_SHORT, "--no-cache",
                       "--hide-process", timeout=180)
    if rc == 0:
        s.pass_("agent default query exit 0")
    else:
        s.fail("agent default query",
               f"exit={rc} err={strip_ansi(e)[:120]!r}")

    # 86
    rc, _, e = run_get(Q_SHORT2, "--no-cache",
                       "--hide-process", timeout=180)
    lo = strip_ansi(e).lower()
    if rc == 0 and "round" not in lo:
        s.pass_("agent --hide-process suppresses rounds")
    else:
        s.fail("agent --hide-process",
               f"err={lo[:120]!r}")

    # 87 -- max-rounds=1
    set_opt("max-rounds", "1")
    rc, _, _ = run_get(Q_NUM, "--no-cache",
                       "--hide-process", timeout=180)
    if rc == 0:
        s.pass_("agent max-rounds=1 terminates cleanly")
    else:
        s.fail("agent max-rounds=1", f"exit={rc}")
    clear_opt("max-rounds")

    # 88 -- log grew
    after = log_entries()
    if after > before:
        s.pass_(f"agent queries appended log ({before}->{after})")
    else:
        s.fail("agent log append",
               f"before={before} after={after}")


def t_cache_behaviour(s: Stats, args) -> None:
    hdr("[11] Cache behavioural tests")
    if args.skip_llm:
        for i in range(7):
            s.skip(f"cache behaviour {i + 1}", "--skip-llm")
        return

    set_opt("instance", "true")
    set_opt("double-check", "false")
    set_opt("hide-process", "true")
    set_opt("vivid", "false")
    set_opt("cache", "true")
    set_opt("cache-trigger-threshold", "1")
    run_get("cache", "--clean")

    Q = "reply with the exact text 'cache-test-1' only"

    # 89 -- first run: no cache entry, seen recorded
    before = cache_entries()
    rc, _, _ = run_get(Q, timeout=120)
    after = cache_entries()
    if rc == 0 and after == before:
        s.pass_("first run: no cache entry added")
    else:
        s.fail("first run cache entries",
               f"before={before} after={after}")

    # 90 -- second run: triggers classification, may add entry
    rc, _, _ = run_get(Q, timeout=120)
    after2 = cache_entries()
    if rc == 0:
        s.pass_(f"second run ok (entries {after}->{after2})")
    else:
        s.fail("second run", f"exit={rc}")

    # 91 -- --cache forces immediate classification
    run_get("cache", "--clean")
    Q2 = "reply with the exact text 'cache-test-2' only"
    before = cache_entries()
    rc, _, _ = run_get(Q2, "--cache", timeout=120)
    after = cache_entries()
    if rc == 0:
        s.pass_(f"--cache force: ran (entries {before}->{after})")
    else:
        s.fail("--cache force", f"exit={rc}")

    # 92 -- cache-trigger-threshold=0 means classify immediately
    run_get("cache", "--clean")
    set_opt("cache-trigger-threshold", "0")
    Q3 = "reply with the exact text 'cache-test-3' only"
    rc, _, _ = run_get(Q3, timeout=120)
    after = cache_entries()
    if rc == 0:
        s.pass_(f"threshold=0 immediate classify "
                f"(entries={after})")
    else:
        s.fail("threshold=0", f"exit={rc}")
    clear_opt("cache-trigger-threshold")

    # 93 -- cache hit same query returns fast
    Q4 = "reply with the exact text 'cache-hit' only"
    run_get(Q4, "--cache", timeout=120)  # 1st
    t0 = time.time()
    rc, _, _ = run_get(Q4, timeout=120)  # 2nd (likely hit or re-exec)
    dt = time.time() - t0
    if rc == 0:
        s.pass_(f"repeat query ok (elapsed {dt:.1f}s)")
    else:
        s.fail("repeat query", f"exit={rc}")

    # 94 -- clean resets everything
    rc, _, _ = run_get("cache", "--clean")
    n = cache_entries()
    if rc == 0 and n == 0:
        s.pass_("cache --clean full reset")
    else:
        s.fail("cache clean reset", f"rc={rc} n={n}")

    # 95 -- cache --unset precision
    Q5 = "reply with the exact text 'unset-target' only"
    # seed cache with --cache on both runs to maximise chance
    run_get(Q5, "--cache", timeout=120)
    run_get(Q5, "--cache", timeout=120)
    rc, o, _ = run_get("cache", "--unset", Q5)
    if rc == 0:
        s.pass_("cache --unset exit 0")
    else:
        s.fail("cache --unset", f"exit={rc}")


def t_missing_config(s: Stats, args) -> None:
    hdr("[12] Missing configuration errors")
    if args.skip_llm:
        for i in range(3):
            s.skip(f"missing-config {i + 1}", "--skip-llm")
        return

    # Backup current to restore after each clear
    orig_url = get_cfg("url")
    orig_model = get_cfg("model")

    # 96 -- no key
    clear_opt("key")
    rc, _, e = run_get("testquery", "--no-cache",
                       "--hide-process", timeout=30)
    low = strip_ansi(e).lower()
    if rc != 0 and ("key" in low or "api" in low):
        s.pass_(f"missing key -> exit {rc}")
    else:
        s.fail("missing key",
               f"exit={rc} err={low.strip()[:120]!r}")
    set_opt("key", args.key)

    # 97 -- no url
    set_opt("url", "")
    rc, _, e = run_get("testquery", "--no-cache",
                       "--hide-process", timeout=30)
    low = strip_ansi(e).lower()
    if rc != 0 and "url" in low:
        s.pass_(f"missing url -> exit {rc}")
    else:
        s.fail("missing url",
               f"exit={rc} err={low.strip()[:120]!r}")
    set_opt("url", orig_url)

    # 98 -- no model
    set_opt("model", "")
    rc, _, e = run_get("testquery", "--no-cache",
                       "--hide-process", timeout=30)
    low = strip_ansi(e).lower()
    if rc != 0 and "model" in low:
        s.pass_(f"missing model -> exit {rc}")
    else:
        s.fail("missing model",
               f"exit={rc} err={low.strip()[:120]!r}")
    set_opt("model", orig_model)


# ---------------------------------------------------------------------------
# Backup / restore
# ---------------------------------------------------------------------------

def backup_config() -> Dict[str, str]:
    rc, o, _ = run_get("config")
    if rc != 0:
        print(f"{C.RED}fatal: cannot read config{C.R}",
              file=sys.stderr)
        sys.exit(2)
    return parse_kv(o)


def restore_config(s: Stats, backup: Dict[str, str]) -> None:
    hdr("[13] Teardown: restore original configuration")

    # command-pattern
    cp = backup.get("command-pattern", "")
    if "built-in" in cp:
        clear_opt("command-pattern")
    elif "disabled" in cp.lower() or cp == "":
        set_opt("command-pattern", "")
    else:
        set_opt("command-pattern", cp)

    # system-prompt
    sp = backup.get("system-prompt", "")
    if sp == "":
        clear_opt("system-prompt")
    else:
        set_opt("system-prompt", sp)

    skip_keys = {"key", "command-pattern", "system-prompt"}
    for k, v in backup.items():
        if k in skip_keys:
            continue
        run_get("set", k, v)

    # Compare
    rc, o, _ = run_get("config")
    current = parse_kv(o)
    diffs = []
    for k in backup:
        if k == "key":
            continue
        if backup[k] != current.get(k):
            diffs.append(
                f"{k}: was={backup[k]!r} now={current.get(k)!r}")
    if not diffs:
        s.pass_(f"original config fully restored")
    else:
        s.fail("config restore diff",
               "; ".join(diffs[:3]))

    # clear test key
    clear_opt("key")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> None:
    global VERBOSE
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--key", required=True,
                    help="LLM API key (required)")
    ap.add_argument("--url", default=None,
                    help="LLM API endpoint URL")
    ap.add_argument("--model", default=None,
                    help="LLM model name")
    ap.add_argument("--skip-llm", action="store_true",
                    help="Skip tests that invoke the LLM")
    ap.add_argument("-v", "--verbose", action="store_true",
                    help="Echo each `get` invocation")
    args = ap.parse_args()

    VERBOSE = args.verbose

    print(f"{C.B}get test suite{C.R}")
    print(f"{C.D}  model    : {args.model or '(default)'}")
    print(f"  url      : {args.url or '(default)'}")
    print(f"  key      : ***")
    print(f"  skip-llm : {args.skip_llm}{C.R}")

    s = Stats()

    hdr("[0] Backup current configuration")
    backup = backup_config()
    s.pass_(f"backed up {len(backup)} options")

    # Apply test credentials
    set_opt("key", args.key)
    if args.url:
        set_opt("url", args.url)
    if args.model:
        set_opt("model", args.model)
    set_opt("vivid", "false")
    set_opt("double-check", "false")
    set_opt("log", "true")
    set_opt("cache", "true")
    s.pass_("test credentials applied")

    try:
        t_info(s)
        t_boolean_options(s)
        t_integer_options(s)
        t_strings(s)
        t_key_and_config(s, args)
        t_invalid(s)
        t_cache_log_mgmt(s)
        t_cache_disabled_warning(s, args)
        t_isok(s, args)
        t_instance_mode(s, args)
        t_agent_mode(s, args)
        t_cache_behaviour(s, args)
        t_missing_config(s, args)
    finally:
        try:
            restore_config(s, backup)
        except Exception as e:
            s.fail("restore config", str(e))

    # Summary
    total = s.passed + s.failed + s.skipped
    print()
    print(f"{C.B}{'=' * 60}{C.R}")
    print(f"{C.B}Test Summary{C.R}   (total {total})")
    print(f"  {C.G}passed  : {s.passed}{C.R}")
    print(f"  {C.RED}failed  : {s.failed}{C.R}")
    print(f"  {C.Y}skipped : {s.skipped}{C.R}")
    if s.failures:
        print(f"\n{C.RED}Failures:{C.R}")
        for name, reason in s.failures:
            print(f"  - {C.B}{name}{C.R}: {reason}")
    print()
    print(f"{C.Y}NOTE:{C.R} your original API key could not be "
          f"restored\n      (encrypted storage is write-only). "
          f"Please run:\n      "
          f"{C.B}get set key <your-original-key>{C.R}\n")

    sys.exit(0 if s.failed == 0 else 1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\ninterrupted.")
        sys.exit(130)
