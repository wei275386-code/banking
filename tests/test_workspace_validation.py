"""Product decoding/integrity faults must never publish the staging state."""
import csv
import json
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from scripts.import_review_materials import run as import_materials
from scripts.processor_result import execute_workspace
from scripts.workspace_initialization import create_workspace
from scripts.workspace_state import MaintenanceGate, StateTransaction
from scripts.workspace_validation import ProductValidationError, validate_product_state, validate_transaction


class ProductValidationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.paths = create_workspace(self.root / 'workspace')
        self.source = self.root / 'wallet.csv'
        with self.source.open('w', encoding='gb18030', newline='') as stream:
            csv.writer(stream).writerows([
                ['交易时间','交易分类','交易对方','对方账号','商品说明','收/支','金额','收/付款方式','交易状态','交易订单号','商家订单号','备注'],
                ['2025-12-20 10:00:00','餐饮美食','测试商户','','咖啡','支出','60.00','余额','交易成功','wallet-fixture','merchant-fixture','']])
        with MaintenanceGate(self.paths).acquire('fixture') as token:
            result, code = execute_workspace(self.paths.workspace, self.paths.read_pointer(),
                str(uuid.uuid4()), str(uuid.uuid4()), None,
                lambda transaction, selected: import_materials(transaction.root, transaction.review,
                    selected, retained=True, input_ids=[str(self.source)]), [str(self.source)], token=token)
        self.assertEqual(code, 0, result)
        self.before = self.paths.read_pointer()

    def tearDown(self):
        self.temp.cleanup()

    def change(self, transaction, name, edit):
        path = transaction.review / name
        value = json.loads(path.read_text())
        edit(value)
        transaction.write_json('review/' + name, value)

    def assert_invalid(self, mutation):
        with MaintenanceGate(self.paths).acquire('validator-fault') as token:
            def action(transaction, selected):
                mutation(transaction)
                validate_transaction(transaction)
            result, code = execute_workspace(self.paths.workspace, self.before,
                str(uuid.uuid4()), str(uuid.uuid4()), None, action, [], token=token)
        self.assertEqual((code, result['phase']), (1, 'failed'), result)
        self.assertEqual(result['membership'], [])
        self.assertEqual(self.paths.read_pointer(), self.before)

    def test_real_empty_and_wallet_projections_validate(self):
        empty = create_workspace(self.root / 'empty')
        self.assertEqual(validate_product_state(empty.resolve_active().root)['financial_records'], 0)
        proof = validate_product_state(self.paths.resolve_active().root)
        self.assertEqual(proof['financial_records'], 1)
        self.assertEqual(proof['registered_sources'], 1)

    def test_required_swift_field_cannot_be_deleted(self):
        self.assert_invalid(lambda tx: self.change(tx, 'financial-review.json',
            lambda value: value.pop('fire_parameters')))

    def test_processor_mandatory_validator_rejects_invalid_action(self):
        with MaintenanceGate(self.paths).acquire('mandatory-validator') as token:
            def action(transaction, selected):
                self.change(transaction, 'financial-review.json', lambda value: value.pop('fire_parameters'))
            result, code = execute_workspace(self.paths.workspace, self.before,
                str(uuid.uuid4()), str(uuid.uuid4()), None, action, [], token=token)
        self.assertEqual((code, result['phase']), (1, 'failed'), result)
        self.assertEqual(result['membership'], [])
        self.assertEqual(self.paths.read_pointer(), self.before)

    def test_bool_is_not_swift_integer(self):
        self.assert_invalid(lambda tx: self.change(tx, 'financial-review.json',
            lambda value: value['records'][0]['components'][0].update(net_cents=True)))

    def test_present_optional_field_must_decode(self):
        self.assert_invalid(lambda tx: self.change(tx, 'financial-review.json',
            lambda value: value['records'][0].update(payment_accounts=[42])))

    def test_nullable_optional_probe_matches_swift_decoder(self):
        with MaintenanceGate(self.paths).acquire('nullable-probe') as token:
            def action(transaction, selected):
                self.change(transaction, 'payment-evidence.json',
                    lambda value: value.update(ocr_probe=None))
                return {}
            result, code = execute_workspace(self.paths.workspace, self.before,
                str(uuid.uuid4()), str(uuid.uuid4()), None, action, [], token=token)
        self.assertEqual((code, result['phase']), (0, 'committed'), result)
        self.assertEqual(validate_product_state(self.paths.resolve_active().root)['financial_records'], 1)

    def test_duplicate_record_identity_rejected(self):
        self.assert_invalid(lambda tx: self.change(tx, 'financial-review.json',
            lambda value: value['records'].append(value['records'][0])))

    def test_dataset_identity_mismatch_rejected(self):
        self.assert_invalid(lambda tx: self.change(tx, 'financial-review.json',
            lambda value: value.update(source_dataset_id='unrelated')))

    def test_coverage_and_cutoff_must_match(self):
        self.assert_invalid(lambda tx: self.change(tx, 'financial-review.json',
            lambda value: value.update(cutoff='2025-12-21')))
        self.assert_invalid(lambda tx: self.change(tx, 'payment-evidence.json',
            lambda value: value['coverage'].update(revision=value['coverage']['revision'] + 1)))

    def test_dangling_financial_evidence_reference_rejected(self):
        self.assert_invalid(lambda tx: self.change(tx, 'financial-review.json',
            lambda value: value['records'][0]['evidence_keys'].append('missing-observation')))

    def test_supporting_material_reference_requires_its_verified_source(self):
        with MaintenanceGate(self.paths).acquire('supporting-material') as token:
            with StateTransaction.begin(self.paths, token) as transaction:
                evidence = json.loads((transaction.review / 'payment-evidence.json').read_text())
                reference = evidence['clusters'][0]['representative']['source_evidence']
                material = {'id': 'image-order:synthetic', 'title': 'Synthetic order support',
                    'date': '2025-12-20', 'date_basis': 'order_service_date',
                    'amount_cents': 6000, 'status': 'support only',
                    'source_evidence': reference}
                supplement = {'observations': [], 'links': [], 'materials': [material]}
                transaction.write_json('review/supplemental-evidence.json', supplement)
                self.change(transaction, 'financial-review.json',
                    lambda value: value['records'][0]['evidence_keys'].append(material['id']))
                validate_transaction(transaction)
                reference['source']['sha256'] = '0' * 64
                transaction.write_json('review/supplemental-evidence.json', supplement)
                with self.assertRaisesRegex(ProductValidationError, 'asset hash differs'):
                    validate_transaction(transaction)
        self.assertEqual(self.paths.read_pointer(), self.before)

    def test_dangling_candidate_reference_rejected(self):
        def change(value):
            value['candidates'].append({'candidate_id': 'dangling', 'kind': 'wallet_bank',
                'record_ids': ['missing-observation'], 'bank_ids': [],
                'association_status': 'pending', 'review_required': True})
        self.assert_invalid(lambda tx: self.change(tx, 'payment-evidence.json', change))

    def test_corrupt_asset_hash_and_path_escape_rejected(self):
        def checksum(value):
            value['clusters'][0]['representative']['source_evidence']['source']['sha256'] = '0' * 64
        self.assert_invalid(lambda tx: self.change(tx, 'payment-evidence.json', checksum))
        def path(value):
            value['clusters'][0]['representative']['source_evidence']['source']['path'] = '../banking.sqlite3'
        self.assert_invalid(lambda tx: self.change(tx, 'payment-evidence.json', path))

    def test_invalid_registry_hash_rejected(self):
        def mutate(transaction):
            registry = json.loads((transaction.root / 'config/review-import-sources.json').read_text())
            registry['sources'][0]['sha256'] = '0' * 64
            transaction.write_json('config/review-import-sources.json', registry)
        self.assert_invalid(mutate)

    def test_document_identity_requires_the_verified_registry(self):
        self.assert_invalid(lambda tx: self.change(tx, 'payment-evidence.json',
            lambda value: value['documents'][0].update(file_sha256='0' * 64)))

    def test_fabricated_bank_row_cannot_enter_projection(self):
        def mutate(value):
            value['bank_records'].append({'id': 999, 'date': '2025-12-20', 'description': 'fabricated',
                'amount_cents': 1, 'is_credit': 0, 'source_evidence': {'kind': 'fixture'}})
        self.assert_invalid(lambda tx: self.change(tx, 'payment-evidence.json', mutate))

    def test_repeated_asset_references_hash_once(self):
        from scripts import workspace_validation
        active = self.paths.resolve_active()
        original = workspace_validation.digest_file
        paths = []
        def counting(path):
            paths.append(path)
            return original(path)
        with patch.object(workspace_validation, 'digest_file', side_effect=counting):
            validate_product_state(active.root)
        self.assertEqual(len(paths), len(set(paths)))

    def test_validator_hook_blocks_prepare_without_mutating_active(self):
        paths = create_workspace(self.root / 'prepare-empty')
        before = paths.read_pointer()
        with MaintenanceGate(paths).acquire('validator-prepare') as token:
            with StateTransaction.begin(paths, token) as transaction:
                transaction.write_json('review/financial-review.json', {})
                with self.assertRaises(ProductValidationError):
                    transaction.prepare(validator=validate_transaction)
        self.assertEqual(paths.read_pointer(), before)
