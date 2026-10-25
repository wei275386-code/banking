import copy
import tempfile
import unittest
import uuid
from pathlib import Path

from scripts.household_settings_state import read_settings_state
from scripts.coverage_policy import empty_coverage
from scripts.release_contracts import ContractError, canonical_json, digest_bytes, parse_json
from scripts.workspace_state import MaintenanceGate, StateTransaction, WorkspacePaths


class HouseholdSettingsStateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = parse_json((Path(__file__).resolve().parents[1] /
            'native/PaymentImageCore/Tests/PaymentImageCoreTests/Fixtures/household-settings-golden.json').read_bytes())

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.directory = Path(self.temporary.name).resolve()

    def tearDown(self):
        self.temporary.cleanup()

    def create(self, mutate=None, fixture=None):
        fixture = self.fixture if fixture is None else fixture
        profile, policies = copy.deepcopy(fixture['profile']), copy.deepcopy(fixture['policies'])
        sources = [dict(id=identity, path=f'inputs/mock-{index}.csv', platform='mock-platform',
                        sha256=digest_bytes(f'mock-source-{index}'.encode()))
                   for index, identity in enumerate(fixture['context']['registered_source_ids'])]
        registry = dict(sources=sources)
        def initialize(transaction):
            db = transaction.connect(); db.execute('CREATE TABLE records(id TEXT PRIMARY KEY)'); db.commit()
            for index in range(len(sources)):
                file = transaction.path(f'inputs/mock-{index}.csv'); file.parent.mkdir(exist_ok=True)
                file.write_bytes(f'mock-source-{index}'.encode())
            docs = {'config/family-profile.json': profile, 'config/account-policies.json': policies,
                    'config/review-import-sources.json': registry, 'review/financial-review.json': {'records': []},
                    'review/payment-evidence.json': {}, 'review/coverage.json': empty_coverage()}
            if mutate:
                mutate(docs)
            for path, value in docs.items():
                transaction.write_json(path, value)
        return WorkspacePaths.create(self.directory / str(uuid.uuid4()), initialize)

    def read(self, paths, **overrides):
        args = dict(currency_codes=self.fixture['context']['currency_codes'],
                    referenced_member_ids=self.fixture['context']['referenced_member_ids'],
                    referenced_account_ids=self.fixture['context']['referenced_account_ids'])
        return read_settings_state(paths, **(args | overrides))

    def test_read_is_pinned_to_committed_settings_registry_and_retained_sources(self):
        paths = self.create(); before = paths.resolve_active()
        settings = self.read(paths)
        self.assertEqual(settings.pointer, (before.workspace_id, before.state_id, 0, before.state_manifest_hash))
        self.assertEqual(settings.settings.profile_bytes, canonical_json(self.fixture['profile']))
        self.assertEqual(len(settings.dependencies), 5)
        self.assertEqual(settings.context.registered_source_ids, ('source-a', 'source-b'))
        self.assertEqual(paths.resolve_active().pointer, before.pointer)

    def test_rename_deactivate_and_add_keep_identities_without_writing(self):
        paths = self.create(); snapshot = self.read(paths); before = paths.resolve_active()
        profile = copy.deepcopy(self.fixture['profile']); profile['members'][0].update(display_name='Renamed mock', status='inactive')
        profile['members'].append(dict(id='member-new', display_name='New mock', status='active'))
        policy = copy.deepcopy(self.fixture['policies']); policy['accounts'][0]['status'] = 'inactive'
        plan = snapshot.prepare_edit(canonical_json(profile), canonical_json(policy))
        self.assertEqual(plan.revalidate(paths).members[0].status, 'inactive')
        self.assertEqual(before.pointer, paths.resolve_active().pointer)
        self.assertEqual(before.path('config/family-profile.json').read_bytes(), snapshot.settings.profile_bytes)

    def test_deleting_even_unreferenced_baseline_ids_is_rejected(self):
        snapshot = self.read(self.create())
        profile = copy.deepcopy(self.fixture['profile']); profile['members'].append(dict(id='never-used', display_name='Extra mock', status='inactive'))
        # Add is legitimate; once committed, that identity too is retained.
        snapshot.prepare_edit(canonical_json(profile), snapshot.settings.policies_bytes)
        def with_extra(docs):
            docs['config/family-profile.json']['members'].append(dict(id='never-used', display_name='Extra mock', status='inactive'))
            docs['config/account-policies.json']['accounts'].append(dict(id='unused-account', display_name='Extra mock', owner_member_id=None, currency='CNY', status='inactive'))
        retained = self.read(self.create(with_extra))
        with self.assertRaises(ContractError):
            retained.prepare_edit(snapshot.settings.profile_bytes, retained.settings.policies_bytes)
        with self.assertRaises(ContractError):
            retained.prepare_edit(retained.settings.profile_bytes, snapshot.settings.policies_bytes)

    def test_registry_requires_explicit_unique_ids_and_manifest_retention(self):
        mutations = [lambda rows: rows[0].pop('id'), lambda rows: rows[1].update(id='source-a'),
                     lambda rows: rows[0].update(sha256='0' * 64), lambda rows: rows[0].update(sha256='0' * 64 + '\n'),
                     lambda rows: rows[0].update(path='../outside'), lambda rows: rows[0].update(path='inputs/missing.csv'),
                     lambda rows: rows[1].update(path=rows[0]['path'], sha256=rows[0]['sha256'])]
        for change in mutations:
            paths = self.create(lambda docs: change(docs['config/review-import-sources.json']['sources']))
            with self.subTest(change=change), self.assertRaises(ContractError):
                self.read(paths)

    def test_absent_partial_noncanonical_or_changed_settings_reject(self):
        for missing in [['config/family-profile.json'], ['config/account-policies.json'], ['config/family-profile.json', 'config/account-policies.json']]:
            paths = self.create(lambda docs: [docs.pop(key) for key in missing])
            with self.assertRaises(ContractError):
                self.read(paths)
        paths = self.create(); state = paths.resolve_active()
        state.path('config/family-profile.json').write_bytes(b'{}')
        with self.assertRaises(ContractError):
            self.read(paths)
        paths = self.create(); state = paths.resolve_active()
        file = state.path('config/family-profile.json'); file.write_bytes(file.read_bytes() + b'\n')
        manifest = parse_json(state.path('state-manifest.json').read_bytes())
        manifest['files']['config/family-profile.json'] = digest_bytes(file.read_bytes())
        raw = canonical_json(manifest); state.path('state-manifest.json').write_bytes(raw)
        pointer = state.pointer | {'state_manifest_hash': digest_bytes(raw)}
        paths.active_pointer.write_bytes(canonical_json(pointer))
        with self.assertRaises(ContractError):
            self.read(paths)

    def test_plan_rejects_other_household_and_any_pointer_advance(self):
        paths = self.create(); snapshot = self.read(paths)
        plan = snapshot.prepare_edit(snapshot.settings.profile_bytes, snapshot.settings.policies_bytes)
        with self.assertRaises(ContractError):
            plan.revalidate(self.create())
        with MaintenanceGate(paths).acquire('synthetic-state-advance') as token:
            with StateTransaction.begin(paths, token) as transaction:
                profile = copy.deepcopy(self.fixture['profile']); profile['household_name'] = 'Later mock state'
                transaction.write_json('config/family-profile.json', profile)
                transaction.prepare(); transaction.commit()
        with self.assertRaises(ContractError):
            plan.revalidate(paths)
        # A pinned reader remains a read of the old immutable state.
        self.assertEqual(snapshot.pointer[2], 0)

    def test_context_capabilities_and_additional_historical_refs_are_explicit(self):
        paths = self.create()
        for args in [dict(currency_codes=['EUR']), dict(referenced_member_ids=['unknown']),
                     dict(referenced_account_ids=['unknown']), dict(currency_codes='CNY')]:
            with self.subTest(args=args), self.assertRaises(ContractError):
                self.read(paths, **args)

    def test_registry_and_retained_ids_preserve_exact_unicode_identity(self):
        fixture = self.fixture['unicode']; paths = self.create(fixture=fixture)
        snapshot = self.read(paths, referenced_member_ids=[], referenced_account_ids=[])
        self.assertEqual(snapshot.context.registered_source_ids, tuple(fixture['context']['registered_source_ids']))
        self.assertEqual(len(set(value.encode('utf-8') for value in snapshot.context.registered_source_ids)), 2)
        profile = copy.deepcopy(fixture['profile']); profile['members'].pop()
        with self.assertRaises(ContractError):
            snapshot.prepare_edit(canonical_json(profile), snapshot.settings.policies_bytes)
