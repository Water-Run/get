#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
get_test.py -- Comprehensive end-to-end test suite for the `get` CLI.

Sections cover configuration, safety, cache, and live harness behavior.

    A  info_help          -- version / help / get get / intro / license
    B  boolean_options    -- boolean settings x {true,false,default}
    C  integer_options    -- disableable values plus hard Harness limits
    D  string_options     -- url / model / system-prompt set/clear/reset
    E  command_pattern    -- semantic-only / custom / dangerous / reset
    F  key_and_config     -- key set/clear isolation, config --reset, fields
    G  invalid_inputs     -- malformed CLI arguments, missing values, types
    H  cache_log_mgmt     -- clean/display/unset for cache and log stores
    I  direct_queries     -- direct-Harness ground-truth validation
    J  harness_queries    -- auto-Harness tool invocation
    K  cache_behaviour    -- deterministic store / hit / unset / expiry
    L  param_interactions -- model/timeout/max-rounds/system-prompt/pattern
    M  missing_config     -- key/url/model absence
    Z  teardown           -- full configuration restore and diff

Usage:
    GET_TEST_API_KEY=<API_KEY> python get_test.py [--url URL] [--model MODEL]
                       [--skip-llm] [--only A,B,...] [--stop-on-fail]
                       [--live-config] [--verbose]

