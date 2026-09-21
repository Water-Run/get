#!/usr/bin/env python3
"""Compare exact Linux binaries against 40 independent real-provider tasks.

All runs, including failures, remain in the report. Private raw records omit
HTTP authorization headers. This is the Linux provider gate; native platform
suites are separate. No installed binary or active provider settings are changed.
"""
from __future__ import annotations
import argparse
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import math
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

sys.path.insert(0, str(Path(__file__).parent / 'tests/replay'))
from v4_cases import make_cases


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def answer(text):
    decoder = json.JSONDecoder()
    for offset, character in enumerate(text):
        if character == '{':
            try:
                value, _ = decoder.raw_decode(text[offset:])
                if isinstance(value, dict): return value
            except ValueError:
                pass
    raise ValueError('no JSON object in answer')


def equivalent(actual, expected):
    if type(actual) is not type(expected): return False
    if isinstance(expected, dict):
        return actual.keys() == expected.keys() and all(equivalent(actual[k], v) for k, v in expected.items())
    if isinstance(expected, list):
        return len(actual) == len(expected) and all(equivalent(a, b) for a, b in zip(actual, expected))
    return actual == expected


class Recorder:
    def __init__(self, endpoint):
        self.endpoint = endpoint.rstrip('/') + '/chat/completions'
        self.records = []
        self.started = time.monotonic()
        class NoRedirect(HTTPRedirectHandler):
            def redirect_request(self, *args, **kwargs): return None
        self.opener = build_opener(NoRedirect)
        recorder = self
        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"
            def do_POST(self):
                started = time.monotonic()
                batch = recorder.records
                origin = recorder.started
                length = int(self.headers.get('Content-Length', '0'))
                if length > 4 * 1024 * 1024:
                    self.send_error(413); return
                body = self.rfile.read(length)
                record = {'at_seconds': started - origin, 'request': json.loads(body), 'status': 0}
                batch.append(record)
                # Authorization is forwarded directly and is never stored in records.
                request = Request(recorder.endpoint, data=body, headers={
                    'Authorization': self.headers.get('Authorization', ''),
                    'Content-Type': 'application/json', 'Accept-Encoding': 'identity'})
                try:
                    with recorder.opener.open(request, timeout=130) as response:
                        code, payload = response.status, response.read(16 * 1024 * 1024)
                except HTTPError as error:
                    code, payload = error.code, error.read(1024 * 1024)
                except Exception as error:
                    code, payload = 502, json.dumps({'error': {'message': str(error)}}).encode()
                record.update(status=code, seconds=time.monotonic() - started)
                try: record['response'] = json.loads(payload)
                except ValueError: record['response'] = {'malformed_body': payload[:1024].decode('utf-8', 'replace')}
                self.send_response(code)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Content-Length', str(len(payload)))
                self.end_headers()
                try: self.wfile.write(payload)
                except (BrokenPipeError, ConnectionResetError): pass
            def log_message(self, *unused): pass
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join(timeout=3)


def observations(records):
    result = []
    for record in records:
        values = []
        for message in record['request'].get('messages', []):
            content = message.get('content') or ''
            try:
                if message.get('role') == 'tool': values.append(json.loads(content))
                elif content.startswith('Tool observations (JSON): '):
                    values.extend(json.loads(content.split(': ', 1)[1]))
            except (ValueError, TypeError): pass
        if len(values) > len(result): result = values
    return result


