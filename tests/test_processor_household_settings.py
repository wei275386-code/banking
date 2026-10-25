"""From-zero production-path checks; no private workspace or provider inputs."""
import copy
import tempfile
import unittest
from pathlib import Path

from scripts.household_settings import (SettingsContext, validate_settings,
    load_processor_settings, project_funding, project_household_records)
from scripts.payment_evidence import generate_candidates
from scripts.source_reconciliation import reconcile
from scripts.release_contracts import canonical_json, ContractError


class AccountIdentityTests(unittest.TestCase):
    def test_consolidation_preserves_independent_original_identity(self):
        from scripts.account_consolidation import apply
        row = {'id': 'record-a', 'user_id': 'member-a', 'user_relation': 'self',
               'payment_accounts': ['Old card'], 'payment_account_status': 'identified',
               'account_views': ['Old card']}
        before = copy.deepcopy(row)
        policy = {'excluded_records': {}, 'aliases': {'Old card': 'New card'},
                  'channel_names': [], 'pending_names': [], 'canonical_accounts': ['New card']}
        apply([row], policy)
        self.assertEqual(row['payment_accounts'], ['New card'])
        self.assertEqual(row['account_identity_before_consolidation'],
                         {key: value for key, value in before.items() if key != 'id'})
        row['payment_accounts'].append('Another card')
        self.assertEqual(row['account_identity_before_consolidation']['payment_accounts'], ['Old card'])


def make_settings(*, conflict=False, visual_account=None):
    profile = { 'household_name': 'Synthetic household', 'members': [
        {'id': 'member-a', 'display_name': 'Synthetic member A', 'status': 'active'},
        {'id': 'member-b', 'display_name': 'Synthetic member B', 'status': 'active'}]}
    def route(identity, platform, source_account, target):
        selector = {'platform': platform, 'source_account_name' if platform != 'bank' else 'source_account_id': source_account}
        return {'id': identity, 'source_selector': selector, 'target_account_id': target,
                'confirmed': True, 'basis': 'From-zero test declaration'}
    policies = { 'accounts': [
        {'id': identity, 'display_name': 'Synthetic ' + identity, 'owner_member_id': 'member-a', 'currency': 'CNY', 'status': 'active'}
        for identity in ('account-a', 'account-b')],
        'routes': [route('wallet', 'alipay', 'Synthetic wallet card', 'account-a'),
                   route('bank-a', 'bank', '9001', 'account-a'), route('bank-b', 'bank', '9002', 'account-b')],
        'aliases': [], 'source_owners': {},
        'unknown_account_policy': {'mode': 'needs_review', 'exclusion_member_ids': ['member-b']}}
    if visual_account is not None:
        policies['routes'].append(route('visual', 'unionpay', 'Synthetic visual card', visual_account))
    if conflict:
        policies['routes'].append({'id': 'overlap', 'source_selector': {'platform': 'alipay', 'source_id': 'source-a', 'source_account_name': 'Synthetic wallet card'},
            'target_account_id': 'account-b', 'confirmed': True, 'basis': 'Explicit conflicting test rule'})
    return validate_settings(profile, policies, context=SettingsContext(('source-a',), ('CNY',), (), ()))


def evidence():
    wallet = {'platform': 'alipay', 'source_id': 'source-a', 'file_sha256': 'a' * 64,
        'payment_method': 'Synthetic wallet card', 'currency': 'CNY', 'event_kind': 'payment',
        'current_payment_state': 'successful', 'raw_direction': '支出', 'platform_reported_amount_cents': 1234,
        'transaction_time': '2026-02-03 10:00:00', 'time_precision': 'second', 'source_profile_id': 'profile-a',
        'merchant': 'Synthetic merchant'}
    banks = [{'id': index, 'account_number': number, 'date': '2026-02-03', 'post_date': '2026-02-04',
              'amount_cents': 1234, 'is_credit': 0, 'currency': 'CNY', 'description': 'ALIPAY synthetic'}
             for index, number in [(1, '9001'), (2, '9002')]]
    return wallet, banks


