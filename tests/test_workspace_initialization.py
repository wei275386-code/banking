"""F0 is created by the production initializer, never hand-patched or seeded."""
import csv
import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path

import openpyxl

from scripts.financial_review import run as financial
from scripts.import_review_materials import run as import_materials
from scripts.processor_result import execute_workspace
from scripts.workspace_initialization import create_workspace, initialize_empty_state
from scripts.workspace_state import MaintenanceGate, WorkspacePaths


class EmptyWorkspaceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.paths = create_workspace(self.root / 'workspace')

    def tearDown(self):
        self.temp.cleanup()

    def import_selected(self, source):
        expected = self.paths.read_pointer()
        with MaintenanceGate(self.paths).acquire('test-import') as token:
            result, status = execute_workspace(self.paths.workspace, expected,
                str(uuid.uuid4()), str(uuid.uuid4()), None,
                lambda transaction, selected: import_materials(transaction.root,
                    transaction.review, selected, retained=True, input_ids=[str(source)]),
                [str(source)], token=token)
        return result, status

    def csv(self, day, *, refund=False, name='wallet.csv'):
        source = self.root / name
        rows = [['交易时间','交易分类','交易对方','对方账号','商品说明','收/支','金额','收/付款方式','交易状态','交易订单号','商家订单号','备注'],
                [day + ' 10:00:00','餐饮美食','测试商户','','咖啡','收入' if refund else '支出','40.00' if refund else '60.00',
                 '余额','退款成功' if refund else '交易成功',name,'merchant-' + name,'']]
        with source.open('w', encoding='gb18030', newline='') as stream:
            csv.writer(stream).writerows(rows)
        return source

    def report(self):
        return json.loads((self.paths.resolve_active().review / 'financial-review.json').read_text())

    def test_empty_real_schema_reports_and_reopen(self):
        handle = self.paths.resolve_active()
        with sqlite3.connect(handle.database) as db:
            self.assertEqual(db.execute('SELECT id,transaction_category FROM transactions').fetchall(), [])
            self.assertIn('transactions', {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")})
        report = self.report()
        self.assertEqual(report['records'], [])
        self.assertIsNone(report['cutoff'])
        self.assertEqual(report['summary']['net_cents'], 0)
        self.assertIsNone(report['summary']['from'])
        self.assertIsNone(report['summary']['to'])
        self.assertIsNone(report['fire_parameters']['currentFireAssets'])
        self.assertEqual(report['fire_parameters']['status'], 'needs_input')
        self.assertTrue(report['taxonomy'])
        evidence = json.loads((handle.review / 'payment-evidence.json').read_text())
        self.assertIsNone(evidence['backfill_cutoff_date'])
        self.assertEqual(evidence['bank_records'], [])
        self.assertEqual(WorkspacePaths(self.paths.workspace).resolve_active().pointer, handle.pointer)
        with self.assertRaises(ValueError):
            create_workspace(self.paths.workspace)

    def test_first_csv_then_cross_year_expands_and_keeps_wallet_date(self):
        result, status = self.import_selected(self.csv('2025-12-20'))
        self.assertEqual((status, result['phase']), (0, 'committed'))
        self.assertEqual(self.report()['coverage']['from'], '2025-12-20')
        result, status = self.import_selected(self.csv('2026-01-02', name='new-year.csv'))
        self.assertEqual(status, 0)
        self.assertEqual((self.report()['coverage']['from'], self.report()['coverage']['to']),
                         ('2025-12-20', '2026-01-02'))

    def test_first_xlsx_uses_same_initializer_schema(self):
        source = self.root / 'wallet.xlsx'
        book = openpyxl.Workbook(); sheet = book.active
        sheet.append(['交易时间','交易类型','交易对方','商品','收/支','金额(元)','支付方式','当前状态','交易单号','商户单号','备注'])
        sheet.append(['2025-12-20 10:00:00','商户消费','商户','咖啡','支出','60.00','零钱','支付成功','wx-fixture','merchant-fixture',''])
        book.save(source)
        result, status = self.import_selected(source)
        self.assertEqual((status, result['phase']), (0, 'committed'))
        self.assertEqual(self.report()['coverage']['from'], '2025-12-20')

    def test_only_refund_forms_range_without_negative_consumption(self):
        result, status = self.import_selected(self.csv('2025-12-21', refund=True))
        self.assertEqual(status, 0)
        report = self.report()
        self.assertEqual((report['coverage']['from'], report['coverage']['to']),
                         ('2025-12-21', '2025-12-21'))
        self.assertEqual(report['summary']['net_cents'], 0)
        self.assertEqual(report['summary']['unallocated_credit_cents'], 4000)

    def test_invalid_financial_input_does_not_commit(self):
        before = self.paths.read_pointer()
        source = self.root / 'bad.csv'; source.write_text('invalid document')
        result, status = self.import_selected(source)
        self.assertEqual((status, result['phase']), (1, 'failed'))
        self.assertEqual(self.paths.read_pointer(), before)
        self.assertEqual(self.report()['records'], [])

    def test_unknown_date_material_is_retained_without_inventing_range(self):
        def initializer(transaction):
            initialize_empty_state(transaction)
            (transaction.review / 'video-evidence.json').write_text(json.dumps({
                'observations': [{'cluster_id': 'undated-fixture', 'representative': {
                    'transaction_time': '', 'platform': 'unionpay', 'raw_status': '日期待确认',
                    'source_evidence': {'kind': 'undated-fixture'}}}],
                'links': [], 'materials': [], 'summary': dict.fromkeys(
                    ['raw_complete_crops', 'deduplicated_materials', 'wallet_links', 'unparsed_crops', 'undated_materials'], 0)}))
            financial(transaction.root, transaction.review)
        paths = WorkspacePaths.create(self.root / 'unknown-dates', initializer)
        report = json.loads((paths.resolve_active().review / 'financial-review.json').read_text())
        self.assertEqual(report['coverage']['mode'], 'empty')
        self.assertIsNone(report['cutoff'])
        self.assertEqual(len(report['undated_observations']), 1)
        from scripts.workspace_validation import validate_product_state
        validate_product_state(paths.resolve_active().root)


    def cli(self, script, extra):
        expected = self.root / 'expected-pointer.json'
        expected.write_text(json.dumps(self.paths.read_pointer()))
        result_file = self.root / 'processor-result.json'
        with MaintenanceGate(self.paths).acquire('cli-test') as token:
            # The packaged coordinator passes its gate as fd 0.
            result = subprocess.run([sys.executable, 'scripts/' + script,
                '--workspace', str(self.paths.workspace), '--expected-pointer-json', str(expected),
                '--operation-id', str(uuid.uuid4()), '--request-id', str(uuid.uuid4()),
                '--result-file', str(result_file), *extra], stdin=token.fd,
                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        response = json.loads(result_file.read_text())
        self.assertEqual(response['phase'], 'committed')
        self.assertEqual(response['state_id'], self.paths.read_pointer()['state_id'])
        return response

    def test_cli_import_review_evidence_and_projection_share_inherited_gate(self):
        manifest = self.root / 'files.json'
        manifest.write_text(json.dumps([str(self.csv('2025-12-20'))]))
        self.cli('import_review_materials.py', ['--files-json', str(manifest)])
        evidence = json.loads((self.paths.resolve_active().review / 'payment-evidence.json').read_text())
        review = self.root / 'review.json'
        review.write_text(json.dumps({'dataset_id': evidence['dataset_id'], 'decisions': {}}))
        self.cli('app_review.py', ['--review', str(review)])
        self.cli('probe_payment_evidence.py', [])
        self.cli('financial_review.py', [])
        handle = self.paths.resolve_active()
        evidence = json.loads((handle.review / 'payment-evidence.json').read_text())
        self.assertEqual(evidence['coverage'], self.report()['coverage'])
        self.assertEqual(evidence['backfill_cutoff_date'], self.report()['cutoff'])

    def test_create_cli_reports_committed_pointer(self):
        result = subprocess.run([sys.executable, 'scripts/workspace_cli.py', '--workspace',
            str(self.root / 'from-cli'), 'create'], capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads(result.stdout)
        self.assertEqual(receipt['command'], 'create')
        self.assertEqual(receipt['outcome'], 'success')
        self.assertTrue(receipt['verification']['state_verified'])
        self.assertEqual(receipt['state']['local_revision'], 0)
        pointer = WorkspacePaths(self.root / 'from-cli').read_pointer()
        self.assertEqual(receipt['workspace_id'], pointer['workspace_id'])
        self.assertEqual(receipt['state'], {key: pointer[key] for key in
            ('state_id', 'local_revision', 'state_manifest_hash')})
