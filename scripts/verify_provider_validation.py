"""Recompute v4 provider gates and bind them to the packaged Linux payload."""
from __future__ import annotations
from collections import Counter
import re


def validate_attestation(record: dict, version: str, payload_sha256: str) -> list[str]:
    if record.get('schema_version') != 4 or record.get('status') != 'passed':
        raise ValueError('provider validation is not a completed v4 attestation')
    if record.get('version') != version or not re.fullmatch(r'[a-f0-9]{64}', payload_sha256):
        raise ValueError('invalid validation version or payload hash')
    if record.get('linux_payload_sha256') != payload_sha256:
        raise ValueError('provider replay did not use this Linux payload')
    if record.get('live_configuration_preserved') is not True or not record.get('replays'):
        raise ValueError('missing preservation evidence or provider replay')
    lines = []
    for replay in record['replays']:
        if (replay.get('coverage') != '40 tasks x 3 or more'
                or replay.get('platform') != 'linux'
                or replay.get('binary_sha256', {}).get('candidate') != payload_sha256
                or replay.get('provider_settings_preserved') is not True
                or replay.get('binaries_preserved') is not True):
            raise ValueError('incomplete, changed, or mismatched replay')
        for field in ['corpus_sha256', 'runner_sha256']:
            if not re.fullmatch(r'[a-f0-9]{64}', replay.get(field, '')):
                raise ValueError('missing replay source identity')
        populations = {}
        for label in ['baseline', 'candidate']:
            rows = [row for row in replay['runs'] if row['binary'] == label]
            identities = [(row['case'], row['repeat']) for row in rows]
            counts = Counter(row['case'] for row in rows)
            categories = {(row['category'], row['case']) for row in rows}
            if (len(identities) != len(set(identities)) or len(counts) != 40
                    or min(counts.values()) < 3
                    or Counter(category for category, _ in categories) != {
                        'system': 8, 'environment': 8, 'files': 8, 'git': 8, 'diagnostics': 8}):
                raise ValueError('replay must retain all 40 tasks with at least three distinct repeats')
            populations[label] = set(identities)
            if label == 'candidate':
                passed = sum(row['passed'] is True for row in rows)
                rejected = sum(row['policy_rejections'] > 0 for row in rows)
                if (passed / len(rows) < .95 or rejected / len(rows) > .02
                        or not all(row['host_preserved'] is True for row in rows)):
                    raise ValueError('candidate completion, misrejection, or host-preservation gate failed')
                lines.append(f"- {replay['model']} / Linux / {replay['shell']}: "
                             f"{passed}/{len(rows)} completed; {rejected}/{len(rows)} tasks with a rejection.")
        if populations['baseline'] != populations['candidate']:
            raise ValueError('baseline and candidate populations differ')
    return lines
