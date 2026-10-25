import copy
from dataclasses import asdict
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

from scripts.household_settings import SettingsContext, validate_settings
from scripts.release_contracts import ContractError, canonical_json, digest_bytes, parse_json, validate_contract
from scripts.settings_snapshot import (SettingsSnapshotPins, settings_document_rows,
                                       settings_field_values, validate_settings_snapshot)


class SettingsSnapshotTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.fixture = parse_json((Path(__file__).resolve().parents[1] /
            'native/PaymentImageCore/Tests/PaymentImageCoreTests/Fixtures/settings-snapshot-golden.json').read_bytes())

    def base(self):
        return copy.deepcopy(self.fixture['base'])

    def seal(self, packet):
        state_hash = digest_bytes(canonical_json(packet['state_manifest']))
        packet['checkpoint']['state']['state_manifest_hash'] = state_hash
        packet['business_proof']['state_manifest_hash'] = state_hash
        for key, name in [('state_manifest', 'state-manifest.json'), ('business_proof', 'business-proof.json'), ('field_state', 'field-state.json')]:
            packet['checkpoint']['files'][name] = digest_bytes(canonical_json(packet[key]))
        raw = {key: canonical_json(packet[key]) for key in ['checkpoint', 'state_manifest', 'business_proof', 'field_state']}
        pins = SettingsSnapshotPins(**self.fixture['pins'], generation=digest_bytes(raw['checkpoint']))
        return dict(pins=pins, checkpoint_raw=raw['checkpoint'], state_manifest_raw=raw['state_manifest'],
                    business_proof_raw=raw['business_proof'], field_state_raw=raw['field_state'],
                    snapshot_documents={path: canonical_json(value) for path, value in packet['snapshot_documents'].items()},
                    replayed_values=packet['replayed_values'], replayed_conflict_keys=set(packet['replayed_conflict_keys']),
                    context=SettingsContext(**self.fixture['context']))

    def mutate(self, packet, case):
        if 'mutations' in case:
            for mutation in case['mutations']:
                self.mutate(packet, mutation)
            return
        path = [case['target'], *case['path']]
        target = packet
        for key in path[:-1]:
            target = target[int(key)] if isinstance(target, list) else target[key]
        key = int(path[-1]) if isinstance(target, list) else path[-1]
        if case.get('remove'):
            del target[key]
        else:
            target[key] = copy.deepcopy(case['value'])

    def test_shared_baseline_and_whole_document_codec(self):
        settings = validate_settings_snapshot(**self.seal(self.base()))
        self.assertEqual(settings_field_values(settings), self.fixture['base']['replayed_values'])
        self.assertEqual(settings_document_rows(settings), self.fixture['base']['business_proof']['settings_documents'])

    def test_shared_resealed_adversarial_vectors_reject_inner_mismatch(self):
        for case in self.fixture['invalid_cases']:
            with self.subTest(case=case['name']), self.assertRaises(ContractError):
                packet = self.base(); self.mutate(packet, case)
                validate_settings_snapshot(**self.seal(packet))

    def test_generation_and_metadata_raw_hash_tampering_fail(self):
        for name in ['checkpoint_raw', 'state_manifest_raw', 'business_proof_raw', 'field_state_raw']:
            args = self.seal(self.base())
            obj = parse_json(args[name]); obj['extra_tamper'] = True
            args[name] = canonical_json(obj)
            with self.subTest(name=name), self.assertRaises(ContractError):
                validate_settings_snapshot(**args)
        args = self.seal(self.base()); args['pins'] = SettingsSnapshotPins(**self.fixture['pins'], generation='f' * 64)
        with self.assertRaises(ContractError):
            validate_settings_snapshot(**args)

    def test_noncanonical_duplicate_key_and_null_raw_inputs_reject_even_when_rehashed(self):
        for name in ['checkpoint_raw', 'state_manifest_raw', 'business_proof_raw', 'field_state_raw']:
            for change in [lambda raw: raw + b'\n', lambda raw: b'{"duplicate":1,"duplicate":2}', lambda raw: b'null']:
                args = self.seal(self.base()); args[name] = change(args[name])
                if name == 'checkpoint_raw':
                    args['pins'] = SettingsSnapshotPins(**self.fixture['pins'], generation=digest_bytes(args[name]))
                else:
                    cp = parse_json(args['checkpoint_raw'])
                    path = {'state_manifest_raw':'state-manifest.json', 'business_proof_raw':'business-proof.json', 'field_state_raw':'field-state.json'}[name]
                    cp['files'][path] = digest_bytes(args[name]); args['checkpoint_raw'] = canonical_json(cp)
                    args['pins'] = SettingsSnapshotPins(**self.fixture['pins'], generation=digest_bytes(args['checkpoint_raw']))
                with self.subTest(name=name), self.assertRaises(ContractError):
                    validate_settings_snapshot(**args)

    def test_baseline_without_heads_and_explicit_ordinary_settings_heads_both_validate(self):
        packet = self.base(); rows = packet['business_proof']['settings_documents']
        packet['business_proof']['documents'] = [dict(path=r['state_path'], snapshot_path=r['snapshot_path'], sha256=r['sha256']) for r in rows]
        packet['business_proof']['settings_documents'].reverse()
        settings = validate_settings_snapshot(**self.seal(packet))
        self.assertEqual(settings.household_name, packet['snapshot_documents']['family-profile.json']['household_name'])
        packet['business_proof']['documents'].append(packet['business_proof']['documents'][0])
        with self.assertRaises(ContractError):
            validate_settings_snapshot(**self.seal(packet))

    def test_business_context_and_schema_validation_still_gate_consistent_hashes(self):
        args = self.seal(self.base())
        args['context'] = SettingsContext(registered_source_ids=(), currency_codes=('CNY',), referenced_member_ids=(), referenced_account_ids=())
        with self.assertRaises(ContractError):
            validate_settings_snapshot(**args)
        cp = self.base()['checkpoint']
        validate_contract('family-snapshot', cp)
        cp['unexpected_control'] = True
        with self.assertRaises(ContractError):
            validate_contract('family-snapshot', cp)

    def test_input_size_and_depth_are_bounded(self):
        args = self.seal(self.base()); args['checkpoint_raw'] = b' ' * (16 * 1024 * 1024 + 1)
        with self.assertRaises(ContractError):
            validate_settings_snapshot(**args)
        args['checkpoint_raw'] = b'[' * 130 + b'0' + b']' * 130
        with self.assertRaises(ContractError):
            validate_settings_snapshot(**args)

    def test_flat_packaged_snapshot_validation_has_complete_stdlib_schema_closure(self):
        source = Path(__file__).resolve().parents[1]
        args = self.seal(self.base())
        portable = {key: value.decode('utf-8') if isinstance(value, bytes) else value for key, value in args.items()}
        portable.update(pins=asdict(args['pins']), context=asdict(args['context']),
                        snapshot_documents={key: raw.decode('utf-8') for key, raw in args['snapshot_documents'].items()},
                        replayed_conflict_keys=[])
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory); scripts = root / 'scripts'; scripts.mkdir()
            schemas = root / 'schemas/release'; schemas.mkdir(parents=True)
            for name in ['settings_snapshot.py', 'household_settings.py', 'release_contracts.py']:
                shutil.copyfile(source / 'scripts' / name, scripts / name)
            for name in ['family-snapshot', 'common', 'state-manifest', 'active-state', 'field-state', 'family-profile', 'account-policies']:
                shutil.copyfile(source / 'schemas/release' / (name + '.schema.json'), schemas / (name + '.schema.json'))
            fixture = root / 'mock.json'; fixture.write_bytes(canonical_json(portable))
            code = '''import json,sys
sys.path.insert(0,sys.argv[1])
import settings_snapshot as s
args=json.load(open(sys.argv[2]))
args['pins']=s.SettingsSnapshotPins(**args['pins'])
args['context']=s.SettingsContext(**args['context'])
for key in ['checkpoint_raw','state_manifest_raw','business_proof_raw','field_state_raw']:
    args[key]=args[key].encode('utf-8')
args['snapshot_documents']={key:value.encode('utf-8') for key,value in args['snapshot_documents'].items()}
args['replayed_conflict_keys']=set(args['replayed_conflict_keys'])
print(s.validate_settings_snapshot(**args).household_name)
'''
            result = subprocess.run([sys.executable, '-I', '-S', '-B', '-c', code, str(scripts), str(fixture)],
                                    cwd=root, env={}, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), self.base()['snapshot_documents']['family-profile.json']['household_name'])
            self.assertFalse((scripts / '__pycache__').exists())

    def test_initial_generation_can_follow_unused_sequence_reservations(self):
        packet = self.base(); packet['checkpoint']['sequence'] = 7
        self.assertIsNotNone(validate_settings_snapshot(**self.seal(packet)))

    def test_strict_hash_checks_preserve_valid_external_pins_and_extra_file_maps(self):
        packet = self.base(); valid_hash = 'abcdef0123456789' * 4
        packet['checkpoint'].update(sequence=2, parent_generation=valid_hash)
        packet['state_manifest']['parent_pointer'] = dict(workspace_id=self.fixture['pins']['workspace_id'],
            state_id='previous-mock-state', local_revision=6, state_manifest_hash=valid_hash)
        for key in ('checkpoint', 'state_manifest'):
            packet[key]['files']['mock/retained.json'] = valid_hash
        self.assertIsNotNone(validate_settings_snapshot(**self.seal(packet)))
