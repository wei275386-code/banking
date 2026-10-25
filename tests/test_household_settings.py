import copy
import json
from dataclasses import FrozenInstanceError
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from scripts.household_settings import SettingsContext, decode_settings, validate_settings
from scripts.release_contracts import ContractError, canonical_json


class HouseholdSettingsTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = json.loads((Path(__file__).resolve().parents[1] /
            'native/PaymentImageCore/Tests/PaymentImageCoreTests/Fixtures/household-settings-golden.json').read_bytes())

    def settings(self, fixture=None, profile=None, policies=None, context=None):
        fixture = self.fixture if fixture is None else fixture
        return validate_settings(fixture['profile'] if profile is None else profile,
            fixture['policies'] if policies is None else policies,
            context=SettingsContext(**(fixture['context'] if context is None else context)))

    def assert_case(self, settings, case):
        result = settings.resolve_funding(case['input'])
        self.assertEqual({'status': result.status, 'reason': result.reason, 'account_id': result.account_id,
                         'matched_rule_ids': list(result.matched_rule_ids),
                         'candidate_account_ids': list(result.candidate_account_ids)}, case['expected'])

    def test_shared_golden_scopes_priority_ambiguity_and_unknowns(self):
        settings = self.settings()
        for case in self.fixture['cases']:
            with self.subTest(case=case['name']):
                self.assert_case(settings, case)
        self.assertEqual(settings.profile_bytes, canonical_json(self.fixture['profile']))
        self.assertEqual(settings.policies_bytes, canonical_json(self.fixture['policies']))

    def test_rule_order_never_breaks_ties_or_changes_outcome(self):
        policy = copy.deepcopy(self.fixture['policies'])
        policy['routes'].reverse(); policy['aliases'].reverse()
        settings = self.settings(policies=policy)
        for case in self.fixture['cases']:
            with self.subTest(case=case['name']):
                self.assert_case(settings, case)

    def test_multiple_confirmed_rules_for_same_target_are_not_false_conflicts(self):
        policy = copy.deepcopy(self.fixture['policies'])
        duplicate = copy.deepcopy(policy['routes'][0]); duplicate['id'] = 'route-a-copy'
        policy['routes'].append(duplicate)
        result = self.settings(policies=policy).resolve_funding(self.fixture['cases'][0]['input'])
        self.assertEqual((result.status, result.account_id, result.matched_rule_ids),
                         ('resolved', 'account-a', ('route-a', 'route-a-copy')))

    def test_two_households_resolve_the_same_input_from_their_own_policy(self):
        first = self.settings()
        profile = copy.deepcopy(self.fixture['profile']); profile['household_name'] = 'Second mock household'
        policy = copy.deepcopy(self.fixture['policies']); policy['routes'][0]['target_account_id'] = 'account-b'
        second = self.settings(profile=profile, policies=policy)
        funding = copy.deepcopy(self.fixture['cases'][0]['input']); before = copy.deepcopy(funding)
        self.assertEqual(first.resolve_funding(funding).account_id, 'account-a')
        self.assertEqual(second.resolve_funding(funding).account_id, 'account-b')
        self.assertEqual(first.resolve_funding(funding).account_id, 'account-a')
        self.assertEqual(funding, before)

    def test_shared_invalid_business_and_shape_documents_fail_closed(self):
        for invalid in self.fixture['invalid_cases']:
            with self.subTest(case=invalid['name']), self.assertRaises(ContractError):
                self.settings(profile=invalid['profile'], policies=invalid['policies'])

    def test_unicode_opaque_ids_and_dynamic_object_keys_remain_byte_distinct(self):
        fixture = self.fixture['unicode']; settings = self.settings(fixture)
        self.assertEqual(len(settings.members), 2)
        self.assertEqual(len(set(dict(settings.source_owners))), 2)
        for case in fixture['cases']:
            self.assert_case(settings, case)
        self.assertEqual(settings.policies_bytes, canonical_json(fixture['policies']))

    def test_empty_household_has_no_personal_defaults_or_funding(self):
        profile = { 'household_name': '', 'members': []}
        policy = { 'accounts': [], 'aliases': [], 'routes': [], 'source_owners': {},
                  'unknown_account_policy': {'mode': 'needs_review', 'exclusion_member_ids': []}}
        settings = self.settings(profile=profile, policies=policy, context={
            'registered_source_ids': [], 'currency_codes': ['CNY'], 'referenced_member_ids': [], 'referenced_account_ids': []})
        self.assertEqual(settings.members, ())
        self.assertIsNone(settings.resolve_funding({'platform': 'unknown', 'source_account_name': 'unknown'}).account_id)

    def test_qualification_owns_immutable_snapshot_and_does_not_mutate_inputs(self):
        profile = copy.deepcopy(self.fixture['profile']); policy = copy.deepcopy(self.fixture['policies'])
        before = canonical_json(profile), canonical_json(policy)
        settings = self.settings(profile=profile, policies=policy)
        self.assertEqual((canonical_json(profile), canonical_json(policy)), before)
        profile['members'].clear(); policy['routes'].clear()
        self.assertEqual((settings.profile_bytes, settings.policies_bytes), before)
        self.assert_case(settings, self.fixture['cases'][0])
        with self.assertRaises(FrozenInstanceError):
            settings.household_name = 'changed'

    def test_historical_references_cannot_be_dropped_or_reassigned(self):
        for field in ('referenced_member_ids', 'referenced_account_ids'):
            context = copy.deepcopy(self.fixture['context']); context[field].append('historical-missing')
            with self.subTest(field=field), self.assertRaises(ContractError):
                self.settings(context=context)
        profile = copy.deepcopy(self.fixture['profile']); profile['members'][0]['status'] = 'inactive'
        self.settings(profile=profile)  # Deactivation preserves stable references.

    def test_duplicate_json_keys_header_numeric_kind_and_bad_unicode_rejected(self):
        context = SettingsContext(**self.fixture['context'])
        policy = canonical_json(self.fixture['policies'])
        raw = canonical_json(self.fixture['profile'])
        for malformed in (b'{"schema_version":1,"schema_version":1}',
                          canonical_json(dict(self.fixture['profile'], household_name=1.0)),
                          canonical_json(dict(self.fixture['profile'], schema_version=1))):
            with self.subTest(raw=malformed[:50]), self.assertRaises(ContractError):
                decode_settings(malformed, policy, context=context)
        profile = copy.deepcopy(self.fixture['profile']); profile['members'][0]['id'] = '\ud800'
        with self.assertRaises(ContractError):
            self.settings(profile=profile)

    def test_explicit_context_and_typed_bounded_inputs_required(self):
        for changed in ({'registered_source_ids': ['source-a', 'source-a']}, {'currency_codes': []},
                        {'currency_codes': ['cny']}, {'registered_source_ids': 'source-a'}):
            context = self.fixture['context'] | changed
            with self.subTest(context=changed), self.assertRaises(ContractError):
                self.settings(context=context)
        settings = self.settings()
        for invalid in ({'platform': True}, {'unexpected': 'value'}, {'source_account_name': 'x' * 4097}):
            with self.subTest(input=next(iter(invalid))), self.assertRaises(ContractError):
                settings.resolve_funding(invalid)

    def test_flat_packaged_import_uses_only_staged_stdlib_module_and_schemas(self):
        source = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as temporary:
            processor = Path(temporary).resolve() / 'processor'
            scripts = processor / 'scripts'; scripts.mkdir(parents=True)
            schemas = processor / 'schemas/release'; schemas.mkdir(parents=True)
            for name in ('household_settings.py', 'release_contracts.py'):
                shutil.copyfile(source / 'scripts' / name, scripts / name)
            for name in ('family-profile.schema.json', 'account-policies.schema.json'):
                shutil.copyfile(source / 'schemas/release' / name, schemas / name)
            fixture = processor / 'mock-settings.json'; fixture.write_text(json.dumps(self.fixture))
            code = ('import sys,json;sys.path.insert(0,sys.argv[1]);import household_settings as h;'
                    'f=json.load(open(sys.argv[2]));s=h.validate_settings(f["profile"],f["policies"],'
                    'context=h.SettingsContext(**f["context"]));'
                    'print(s.resolve_funding(f["cases"][0]["input"]).account_id)')
            result = subprocess.run([sys.executable, '-I', '-B', '-S', '-c', code, str(scripts), str(fixture)],
                                    env={}, cwd=processor, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), 'account-a')
            self.assertFalse((scripts / '__pycache__').exists())


if __name__ == '__main__':
    unittest.main()