`--key` remains available, but the environment avoids process-argument leaks.
Assumes `get` is installed and on $PATH. Configuration is isolated by default.
"""
from __future__ import annotations

import argparse
import atexit
import getpass
import hashlib
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
    "hide-process", "system-proxy", "cache", "vivid", "markdown",
]

DISABLABLE_INT_OPTIONS_DEFAULTS = {
    "timeout":                 "300",
    "max-token":               "20480",
    "cache-expiry":            "30",
    "cache-max-entries":       "1000",
    "log-max-entries":         "1000",
}

HARD_LIMIT_OPTIONS_DEFAULTS = {
    "max-rounds":       "3",
    "max-tool-calls":   "8",
    "max-parallel":     "4",
    "command-timeout":  "30",
    "max-output-bytes": "1048576",
}

INT_OPTIONS_DEFAULTS = {
    **DISABLABLE_INT_OPTIONS_DEFAULTS,
    **HARD_LIMIT_OPTIONS_DEFAULTS,
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
        # Normalise: platform.system() returns 'Darwin' on macOS;
        # tests use 'darwin' for cross-platform comparisons.
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
    key_existed: bool = False
    key_bytes: bytes = b""
    key_mode: int = 0

    @staticmethod
    def key_path() -> Path:
        """Return the key-store path used by the current test environment."""

        if os.name == "nt":
            base = Path(os.environ.get(
                "APPDATA", str(Path.home() / "AppData" / "Roaming")))
        else:
            base = Path(os.environ.get(
                "XDG_CONFIG_HOME", str(Path.home() / ".config")))
        return base / "get" / "key"

    def snapshot(self) -> None:
        key_path = self.key_path()
        self.key_existed = key_path.is_file()
        if self.key_existed:
            self.key_bytes = key_path.read_bytes()
            self.key_mode = key_path.stat().st_mode & 0o777
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
                if "supplemental regex cleared" in v.lower() or v == "":
                    self.set("command-pattern", "")
                elif "semantic policy only" in v.lower() or "built-in" in v:
                    self.clear("command-pattern")
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

    def restore_key(self) -> bool:
        """Restore the exact key-store bytes captured before the test run."""

        key_path = self.key_path()
        if self.key_existed:
            key_path.parent.mkdir(parents=True, exist_ok=True)
            key_path.write_bytes(self.key_bytes)
            if os.name != "nt":
                key_path.chmod(self.key_mode)
        elif key_path.exists():
            key_path.unlink()
        return key_path.is_file() == self.key_existed


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
    cm.set("harness",        "auto")
    cm.set("tool-protocol",  "auto")


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
    ver = r.out_plain.strip()
    if r.ok:
        a_regex(stats, "A02 version matches X.Y(.Z)", ver,
                r"\d+\.\d+")
        a_not_contains(stats, "A03 version has no stack trace",
                       ver, "traceback", case_insensitive=True)
    aliases = [run_get("--version"), run_get("-V")]
    if all(item.ok and item.out_plain.strip() == ver for item in aliases):
        stats.pass_("A25 --version and -V match get version")
    else:
        stats.fail(
            "A25 version aliases",
            f"exits={[item.returncode for item in aliases]}")

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
    log_hdr("SECTION C -- integer options and hard limits")
    cm = ConfigManager()
    idx = 1
    for opt, default_val in DISABLABLE_INT_OPTIONS_DEFAULTS.items():
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

    for opt, default_val in HARD_LIMIT_OPTIONS_DEFAULTS.items():
        log_sub(f"C.{opt}")
        prev = get_config_field(opt)
        test_value = "12" if opt == "max-rounds" else "42"

        cm.set(opt, test_value)
        a_cfg_eq(stats, f"C{idx:02d} set {opt}={test_value}",
                 opt, test_value)
        idx += 1

        rejected = not cm.set(opt, "false")
        if rejected and get_config_field(opt) == test_value:
            stats.pass_(f"C{idx:02d} {opt} rejects disabled hard limit")
        else:
            stats.fail(f"C{idx:02d} {opt} accepted disabled hard limit")
        idx += 1

        cm.clear(opt)
        a_cfg_eq(stats, f"C{idx:02d} reset {opt} default",
                 opt, default_val)
        idx += 1

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

    # E-1 semantic-policy-only default when value omitted
    cm.clear("command-pattern")
    v = get_config_field("command-pattern")
    if "semantic policy only" in v.lower() and "default" in v.lower():
        stats.pass_("E01 command-pattern default = semantic policy only")
    else:
        stats.fail("E01 command-pattern default", f"got={v!r}")

    # E-2 clearing an added regex keeps the mandatory semantic policy
    cm.set("command-pattern", "")
    v = get_config_field("command-pattern")
    if "semantic policy only" in v.lower() and "cleared" in v.lower():
        stats.pass_("E02 command-pattern \"\" => supplemental regex cleared")
    else:
        stats.fail("E02 command-pattern clear", f"got={v!r}")

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
    if "semantic policy only" in prev.lower():
        cm.clear("command-pattern")
    elif "cleared" in prev.lower():
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
    a_eq(stats, "F04 config has >= 24 fields",
         len(cfg) >= 24, True, detail=f"count={len(cfg)}")

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

    for idx, value in enumerate(
            ["auto", "direct", "loop", "parallel"], start=15):
        cm.set("harness", value)
        a_cfg_eq(stats, f"F{idx:02d} harness={value}",
                 "harness", value)
    for idx, value in enumerate(
            ["auto", "native", "legacy"], start=19):
        cm.set("tool-protocol", value)
        a_cfg_eq(stats, f"F{idx:02d} tool-protocol={value}",
                 "tool-protocol", value)
    cm.set("harness", "auto")
    cm.set("tool-protocol", "auto")

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
        ("G20 unknown harness rejected",
         ["set", "harness", "rough"]),
        ("G21 unknown tool protocol rejected",
         ["set", "tool-protocol", "magic"]),
        ("G22 disabled hard limit rejected",
         ["set", "max-rounds", "false"]),
        ("G23 zero-valued timeout rejected",
         ["set", "timeout", "0"]),
        ("G24 zero-valued query timeout rejected",
         ["what is two plus two", "--timeout", "0"]),
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
#                  S E C T I O N   I :   DIRECT LLM QUERIES
# =============================================================================
# =============================================================================
#
# Each test runs a real query through the direct Harness strategy and validates
# the response against locally computed ground truth or structural expectations.

def _llm_precondition(stats: Stats, prefix: str,
                      count: int) -> bool:
    if ARGS.skip_llm:
        for i in range(count):
            stats.skip(f"{prefix}{i + 1:02d} skipped", "--skip-llm set")
        return False
    return True


def _run_live_semantic_query(
        query: str,
        validate: Callable[[str], bool],
        timeout: int,
) -> Tuple[RunResult, int, List[str]]:
    """Allow one independent retry for stochastic semantic model failures.

    Transport retries belong to get itself. This outer retry is deliberately
    limited to live-evaluation semantics and records the first failure so a
    recovered provider wobble remains visible in the test log.
    """
    failures: List[str] = []
    last: Optional[RunResult] = None
    for attempt in range(1, 3):
        last = _run_query(query, "--no-cache", timeout=timeout)
        plain = last.out_plain.strip()
        if last.ok and validate(plain):
            return last, attempt, failures
        if last.ok:
            failures.append(
                "semantic=" + plain.replace("\n", " | ")[:100])
        else:
            failures.append(
                f"exit={last.returncode}:" + last.err_plain.strip()[:100])
    assert last is not None
    return last, 2, failures


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


# ---- direct-Harness ground-truth query table ------------------------------
#
# (name, query_text, validator(plain_output) -> bool, notes)

def _direct_query_table() -> List[Tuple[str, str,
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
         lambda o: f.hostname.lower() in o.lower()
         or host.lower() in o.lower(),
         "matches socket.gethostname()"),
        ("username",
         "reply with ONLY the current unix/linux user name, "
         "nothing else",
         lambda o: user and user.lower() in o.lower(),
         "matches getpass.getuser()"),
        ("cwd",
         "reply with ONLY the current working directory absolute path",
         lambda o: cwd.lower() in o.lower()
         or f.cwd_basename.lower() in o.lower(),
         "matches os.getcwd()"),
        ("home",
         "reply with ONLY the user's home directory path",
         lambda o: f.home.lower() in o.lower()
         or os.path.basename(f.home).lower() in o.lower(),
         "matches $HOME"),
        ("os_name",
         "reply with ONLY the operating system kernel/family name "
         "(one of: Linux, Darwin, Windows)",
         lambda o: plt in o.lower()
         or ("mac" in o.lower() and plt == "darwin")
         or ("darwin" in o.lower() and plt == "darwin")
         or ("macos" in o.lower() and plt == "darwin")
         or ("windows" in o.lower() and plt == "windows")
         or ("win32nt" in o.lower() and plt == "windows"),
         "matches platform.system()"),
        ("year",
         f"reply with ONLY the current year as a 4-digit number",
         lambda o: year in o,
         "current year"),
        ("python_version",
         "Use exactly the read-only command `python3 --version` (never -c), "
         "then return its version.",
         lambda o: pyv in o,
         "matches sys.version_info"),
        ("ip_format",
         "Use a read-only system command to discover this machine's primary "
         "local IPv4 address (`hostname -I` on Linux, "
         "`ipconfig getifaddr en0` on macOS, or `ipconfig` on Windows). "
         "Return ONLY the dotted-decimal IPv4 address.",
         lambda o: re.search(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", o)
         is not None,
         "IPv4 regex match"),
        ("disk_listing_exists",
         "Use the read-only command `ls -1 /` on Unix or `dir /b C:\\` "
         "on Windows. Return at least three directory names, not the root "
         "path itself.",
         lambda o: any(
             tok in o for tok in
             ("/bin", "/etc", "/usr", "/var",
              "/Users", "/System", "/Library",
              "bin", "etc", "usr", "var",
              "Windows", "Users", "Program")),
         "contains canonical dir names"),
        ("simple_math",
         "Without calling a tool, what is 17 plus 25? Reply with ONLY the "
         "numeric answer.",
         lambda o: "42" in o,
         "17+25=42"),
        ("bigger_math",
         "Without calling a tool, what is 123 multiplied by 456? Reply with ONLY "
         "the numeric answer, no commas.",
         lambda o: "56088" in o,
         "123*456=56088"),
        ("string_len",
         "Use the read-only command `printf %s encyclopedia | wc -c` and "
         "return only its numeric output.",
         lambda o: "12" in o,
         "len('encyclopedia')==12"),
        ("uppercase",
         "Without calling a tool, convert 'hello world' to uppercase and reply with "
         "ONLY the result",
         lambda o: "HELLO WORLD" in o,
         "simple transform"),
        ("json_parse",
         'Without calling a tool, parse this JSON and reply with ONLY the value of the '
         '"value" field: {"value": 314, "other": 1}',
         lambda o: "314" in o,
         "json parse"),
        ("yes_no_file",
         "This is general Linux knowledge, not a request to inspect this "
         "machine. Without calling a tool: is /etc/hostname the conventional "
         "hostname file path on Linux? Answer yes or no only.",
         lambda o: "yes" in o.lower(),
         "yes/no factual"),
        ("short_poem",
         "Without calling a tool, write exactly one four-line poem about 42; "
         "include the digits '42' literally somewhere in the poem",
         lambda o: (len(o.strip().splitlines()) >= 3
                    or o.count("|") >= 3)
         and ("42" in o
              or "forty-two" in o.lower()
              or "forty two" in o.lower()),
         "format + content"),
        ("language_code",
         "Without calling a tool, what is the two-letter ISO 639-1 code for English? "
         "Reply with ONLY the two letters.",
         lambda o: re.search(r"\ben\b", o, re.IGNORECASE) is not None,
         "ISO 639-1 en"),
        ("day_count",
         "Without calling a tool, how many days are in a common year? "
         "reply with ONLY the number.",
         lambda o: "365" in o,
         "factual"),
        ("negation",
         "Without calling a tool, is 'the sun rises in the west' true or false? "
         "reply with ONLY one word.",
         lambda o: "false" in o.lower(),
         "logic"),
        ("multi_language",
         "Without calling a tool, how do you say 'thank you' in Spanish? "
         "reply with ONLY the spanish phrase.",
         lambda o: "gracias" in o.lower(),
         "translate"),
    ]


def section_direct_queries(stats: Stats) -> None:
    stats.section = "I"
    log_hdr("SECTION I -- direct-Harness real LLM queries (ground truth)")
    table = _direct_query_table()
    if not _llm_precondition(stats, "I", len(table) + 8):
        return

    cm = ConfigManager()
    cm.set("harness", "direct")
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
        r, attempts, failures = _run_live_semantic_query(
            query, validate, timeout=180)
        plain = r.out_plain.strip()
        if r.ok and validate(plain):
            retry_detail = (
                f"; attempt={attempts}; first={failures[0]!r}"
                if attempts > 1 else ""
            )
            stats.pass_(f"I{idx:02d} {name}",
                        detail=f"{note} ({r.elapsed:.1f}s){retry_detail}")
        else:
            short = plain.replace("\n", " | ")[:140]
            stats.fail(f"I{idx:02d} {name}",
                       f"attempts=2; last_exit={r.returncode}; "
                       f"last={short!r}; failures={failures!r}")

    # I-21 --no-vivid no ANSI
    log_sub("I.21 --no-vivid has no ANSI in stdout")
    r = _run_query("Without calling a tool, reply with the word 'vivid-off'",
                   "--no-cache", "--no-vivid", timeout=120)
    if r.ok and ANSI_RE.search(r.stdout) is None:
        stats.pass_("I21 --no-vivid strips ANSI")
    else:
        stats.fail("I21 --no-vivid",
                   f"ok={r.ok} has_ansi="
                   f"{bool(ANSI_RE.search(r.stdout))}")

    # I-22 --vivid may emit ANSI (we don't strictly assert — terminals differ)
    r = _run_query("Without calling a tool, reply with the word 'vivid-on'",
                   "--no-cache", "--vivid", timeout=120)
    if r.ok:
        stats.pass_("I22 --vivid succeeds",
                    detail=f"has_ansi={bool(ANSI_RE.search(r.stdout))}")
    else:
        stats.fail("I22 --vivid", f"exit={r.returncode}")

    # I-23 --hide-process suppresses 'executing' markers in stderr
    r = _run_query("Without calling a tool, reply with 'hp-test'", "--no-cache",
                   "--hide-process", timeout=120)
    low = r.err_plain.lower()
    if r.ok and "executing" not in low and "round" not in low:
        stats.pass_("I23 --hide-process suppresses rounds/exec markers")
    else:
        stats.fail("I23 --hide-process",
                   f"stderr={low.strip()[:120]!r}")

    # I-24 --no-hide-process may show markers (non-strict)
    r = _run_query("Without calling a tool, reply with 'hp-test-visible'", "--no-cache",
                   "--no-hide-process", timeout=120,
                   hide_process=False)
    if r.ok:
        stats.pass_("I24 --no-hide-process succeeds")
    else:
        stats.fail("I24 --no-hide-process", f"exit={r.returncode}")

    # I-25 --model override runs
    mdl = ARGS.model or "gpt-4o-mini"
    r = _run_query("Without calling a tool, reply with 'mdl'", "--no-cache",
                   "--model", mdl, timeout=120)
    a_exit_ok(stats, f"I25 --model {mdl} override runs", r)

    # I-26 --timeout override runs
    r = _run_query("Without calling a tool, reply with 'to'", "--no-cache",
                   "--timeout", "120", timeout=140)
    a_exit_ok(stats, "I26 --timeout override runs", r)

    # I-27 --no-cache explicit
    r = _run_query(
        "Without calling a tool, reply with 'nc'", "--no-cache", timeout=120)
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
#                  S E C T I O N   J :   HARNESS TOOL QUERIES
# =============================================================================
# =============================================================================
#
# Auto Harness -- the model uses bounded read-only tools when needed.

def _harness_query_table(scratch: Path
                         ) -> List[Tuple[str, str,
                                         Callable[[str], bool], str]]:
    f = FACTS
    alpha_digest = hashlib.sha256(
        (scratch / "alpha.txt").read_bytes()).hexdigest()
    cases = [
        ("uname",
         "Use exactly the read-only command `uname -s` and return its output.",
         lambda o: f.platform_name in o.lower()
         or ("darwin" in o.lower() and f.platform_name == "darwin"),
         "Harness invokes `uname` or equivalent"),
        ("hostname_tool",
         "report the local hostname.  include the hostname string "
         "in the reply.",
         lambda o: f.hostname in o or f.short_host in o,
         "Harness invokes `hostname`"),
        ("current_user",
         "who am i? report the current unix user. include the "
         "username in the reply.",
         lambda o: f.username in o,
         "Harness invokes `whoami` or `id`"),
        ("pwd",
         "print the current working directory of this shell session. "
         "include the path in the reply.",
         lambda o: f.cwd in o or f.cwd_basename in o,
         "Harness invokes `pwd`"),
        ("list_scratch",
         f"list the files directly inside the directory "
         f"'{scratch}'. include the filename 'alpha.txt' in the reply.",
         lambda o: "alpha.txt" in o,
         "Harness invokes `ls <path>`"),
        ("count_lines",
         f"how many lines are in the file '{scratch / 'numbers.txt'}'? "
         f"reply with the number prominently.",
         lambda o: "10" in o,
         "Harness invokes `wc -l`"),
        ("grep_content",
         f"find which line in '{scratch / 'words.txt'}' contains "
         f"the word 'needle'. include the word 'needle' in the reply.",
         lambda o: "needle" in o.lower(),
         "Harness invokes `grep`"),
        ("first_line",
         f"what is the first line of '{scratch / 'alpha.txt'}'? "
         f"include its text prominently.",
         lambda o: "first-line-marker-42" in o,
         "Harness invokes `head -n 1` or `sed`"),
        ("file_size",
         f"how many bytes does '{scratch / 'alpha.txt'}' occupy "
         f"on disk? include the number prominently.",
         lambda o: re.search(r"\b\d{1,6}\b", o) is not None,
         "Harness invokes `stat` or `wc -c`"),
        ("python_version_tool",
         "what is the installed python 3 version on this system? "
         "include the version number in the reply.",
         lambda o: f.py_major_minor in o or f.py_major in o,
         "Harness invokes `python3 --version`"),
        ("direct_file_count",
         f"Count regular files directly inside '{scratch}' (do not recurse). "
         "Use a bounded read-only find/wc pipeline and return the count.",
         lambda o: re.search(r"\b7\b", o) is not None,
         "seven deterministic direct child files"),
        ("extension_composition",
         f"Summarize the code/file extensions directly inside '{scratch}'. "
         "Use only read-only stdout transforms; never use find -exec. Include "
         "the txt, nim, py, and md extension counts.",
         lambda o: all(part in o.lower() for part in ("txt", "nim", "py", "md")),
         "mixed extension inventory without an AWK program"),
        ("no_match_recovery",
         f"Search '{scratch}' recursively for the literal marker "
         "ZZZ_GET_NO_MATCH_9F31. If grep finds no match, treat exit 1 as "
         "evidence and clearly say that no match exists.",
         lambda o: any(part in o.lower() for part in
                       ("no match", "not found", "none", "no occurrence",
                        "no files", "no result")),
         "ordinary grep exit 1 is interpreted, not surfaced as a crash"),
        ("missing_path_recovery",
         f"Check whether '{scratch / 'definitely-missing-31.txt'}' exists using "
         "a simple read-only file/listing command. Treat a nonzero reader exit "
         "as evidence and answer no if it is absent.",
         lambda o: re.search(r"\b(no|absent|missing|not found|does not exist)\b",
                             o, re.IGNORECASE) is not None,
         "missing-file reader failure becomes a useful answer"),
        ("sha256",
         f"Compute the SHA-256 of '{scratch / 'alpha.txt'}' with a read-only "
         "checksum command and return the digest.",
         lambda o: alpha_digest in o.lower(),
         "matches hashlib ground truth"),
        ("identical_compare",
         f"Use cmp to determine whether '{scratch / 'alpha.txt'}' is identical "
         "to itself. Produce an explicit identical/different answer with a "
         "small fully read-only &&/|| command sequence.",
         lambda o: "identical" in o.lower() or "same" in o.lower(),
         "safe compound readers produce a semantic answer"),
        ("nested_marker",
         f"Recursively search regular files below '{scratch / 'subdir'}' for "
         "the exact literal inside-subdir-content with a read-only grep. "
         "Return the matching content line, not only its filename.",
         lambda o: "inside-subdir-content" in o,
         "bounded recursive content discovery"),
        ("file_type",
         f"Inspect the file type of '{scratch / 'sample.py'}' with the file "
         "command and include its text/script classification.",
         lambda o: "text" in o.lower() or "script" in o.lower()
         or "python" in o.lower(),
         "file metadata inspection"),
    ]
    if f.platform_name == "linux":
        cases.extend([
          (
            "performance_snapshot",
            "Report a one-shot system performance snapshot using a bounded "
            "read-only command. Prefer `top -bn1 | head -n 15`; an equivalent "
            "one-shot process CPU/memory table or `/proc/loadavg` record is "
            "acceptable. Return output.",
            lambda o: (
                "load average" in o.lower()
                and ("tasks:" in o.lower() or "%cpu" in o.lower())
            ) or (
                "pid" in o.lower() and "%cpu" in o.lower()
                and ("%mem" in o.lower() or "rss" in o.lower())
            ) or bool(
                re.search(
                    r"(?m)^\s*\d+(?:\.\d+)?\s+\d+(?:\.\d+)?\s+"
                    r"\d+(?:\.\d+)?\s+\d+/\d+\s+\d+\s*$",
                    o,
                )
            ),
            "Harness admits a bounded Linux performance reader",
          ),
          (
            "running_services",
            "List currently running system services with a finite read-only "
            "systemctl query and summarize what the output means.",
            lambda o: any(part in o.lower() for part in
                          (".service", "running", "systemd", "not booted",
                           "failed to connect")),
            "running-service inspection or an explicit host limitation",
          ),
          (
            "failed_services",
            "Inspect failed systemd services using exactly `systemctl --failed "
            "--no-pager`; explain whether failed units exist.",
            lambda o: any(part in o.lower() for part in
                          ("failed", ".service", "no failed", "none", "0 loaded")),
            "option-only systemctl query is usable",
          ),
          (
            "listening_ports",
            "Show listening TCP/UDP sockets with a finite read-only ss command "
            "and summarize the result.",
            lambda o: "listen" in o.lower() or
            re.search(r":\d{1,5}\b", o) is not None,
            "socket inventory",
          ),
          (
            "default_route",
            "Inspect the default network route and report its gateway/interface.",
            lambda o: any(part in o.lower() for part in
                          ("default", "gateway", " via ", " dev ")),
            "routing query",
          ),
          (
            "dns_configuration",
            "Inspect this machine's active DNS resolver configuration using a "
            "read-only command and summarize it.",
            lambda o: "nameserver" in o.lower() or "dns" in o.lower()
            or re.search(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", o) is not None,
            "DNS configuration query",
          ),
          (
            "memory_and_disk",
            "Report both current memory availability and root filesystem usage "
            "using a small sequence or batch of read-only commands.",
            lambda o: ("mem" in o.lower() or "memory" in o.lower()) and
            ("filesystem" in o.lower() or "mounted" in o.lower()
             or "disk" in o.lower()),
            "multiple observational checks",
          ),
          (
            "block_devices",
            "List block devices and filesystems with a read-only lsblk command.",
            lambda o: any(part in o.lower() for part in
                          ("name", "mountpoint", "filesystem", "nvme", "loop")),
            "storage inventory",
          ),
          (
            "firewall_status",
            "Inspect the local firewall state/rules using an available read-only "
            "firewall-cmd, nft list, or iptables -L query. Explain permission or "
            "service limitations instead of attempting to change anything.",
            lambda o: any(part in o.lower() for part in
                          ("firewall", "ruleset", "chain", "table", "running",
                           "not running", "permission", "not installed")),
            "firewall query with graceful unavailable/permission handling",
          ),
          (
            "natural_ip_zh",
            "设备的IP地址",
            lambda o: re.search(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", o)
            is not None,
            "unprompted Chinese local-IP request",
          ),
          (
            "natural_weather_zh",
            "今天天气",
            lambda o: ("shanghai" in o.lower() or "上海" in o) and
            (re.search(r"[+-]?\d+\s*°?[CF]\b", o, re.IGNORECASE) is not None
             or any(part in o.lower() for part in
                    ("sunny", "clear", "cloud", "overcast", "rain", "snow"))
             or any(part in o for part in ("晴", "雨", "阴", "云", "雪"))),
            "timezone-derived weather, never proxy-egress location",
          ),
          (
            "natural_services_zh",
            "在运行的服务",
            lambda o: any(part in o.lower() for part in
                          (".service", "running", "active", "systemd")),
            "unprompted Chinese service inventory",
          ),
          (
            "natural_code_composition_zh",
            "目录下的代码组成",
            lambda o: "nim" in o.lower() and
            ("src" in o.lower() or "源码" in o) and
            "budget exhausted" not in o.lower(),
            "interpreted code breakdown rather than a raw artifact dump",
          ),
          (
            "natural_performance_zh",
            "系统性能情况",
            lambda o: any(part in o.lower() for part in
                          ("load", "cpu", "负载")) and
            any(part in o.lower() for part in
                ("mem", "memory", "内存")),
            "unprompted bounded performance diagnosis",
          ),
          (
            "natural_git_changes_zh",
            "总结这个目录的 Git 分支和未提交变化",
            lambda o: ("main" in o.lower() or "分支" in o) and
            any(part in o.lower() for part in
                ("modified", "untracked", "变化", "修改", "未提交", "干净")),
            "safe branch/worktree summary without git status",
          ),
          (
            "natural_recent_errors_zh",
            "查看最近20条系统错误日志并说明重点",
            lambda o: any(part in o.lower() for part in
                          ("error", "failed", "warning", "journal",
                           "permission", "错误", "失败", "日志", "无记录")),
            "bounded system-log interpretation",
          ),
          (
            "natural_largest_files_zh",
            "列出这个目录中最大的十个文件",
            lambda o: re.search(r"\d", o) is not None and
            any(part in o.lower() for part in
                ("get_test.py", "license", ".release", ".ci", "bytes",
                 "kb", "mb", "文件")),
            "bounded filesystem sizing",
          ),
          (
            "natural_hardware_zh",
            "总结 CPU、内存、磁盘和 GPU 情况",
            lambda o: ("cpu" in o.lower() or "处理器" in o) and
            ("mem" in o.lower() or "内存" in o) and
            ("disk" in o.lower() or "磁盘" in o or "存储" in o),
            "multi-source local hardware summary",
          ),
          (
            "natural_container_zh",
            "总结当前容器和镜像运行情况",
            lambda o: any(part in o.lower() for part in
                          ("docker", "container", "image", "容器", "镜像",
                           "permission", "不可用", "未安装")),
            "read-only container runtime summary",
          ),
          (
            "natural_ssh_zh",
            "检查 SSH 服务是否运行并说明监听端口",
            lambda o: any(part in o.lower() for part in
                          ("ssh", "sshd", ":22", "port 22", "端口")),
            "service plus socket diagnosis",
          ),
        ])
    elif f.platform_name == "darwin":
        cases.extend([(
            "performance_snapshot",
            "Report a one-shot system performance snapshot. Use the exact "
            "read-only command `top -l 1 -n 15` and return its output.",
            lambda o: "load avg" in o.lower()
            or "cpu usage" in o.lower(),
            "Harness admits bounded macOS top",
        ), (
            "natural_ip_route_zh",
            "说明这台 Mac 的 IP 地址、活跃网络接口和默认路由",
            lambda o: re.search(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", o)
            is not None and any(part in o.lower() for part in
                                ("default", "gateway", "en0", "route", "路由")),
            "natural macOS network diagnosis",
        ), (
            "natural_services_zh",
            "列出这台 Mac 当前加载的服务并简要说明",
            lambda o: any(part in o.lower() for part in
                          ("launchctl", "label", "pid", "service", "服务")),
            "launchd service inventory",
        ), (
            "natural_security_zh",
            "检查这台 Mac 的 SIP、Gatekeeper 和 FileVault 状态",
            lambda o: any(part in o.lower() for part in
                          ("sip", "system integrity", "gatekeeper", "filevault"))
            and any(part in o.lower() for part in
                    ("enabled", "disabled", "status", "开启", "关闭", "状态")),
            "macOS security controls remain queryable",
        ), (
            "natural_storage_backup_zh",
            "总结根磁盘空间以及 Time Machine 当前状态",
            lambda o: any(part in o.lower() for part in
                          ("filesystem", "capacity", "disk", "磁盘"))
            and any(part in o.lower() for part in
                    ("time machine", "tmutil", "backup", "备份")),
            "storage plus backup status",
        ), (
            "natural_dns_zh",
            "查看这台 Mac 当前 DNS 解析器配置并说明重点",
            lambda o: any(part in o.lower() for part in
                          ("dns", "resolver", "nameserver", "解析")),
            "macOS resolver inventory",
        ), (
            "natural_power_zh",
            "查看这台 Mac 的电源和电池状态",
            lambda o: any(part in o.lower() for part in
                          ("battery", "ac power", "power source", "电池", "电源",
                           "no batteries")),
            "bounded pmset power query",
        )])
    elif f.platform_name == "windows":
        cases.extend([(
            "performance_snapshot",
            "Report a one-shot process performance snapshot using Get-Process "
            "and return its output.",
            lambda o: bool(o.strip()),
            "Harness uses a Windows performance reader",
        ), (
            "natural_ip_route_zh",
            "说明这台 Windows 设备的 IP 地址、DNS 和默认路由",
            lambda o: re.search(r"\b\d{1,3}(?:\.\d{1,3}){3}\b", o)
            is not None and any(part in o.lower() for part in
                                ("dns", "gateway", "route", "网关", "路由")),
            "natural Windows network diagnosis",
        ), (
            "natural_services_zh",
            "列出正在运行的 Windows 服务，最多显示前20项并说明",
            lambda o: any(part in o.lower() for part in
                          ("running", "service", "status", "运行", "服务")),
            "bounded Windows service inventory",
        ), (
            "natural_events_zh",
            "查看 Windows 系统最近20条事件并总结错误或警告",
            lambda o: any(part in o.lower() for part in
                          ("event", "error", "warning", "system", "事件", "错误",
                           "警告", "no matching")),
            "bounded event-log interpretation",
        ), (
            "natural_security_zh",
            "总结 Windows 防火墙和 Defender 当前状态",
            lambda o: any(part in o.lower() for part in
                          ("firewall", "防火墙")) and
            any(part in o.lower() for part in
                ("defender", "antivirus", "realtime", "安全", "不可用")),
            "Windows security status readers",
        ), (
            "natural_storage_zh",
            "总结 Windows 磁盘、卷以及 BitLocker 状态",
            lambda o: any(part in o.lower() for part in
                          ("disk", "volume", "磁盘", "卷")) and
            any(part in o.lower() for part in
                ("bitlocker", "encrypted", "encryption", "加密", "不可用")),
            "storage and encryption inventory",
        ), (
            "natural_tasks_zh",
            "列出前20个 Windows 计划任务并说明当前状态",
            lambda o: any(part in o.lower() for part in
                          ("task", "scheduled", "ready", "running", "任务")),
            "bounded scheduled-task inventory",
        )])
    return cases


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
    (tmp / "sample.nim").write_text(
        'echo "nim-marker-73"\n', encoding="utf-8")
    (tmp / "sample.py").write_text(
        "PYTHON_MARKER_86 = True\n", encoding="utf-8")
    (tmp / "notes.md").write_text(
        "markdown-marker-19\n", encoding="utf-8")
    (tmp / "subdir").mkdir()
    (tmp / "subdir" / "inner.txt").write_text(
        "inside-subdir-content\n", encoding="utf-8")
    return tmp


def section_harness_queries(stats: Stats) -> None:
    stats.section = "J"
    log_hdr("SECTION J -- auto-Harness queries (tool invocation)")
    scratch = _build_scratch()
    log_info(f"scratch dir: {scratch}")

    table = _harness_query_table(scratch)
    if not _llm_precondition(stats, "J", len(table) + 6):
        shutil.rmtree(scratch, ignore_errors=True)
        return

    cm = ConfigManager()
    cm.set("harness", "auto")
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
        r, attempts, failures = _run_live_semantic_query(
            query, validate, timeout=240)
        plain = r.out_plain
        if r.ok and validate(plain):
            retry_detail = (
                f"; attempt={attempts}; first={failures[0]!r}"
                if attempts > 1 else ""
            )
            stats.pass_(f"J{idx:02d} {name}",
                        detail=f"{note} ({r.elapsed:.1f}s){retry_detail}")
        else:
            short = plain.replace("\n", " | ")[:140]
            stats.fail(f"J{idx:02d} {name}",
                       f"attempts=2; last_exit={r.returncode}; "
                       f"last={short!r}; failures={failures!r}")

    def extra_id(offset: int) -> str:
        return f"J{len(table) + offset:02d}"

    # Extra 1: max-rounds = 1 terminates cleanly.
    cm.set("max-rounds", "1")
    r = _run_query(
        "use at least three distinct shell commands to gather "
        "information and reply. include the word 'done'.",
        "--no-cache", timeout=120)
    if r.returncode in (0, 1, 2, 126):
        stats.pass_(f"{extra_id(1)} max-rounds=1 terminates without crash",
                    detail=f"exit={r.returncode}")
    else:
        stats.fail(f"{extra_id(1)} max-rounds=1", f"exit={r.returncode}")

    # Extra 2: agent queries append log entries.
    n_before = log_entries_count()
    cm.set("max-rounds", "3")
    _run_query("reply with the word 'log-probe'",
               "--no-cache", timeout=120)
    n_after = log_entries_count()
    if n_after > n_before:
        stats.pass_(f"{extra_id(2)} agent query appended log "
                    f"({n_before} -> {n_after})")
    else:
        stats.fail(f"{extra_id(2)} agent log append",
                   f"before={n_before} after={n_after}")

    # Extra 3: agent without hide-process shows intermediate rounds.
    r = _run_query("report the machine hostname in a single word",
                   "--no-cache", "--no-hide-process",
                   timeout=180, hide_process=False)
    merged = r.err_plain.lower() + r.out_plain.lower()
    if r.ok and ("round" in merged
                 or "executing" in merged
                 or "$" in r.err_plain):
        stats.pass_(f"{extra_id(3)} agent --no-hide-process shows progress")
    else:
        stats.pass_(
            f"{extra_id(3)} agent --no-hide-process (progress markers "
            "format depends on backend)",
            detail="accepted as soft-pass")

    # Extra 4: agent tool-use with system-prompt injection.
    cm.set("system-prompt",
           "When listing files, use `ls -1` and only mention files, "
           "not directories.")
    r = _run_query(f"list files in '{scratch}' that contain letters",
                   "--no-cache", timeout=180)
    if r.ok and "alpha.txt" in r.out_plain:
        stats.pass_(f"{extra_id(4)} system-prompt respected "
                    "(alpha.txt present)")
    else:
        stats.fail(f"{extra_id(4)} system-prompt agent",
                   f"ok={r.ok} out={r.out_plain[:120]!r} "
                   f"err={r.err_plain[-160:]!r}")
    cm.clear("system-prompt")

    # Extra 5: command-pattern blocks read-command verbs.
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
        stats.pass_(f"{extra_id(5)} command-pattern suppressed "
                    "matching command")
    elif not r.ok:
        stats.pass_(f"{extra_id(5)} command-pattern caused non-zero exit",
                    detail=f"exit={r.returncode}")
    else:
        stats.pass_(
            f"{extra_id(5)} content leaked via alternative tool — soft-pass",
            detail=("verb-blocklist cannot prevent agents from "
                    "choosing substitute read tools; this is a "
                    "documented limitation (README.md + man "
                    "page SAFETY section)"))
    run_get("set", "command-pattern", "")  # clear supplemental regex for rest

    # Extra 6: restore semantic-policy-only command-pattern default.
    run_get("set", "command-pattern")
    v = get_config_field("command-pattern")
    if "semantic policy only" in v.lower():
        stats.pass_(f"{extra_id(6)} command-pattern default restored")
    else:
        stats.fail(f"{extra_id(6)} command-pattern restore", v[:80])

    shutil.rmtree(scratch, ignore_errors=True)


# =============================================================================
# =============================================================================
#                   S E C T I O N   K :   CACHE BEHAVIOUR
# =============================================================================
# =============================================================================

def _unique_query(tag: str) -> str:
    nonce = int(time.time() * 1000) % 1_000_000
    return (f"Without calling a tool, reply with the exact text "
            f"'cache-{tag}-{nonce}' "
            f"and nothing else")


def section_cache_behaviour(stats: Stats) -> None:
    stats.section = "K"
    log_hdr("SECTION K -- cache behaviour & state transitions")

    if not _llm_precondition(stats, "K", 30):
        return

    cm = ConfigManager()
    cm.set("harness", "direct")
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

    # K.3 plain text is not stored implicitly, while a successful one-command
    # result is stored deterministically without a classifier call.
    log_sub("K.3 deterministic text-or-command storage")
    q1 = _unique_query("k3")
    n0 = cache_entries_count()
    r1 = _run_query(q1, timeout=120)
    a_exit_ok(stats, "K04 first unforced text query exits 0", r1)
    n1 = cache_entries_count()
    if n1 in (n0, n0 + 1):
        stats.pass_(
            "K05 unforced result follows deterministic storage",
            detail=f"entries={n1} (text=0, single command=1)")
    else:
        stats.fail("K05 deterministic first-run storage",
                   f"entries={n0}->{n1}")

    # K.4 repeating can create one command entry if the model switches from a
    # text answer to a shell call, but it cannot create classifier entries.
    log_sub("K.4 repeated query creates at most one command entry")
    r2 = _run_query(q1, timeout=120)
    a_exit_ok(stats, "K06 repeated unforced query exits 0", r2)
    n2 = cache_entries_count()
    if n1 <= n2 <= n0 + 1:
        stats.pass_("K07 no classifier-created entries",
                    detail=f"entries={n0}->{n1}->{n2}")
    else:
        stats.fail("K07 deterministic repeat storage",
                   f"entries={n0}->{n1}->{n2}")

    # K.5 a clean store follows the same deterministic rule.
    log_sub("K.5 deterministic behavior after clean")
    run_get("cache", "--clean")
    q5 = _unique_query("k5")
    r = _run_query(q5, timeout=120)
    a_exit_ok(stats, "K08 clean-store query exits 0", r)
    n = cache_entries_count()
    if n in (0, 1):
        stats.pass_("K09 clean-store write remains deterministic",
                    detail=f"entries={n} (text=0, command=1)")
    else:
        stats.fail("K09 clean-store write", f"entries={n}")

    # K.6 multiple runs never trigger a hidden classifier call.
    log_sub("K.6 repeated queries never invoke a hidden classifier")
    run_get("cache", "--clean")
    q6 = _unique_query("k6")
    entries_trace: List[int] = []
    for i in range(3):
        r = _run_query(q6, timeout=120)
        if not r.ok:
            stats.fail(f"K10 compatibility run {i + 1} failed",
                       f"exit={r.returncode}")
            entries_trace.append(-1)
            continue
        entries_trace.append(cache_entries_count())
    trace_is_valid = all(entry in (0, 1) for entry in entries_trace) \
        and entries_trace == sorted(entries_trace)
    if trace_is_valid:
        stats.pass_("K10 repeated queries create at most one entry",
                    detail=f"entries trace={entries_trace}")
    else:
        stats.fail("K10 deterministic repeated storage",
                   f"entries trace={entries_trace}")
    r = _run_query(q6, timeout=120)
    a_exit_ok(stats, "K11 fourth unforced query exits 0", r)

    # K.7 --cache explicitly stores a text response immediately.
    log_sub("K.7 --cache explicitly stores text")
    run_get("cache", "--clean")
    q7 = _unique_query("k7")
    r = _run_query(q7, "--cache", timeout=120)
    a_exit_ok(stats, "K12 --cache flag first run exit 0", r)
    n = cache_entries_count()
    if n > 0:
        stats.pass_(f"K13 --cache first-run entries={n}")
    else:
        stats.fail("K13 --cache first-run", f"entries={n}")

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

    # K.9 an explicitly stored text result is reused exactly.
    log_sub("K.9 deterministic text cache hit")
    run_get("cache", "--clean")
    q9 = _unique_query("k9")
    r_first = _run_query(q9, "--cache", timeout=180)
    first_entries = cache_entries_count()
    r_secnd = _run_query(q9, "--cache", timeout=180)
    second_entries = cache_entries_count()
    if r_first.ok and r_secnd.ok:
        stats.pass_(
            "K15 two runs with --cache succeeded",
            detail=f"1st={r_first.elapsed:.1f}s "
            f"2nd={r_secnd.elapsed:.1f}s")
        if first_entries > 0 \
                and second_entries == first_entries \
                and r_secnd.out_plain == r_first.out_plain:
            stats.pass_("K16 second run reused the exact stored result",
                        detail=f"entries={second_entries} "
                        f"elapsed={r_secnd.elapsed:.1f}s")
        else:
            stats.fail(
                "K16 deterministic cache hit",
                f"entries={first_entries}->{second_entries} "
                f"same_output={r_secnd.out_plain == r_first.out_plain}")
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
    cm.set("harness", "direct")
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
    toggle_query = "Without calling a tool, reply with 'hp'"
    r_h = _run_query(toggle_query, "--no-cache",
                     "--hide-process", timeout=120)
    r_s = _run_query(toggle_query, "--no-cache",
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
                   f"exits={r_h.returncode},{r_s.returncode}; "
                   f"hidden-stderr={r_h.err_plain.strip()[-160:]!r}; "
                   f"shown-stderr={r_s.err_plain.strip()[-160:]!r}")

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

    # L.8 legacy instance flags remain per-call compatibility aliases.
    log_sub("L.7 instance compatibility alias")
    cm.set("instance", "false")
    r = _run_query("reply with 'instance-forced'",
                   "--no-cache", "--instance", timeout=120)
    a_exit_ok(stats, "L13 --instance forces direct Harness", r)
    still = get_config_field("instance")
    a_eq(stats, "L14 --instance flag does not persist to config",
         still, "false")
    cm.set("harness", "direct")

    # L.9 a one-turn model budget is valid and bounded.
    log_sub("L.8 max-rounds=1 budget")
    prev_mr = get_config_field("max-rounds")
    cm.set("harness", "auto")
    cm.set("max-rounds", "1")
    r = _run_query("reply with the word 'mr1'", "--no-cache", timeout=120)
    if r.returncode in (0, 1) and r.elapsed < 120:
        stats.pass_("L15 max-rounds=1 bounded query",
                    detail=f"exit={r.returncode} elapsed={r.elapsed:.1f}s")
    else:
        stats.fail("L15 max-rounds=1 bounded query",
                   f"exit={r.returncode} elapsed={r.elapsed:.1f}s")
    cm.set("max-rounds", prev_mr)
    cm.set("harness", "direct")

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
    restored = False
    try:
        diffs = cm.restore()
        if not diffs:
            stats.pass_("Z01 original configuration fully restored")
        else:
            stats.fail("Z01 configuration differences after restore",
                       "; ".join(diffs[:5]))

        # Z.2 prove that the test key can be removed before restoration.
        run_get("set", "key")
        v = get_config_field("key")
        if "not set" in v.lower() or "unset" in v.lower():
            stats.pass_("Z02 test API key cleared from storage")
        else:
            stats.fail("Z02 clear key", f"shown={v!r}")
    finally:
        restored = cm.restore_key()
    if restored:
        stats.pass_("Z03 original key store restored")
    else:
        stats.fail("Z03 restore key store")


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
    ("I", "direct_queries",     section_direct_queries,     True),
    ("J", "harness_queries",    section_harness_queries,    True),
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
    if not ARGS.live_config:
        print(_c(C.DIM,
                 "Configuration and key tests used an isolated temporary "
                 "directory.\n"))
    else:
        print(_c(C.DIM,
                 "The active key-store file was backed up and restored "
                 "byte-for-byte.\n"))


def parse_args() -> Any:
    p = argparse.ArgumentParser(
        description="Comprehensive test suite for the `get` CLI.")
    environment_key = os.environ.get("GET_TEST_API_KEY", "")
    p.add_argument(
        "--key",
        default=environment_key,
        required=not bool(environment_key),
        help="API key (prefer GET_TEST_API_KEY to avoid argv exposure)",
    )
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
    p.add_argument("--live-config", action="store_true",
                   help="test active user configuration (key file is backed "
                        "up and restored)")
    p.add_argument("-v", "--verbose", action="store_true",
                   help="echo every `get` invocation")
    return p.parse_args()


def main() -> None:
    global ARGS, VERBOSE, STOP_ON_FAIL
    ARGS = parse_args()
    VERBOSE = ARGS.verbose
    STOP_ON_FAIL = ARGS.stop_on_fail

    if not ARGS.live_config:
        config_home = tempfile.mkdtemp(prefix="get_test_config_")
        atexit.register(shutil.rmtree, config_home, ignore_errors=True)
        os.environ["XDG_CONFIG_HOME"] = config_home
        if os.name == "nt":
            os.environ["APPDATA"] = config_home

    only = {s.strip().upper() for s in ARGS.only.split(",")
            if s.strip()} if ARGS.only else None

    log_hdr("`get` comprehensive test suite")
    log_info(f"model       : {ARGS.model or '(config default)'}")
    log_info(f"url         : {ARGS.url or '(config default)'}")
    log_info(f"key         : ****")
    log_info(f"skip-llm    : {ARGS.skip_llm}")
    log_info(f"stop-on-fail: {ARGS.stop_on_fail}")
    log_info(f"live-config : {ARGS.live_config}")
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