class ProcessorHouseholdSettingsTests(unittest.TestCase):
    def _visual_bridge_report(self, visual_account):
        wallet, _ = evidence()
        wallet.update(owner_id='member-a', profile_identity_verified=True)
        visual = copy.deepcopy(wallet)
        visual.update(platform='unionpay', payment_method='Synthetic visual card', visually_verified_funding=True)
        project_funding([wallet, visual], [], make_settings(visual_account=visual_account),
                        {'source-a': {'sha256': 'a' * 64}})
        return {'clusters': [{'cluster_id': key, 'representative': row, 'conflicting_fields': []}
                             for key, row in [('wallet', wallet), ('visual', visual)]],
                'bank_records': [], 'candidates': []}

    def test_visual_bridge_accepts_same_resolved_funding_account(self):
        report = self._visual_bridge_report('account-a')
        added = reconcile(report, {})
        self.assertEqual(len(added), 1)
        self.assertEqual(set(added[0]['record_ids']), {'visual', 'wallet'})
        self.assertFalse(added[0]['review_required'])

    def test_visual_bridge_rejects_different_resolved_funding_accounts(self):
        report = self._visual_bridge_report('account-b')
        originals = copy.deepcopy(report['clusters'])
        self.assertEqual(reconcile(report, {}), [])
        self.assertEqual(report['candidates'], [])
        self.assertEqual(report['clusters'], originals)

    def test_configured_stable_funding_selects_only_its_bank_account(self):
        row, banks = evidence()
        raw = copy.deepcopy(row)
        sources = {'source-a': {'sha256': 'a' * 64}}
        project_funding([row], banks, make_settings(), sources)
        result = generate_candidates([{'cluster_id': 'wallet-a', 'representative': row, 'conflicting_fields': []}], banks)
        self.assertEqual([c['bank_ids'] for c in result['candidates']], [['bank:1']])
        self.assertEqual(row['payment_method'], raw['payment_method'])
        self.assertEqual(row['transaction_time'], raw['transaction_time'])
        self.assertNotIn('owner_id', row)  # Funding owner never becomes consumer.

    def test_missing_or_conflicting_configuration_never_uses_a_card_default(self):
        for settings in (None, make_settings(conflict=True)):
            row, banks = evidence()
            project_funding([row], banks, settings, {'source-a': {'sha256': 'a' * 64}})
            result = generate_candidates([{'cluster_id': 'wallet-a', 'representative': row, 'conflicting_fields': []}], banks, mapping_status='confirmed')
            self.assertFalse(result['candidates'])
            self.assertNotIn('funding_account_id', row)

    def test_currency_change_does_not_gain_ownership_or_funding(self):
        row, banks = evidence()
        row['currency'] = 'USD'
        project_funding([row], banks, make_settings(), {'source-a': {'sha256': 'a' * 64}})
        self.assertEqual(row['funding_resolution']['reason'], 'currency_mismatch')
        self.assertNotIn('funding_account_id', row)
        self.assertNotIn('owner_id', row)

    def test_names_and_exclusion_are_explicit_and_identity_snapshot_is_retained(self):
        row, banks = evidence()
        settings = make_settings()
        project_funding([row], banks, settings, {})
        old = {'id': 'purchase', 'user_id': 'member-b', 'user_relation': 'self', 'events': [],
               'evidence_keys': ['wallet-a'], 'payment_accounts': ['Old retained label'],
               'payment_account_status': 'unresolved', 'account_views': []}
        record = copy.deepcopy(old)
        project_household_records([record], settings, {'wallet-a': row}, {}, originals=[old])
        self.assertEqual(record['user_display_name'], 'Synthetic member B')
        self.assertTrue(record['review_exclusion_allowed'])
        self.assertEqual(record['account_identity_before_consolidation']['payment_accounts'], ['Old retained label'])
        unknown = copy.deepcopy(old) | {'id': 'unknown', 'user_id': None}
        project_household_records([unknown], settings, {}, {})
        self.assertIsNone(unknown['user_id'])
        self.assertFalse(unknown['review_exclusion_allowed'])
        self.assertEqual(unknown['user_display_name'], '未确认')

    def test_actual_root_loader_requires_pair_and_explicit_currency_registry(self):
        settings = make_settings()
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); config = root / 'config'; config.mkdir()
            self.assertEqual(load_processor_settings(root), (None, {}))
            (config / 'family-profile.json').write_bytes(settings.profile_bytes)
            with self.assertRaises(ContractError): load_processor_settings(root)
            (config / 'account-policies.json').write_bytes(settings.policies_bytes)
            registry = {'sources': [{'id': 'source-a', 'path': 'sources/a.csv', 'platform': 'alipay', 'sha256': 'a' * 64}]}
            (config / 'review-import-sources.json').write_bytes(canonical_json(registry))
            with self.assertRaises(ContractError): load_processor_settings(root)
            registry['currency_codes'] = ['USD']
            (config / 'review-import-sources.json').write_bytes(canonical_json(registry))
            with self.assertRaises(ContractError): load_processor_settings(root)
            registry['currency_codes'] = ['CNY']
            (config / 'review-import-sources.json').write_bytes(canonical_json(registry))
            qualified, sources = load_processor_settings(root)
            self.assertEqual(qualified.profile_bytes, settings.profile_bytes)
            self.assertEqual(set(sources), {'source-a'})

    def test_new_workspace_uses_empty_pair_and_preserves_its_committed_identity(self):
        from scripts.workspace_initialization import create_workspace
        from scripts.workspace_state import WorkspacePaths
        with tempfile.TemporaryDirectory() as folder:
            destination = Path(folder).resolve() / 'new-family'
            create_workspace(destination)
            paths = WorkspacePaths(destination)
            state = paths.resolve_active()
            settings, sources = load_processor_settings(state.root)
            self.assertEqual(settings.members, ())
            self.assertEqual(settings.accounts, ())
            self.assertEqual(sources, {})
            self.assertEqual(settings.household_name, '')
