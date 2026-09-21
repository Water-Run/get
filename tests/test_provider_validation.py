"""Release gates reject incomplete populations and mismatched payloads."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from verify_provider_validation import validate_attestation


def fixture():
    digest = 'a' * 64
    runs = []
    for label in ['baseline', 'candidate']:
        for category in ['system', 'environment', 'files', 'git', 'diagnostics']:
            for index in range(8):
                for repeat in range(1, 4):
                    runs.append(dict(binary=label, category=category, case=f'{category}-{index}',
                                     repeat=repeat, passed=True, policy_rejections=0, host_preserved=True))
    return dict(schema_version=4, version='4.0.0', status='passed',
                linux_payload_sha256=digest, live_configuration_preserved=True,
                replays=[dict(model='fixture-model', shell='fish', platform='linux',
                              coverage='40 tasks x 3 or more', binary_sha256={'candidate': digest},
                              provider_settings_preserved=True, binaries_preserved=True,
                              corpus_sha256=digest, runner_sha256=digest, runs=runs)])


class ProviderGateTests(unittest.TestCase):
    def test_complete_population_is_bound_to_payload(self):
        record = fixture()
        self.assertIn('120/120', validate_attestation(record, '4.0.0', 'a' * 64)[0])
        with self.assertRaises(ValueError): validate_attestation(record, '4.0.0', 'b' * 64)

    def test_missing_duplicate_and_pilot_attempts_cannot_attest(self):
        for kind in ['missing', 'duplicate', 'pilot', 'pending']:
            record = fixture()
            if kind == 'missing': record['replays'][0]['runs'].pop()
            elif kind == 'duplicate': record['replays'][0]['runs'].append(record['replays'][0]['runs'][-1])
            elif kind == 'pilot': record['replays'][0]['coverage'] = 'pilot'
            else: record['status'] = 'pending'
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                validate_attestation(record, '4.0.0', 'a' * 64)

    def test_failures_remain_in_denominator_and_mutation_always_fails(self):
        record = fixture()
        rows = record['replays'][0]['runs'][120:]
        for row in rows[:6]: row['passed'] = False
        self.assertIn('114/120', validate_attestation(record, '4.0.0', 'a' * 64)[0])
        rows[6]['passed'] = False
        with self.assertRaises(ValueError): validate_attestation(record, '4.0.0', 'a' * 64)
        rows[6]['passed'] = True
        rows[0]['host_preserved'] = False
        with self.assertRaises(ValueError): validate_attestation(record, '4.0.0', 'a' * 64)

    def test_rejections_have_an_independent_task_gate(self):
        record = fixture()
        for row in record['replays'][0]['runs'][120:123]: row['policy_rejections'] = 1
        with self.assertRaises(ValueError): validate_attestation(record, '4.0.0', 'a' * 64)


if __name__ == '__main__': unittest.main()
