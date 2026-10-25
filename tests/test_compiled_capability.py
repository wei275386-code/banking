"""Fail closed on compiled/configured release drift; no installs or device use."""
import json
from pathlib import Path
import unittest

from scripts.release_preflight import compiled_capability_failures


class Source:
    def __init__(self):
        root = Path(__file__).resolve().parents[1]
        name = 'native/PaymentImageCore/Sources/PaymentImageCore/WorkspaceCompatibility.swift'
        self.values = {path: (root / path).read_bytes() for path in (
            name, 'release/compatibility.json', 'release/runtime-lock.json', 'config/release-version.json')}
        self.entries = dict.fromkeys(self.values)

    def entry(self, path):
        return '100644', 'blob', path

    def git(self, *arguments):
        return self.values[arguments[-1]]

    def metadata(self, path):
        return json.loads(self.values[path])

    def set(self, path, value):
        self.values[path] = json.dumps(value).encode()


class CompiledCapabilityTests(unittest.TestCase):
    def check(self, source):
        return compiled_capability_failures(source, source.metadata('config/release-version.json'), list(source.entries))

    def test_current_compiled_constants_match_authoritative_inputs(self):
        self.assertEqual(self.check(Source()), [])

    def test_version_build_runtime_schema_and_policy_drift_fail_closed(self):
        for path, key in [('config/release-version.json', 'app_version'),
                          ('release/compatibility.json', 'build_number'),
                          ('release/runtime-lock.json', 'runtime_version')]:
            with self.subTest(path=path, key=key):
                source = Source()
                document = source.metadata(path)
                original = document[key]
                if key == 'app_version':
                    major, minor, patch = map(int, original.split('.'))
                    document[key] = f'{major}.{minor}.{patch + 1}'
                elif key == 'build_number':
                    document[key] = original + 1
                else:
                    document[key] = original + '-unqualified'
                self.assertNotEqual(document[key], original)
                source.set(path, document)
                self.assertEqual(self.check(source), ['compiled_release_version_drift'])
        source = Source(); policy = source.metadata('release/compatibility.json')
        policy['runtime_version'] = 'another-runtime'; source.set('release/compatibility.json', policy)
        self.assertEqual(self.check(source), ['compiled_runtime_capability_drift'])

    def test_missing_allowlist_or_duplicate_declaration_is_blocked(self):
        source = Source(); version = source.metadata('config/release-version.json')
        self.assertEqual(compiled_capability_failures(source, version, []), ['compiled_capability_inputs_missing'])
        name = 'native/PaymentImageCore/Sources/PaymentImageCore/WorkspaceCompatibility.swift'
        source.values[name] += b'\npublic static let buildNumber = 18\n'
        self.assertEqual(self.check(source), ['compiled_capability_contract_invalid'])


if __name__ == '__main__':
    unittest.main()