def sample_tree(pid):
    pending, seen, rss = [pid], set(), 0
    while pending and len(seen) < 128:
        current = pending.pop()
        if current in seen: continue
        seen.add(current)
        try:
            directory = Path('/proc') / str(current)
            for line in (directory / 'status').read_text().splitlines():
                if line.startswith('VmRSS:'): rss += int(line.split()[1])
            for task in (directory / 'task').iterdir():
                pending.extend(int(value) for value in (task / 'children').read_text().split())
        except (OSError, ValueError): pass
    return rss


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', action='append', required=True, help='label=/absolute/binary/path')
    parser.add_argument('--provider-config', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--shell', default='fish')
    parser.add_argument('--case', action='append', help='pilot selection; report marks reduced coverage')
    args = parser.parse_args()
    if args.repeats < 1: parser.error('repeats must be positive')
    binaries = dict(item.split('=', 1) for item in args.binary)
    binaries = {label: Path(path).resolve(strict=True) for label, path in binaries.items()}
    config_path, key_path = args.provider_config / 'config.json', args.provider_config / 'key'
    preserved = {path: sha(path) for path in [config_path, key_path]}
    settings = json.loads(config_path.read_text())
    key = key_path.read_text().strip()
    if not key or not settings.get('url') or not settings.get('model'):
        parser.error('provider configuration is incomplete')
    args.report.parent.mkdir(parents=True, exist_ok=True)
    private = args.report.parent / (args.report.stem + '-raw')
    private.mkdir(mode=0o700, exist_ok=True)
    digests = {name: sha(path) for name, path in binaries.items()}
    report = {'schema_version': 1, 'platform': 'linux', 'shell': args.shell,
              'model': settings['model'], 'binary_sha256': digests,
              'corpus_sha256': sha(Path(__file__).parent / 'tests/replay/v4_cases.py'),
              'runner_sha256': sha(Path(__file__)),
              'coverage': 'pilot' if args.case or args.repeats < 3 else '40 tasks x 3 or more',
              'configuration': {'max_rounds': 6, 'max_tool_calls': 16, 'max_parallel': 4,
                                'command_timeout': 30, 'query_timeout': 120},
              'metric_notes': {'misrejection': 'conservative upper bound: any policy-rejected proposal in a task',
                               'budgets': 'identical supplied settings; v3.2 ignores queryTimeout; external process bound is 145 seconds for both',
                               'transport': 'private loopback recorder forwards to the real provider with TLS verification and no redirects',
                               'memory': 'sum of process-tree RSS sampled every 30 ms; shared pages counted per process',
                               'first_observation': 'runtime event when available; otherwise upper bound at next model request'},
              'runs': []}
    relay = Recorder(settings['url'])
    try:
        with tempfile.TemporaryDirectory(prefix='get-v4-provider-') as temporary:
            root = Path(temporary)
            cases, env, listener, host_preserved = make_cases(root)
            try:
                if args.case: cases = [case for case in cases if case.name in args.case]
                if not cases: parser.error('no matching cases')
                config_root = root / 'config'
                config_dir = config_root / 'get'
                config_dir.mkdir(parents=True, mode=0o700)
                private_key = config_dir / 'key'
                private_key.touch(mode=0o600)
                private_key.write_text(key)
                config = {'schemaVersion': 3, 'url': f'http://127.0.0.1:{relay.server.server_port}/v1',
                          'model': settings['model'], 'shell': args.shell, 'harness': 'auto',
                          'toolProtocol': 'auto', 'hideProcess': True, 'vivid': False, 'markdown': False,
                          'systemProxy': False, 'cache': False, 'log': True, 'diagnostics': True,
                          'maxRounds': 6, 'maxToolCalls': 16, 'maxParallel': 4,
                          'timeout': 120, 'queryTimeout': 120, 'commandTimeout': 30,
                          'maxOutputBytes': 1048576}
                (config_dir / 'config.json').write_text(json.dumps(config))
                env.update(XDG_CONFIG_HOME=str(config_root), NO_PROXY='127.0.0.1,localhost')
                env.pop('GET_TEST_API_KEY', None)
                for repeat in range(1, args.repeats + 1):
                    for case in cases:
                        for label, binary in binaries.items():
                            run_id = f'{label}-{repeat}-{case.name}'
                            relay.records = []
                            relay.started = time.monotonic()
                            log_path = config_dir / 'get.log'
                            log_path.unlink(missing_ok=True)
                            started = time.monotonic()
                            process = subprocess.Popen([str(binary), case.question, '--no-cache'],
                                                       cwd=case.cwd, env=env, stdout=subprocess.PIPE,
                                                       stderr=subprocess.PIPE, text=True, encoding='utf-8', errors='replace')
                            peak, done = [0], threading.Event()
                            def measure():
                                while not done.wait(0.03): peak[0] = max(peak[0], sample_tree(process.pid))
                            sampler = threading.Thread(target=measure, daemon=True)
                            sampler.start()
                            timed_out = False
                            try: stdout, stderr = process.communicate(timeout=145)
                            except subprocess.TimeoutExpired:
                                timed_out = True
                                process.send_signal(__import__('signal').SIGINT)
                                try: stdout, stderr = process.communicate(timeout=5)
                                except subprocess.TimeoutExpired:
                                    process.kill(); stdout, stderr = process.communicate(timeout=5)
                            done.set(); sampler.join(timeout=2)
                            elapsed = time.monotonic() - started
                            evidence = observations(relay.records)
                            events = []
                            for line in stderr.splitlines():
                                if line.startswith('{"get_event":'):
                                    try: events.append(json.loads(line))
                                    except ValueError: pass
                            summary = next((json.loads(event['message']) for event in events
                                            if event['get_event'] == 'hekRunSummary'), {})
                            first = next((event['elapsed_ms'] / 1000 for event in events
                                          if event['get_event'] == 'hekToolCompleted'), None)
                            if first is None:
                                first = next((record['at_seconds'] for record in relay.records
                                              if observations([record])), None)
                            try: actual = answer(stdout)
                            except ValueError: actual = None
                            preserved_host = host_preserved()
                            passed = (process.returncode == 0 and equivalent(actual, case.expected)
                                      and preserved_host and not timed_out)
                            tokens = sum(record.get('response', {}).get('usage', {}).get('total_tokens', 0)
                                         for record in relay.records)
                            row = {'id': run_id, 'binary': label, 'repeat': repeat, 'category': case.category,
                                   'case': case.name, 'passed': passed, 'exit_code': process.returncode,
                                   'timed_out': timed_out, 'host_preserved': preserved_host,
                                   'seconds': round(elapsed, 3), 'first_observation_seconds': first,
                                   'peak_sum_rss_kib': peak[0], 'provider_requests': len(relay.records),
                                   'tokens': tokens,
                                   'pending_provider_requests': sum(record['status'] == 0 for record in relay.records),
                                   'token_usage_complete': all('usage' in record.get('response', {}) for record in relay.records),
                                   'policy_rejections': sum(bool(item.get('policy_rejected')) for item in evidence),
                                   'observation_count': len(evidence), 'runtime': summary,
                                   'failure': None if passed else ('host_mutation' if not preserved_host else
                                       'timeout' if timed_out else 'provider' if any(record['status'] >= 400 for record in relay.records)
                                       else 'answer_or_execution')}
                            report['runs'].append(row)
                            raw = {'question': case.question, 'expected': case.expected, 'actual': actual,
                                   'stdout': stdout, 'stderr': stderr, 'requests': relay.records,
                                   'execution_log': log_path.read_text() if log_path.exists() else ''}
                            (private / (run_id + '.json')).write_text(json.dumps(raw, ensure_ascii=False, indent=2).replace(key, '[redacted]'))
                            report['provider_settings_preserved'] = all(sha(path) == old for path, old in preserved.items())
                            args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
                            print(json.dumps(row), flush=True)
                            if not preserved_host:
                                raise RuntimeError('host fixture changed; boundary violation recorded, stop this matrix')
            finally: listener.close()
    finally: relay.close()
    report['summary'] = {}
    for label in binaries:
        rows = [row for row in report['runs'] if row['binary'] == label]
        timings = sorted(row['seconds'] for row in rows)
        rate = sum(row['passed'] for row in rows) / len(rows)
        rejection_rate = sum(row['policy_rejections'] > 0 for row in rows) / len(rows)
        report['summary'][label] = {'runs': len(rows), 'passed': sum(row['passed'] for row in rows),
            'completion_rate': rate, 'misrejection_task_upper_bound': rejection_rate,
            'latency_p50': timings[max(0, math.ceil(len(timings) * .5) - 1)],
            'latency_p95': timings[max(0, math.ceil(len(timings) * .95) - 1)],
            'gate_passed': report['coverage'] != 'pilot' and rate >= .95 and rejection_rate <= .02}
    report['binaries_preserved'] = all(sha(path) == digests[label] for label, path in binaries.items())
    args.report.write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return int(not all(row['passed'] for row in report['runs']))


if __name__ == '__main__':
    raise SystemExit(main())
