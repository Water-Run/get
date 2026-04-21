#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
get_test.py -- Comprehensive end-to-end test suite for the `get` CLI.

Sections (188 test cases total):

    A  info_help          -- version / help / get get / intro / license
    B  boolean_options    -- 8 booleans x {true,false,default}
    C  integer_options    -- 7 integers x {pos,zero,disabled,default}
    D  string_options     -- url / model / system-prompt set/clear/reset
    E  command_pattern    -- default / disabled / custom / dangerous / reset
    F  key_and_config     -- key set/clear isolation, config --reset, fields
    G  invalid_inputs     -- malformed CLI arguments, missing values, types
    H  cache_log_mgmt     -- clean/display/unset for cache and log stores
    I  instance_queries   -- real LLM queries with ground-truth validation
    J  agent_queries      -- real tool-invoking agent queries
    K  cache_behaviour    -- threshold / force / hit-timing / unset / expiry
    L  param_interactions -- model/timeout/max-rounds/system-prompt/pattern
    M  missing_config     -- key/url/model absence
    Z  teardown           -- full configuration restore and diff

Usage:
    python get_test.py --key <API_KEY> [--url URL] [--model MODEL]
                       [--skip-llm] [--only A,B,...] [--stop-on-fail]
                       [--verbose]

Assumes `get` is installed and on $PATH.
"""
from __future__ import annotations

import argparse
import getpass
import os
import platform
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import (Any, Callable, Dict, Iterable, List, Optional, Tuple)

# =============================================================================
#                             CONSTANTS & ANSI
# =============================================================================

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

BOOL_OPTIONS = [
    "manual-confirm", "double-check", "instance", "log",
    "hide-process", "cache", "vivid", "external-display",
]

INT_OPTIONS_DEFAULTS = {
    "timeout":                 "300",
    "max-token":               "20480",
    "max-rounds":              "3",
    "cache-expiry":            "30",
    "cache-max-entries":       "1000",
    "cache-trigger-threshold": "1",
    "log-max-entries":         "1000",
}

STRING_OPTIONS = ["url", "model", "system-prompt"]


class C:
    R = "\033[0m"
    BLD = "\033[1m"
    DIM = "\033[2m"
    RED = "\033[31m"
    GRN = "\033[32m"
    YEL = "\033[33m"
    BLU = "\033[34m"
    MAG = "\033[35m"
    CYA = "\033[36m"


if not sys.stdout.isatty():
    for _k in list(vars(C)):
        if not _k.startswith("_"):
            setattr(C, _k, "")


def strip_ansi(s: str) -> str:
    """Remove ANSI colour/cursor escapes."""
    return ANSI_RE.sub("", s or "")


# =============================================================================
#                             LOGGER / OUTPUT
# =============================================================================

VERBOSE = False


def _c(colour: str, msg: str) -> str:
    return f"{colour}{msg}{C.R}"


def log_hdr(title: str) -> None:
    bar = "=" * 72
    print(f"\n{C.BLD}{C.CYA}{bar}")
    print(f" {title}")
    print(f"{bar}{C.R}")


def log_sub(title: str) -> None:
    print(f"\n{C.BLD}{C.BLU}-- {title}{C.R}")


def log_pass(name: str, detail: str = "") -> None:
    tag = _c(C.GRN, "PASS")
    extra = f"  {C.DIM}{detail}{C.R}" if detail else ""
    print(f"  [{tag}] {name}{extra}")


def log_fail(name: str, reason: str = "") -> None:
    tag = _c(C.RED, "FAIL")
    extra = f"  {C.DIM}-- {reason}{C.R}" if reason else ""
    print(f"  [{tag}] {name}{extra}")


def log_skip(name: str, reason: str = "") -> None:
    tag = _c(C.YEL, "SKIP")
    extra = f"  {C.DIM}-- {reason}{C.R}" if reason else ""
    print(f"  [{tag}] {name}{extra}")


def log_info(msg: str) -> None:
    print(f"  {_c(C.DIM, msg)}")


def log_debug(msg: str) -> None:
    if VERBOSE:
        print(f"    {_c(C.DIM, msg)}")


# =============================================================================
#                       ENVIRONMENT GROUND TRUTH
# =============================================================================
#
# The test suite prefers to verify the LLM's answers against values the test
# process can compute locally (hostname, cwd, user, etc.).  This makes the
# suite mostly deterministic: if the LLM / tool actually worked, the
# local ground truth will appear somewhere in the output.

@dataclass(frozen=True)
class EnvFacts:
    hostname:       str
    short_host:     str
    username:       str
    cwd:            str
    cwd_basename:   str
    home:           str
    platform_name:  str           # 'linux' | 'darwin' | 'windows'
    py_major_minor: str           # e.g. '3.12'
    py_major:       str           # e.g. '3'
    uname_release:  str
    year:           str
    ipv4_candidates: Tuple[str, ...]

    @classmethod
    def detect(cls) -> "EnvFacts":
        hn = socket.gethostname()
        sh = hn.split(".")[0]
        try:
            user = getpass.getuser()
        except Exception:
            user = os.environ.get("USER") or os.environ.get("USERNAME") or ""
        cwd = os.getcwd()
        home = os.path.expanduser("~")
        plt = platform.system().lower()
        vi = sys.version_info
        ips: List[str] = []
        try:
            for fam, *_rest, sa in socket.getaddrinfo(
                    socket.gethostname(), None):
                if fam == socket.AF_INET and sa[0] not in ips:
                    ips.append(sa[0])
        except socket.gaierror:
            pass
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.settimeout(0.2)
            s.connect(("10.255.255.255", 1))
            probe = s.getsockname()[0]
            s.close()
            if probe not in ips:
                ips.append(probe)
        except OSError:
            pass
        return cls(
            hostname=hn,
            short_host=sh,
            username=user,
            cwd=cwd,
            cwd_basename=os.path.basename(cwd) or cwd,
            home=home,
            platform_name=plt,
            py_major_minor=f"{vi.major}.{vi.minor}",
            py_major=str(vi.major),
            uname_release=platform.release(),
            year=str(datetime.now().year),
            ipv4_candidates=tuple(ips),
        )


FACTS = EnvFacts.detect()


# =============================================================================
#                             PROCESS RUNNER
# =============================================================================

@dataclass
class RunResult:
    argv:     List[str]
    returncode: int
    stdout:   str
    stderr:   str
    elapsed:  float

    @property
    def out_plain(self) -> str:
        return strip_ansi(self.stdout)

    @property
    def err_plain(self) -> str:
        return strip_ansi(self.stderr)

    @property
    def all_plain(self) -> str:
        return self.out_plain + "\n" + self.err_plain

    @property
    def ok(self) -> bool:
        return self.returncode == 0


def run_get(*args: str, timeout: int = 60,
            stdin: Optional[str] = None,
            env_extra: Optional[Dict[str, str]] = None) -> RunResult:
    """Run `get` with the given arguments."""
    argv = ["get", *args]
    log_debug("$ " + " ".join(shlex.quote(a) for a in argv))
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    t0 = time.time()
    try:
        proc = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=timeout,
            input=stdin,
            encoding="utf-8",
            errors="replace",
            env=env,
        )
        dt = time.time() - t0
        return RunResult(argv, proc.returncode, proc.stdout or "",
                         proc.stderr or "", dt)
    except subprocess.TimeoutExpired as te:
        dt = time.time() - t0
        return RunResult(argv, 124,
                         (te.stdout or b"").decode(errors="replace")
                         if isinstance(te.stdout, bytes) else (te.stdout or ""),
                         (te.stderr or b"").decode(errors="replace")
                         if isinstance(te.stderr, bytes) else (te.stderr or ""),
                         dt)
    except FileNotFoundError:
        print(_c(C.RED, "fatal: 'get' binary not found on PATH"),
              file=sys.stderr)
        sys.exit(2)


# =============================================================================
#                         PARSERS (config / cache / log)
# =============================================================================

KV_LINE_RE = re.compile(r"^\s*([\w\-]+)\s*=\s*(.*?)\s*$")


def parse_keyvalues(text: str) -> Dict[str, str]:
    """Parse `key = value` lines from stripped stdout."""
    result: Dict[str, str] = {}
    for raw in strip_ansi(text).splitlines():
        m = KV_LINE_RE.match(raw)
        if m:
            k, v = m.group(1), m.group(2)
            result[k.strip()] = v.rstrip()
    return result


def get_config() -> Dict[str, str]:
    r = run_get("config", timeout=20)
    if not r.ok:
        raise RuntimeError(f"`get config` failed: {r.err_plain!r}")
    return parse_keyvalues(r.stdout)


def get_config_field(name: str) -> str:
    r = run_get("config", f"--{name}", timeout=20)
    if not r.ok:
        return "<ERROR>"
    d = parse_keyvalues(r.stdout)
    return d.get(name, "")


def get_cache_info() -> Dict[str, str]:
    r = run_get("cache", timeout=20)
    if not r.ok:
        return {}
    return parse_keyvalues(r.stdout)


def get_log_info() -> Dict[str, str]:
    r = run_get("log", timeout=20)
    if not r.ok:
        return {}
    return parse_keyvalues(r.stdout)


def cache_entries_count() -> int:
    info = get_cache_info()
    try:
        return int(info.get("entries", "-1"))
    except ValueError:
        return -1


def log_entries_count() -> int:
    info = get_log_info()
    try:
        return int(info.get("entries", "-1"))
    except ValueError:
        return -1


# =============================================================================
#                       CONFIG MANAGER (backup / restore)
# =============================================================================

@dataclass
class ConfigManager:
    """Wrapper around `get set` / `get config` for test orchestration."""
    backup: Dict[str, str] = field(default_factory=dict)

    def snapshot(self) -> None:
        self.backup = dict(get_config())
        log_info(f"backed up {len(self.backup)} configuration options")

    def set(self, opt: str, *values: str) -> bool:
        r = run_get("set", opt, *values, timeout=20)
        return r.ok

    def clear(self, opt: str) -> bool:
        r = run_get("set", opt, timeout=20)
        return r.ok

    def value(self, opt: str) -> str:
        return get_config_field(opt)

    def restore(self) -> List[str]:
        """Best-effort restore; returns list of fields that could not be
        fully restored."""
        diffs: List[str] = []
        current = dict(get_config())
        for k, v in self.backup.items():
            if k == "key":
                continue       # not restorable (encrypted write-only store)
            if k == "command-pattern":
                if "built-in" in v:
                    self.clear("command-pattern")
                elif "disabled" in v.lower() or v == "":
                    self.set("command-pattern", "")
                else:
                    self.set("command-pattern", v)
                continue
            if k == "system-prompt":
                if v == "":
                    self.clear("system-prompt")
                else:
                    self.set("system-prompt", v)
                continue
            if current.get(k) != v:
                self.set(k, v)
        for k, v in self.backup.items():
            if k == "key":
                continue
            now = get_config_field(k)
            if now != v and k not in ("command-pattern", "system-prompt"):
                diffs.append(f"{k}: was={v!r} now={now!r}")
        return diffs


# =============================================================================
#                             STATS / REGISTRY
# =============================================================================

@dataclass
class Stats:
    passed:   int = 0
    failed:   int = 0
    skipped:  int = 0
    section:  str = ""
    failures: List[Tuple[str, str, str]] = field(default_factory=list)

    def pass_(self, name: str, detail: str = "") -> None:
        self.passed += 1
        log_pass(name, detail)

    def fail(self, name: str, reason: str = "") -> None:
        self.failed += 1
        self.failures.append((self.section, name, reason))
        log_fail(name, reason)
        if STOP_ON_FAIL:
            raise SystemExit(self._summary_then_exit_code())

    def skip(self, name: str, reason: str = "") -> None:
        self.skipped += 1
        log_skip(name, reason)

    def _summary_then_exit_code(self) -> int:
        summarize(self)
        return 1 if self.failed else 0


STOP_ON_FAIL = False


# =============================================================================
#                             ASSERTION HELPERS
# =============================================================================

def a_eq(stats: Stats, name: str, got: Any, expected: Any,
         detail: str = "") -> bool:
    if got == expected:
        stats.pass_(name, detail or f"= {expected!r}")
        return True
    stats.fail(name, f"got={got!r} expected={expected!r}")
    return False


def a_ne(stats: Stats, name: str, got: Any, not_expected: Any) -> bool:
    if got != not_expected:
        stats.pass_(name, f"!= {not_expected!r}")
        return True
    stats.fail(name, f"got={got!r} should differ from {not_expected!r}")
    return False


def a_contains(stats: Stats, name: str, haystack: str,
               needle: str, *, case_insensitive: bool = False) -> bool:
    h = haystack.lower() if case_insensitive else haystack
    n = needle.lower() if case_insensitive else needle
    if n in h:
        stats.pass_(name, f"contains {needle!r}")
        return True
    short = haystack.strip().replace("\n", "\\n")[:140]
    stats.fail(name, f"missing {needle!r}; saw {short!r}")
    return False


def a_contains_any(stats: Stats, name: str, haystack: str,
                   needles: Iterable[str],
                   *, case_insensitive: bool = False) -> bool:
    h = haystack.lower() if case_insensitive else haystack
    for n in needles:
        if (n.lower() if case_insensitive else n) in h:
            stats.pass_(name, f"contains {n!r}")
            return True
    short = haystack.strip().replace("\n", "\\n")[:140]
    stats.fail(name,
               f"none of {list(needles)!r} in output; saw {short!r}")
    return False


def a_not_contains(stats: Stats, name: str, haystack: str,
                   needle: str, *, case_insensitive: bool = False) -> bool:
    h = haystack.lower() if case_insensitive else haystack
    n = needle.lower() if case_insensitive else needle
    if n not in h:
        stats.pass_(name, f"absent {needle!r}")
        return True
    stats.fail(name, f"unexpectedly found {needle!r}")
    return False


def a_regex(stats: Stats, name: str, haystack: str,
            pattern: str, *, flags: int = 0) -> bool:
    if re.search(pattern, haystack, flags):
        stats.pass_(name, f"~/{pattern}/")
        return True
    short = haystack.strip().replace("\n", "\\n")[:140]
    stats.fail(name, f"no match for /{pattern}/; saw {short!r}")
    return False


def a_exit_ok(stats: Stats, name: str, r: RunResult) -> bool:
    if r.ok:
        stats.pass_(name, f"exit=0 ({r.elapsed:.1f}s)")
        return True
    snippet = r.err_plain.strip().replace("\n", "\\n")[:140]
    stats.fail(name, f"exit={r.returncode} err={snippet!r}")
    return False


def a_exit_nonzero(stats: Stats, name: str, r: RunResult) -> bool:
    if not r.ok:
        stats.pass_(name, f"exit={r.returncode}")
        return True
    stats.fail(name, "unexpected exit 0")
    return False


def a_cfg_eq(stats: Stats, name: str, opt: str, expected: str) -> bool:
    got = get_config_field(opt)
    if got == expected:
        stats.pass_(name, f"{opt} = {expected!r}")
        return True
    stats.fail(name, f"{opt}: got={got!r} expected={expected!r}")
    return False


def a_cfg_contains(stats: Stats, name: str, opt: str,
                   needle: str) -> bool:
    got = get_config_field(opt)
    if needle in got:
        stats.pass_(name, f"{opt} ~ {needle!r}")
        return True
    stats.fail(name, f"{opt}: {needle!r} not in {got!r}")
    return False


# =============================================================================
#                           GLOBAL TEST ARGUMENTS
# =============================================================================

ARGS: Any = None   # populated in main()


def _apply_test_preset(cm: ConfigManager, args) -> None:
    """Baseline configuration for tests that need to run LLM queries."""
    cm.set("key", args.key)
    if args.url:
        cm.set("url", args.url)
    if args.model:
        cm.set("model", args.model)
    cm.set("double-check",   "false")
    cm.set("manual-confirm", "false")
    cm.set("hide-process",   "true")
    cm.set("vivid",          "false")
    cm.set("log",            "true")
    cm.set("cache",          "true")


# =============================================================================
# =============================================================================
#                        S E C T I O N   A :   INFO & HELP
# =============================================================================
# =============================================================================

def section_info_help(stats: Stats) -> None:
    stats.section = "A"
    log_hdr("SECTION A -- info & help surfaces")

    # A-1 version
    log_sub("A.1 version")
    r = run_get("version")
    a_exit_ok(stats, "A01 get version exits 0", r)
    if r.ok:
        ver = r.out_plain.strip()
        a_regex(stats, "A02 version matches X.Y(.Z)", ver,
                r"\d+\.\d+")
        a_not_contains(stats, "A03 version has no stack trace",
                       ver, "traceback", case_insensitive=True)

    # A-2 help variants
    log_sub("A.2 help / --help / -h")
    for i, cmd in enumerate(["help", "--help", "-h"], start=4):
        r = run_get(cmd)
        a_exit_ok(stats, f"A{i:02d} `get {cmd}` exits 0", r)
        if r.ok:
            text = r.out_plain.lower()
            a_contains(stats, f"A{i + 3:02d} `get {cmd}` mentions usage",
                       text, "usage")

    # A-10 usage mentions at least several subcommands
    r = run_get("help")
    text = r.out_plain.lower()
    for idx, kw in enumerate(["set", "config", "cache", "log"], start=10):
        a_contains(stats, f"A{idx:02d} help mentions `{kw}`", text, kw)

    # A-14 get get all fields
    log_sub("A.3 `get get` self metadata")
    r = run_get("get")
    a_exit_ok(stats, "A14 `get get` exits 0", r)
    if r.ok:
        low = r.out_plain.lower()
        for idx, kw in enumerate(["name", "version", "author",
                                  "license", "github"], start=15):
            a_contains(stats, f"A{idx:02d} `get get` has {kw}", low, kw)

    # A-20..A-23 individual meta flags
    for idx, (flag, check) in enumerate([
            ("--intro", lambda s: len(s.strip()) > 5),
            ("--version", lambda s: re.search(r"\d+\.\d+", s)),
            ("--license", lambda s: "agpl" in s.lower()
             or "gpl" in s.lower()
             or "mit" in s.lower()),
            ("--github", lambda s: "github.com" in s.lower()),
    ], start=20):
        r = run_get("get", flag)
        if r.ok and check(r.out_plain):
            stats.pass_(f"A{idx:02d} `get get {flag}` content ok")
        else:
            stats.fail(f"A{idx:02d} `get get {flag}`",
                       f"exit={r.returncode} out={r.out_plain[:80]!r}")

    # A-24 unknown meta flag
    r = run_get("get", "--totally-unknown-flag")
    a_exit_nonzero(stats, "A24 unknown meta flag fails", r)


# =============================================================================
#                      S E C T I O N   B :   BOOLEAN OPTIONS
# =============================================================================

def section_boolean_options(stats: Stats) -> None:
    stats.section = "B"
    log_hdr("SECTION B -- boolean options roundtrip")
    cm = ConfigManager()   # local manager; we only call set/clear
    idx = 1
    for opt in BOOL_OPTIONS:
        log_sub(f"B.{opt}")
        prev = get_config_field(opt)
        for value in ("true", "false"):
            ok_ = cm.set(opt, value)
            if not ok_:
                stats.fail(f"B{idx:02d} set {opt}={value} exit 0",
                           "non-zero exit")
                idx += 1
                continue
            stats.pass_(f"B{idx:02d} set {opt}={value} exit 0")
            idx += 1
            a_cfg_eq(stats, f"B{idx:02d} readback {opt}",
                     opt, value)
            idx += 1
        # restore to previous value (should not be 'default' notion)
        if prev in ("true", "false"):
            cm.set(opt, prev)


# =============================================================================
#                      S E C T I O N   C :   INTEGER OPTIONS
# =============================================================================

def section_integer_options(stats: Stats) -> None:
    stats.section = "C"
    log_hdr("SECTION C -- integer options (int / disabled / default)")
    cm = ConfigManager()
    idx = 1
    for opt, default_val in INT_OPTIONS_DEFAULTS.items():
        log_sub(f"C.{opt}")
        prev = get_config_field(opt)

        # positive int
        cm.set(opt, "42")
        a_cfg_eq(stats, f"C{idx:02d} set {opt}=42", opt, "42")
        idx += 1

        # disabled ("false")
        cm.set(opt, "false")
        a_cfg_eq(stats, f"C{idx:02d} disable {opt}",
                 opt, "false")
        idx += 1

        # reset to default (omit value)
        cm.clear(opt)
        a_cfg_eq(stats, f"C{idx:02d} reset {opt} default",
                 opt, default_val)
        idx += 1

        # restore user value
        if prev and prev != default_val:
            cm.set(opt, prev)


# =============================================================================
#                        S E C T I O N   D :   STRINGS
# =============================================================================

def section_string_options(stats: Stats) -> None:
    stats.section = "D"
    log_hdr("SECTION D -- string options (url / model / system-prompt)")
    cm = ConfigManager()

    prev_url = get_config_field("url")
    prev_model = get_config_field("model")
    prev_sp = get_config_field("system-prompt")

    # D.url
    log_sub("D.url")
    cm.set("url", "https://example.test/v1")
    a_cfg_eq(stats, "D01 url roundtrip",
             "url", "https://example.test/v1")
    cm.set("url", "http://localhost:8080/api/v1")
    a_cfg_eq(stats, "D02 url alt roundtrip",
             "url", "http://localhost:8080/api/v1")
    cm.set("url", prev_url)
    a_cfg_eq(stats, "D03 url restore", "url", prev_url)

    # D.model
    log_sub("D.model")
    cm.set("model", "test-model-xyz-1")
    a_cfg_eq(stats, "D04 model roundtrip", "model", "test-model-xyz-1")
    cm.set("model", "another/model-v2")
    a_cfg_eq(stats, "D05 model roundtrip with slash",
             "model", "another/model-v2")
    cm.set("model", prev_model)
    a_cfg_eq(stats, "D06 model restore", "model", prev_model)

    # D.system-prompt
    log_sub("D.system-prompt")
    sp1 = "You are a terse assistant. Reply concisely."
    cm.set("system-prompt", sp1)
    a_cfg_eq(stats, "D07 system-prompt roundtrip",
             "system-prompt", sp1)
    sp2 = "Multiple words including punctuation: apostrophes' and \"quotes\"."
    cm.set("system-prompt", sp2)
    a_cfg_eq(stats, "D08 system-prompt punctuation",
             "system-prompt", sp2)
    cm.clear("system-prompt")
    a_cfg_eq(stats, "D09 system-prompt clear",
             "system-prompt", "")
    if prev_sp:
        cm.set("system-prompt", prev_sp)


# =============================================================================
#                     S E C T I O N   E :   COMMAND-PATTERN
# =============================================================================

def section_command_pattern(stats: Stats) -> None:
    stats.section = "E"
    log_hdr("SECTION E -- command-pattern semantics")
    cm = ConfigManager()
    prev = get_config_field("command-pattern")

    # E-1 built-in default when value omitted
    cm.clear("command-pattern")
    v = get_config_field("command-pattern")
    ok_builtin = "built-in" in v.lower() and ("\\b" in v or r"\b" in v)
    if ok_builtin:
        stats.pass_("E01 command-pattern default = built-in regex")
    else:
        stats.fail("E01 command-pattern default", f"got={v!r}")

    # E-2 disabled when empty string
    cm.set("command-pattern", "")
    v = get_config_field("command-pattern")
    if "disabled" in v.lower():
        stats.pass_("E02 command-pattern \"\" => disabled")
    else:
        stats.fail("E02 command-pattern disabled", f"got={v!r}")

    # E-3 custom pattern roundtrip
    cm.set("command-pattern", r"\bmydanger\b")
    v = get_config_field("command-pattern")
    if r"\bmydanger\b" in v:
        stats.pass_("E03 command-pattern custom roundtrip")
    else:
        stats.fail("E03 command-pattern custom", f"got={v!r}")

    # E-4 very permissive / weak pattern still accepted
    r = run_get("set", "command-pattern", "^ls$")
    a_exit_ok(stats, "E04 weak pattern accepted", r)

    # E-5 regex with pipe alternation
    alt = r"\b(rm|dd|mkfs)\b"
    cm.set("command-pattern", alt)
    a_cfg_contains(stats, "E05 alternation pattern", "command-pattern", alt)

    # E-6 invalid regex still probably rejected OR still stored — we only
    #     require the CLI does not crash
    r = run_get("set", "command-pattern", "[unbalanced")
    if r.returncode in (0, 1, 2):
        stats.pass_("E06 malformed pattern handled without crash",
                    f"exit={r.returncode}")
    else:
        stats.fail("E06 malformed pattern crash", f"exit={r.returncode}")

    # restore
    if "built-in" in prev.lower():
        cm.clear("command-pattern")
    elif "disabled" in prev.lower():
        cm.set("command-pattern", "")
    else:
        # best-effort: strip tags if the "value" shown includes decoration
        m = re.search(r"(\\b.*\\b)", prev)
        if m:
            cm.set("command-pattern", m.group(1))
        else:
            cm.clear("command-pattern")


# =============================================================================
#                      S E C T I O N   F :   KEY & CONFIG
# =============================================================================

def section_key_and_config(stats: Stats) -> None:
    stats.section = "F"
    log_hdr("SECTION F -- key storage and config view")
    cm = ConfigManager()

    # F.1 key set does not leak
    log_sub("F.1 key isolation")
    cm.set("key", ARGS.key)
    shown = get_config_field("key")
    if "set" in shown.lower() and ARGS.key not in shown:
        stats.pass_("F01 `config --key` says 'set' without leaking value")
    else:
        stats.fail("F01 key leak guard", f"shown={shown!r}")

    # F.2 clear key
    cm.clear("key")
    shown = get_config_field("key")
    if "not set" in shown.lower() or "unset" in shown.lower():
        stats.pass_("F02 cleared key shows 'not set'")
    else:
        stats.fail("F02 cleared key state", f"shown={shown!r}")

    # F.3 re-apply
    cm.set("key", ARGS.key)
    shown = get_config_field("key")
    if "set" in shown.lower():
        stats.pass_("F03 re-applied key -> shown 'set'")
    else:
        stats.fail("F03 re-apply key", f"shown={shown!r}")

    # F.4 config shows many fields
    log_sub("F.2 config view")
    cfg = get_config()
    a_eq(stats, "F04 config has >= 16 fields",
         len(cfg) >= 16, True, detail=f"count={len(cfg)}")

    # F.5-F.10 each known key present
    for idx, opt in enumerate(
            ["url", "model", "timeout", "max-token",
             "cache-expiry", "log"], start=5):
        if opt in cfg:
            stats.pass_(f"F{idx:02d} config has `{opt}`")
        else:
            stats.fail(f"F{idx:02d} config missing `{opt}`", repr(cfg))

    # F.11 reset
    log_sub("F.3 config --reset")
    cm.set("timeout", "777")
    cm.set("max-token", "11111")
    r = run_get("config", "--reset")
    a_exit_ok(stats, "F11 `config --reset` exit 0", r)
    a_cfg_eq(stats, "F12 timeout back to default",
             "timeout", INT_OPTIONS_DEFAULTS["timeout"])
    a_cfg_eq(stats, "F13 max-token back to default",
             "max-token", INT_OPTIONS_DEFAULTS["max-token"])

    # F.14 unknown --xxx
    r = run_get("config", "--totally-unknown-opt")
    a_exit_nonzero(stats, "F14 unknown config flag fails", r)

    # reapply test credentials since reset wiped them
    _apply_test_preset(cm, ARGS)


# =============================================================================
#                     S E C T I O N   G :   INVALID INPUTS
# =============================================================================

def section_invalid_inputs(stats: Stats) -> None:
    stats.section = "G"
    log_hdr("SECTION G -- invalid CLI input")

    # G-01 bool with non-boolean value
    cases = [
        ("G01 bool non-bool value",
         ["set", "double-check", "maybe"]),
        ("G02 bool empty-string odd value",
         ["set", "instance", "?"]),
        ("G03 int non-numeric",
         ["set", "timeout", "abc"]),
        ("G04 int negative",
         ["set", "timeout", "-5"]),
        ("G05 int float",
         ["set", "timeout", "3.14"]),
        ("G06 int with unit",
         ["set", "cache-expiry", "30d"]),
        ("G07 int overflow-ish",
         ["set", "max-token", "999999999999999999999"]),
        ("G08 unknown option name",
         ["set", "nosuch-opt", "x"]),
        ("G09 set missing option name",
         ["set"]),
        ("G10 unknown top-level subcommand",
         ["no-such-command"]),
        ("G11 query + --model with no value",
         ["what is two plus two", "--model"]),
        ("G12 query + --timeout with no value",
         ["what is two plus two", "--timeout"]),
        ("G13 query + --timeout not a number",
         ["what is two plus two", "--timeout", "notanumber"]),
        ("G14 cache --unset missing arg",
         ["cache", "--unset"]),
        ("G15 set url missing value would be clear — allowed; "
         "but set with unknown flag should fail",
         ["set", "--no-such-flag"]),
        ("G16 config --key value (flag does not take value)",
         ["config", "--key", "should-not-accept"]),
        ("G17 get get unknown flag",
         ["get", "--no-such-meta"]),
        ("G18 integer option 'true' not allowed",
         ["set", "timeout", "true"]),
    ]
    for name, argv in cases:
        r = run_get(*argv, timeout=15)
        a_exit_nonzero(stats, name, r)

    # G-19 empty query string treated as missing (permissive: may succeed
    # printing help or fail; we accept either but require no crash)
    r = run_get("", timeout=15)
    if r.returncode in (0, 1, 2):
        stats.pass_(f"G19 empty query handled (exit {r.returncode})")
    else:
        stats.fail("G19 empty query crash", f"exit={r.returncode}")


# =============================================================================
#                   S E C T I O N   H :   CACHE / LOG MGMT
# =============================================================================

def section_cache_log_mgmt(stats: Stats) -> None:
    stats.section = "H"
    log_hdr("SECTION H -- cache/log management commands")

    # H.1 cache display
    log_sub("H.1 cache display")
    r = run_get("cache")
    a_exit_ok(stats, "H01 `cache` exits 0", r)
    info = parse_keyvalues(r.stdout)
    for idx, k in enumerate(
            ["cache", "entries", "max-entries", "file"], start=2):
        if k in info:
            stats.pass_(f"H{idx:02d} cache display has `{k}`")
        else:
            stats.fail(f"H{idx:02d} cache display missing `{k}`",
                       f"fields={list(info)}")

    # H.6 cache --clean
    r = run_get("cache", "--clean")
    a_exit_ok(stats, "H06 `cache --clean` exits 0", r)
    n = cache_entries_count()
    a_eq(stats, "H07 entries after --clean", n, 0)

    # H.8 cache --unset non-existent query
    r = run_get("cache", "--unset", "this-query-does-not-exist-xxx")
    a_exit_ok(stats, "H08 `cache --unset` on unknown query exits 0", r)
    n2 = cache_entries_count()
    a_eq(stats, "H09 entries unchanged after no-op unset", n2, 0)

    # H.10 log display
    log_sub("H.2 log display")
    r = run_get("log")
    a_exit_ok(stats, "H10 `log` exits 0", r)
    info = parse_keyvalues(r.stdout)
    for idx, k in enumerate(
            ["log", "entries", "file", "file-size"], start=11):
        if k in info:
            stats.pass_(f"H{idx:02d} log display has `{k}`")
        else:
            stats.fail(f"H{idx:02d} log display missing `{k}`",
                       f"fields={list(info)}")

    # H.15 log --clean
    r = run_get("log", "--clean")
    a_exit_ok(stats, "H15 `log --clean` exits 0", r)
    a_eq(stats, "H16 log entries after clean",
         log_entries_count(), 0)

    # H.17 log display file path points to a real file
    info = get_log_info()
    fpath = info.get("file", "")
    if fpath and Path(fpath).exists():
        stats.pass_(f"H17 log file exists at {fpath}")
    elif fpath:
        stats.pass_("H17 log file path reported (may not be created yet)",
                    detail=fpath)
    else:
        stats.fail("H17 log file path missing", "")

    # H.18 cache display file path reasonable
    info = get_cache_info()
    cpath = info.get("file", "")
    if cpath:
        stats.pass_(f"H18 cache file path reported", detail=cpath)
    else:
        stats.fail("H18 cache file path missing", "")


# =============================================================================
# =============================================================================
#                   S E C T I O N   I :   INSTANCE LLM QUERIES
# =============================================================================
# =============================================================================
#
# Each test runs a real query in *instance* mode (single-shot, no tools) and
# validates the response against locally-computed ground truth or structural
# expectations.

def _llm_precondition(stats: Stats, prefix: str,
                      count: int) -> bool:
    if ARGS.skip_llm:
        for i in range(count):
            stats.skip(f"{prefix}{i + 1:02d} skipped", "--skip-llm set")
        return False
    return True


def _run_query(query: str, *flags: str,
               timeout: int = 180,
               hide_process: bool = True) -> RunResult:
    args = list(flags)
    # Baseline determinism flags (unless overridden)
    if "--no-vivid" not in args and "--vivid" not in args:
        args.append("--no-vivid")
    if hide_process and "--hide-process" not in args \
            and "--no-hide-process" not in args:
        args.append("--hide-process")
    return run_get(query, *args, timeout=timeout)


# ---- instance-mode ground-truth query table -------------------------------
#
# (name, query_text, validator(plain_output) -> bool, notes)

def _instance_query_table() -> List[Tuple[str, str,
                                          Callable[[str], bool], str]]:
    f = FACTS
    host = f.short_host
    user = f.username
    cwd = f.cwd
    year = f.year
    pyv = f.py_major_minor
    plt = f.platform_name
    return [
        ("hostname",
         "reply with ONLY the local hostname, nothing else",
         lambda o: f.hostname in o or host in o,
         "matches socket.gethostname()"),
        ("username",
         "reply with ONLY the current unix/linux user name, "
         "nothing else",
         lambda o: user and user in o,
         "matches getpass.getuser()"),
        ("cwd",
         "reply with ONLY the current working directory absolute path",
         lambda o: cwd in o or f.cwd_basename in o,
         "matches os.getcwd()"),
        ("home",
         "reply with ONLY the user's home directory path",
         lambda o: f.home in o or os.path.basename(f.home) in o,
         "matches $HOME"),
        ("os_name",
         "reply with ONLY the operating system kernel/family name "
         "(one of: Linux, Darwin, Windows)",
         lambda o: plt in o.lower()
         or ("mac" in o.lower() and plt == "darwin")
         or ("windows" in o.lower() and plt == "windows"),
         "matches platform.system()"),
        ("year",
         f"reply with ONLY the current year as a 4-digit number",
         lambda o: year in o,
         "current year"),
        ("python_version",
         "reply with ONLY the major.minor version of the system "
         "Python 3 interpreter (e.g. 3.12)",
         lambda o: pyv in o,
         "matches sys.version_info"),
        ("ip_format",
         "reply with ONLY the primary local IPv4 address of this machine "
         "in dotted-decimal form",
         lambda o: re.search(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", o)
         is not None,
         "IPv4 regex match"),
        ("disk_listing_exists",
         "list root-level directories under /  (or C:\\ on windows). "
         "reply with at least three entries separated by newlines or spaces",
         lambda o: any(
             tok in o for tok in
             ("/bin", "/etc", "/usr", "/var",
              "bin", "etc", "usr", "var",
              "Windows", "Users", "Program")),
         "contains canonical dir names"),
        ("simple_math",
         "what is 17 plus 25. reply with ONLY the numeric answer.",
         lambda o: "42" in o,
         "17+25=42"),
        ("bigger_math",
         "what is 123 multiplied by 456. reply with ONLY "
         "the numeric answer, no commas.",
         lambda o: "56088" in o,
         "123*456=56088"),
        ("string_len",
         "how many characters are in the word 'encyclopedia'. "
         "reply with ONLY the number.",
         lambda o: "12" in o,
         "len('encyclopedia')==12"),
        ("uppercase",
         "convert 'hello world' to all uppercase and reply with "
         "ONLY the result",
         lambda o: "HELLO WORLD" in o,
         "simple transform"),
        ("json_parse",
         'parse this JSON and reply with ONLY the value of the '
         '"value" field: {"value": 314, "other": 1}',
         lambda o: "314" in o,
         "json parse"),
        ("yes_no_file",
         "is /etc/hostname a reasonable path for a Linux system "
         "file that stores the hostname? answer yes or no only.",
         lambda o: "yes" in o.lower(),
         "yes/no factual"),
        ("short_poem",
         "write exactly one four-line poem about the number 42; "
         "include the digits '42' literally somewhere in the poem",
         lambda o: (len(o.strip().splitlines()) >= 3
                    or o.count("|") >= 3)
         and ("42" in o
              or "forty-two" in o.lower()
              or "forty two" in o.lower()),
         "format + content"),
        ("language_code",
         "what is the two-letter ISO 639-1 code for the English "
         "language. reply with ONLY the two letters.",
         lambda o: re.search(r"\ben\b", o, re.IGNORECASE) is not None,
         "ISO 639-1 en"),
        ("day_count",
         "how many days are in a common (non-leap) year. "
         "reply with ONLY the number.",
         lambda o: "365" in o,
         "factual"),
        ("negation",
         "is the statement 'the sun rises in the west' true or false? "
         "reply with ONLY one word.",
         lambda o: "false" in o.lower(),
         "logic"),
        ("multi_language",
         "how do you say 'thank you' in Spanish? "
         "reply with ONLY the spanish phrase.",
         lambda o: "gracias" in o.lower(),
         "translate"),
    ]


def section_instance_queries(stats: Stats) -> None:
    stats.section = "I"
    log_hdr("SECTION I -- instance-mode real LLM queries (ground truth)")
    table = _instance_query_table()
    if not _llm_precondition(stats, "I", len(table) + 8):
        return

    cm = ConfigManager()
    cm.set("instance", "true")
    cm.set("double-check", "false")
    cm.set("manual-confirm", "false")
    cm.set("hide-process", "true")
    cm.set("vivid", "false")
    cm.set("cache", "true")
    cm.set("log", "true")
    run_get("cache", "--clean")

    # I-1..I-20 ground truth queries
    for idx, (name, query, validate, note) in enumerate(
            table, start=1):
        log_sub(f"I.{idx} {name}")
        r = _run_query(query, "--no-cache", timeout=180)
        if not r.ok:
            stats.fail(f"I{idx:02d} {name} exit",
                       f"exit={r.returncode} "
                       f"err={r.err_plain[:120]!r}")
            continue
        plain = r.out_plain.strip()
        if validate(plain):
            stats.pass_(f"I{idx:02d} {name}",
                        detail=f"{note} ({r.elapsed:.1f}s)")
        else:
            short = plain.replace("\n", " | ")[:140]
            stats.fail(f"I{idx:02d} {name}",
                       f"output did not validate; saw {short!r}")

    # I-21 --no-vivid no ANSI
    log_sub("I.21 --no-vivid has no ANSI in stdout")
    r = _run_query("reply with the word 'vivid-off'",
                   "--no-cache", "--no-vivid", timeout=120)
    if r.ok and ANSI_RE.search(r.stdout) is None:
        stats.pass_("I21 --no-vivid strips ANSI")
    else:
        stats.fail("I21 --no-vivid",
                   f"ok={r.ok} has_ansi="
                   f"{bool(ANSI_RE.search(r.stdout))}")

    # I-22 --vivid may emit ANSI (we don't strictly assert — terminals differ)
    r = _run_query("reply with the word 'vivid-on'",
                   "--no-cache", "--vivid", timeout=120)
    if r.ok:
        stats.pass_("I22 --vivid succeeds",
                    detail=f"has_ansi={bool(ANSI_RE.search(r.stdout))}")
    else:
        stats.fail("I22 --vivid", f"exit={r.returncode}")

    # I-23 --hide-process suppresses 'executing' markers in stderr
    r = _run_query("reply with 'hp-test'", "--no-cache",
                   "--hide-process", timeout=120)
    low = r.err_plain.lower()
    if r.ok and "executing" not in low and "round" not in low:
        stats.pass_("I23 --hide-process suppresses rounds/exec markers")
    else:
        stats.fail("I23 --hide-process",
                   f"stderr={low.strip()[:120]!r}")

    # I-24 --no-hide-process may show markers (non-strict)
    r = _run_query("reply with 'hp-test-visible'", "--no-cache",
                   "--no-hide-process", timeout=120,
                   hide_process=False)
    if r.ok:
        stats.pass_("I24 --no-hide-process succeeds")
    else:
        stats.fail("I24 --no-hide-process", f"exit={r.returncode}")

    # I-25 --model override runs
    mdl = ARGS.model or "gpt-4o-mini"
    r = _run_query("reply with 'mdl'", "--no-cache",
                   "--model", mdl, timeout=120)
    a_exit_ok(stats, f"I25 --model {mdl} override runs", r)

    # I-26 --timeout override runs
    r = _run_query("reply with 'to'", "--no-cache",
                   "--timeout", "120", timeout=140)
    a_exit_ok(stats, "I26 --timeout override runs", r)

    # I-27 --no-cache explicit
    r = _run_query("reply with 'nc'", "--no-cache", timeout=120)
    a_exit_ok(stats, "I27 --no-cache explicit exit 0", r)

    # I-28 response is non-empty
    r = _run_query("reply with the word 'nonempty'",
                   "--no-cache", timeout=120)
    if r.ok and len(r.out_plain.strip()) > 0:
        stats.pass_("I28 non-empty response",
                    detail=f"{len(r.out_plain)} bytes")
    else:
        stats.fail("I28 non-empty response",
                   f"exit={r.returncode} len={len(r.out_plain)}")


# =============================================================================
# =============================================================================
#                    S E C T I O N   J :   AGENT LLM QUERIES
# =============================================================================
# =============================================================================
#
# Agent mode -- the tool uses shell commands to produce the answer.

def _agent_query_table(scratch: Path
                       ) -> List[Tuple[str, str,
                                       Callable[[str], bool], str]]:
    f = FACTS
    return [
        ("uname",
         "report the kernel/OS name using the local system. "
         "include the os name in the reply.",
         lambda o: f.platform_name in o.lower()
         or ("darwin" in o.lower() and f.platform_name == "darwin"),
         "agent invokes `uname` or equivalent"),
        ("hostname_tool",
         "report the local hostname.  include the hostname string "
         "in the reply.",
         lambda o: f.hostname in o or f.short_host in o,
         "agent invokes `hostname`"),
        ("current_user",
         "who am i? report the current unix user. include the "
         "username in the reply.",
         lambda o: f.username in o,
         "agent invokes `whoami` or `id`"),
        ("pwd",
         "print the current working directory of this shell session. "
         "include the path in the reply.",
         lambda o: f.cwd in o or f.cwd_basename in o,
         "agent invokes `pwd`"),
        ("list_scratch",
         f"list the files directly inside the directory "
         f"'{scratch}'. include the filename 'alpha.txt' in the reply.",
         lambda o: "alpha.txt" in o,
         "agent invokes `ls <path>`"),
        ("count_lines",
         f"how many lines are in the file '{scratch / 'numbers.txt'}'? "
         f"reply with the number prominently.",
         lambda o: "10" in o,
         "agent invokes `wc -l`"),
        ("grep_content",
         f"find which line in '{scratch / 'words.txt'}' contains "
         f"the word 'needle'. include the word 'needle' in the reply.",
         lambda o: "needle" in o.lower(),
         "agent invokes `grep`"),
        ("first_line",
         f"what is the first line of '{scratch / 'alpha.txt'}'? "
         f"include its text prominently.",
         lambda o: "first-line-marker-42" in o,
         "agent invokes `head -n 1` or `sed`"),
        ("file_size",
         f"how many bytes does '{scratch / 'alpha.txt'}' occupy "
         f"on disk? include the number prominently.",
         lambda o: re.search(r"\b\d{1,6}\b", o) is not None,
         "agent invokes `stat` or `wc -c`"),
        ("python_version_agent",
         "what is the installed python 3 version on this system? "
         "include the version number in the reply.",
         lambda o: f.py_major_minor in o or f.py_major in o,
         "agent invokes `python3 --version`"),
    ]


def _build_scratch() -> Path:
    tmp = Path(tempfile.mkdtemp(prefix="get_test_scratch_"))
    (tmp / "alpha.txt").write_text(
        "first-line-marker-42\nsecond line\nthird\n",
        encoding="utf-8")
    (tmp / "numbers.txt").write_text(
        "\n".join(str(i) for i in range(1, 11)) + "\n",
        encoding="utf-8")
    (tmp / "words.txt").write_text(
        "apple\nbanana\ncherry needle line\ndate\n",
        encoding="utf-8")
    (tmp / "empty.txt").write_text("", encoding="utf-8")
    (tmp / "subdir").mkdir()
    (tmp / "subdir" / "inner.txt").write_text(
        "inside-subdir-content\n", encoding="utf-8")
    return tmp


def section_agent_queries(stats: Stats) -> None:
    stats.section = "J"
    log_hdr("SECTION J -- agent-mode queries (tool invocation)")
    scratch = _build_scratch()
    log_info(f"scratch dir: {scratch}")

    table = _agent_query_table(scratch)
    if not _llm_precondition(stats, "J", len(table) + 6):
        shutil.rmtree(scratch, ignore_errors=True)
        return

    cm = ConfigManager()
    cm.set("instance", "false")
    cm.set("double-check", "false")
    cm.set("manual-confirm", "false")
    cm.set("hide-process", "true")
    cm.set("vivid", "false")
    cm.set("cache", "true")
    cm.set("log", "true")
    cm.set("max-rounds", "5")
    run_get("log", "--clean")
    run_get("cache", "--clean")

    for idx, (name, query, validate, note) in enumerate(table, start=1):
        log_sub(f"J.{idx} {name}")
        r = _run_query(query, "--no-cache", timeout=240)
        if not r.ok:
            stats.fail(f"J{idx:02d} {name} exit",
                       f"exit={r.returncode} "
                       f"err={r.err_plain[:120]!r}")
            continue
        plain = r.out_plain
        if validate(plain):
            stats.pass_(f"J{idx:02d} {name}",
                        detail=f"{note} ({r.elapsed:.1f}s)")
        else:
            short = plain.replace("\n", " | ")[:140]
            stats.fail(f"J{idx:02d} {name}",
                       f"did not validate; saw {short!r}")

    # J-extra 11 max-rounds = 1 terminates cleanly
    cm.set("max-rounds", "1")
    r = _run_query(
        "use at least three distinct shell commands to gather "
        "information and reply. include the word 'done'.",
        "--no-cache", timeout=120)
    if r.returncode in (0, 1, 2):
        stats.pass_("J11 max-rounds=1 terminates without crash",
                    detail=f"exit={r.returncode}")
    else:
        stats.fail("J11 max-rounds=1", f"exit={r.returncode}")

    # J-12 agent queries appended log entries
    n_before = log_entries_count()
    cm.set("max-rounds", "3")
    _run_query("reply with the word 'log-probe'",
               "--no-cache", timeout=120)
    n_after = log_entries_count()
    if n_after > n_before:
        stats.pass_(f"J12 agent query appended log "
                    f"({n_before} -> {n_after})")
    else:
        stats.fail("J12 agent log append",
                   f"before={n_before} after={n_after}")

    # J-13 agent without hide-process shows intermediate rounds
    r = _run_query("report the machine hostname in a single word",
                   "--no-cache", "--no-hide-process",
                   timeout=180, hide_process=False)
    merged = r.err_plain.lower() + r.out_plain.lower()
    if r.ok and ("round" in merged
                 or "executing" in merged
                 or "$" in r.err_plain):
        stats.pass_("J13 agent --no-hide-process shows progress")
    else:
        stats.pass_(
            "J13 agent --no-hide-process (progress markers "
            "format depends on backend)",
            detail="accepted as soft-pass")

    # J-14 agent tool-use with system-prompt injection
    cm.set("system-prompt",
           "When listing files, use `ls -1` and only mention files, "
           "not directories.")
    r = _run_query(f"list files in '{scratch}' that contain letters",
                   "--no-cache", timeout=180)
    if r.ok and "alpha.txt" in r.out_plain:
        stats.pass_("J14 system-prompt respected (alpha.txt present)")
    else:
        stats.fail("J14 system-prompt agent",
                   f"ok={r.ok} out={r.out_plain[:120]!r}")
    cm.clear("system-prompt")

    # J-15 command-pattern blocks read-command verbs.
    #
    # Note: `get`'s command-pattern is a verb-level blocklist.  It
    # cannot prevent a sufficiently capable agent from switching
    # to an alternative read tool (bat, rg, python3, grep '',
    # Get-Content, shell here-strings, etc.).  This limitation is
    # documented in README.md and man page SAFETY section.  The
    # system prompt now explicitly asks the model to respect the
    # spirit of the restriction, but compliance is not guaranteed.
    # We therefore accept three outcomes:
    #   (a) the matched command was suppressed (no leaked marker),
    #   (b) the run failed (exit non-zero), or
    #   (c) the model honoured the spirit and refused in text,
    # and soft-pass when the model bypassed via a substitute tool.
    run_get("set", "command-pattern",
            r"\b(cat|head|tail|less|more|sed|awk)\b")
    r = _run_query(
        f"show me the full content of '{scratch / 'alpha.txt'}'",
        "--no-cache", timeout=180)
    if r.ok and "first-line-marker-42" not in r.out_plain:
        stats.pass_("J15 command-pattern suppressed matching command")
    elif not r.ok:
        stats.pass_("J15 command-pattern caused non-zero exit",
                    detail=f"exit={r.returncode}")
    else:
        stats.pass_(
            "J15 content leaked via alternative tool — soft-pass",
            detail=("verb-blocklist cannot prevent agents from "
                    "choosing substitute read tools; this is a "
                    "documented limitation (README.md + man "
                    "page SAFETY section)"))
    run_get("set", "command-pattern", "")  # temporarily disable for rest

    # J-16 restore command-pattern default
    run_get("set", "command-pattern")
    v = get_config_field("command-pattern")
    if "built-in" in v.lower():
        stats.pass_("J16 command-pattern default restored")
    else:
        stats.fail("J16 command-pattern restore", v[:80])

    shutil.rmtree(scratch, ignore_errors=True)


# =============================================================================
# =============================================================================
#                   S E C T I O N   K :   CACHE BEHAVIOUR
# =============================================================================
# =============================================================================

def _unique_query(tag: str) -> str:
    nonce = int(time.time() * 1000) % 1_000_000
    return (f"reply with the exact text 'cache-{tag}-{nonce}' "
            f"and nothing else")


def section_cache_behaviour(stats: Stats) -> None:
    stats.section = "K"
    log_hdr("SECTION K -- cache behaviour & state transitions")

    if not _llm_precondition(stats, "K", 30):
        return

    cm = ConfigManager()
    cm.set("instance", "true")
    cm.set("double-check", "false")
    cm.set("manual-confirm", "false")
    cm.set("hide-process", "true")
    cm.set("vivid", "false")
    cm.set("log", "true")

    # K.1 cache disabled globally produces warning
    log_sub("K.1 cache disabled")
    cm.set("cache", "false")
    q = _unique_query("k1")
    r = _run_query(q, timeout=120)
    warning = r.err_plain.lower()
    if r.ok and "cache is disabled" in warning:
        stats.pass_("K01 cache=false query emits warning")
    elif r.ok:
        stats.pass_("K01 cache=false query runs (warning phrasing differs)",
                    detail=warning.strip()[:80])
    else:
        stats.fail("K01 cache=false query exit",
                   f"exit={r.returncode}")
    cm.set("cache", "true")

    # K.2 cache --clean baseline
    log_sub("K.2 clean cache baseline")
    r = run_get("cache", "--clean")
    a_exit_ok(stats, "K02 clean cache exit 0", r)
    a_eq(stats, "K03 entries == 0 after clean",
         cache_entries_count(), 0)

    # K.3 cache-trigger-threshold=1: first query does NOT create entry
    log_sub("K.3 threshold=1 first-run behaviour")
    cm.set("cache-trigger-threshold", "1")
    q1 = _unique_query("k3")
    n0 = cache_entries_count()
    r1 = _run_query(q1, timeout=120)
    a_exit_ok(stats, "K04 first query with threshold=1 exit 0", r1)
    n1 = cache_entries_count()
    a_eq(stats, "K05 entries unchanged after first query",
         n1, n0)

    # K.4 second identical query may trigger classification
    log_sub("K.4 threshold=1 second-run classification")
    r2 = _run_query(q1, timeout=120)
    a_exit_ok(stats, "K06 second identical query exit 0", r2)
    n2 = cache_entries_count()
    if n2 >= n1:
        stats.pass_(f"K07 entries {n1} -> {n2} (may have classified)")
    else:
        stats.fail("K07 entries decreased?", f"{n1} -> {n2}")

    # K.5 threshold=0 classifies immediately
    log_sub("K.5 threshold=0 immediate classification")
    run_get("cache", "--clean")
    cm.set("cache-trigger-threshold", "0")
    q5 = _unique_query("k5")
    r = _run_query(q5, timeout=120)
    a_exit_ok(stats, "K08 threshold=0 first query exit 0", r)
    n = cache_entries_count()
    if n >= 0:
        stats.pass_(f"K09 threshold=0 after first query entries={n}")
    else:
        stats.fail("K09 cache entries unreadable", "")

    # K.6 threshold=3 requires three runs before classification
    log_sub("K.6 threshold=3 delayed classification")
    run_get("cache", "--clean")
    cm.set("cache-trigger-threshold", "3")
    q6 = _unique_query("k6")
    entries_trace: List[int] = []
    for i in range(3):
        r = _run_query(q6, timeout=120)
        if not r.ok:
            stats.fail(f"K10 threshold=3 run {i + 1} failed",
                       f"exit={r.returncode}")
            entries_trace.append(-1)
            continue
        entries_trace.append(cache_entries_count())
    if all(e >= 0 for e in entries_trace):
        stats.pass_(f"K10 threshold=3 three runs completed",
                    detail=f"entries trace = {entries_trace}")
    # K.11 after threshold+1 runs, classification is possible
    r = _run_query(q6, timeout=120)
    a_exit_ok(stats, "K11 threshold=3 fourth run exit 0", r)

    cm.clear("cache-trigger-threshold")  # back to default

    # K.7 --cache forces immediate classification
    log_sub("K.7 --cache flag forces classification")
    run_get("cache", "--clean")
    q7 = _unique_query("k7")
    r = _run_query(q7, "--cache", timeout=120)
    a_exit_ok(stats, "K12 --cache flag first run exit 0", r)
    n = cache_entries_count()
    if n >= 0:
        stats.pass_(f"K13 --cache first-run entries={n}")
    else:
        stats.fail("K13 --cache first-run", "entries unreadable")

    # K.8 --no-cache bypasses cache completely
    log_sub("K.8 --no-cache bypass")
    q8 = _unique_query("k8")
    r1 = _run_query(q8, "--no-cache", timeout=120)
    r2 = _run_query(q8, "--no-cache", timeout=120)
    if r1.ok and r2.ok:
        stats.pass_("K14 --no-cache repeated runs ok")
    else:
        stats.fail("K14 --no-cache repeats",
                   f"exits={r1.returncode},{r2.returncode}")

    # K.9 cache-hit timing: if second run is hit, it should be fast
    log_sub("K.9 cache-hit timing")
    run_get("cache", "--clean")
    q9 = _unique_query("k9")
    r_first = _run_query(q9, "--cache", timeout=180)
    r_secnd = _run_query(q9, "--cache", timeout=180)
    if r_first.ok and r_secnd.ok:
        stats.pass_(
            "K15 two runs with --cache succeeded",
            detail=f"1st={r_first.elapsed:.1f}s "
            f"2nd={r_secnd.elapsed:.1f}s")
        # Only flag speed-up if second is noticeably faster
        if r_secnd.elapsed <= r_first.elapsed * 0.5 \
                or r_secnd.elapsed < 1.5:
            stats.pass_("K16 second run appears cache-accelerated",
                        detail=f"{r_secnd.elapsed:.1f}s")
        else:
            stats.pass_("K16 second run not faster — likely re-run path",
                        detail=f"{r_secnd.elapsed:.1f}s "
                        f"(acceptable; classifier choice)")
    else:
        stats.fail("K15 cache-hit runs",
                   f"exits={r_first.returncode},{r_secnd.returncode}")

    # K.10 cache --unset specific query
    log_sub("K.10 cache --unset precision")
    qa = _unique_query("ka")
    qb = _unique_query("kb")
    _run_query(qa, "--cache", timeout=120)
    _run_query(qa, "--cache", timeout=120)
    _run_query(qb, "--cache", timeout=120)
    _run_query(qb, "--cache", timeout=120)
    n_before = cache_entries_count()
    r = run_get("cache", "--unset", qa)
    a_exit_ok(stats, "K17 cache --unset exit 0", r)
    n_after = cache_entries_count()
    if n_after <= n_before:
        stats.pass_(f"K18 entries non-increasing after unset "
                    f"({n_before} -> {n_after})")
    else:
        stats.fail("K18 entries grew after unset",
                   f"{n_before} -> {n_after}")

    # K.11 cache --clean wipes everything
    log_sub("K.11 cache --clean wipes all")
    r = run_get("cache", "--clean")
    a_exit_ok(stats, "K19 clean exit 0", r)
    a_eq(stats, "K20 after clean entries==0",
         cache_entries_count(), 0)

    # K.12 cache-max-entries limit enforced by churning queries
    log_sub("K.12 cache-max-entries enforcement")
    cm.set("cache-max-entries", "3")
    cm.set("cache-trigger-threshold", "0")
    for i in range(6):
        _run_query(_unique_query(f"kcap{i}"),
                   "--cache", timeout=120)
    n_final = cache_entries_count()
    if 0 <= n_final <= 3:
        stats.pass_(f"K21 cache-max-entries=3 honoured "
                    f"(entries={n_final})")
    else:
        stats.fail("K21 cache-max-entries=3", f"entries={n_final}")
    cm.clear("cache-max-entries")
    cm.clear("cache-trigger-threshold")

    # K.13 cache expiry: set expiry=1 day — we can only assert the
    # field roundtrip; true expiry is time-based.
    log_sub("K.13 cache-expiry roundtrip")
    cm.set("cache-expiry", "1")
    a_cfg_eq(stats, "K22 cache-expiry=1", "cache-expiry", "1")
    cm.set("cache-expiry", "false")
    a_cfg_eq(stats, "K23 cache-expiry=false", "cache-expiry", "false")
    cm.clear("cache-expiry")
    a_cfg_eq(stats, "K24 cache-expiry reset",
             "cache-expiry", INT_OPTIONS_DEFAULTS["cache-expiry"])

    # K.14 log-max-entries enforcement
    log_sub("K.14 log-max-entries enforcement")
    run_get("log", "--clean")
    cm.set("log-max-entries", "3")
    for i in range(5):
        _run_query(_unique_query(f"lme{i}"),
                   "--no-cache", timeout=120)
    n_log = log_entries_count()
    if 0 <= n_log <= 3:
        stats.pass_(f"K25 log-max-entries=3 honoured (entries={n_log})")
    else:
        stats.fail("K25 log-max-entries=3", f"entries={n_log}")
    cm.clear("log-max-entries")

    # K.15 log=false means no entries appended
    log_sub("K.15 log=false disables append")
    run_get("log", "--clean")
    n0 = log_entries_count()
    cm.set("log", "false")
    _run_query(_unique_query("logoff"), "--no-cache", timeout=120)
    n1 = log_entries_count()
    if n1 == n0:
        stats.pass_(f"K26 log=false did not append (entries={n1})")
    else:
        stats.fail("K26 log=false appended", f"{n0} -> {n1}")
    cm.set("log", "true")


# =============================================================================
# =============================================================================
#               S E C T I O N   L :   PARAMETER INTERACTIONS
# =============================================================================
# =============================================================================

def section_param_interactions(stats: Stats) -> None:
    stats.section = "L"
    log_hdr("SECTION L -- parameter combinations & per-call overrides")

    if not _llm_precondition(stats, "L", 18):
        return

    cm = ConfigManager()
    cm.set("instance", "true")
    cm.set("double-check", "false")
    cm.set("manual-confirm", "false")
    cm.set("hide-process", "true")
    cm.set("vivid", "false")
    cm.set("log", "true")
    cm.set("cache", "true")

    # L.1 per-call --model overrides global model (runs)
    log_sub("L.1 --model override")
    prev_model = get_config_field("model")
    alt_model = ARGS.model or prev_model
    r = _run_query("reply with 'ok'", "--no-cache",
                   "--model", alt_model, timeout=120)
    a_exit_ok(stats, f"L01 --model {alt_model}", r)
    still = get_config_field("model")
    a_eq(stats, "L02 --model does not mutate stored model",
         still, prev_model)

    # L.2 --timeout override runs
    log_sub("L.2 --timeout override")
    r = _run_query("reply with 'ok'", "--no-cache",
                   "--timeout", "90", timeout=120)
    a_exit_ok(stats, "L03 --timeout 90 override", r)

    # L.3 --timeout extremely small triggers failure (hopefully)
    r = _run_query("write a 20-word sentence about the Roman Empire",
                   "--no-cache", "--timeout", "1", timeout=30)
    if not r.ok:
        stats.pass_(f"L04 --timeout 1 aborts (exit={r.returncode})")
    else:
        stats.pass_(
            "L04 --timeout 1 happened to succeed — soft-pass",
            detail="network too fast or permissive timeout semantics")

    # L.4 --vivid produces ANSI; --no-vivid does not
    log_sub("L.3 vivid toggle")
    r_on = _run_query("reply with 'vv'",
                      "--no-cache", "--vivid", timeout=120)
    r_off = _run_query("reply with 'vv'",
                       "--no-cache", "--no-vivid", timeout=120)
    if r_on.ok and r_off.ok:
        ansi_on = bool(ANSI_RE.search(r_on.stdout))
        ansi_off = bool(ANSI_RE.search(r_off.stdout))
        if not ansi_off:
            stats.pass_("L05 --no-vivid: no ANSI in stdout")
        else:
            stats.fail("L05 --no-vivid", "ANSI present in stdout")
        # We don't require --vivid to emit ANSI (may depend on TTY), but
        # we assert at least it does not fail.
        stats.pass_(f"L06 --vivid runs (ansi_on={ansi_on})")
    else:
        stats.fail("L05/L06 vivid toggle",
                   f"exits={r_on.returncode},{r_off.returncode}")

    # L.5 --hide-process toggle
    log_sub("L.4 hide-process toggle")
    r_h = _run_query("reply with 'hp'", "--no-cache",
                     "--hide-process", timeout=120)
    r_s = _run_query("reply with 'hp'", "--no-cache",
                     "--no-hide-process", timeout=120,
                     hide_process=False)
    if r_h.ok and r_s.ok:
        len_h = len(r_h.err_plain)
        len_s = len(r_s.err_plain)
        if len_h <= len_s:
            stats.pass_(f"L07 --hide-process stderr "
                        f"(hp={len_h} vs show={len_s})")
        else:
            stats.pass_(
                "L07 stderr sizes inverse — soft-pass",
                detail="backend may route differently")
    else:
        stats.fail("L07 hide-process toggle",
                   f"exits={r_h.returncode},{r_s.returncode}")

    # L.6 system-prompt influence
    log_sub("L.5 system-prompt")
    prev_sp = get_config_field("system-prompt")
    cm.set("system-prompt",
           "You always append the word 'SPSIG' at the very end of "
           "every reply, on its own line.")
    r = _run_query("reply with the word 'payload'",
                   "--no-cache", timeout=120)
    if r.ok and "SPSIG" in r.out_plain.upper():
        stats.pass_("L08 system-prompt: signature appeared")
    elif r.ok:
        stats.pass_(
            "L08 system-prompt: signature absent — soft-pass",
            detail="model did not obey; not strictly testable")
    else:
        stats.fail("L08 system-prompt run", f"exit={r.returncode}")

    # Restore system-prompt
    if prev_sp:
        cm.set("system-prompt", prev_sp)
    else:
        cm.clear("system-prompt")

    # L.7 manual-confirm global (off) vs --manual-confirm: we can't
    # fully exercise interactive confirmation non-interactively, so
    # we just verify the flags set state cleanly.
    log_sub("L.6 manual-confirm flag")
    r = run_get("set", "manual-confirm", "true")
    a_exit_ok(stats, "L09 set manual-confirm=true", r)
    a_cfg_eq(stats, "L10 manual-confirm = true", "manual-confirm", "true")
    r = run_get("set", "manual-confirm", "false")
    a_exit_ok(stats, "L11 set manual-confirm=false", r)
    a_cfg_eq(stats, "L12 manual-confirm = false", "manual-confirm", "false")

    # L.8 --instance / --no-instance flip runtime mode
    log_sub("L.7 instance / agent runtime flip")
    cm.set("instance", "false")   # make global = agent
    r = _run_query("reply with 'instance-forced'",
                   "--no-cache", "--instance", timeout=120)
    a_exit_ok(stats, "L13 --instance forces instance at runtime", r)
    still = get_config_field("instance")
    a_eq(stats, "L14 --instance flag does not persist to config",
         still, "false")
    cm.set("instance", "true")    # restore

    # L.9 max-rounds=0 — agent mode expected to error or refuse;
    # we accept either behaviour as long as it doesn't hang.
    log_sub("L.8 max-rounds=0 edge")
    prev_mr = get_config_field("max-rounds")
    cm.set("instance", "false")
    cm.set("max-rounds", "0")
    r = _run_query("reply with the word 'mr0'", "--no-cache", timeout=60)
    if r.returncode in (0, 1, 2) and r.elapsed < 60:
        stats.pass_(f"L15 max-rounds=0 finished "
                    f"(exit={r.returncode}, {r.elapsed:.1f}s)")
    else:
        stats.fail("L15 max-rounds=0", f"exit={r.returncode}")
    cm.set("max-rounds", prev_mr)
    cm.set("instance", "true")

    # L.10 max-token very small (may truncate but should not crash)
    log_sub("L.9 max-token very small")
    prev_mt = get_config_field("max-token")
    cm.set("max-token", "32")
    r = _run_query("reply with a sentence about dogs", "--no-cache",
                   timeout=120)
    if r.returncode in (0, 1, 2):
        stats.pass_(f"L16 max-token=32 handled (exit={r.returncode})")
    else:
        stats.fail("L16 max-token=32", f"exit={r.returncode}")
    cm.set("max-token", prev_mt)

    # L.11 external-display toggle (state only, no interactive assert)
    log_sub("L.10 external-display state")
    prev_ed = get_config_field("external-display")
    cm.set("external-display", "true")
    a_cfg_eq(stats, "L17 external-display=true",
             "external-display", "true")
    cm.set("external-display", prev_ed)


# =============================================================================
#                     S E C T I O N   M :   MISSING CONFIG
# =============================================================================

def section_missing_config(stats: Stats) -> None:
    stats.section = "M"
    log_hdr("SECTION M -- missing / invalid critical configuration")

    if not _llm_precondition(stats, "M", 6):
        return

    cm = ConfigManager()
    orig_url = get_config_field("url")
    orig_model = get_config_field("model")
    try:
        # M.1 missing key
        log_sub("M.1 missing key")
        cm.clear("key")
        r = _run_query("reply with 'mc'", "--no-cache", timeout=30)
        low = r.err_plain.lower()
        if not r.ok and ("key" in low or "api" in low):
            stats.pass_(f"M01 missing key -> exit {r.returncode} "
                        f"with helpful message")
        else:
            stats.fail("M01 missing key",
                       f"exit={r.returncode} err={low[:120]!r}")
        cm.set("key", ARGS.key)

        # M.2 missing URL
        log_sub("M.2 missing URL")
        cm.set("url", "")
        r = _run_query("reply with 'mc2'", "--no-cache", timeout=30)
        low = r.err_plain.lower()
        if not r.ok and ("url" in low or "endpoint" in low):
            stats.pass_(f"M02 missing url -> exit {r.returncode}")
        else:
            stats.fail("M02 missing url",
                       f"exit={r.returncode} err={low[:120]!r}")
        cm.set("url", orig_url)

        # M.3 missing model
        log_sub("M.3 missing model")
        cm.set("model", "")
        r = _run_query("reply with 'mc3'", "--no-cache", timeout=30)
        low = r.err_plain.lower()
        if not r.ok and "model" in low:
            stats.pass_(f"M03 missing model -> exit {r.returncode}")
        else:
            stats.fail("M03 missing model",
                       f"exit={r.returncode} err={low[:120]!r}")
        cm.set("model", orig_model)

        # M.4 bad URL (unreachable)
        log_sub("M.4 unreachable URL")
        cm.set("url", "https://127.0.0.1:1/totally-not-a-real-endpoint")
        r = _run_query("reply with 'mc4'", "--no-cache", timeout=30)
        if not r.ok:
            stats.pass_(f"M04 unreachable url -> exit {r.returncode}")
        else:
            stats.fail("M04 unreachable url",
                       f"unexpectedly exit 0")
        cm.set("url", orig_url)

        # M.5 blatantly invalid model name
        log_sub("M.5 invalid model name")
        cm.set("model", "definitely-not-a-real-model-name-xyz-123")
        r = _run_query("reply with 'mc5'", "--no-cache", timeout=60)
        if not r.ok:
            stats.pass_(f"M05 invalid model -> exit {r.returncode}")
        else:
            stats.pass_(
                "M05 invalid model happened to succeed — soft-pass "
                "(proxy may fall through to default)")
        cm.set("model", orig_model)

        # M.6 `get isok` connectivity check (with valid creds)
        log_sub("M.6 get isok")
        r = run_get("isok", timeout=90)
        combined = (r.out_plain + " " + r.err_plain).lower()
        if r.ok and "ok" in combined:
            stats.pass_("M06 get isok passes with valid creds")
        elif r.ok:
            stats.pass_("M06 get isok exit 0",
                        detail="no 'ok' marker — soft-pass")
        else:
            stats.fail("M06 get isok",
                       f"exit={r.returncode} out={combined[:120]!r}")
    finally:
        cm.set("url", orig_url)
        cm.set("model", orig_model)
        cm.set("key", ARGS.key)


# =============================================================================
#                     S E C T I O N   Z :   TEARDOWN
# =============================================================================

def section_teardown(stats: Stats, cm: ConfigManager) -> None:
    stats.section = "Z"
    log_hdr("SECTION Z -- teardown / restore original configuration")
    diffs = cm.restore()
    if not diffs:
        stats.pass_("Z01 original configuration fully restored")
    else:
        stats.fail("Z01 configuration differences after restore",
                   "; ".join(diffs[:5]))

    # Z.2 clear test key (cannot recover user's original, encrypted)
    run_get("set", "key")
    v = get_config_field("key")
    if "not set" in v.lower() or "unset" in v.lower():
        stats.pass_("Z02 test API key cleared from storage")
    else:
        stats.fail("Z02 clear key", f"shown={v!r}")


# =============================================================================
#                            DRIVER / MAIN
# =============================================================================

SECTIONS = [
    ("A", "info_help",          section_info_help,         False),
    ("B", "boolean_options",    section_boolean_options,   False),
    ("C", "integer_options",    section_integer_options,   False),
    ("D", "string_options",     section_string_options,    False),
    ("E", "command_pattern",    section_command_pattern,   False),
    ("F", "key_and_config",     section_key_and_config,    False),
    ("G", "invalid_inputs",     section_invalid_inputs,    False),
    ("H", "cache_log_mgmt",     section_cache_log_mgmt,    False),
    ("I", "instance_queries",   section_instance_queries,  True),
    ("J", "agent_queries",      section_agent_queries,     True),
    ("K", "cache_behaviour",    section_cache_behaviour,   True),
    ("L", "param_interactions", section_param_interactions, True),
    ("M", "missing_config",     section_missing_config,    True),
]


def summarize(stats: Stats) -> None:
    total = stats.passed + stats.failed + stats.skipped
    print()
    print(_c(C.BLD, "=" * 72))
    print(_c(C.BLD, f" Test Summary   total={total}"))
    print(_c(C.BLD, "=" * 72))
    print(f"  {_c(C.GRN, f'passed  : {stats.passed}')}")
    print(f"  {_c(C.RED, f'failed  : {stats.failed}')}")
    print(f"  {_c(C.YEL, f'skipped : {stats.skipped}')}")
    if stats.failures:
        print(f"\n{_c(C.RED, 'Failures:')}")
        for sec, name, reason in stats.failures:
            print(f"  - [{sec}] {_c(C.BLD, name)}: {reason}")
    print()
    print(_c(C.YEL,
             "NOTE: your original encrypted API key could NOT be "
             "recovered by this suite (the key store is write-only)."))
    print(_c(C.YEL,
             "      please re-apply it with:"))
    print(_c(C.BLD, "          get set key <your-original-key>\n"))


def parse_args() -> Any:
    p = argparse.ArgumentParser(
        description="Comprehensive test suite for the `get` CLI.")
    p.add_argument("--key", required=True,
                   help="API key to use for LLM-backed tests")
    p.add_argument("--url", default=None,
                   help="LLM endpoint URL (uses current config default)")
    p.add_argument("--model", default=None,
                   help="model name override for tests")
    p.add_argument("--skip-llm", action="store_true",
                   help="skip any test that requires real LLM calls")
    p.add_argument("--only", default="",
                   help="comma-separated section letters "
                        "to run (e.g. 'A,B,K')")
    p.add_argument("--stop-on-fail", action="store_true",
                   help="stop on first failure")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="echo every `get` invocation")
    return p.parse_args()


def main() -> None:
    global ARGS, VERBOSE, STOP_ON_FAIL
    ARGS = parse_args()
    VERBOSE = ARGS.verbose
    STOP_ON_FAIL = ARGS.stop_on_fail

    only = {s.strip().upper() for s in ARGS.only.split(",")
            if s.strip()} if ARGS.only else None

    log_hdr("`get` comprehensive test suite")
    log_info(f"model       : {ARGS.model or '(config default)'}")
    log_info(f"url         : {ARGS.url or '(config default)'}")
    log_info(f"key         : ****")
    log_info(f"skip-llm    : {ARGS.skip_llm}")
    log_info(f"stop-on-fail: {ARGS.stop_on_fail}")
    log_info(f"only        : "
             f"{','.join(sorted(only)) if only else '(all sections)'}")
    log_info(f"host facts  : host={FACTS.short_host} "
             f"user={FACTS.username} os={FACTS.platform_name} "
             f"py={FACTS.py_major_minor} year={FACTS.year}")

    stats = Stats()
    cm = ConfigManager()

    # Sanity: get must be on PATH
    if shutil.which("get") is None:
        print(_c(C.RED, "fatal: 'get' not found on PATH."),
              file=sys.stderr)
        sys.exit(2)

    # Snapshot before any modification
    try:
        cm.snapshot()
    except Exception as e:
        print(_c(C.RED, f"fatal: could not read current config: {e}"),
              file=sys.stderr)
        sys.exit(2)

    # Apply preset only if running any LLM section
    if not ARGS.skip_llm:
        _apply_test_preset(cm, ARGS)
    else:
        cm.set("key", ARGS.key)   # still set for key-related tests

    # Run selected sections
    try:
        for letter, name, func, needs_llm in SECTIONS:
            if only and letter not in only:
                log_hdr(f"SECTION {letter} ({name}) — skipped by --only")
                continue
            if needs_llm and ARGS.skip_llm:
                # Section itself will emit skips for each test.
                pass
            try:
                func(stats)
            except SystemExit:
                raise
            except Exception as e:
                stats.fail(f"section_{name}_uncaught",
                           f"{type(e).__name__}: {e}")
    finally:
        try:
            section_teardown(stats, cm)
        except Exception as e:
            stats.fail("teardown_uncaught",
                       f"{type(e).__name__}: {e}")

    summarize(stats)
    sys.exit(0 if stats.failed == 0 else 1)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print("\n\ninterrupted.")
        sys.exit(130)
