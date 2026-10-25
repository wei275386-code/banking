import csv
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

from scripts.import_review_materials import run as import_materials
from scripts.processor_result import execute_workspace
from scripts.release_contracts import canonical_json, digest_bytes, parse_json
from scripts.workspace_initialization import create_workspace
from scripts.workspace_repair import child_identity, repair_input
from scripts.workspace_state import MaintenanceGate


class PendingInputRepairTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.paths = create_workspace(self.root / 'workspace')
        self.video = self.root / 'recording.mov'; self.video.write_bytes(b'controlled-video-fixture')
        self.wallet = self.root / 'wallet.csv'
        with self.wallet.open('w', encoding='gb18030', newline='') as stream:
            csv.writer(stream).writerows([
                ['交易时间','交易分类','交易对方','对方账号','商品说明','收/支','金额','收/付款方式','交易状态','交易订单号','商家订单号','备注'],
                ['2025-12-20 10:00:00','餐饮美食','测试商户','','咖啡','支出','60.00','余额','交易成功','wallet-fixture','merchant-fixture','']])
        self.parent_request = str(uuid.uuid4())
        self.helper = self.root / 'fixture-video-helper'
        # Bank/PDF rendering is unrelated to repair; the committed bank row is
        # real SQLite and must remain one row throughout every retry.
        def bank_materials(root, output, rows):
            from scripts.payment_materials import write_asset
            source = write_asset(output, 'materials/sources/fixture/bank.pdf', b'controlled-bank-original')
            source['original_name'] = 'fixture.pdf'
            for row in rows:
                row['source_evidence'] = {'kind': 'pdf_text_unlocated', 'source': source}
            return {'bank_crops': 0, 'unlocated_bank_records': []}
        self.bank_materials = patch('scripts.probe_payment_evidence.bank_materials', side_effect=bank_materials)
        self.bank_materials.start()
        def initial(transaction, selected):
            with sqlite3.connect(transaction.root / 'banking.sqlite3') as db:
                db.execute("INSERT INTO statements(id,file_name,account_number,currency) VALUES(1,'fixture.pdf','1234','CNY')")
                db.execute("INSERT INTO transactions(statement_id,post_date_raw,post_date,trans_date_raw,trans_date,description,amount_cents,is_credit,currency,raw_line) VALUES(1,'20DEC','2025-12-20','20DEC','2025-12-20','Bank fixture',100,0,'CNY','fixture')")
            return import_materials(transaction.root, transaction.review, selected,
                                    retained=True, input_ids=[str(self.wallet), str(self.video)])
        self.helper_script(known=False)
        with MaintenanceGate(self.paths).acquire('fixture-import') as token, patch.dict(
                os.environ, {'BANKING_VIDEO_HELPER': str(self.helper)}):
            self.parent, status = execute_workspace(self.paths.workspace, self.paths.read_pointer(),
                str(uuid.uuid4()), self.parent_request, None, initial,
                [str(self.wallet), str(self.video)], token=token)
        self.assertEqual((status, self.parent['outcome']), (0, 'partial'), self.parent)
        self.original_pointer = self.paths.read_pointer()
        self.video.unlink()  # repairs can never reopen this original selection

    def tearDown(self):
        self.bank_materials.stop()
        self.temp.cleanup()

    def helper_script(self, *, known):
        rows = [{'id': 'unsupported-fixture', 'text': 'unrecognized layout'}]
        if known:
            rows = [{'id': 'row-fixture', 'text': '测试咖啡商户\n-¥60.00\n银行[9999]\n10:00',
                     'image': 'crop.png', 'crop': [0, 0, 100, 200],
                     'requested_second': 1, 'actual_second': 1,
                     'completeness': {}, 'date_context': '12.20', 'year_context': '2025'}]
        self.helper.write_text('#!' + sys.executable + '\n' +
            'import hashlib,json,sys\nfrom pathlib import Path\n'
            'folder=Path(sys.argv[2]);folder.mkdir(parents=True,exist_ok=True)\n'
            'crop=b"controlled-crop-fixture";(folder/"crop.png").write_bytes(crop)\n'
            'rows=' + repr(rows) + '\n'
            'for row in rows: row["image_sha256"]=hashlib.sha256(crop).hexdigest()\n'
            '(folder/"video-records.json").write_text(json.dumps({"source":sys.argv[1],"rows":rows,"recall_status":"fixture"},ensure_ascii=False))\n')
        self.helper.chmod(0o700)

    def repair(self, *, expected=None):
        with MaintenanceGate(self.paths).acquire('fixture-repair') as token, patch.dict(
                os.environ, {'BANKING_VIDEO_HELPER': str(self.helper)}), patch(
                'scripts.workspace_state.WorkspacePaths.retain_source', side_effect=AssertionError('repair must reuse retained source')):
            return repair_input(self.paths.workspace, expected or self.paths.read_pointer(),
                self.parent_request, str(self.video), token=token)

    def ledger(self):
        return parse_json((self.paths.resolve_active().root / 'operation-results.json').read_bytes())

    def bank_count(self):
        with sqlite3.connect(self.paths.resolve_active().database) as db:
            return db.execute('SELECT count(*) FROM transactions').fetchone()[0]

    def test_unknown_retry_keeps_pending_and_can_later_finish_same_child(self):
        self.helper_script(known=False)
        failed, status = self.repair()
        self.assertEqual((status, failed['phase']), (1, 'failed'))
        self.assertEqual(self.paths.read_pointer(), self.original_pointer)
        self.assertEqual(self.ledger()['results'], [self.parent])
        self.assertEqual(failed['membership'], [])
        self.assertEqual(self.bank_count(), 1)
        failed_again, status = self.repair()
        self.assertEqual(failed_again['request_id'], failed['request_id'])
        self.assertEqual(self.paths.read_pointer(), self.original_pointer)
        self.helper_script(known=True)
        successful, status = self.repair()
        self.assertEqual((status, successful['phase']), (0, 'committed'))
        self.assertEqual(successful['request_id'], failed['request_id'])
        self.assertEqual(self.bank_count(), 1)

    def test_success_preserves_partial_history_and_claims_only_missing_stage(self):
        self.helper_script(known=True)
        result, status = self.repair()
        self.assertEqual(status, 0, result)
        self.assertEqual(result['parent_request_id'], self.parent_request)
        self.assertEqual(result['inputs'][0]['completed_stages'], ['retained', 'projected'])
        self.assertTrue(result['inputs'][0]['retained'])
        stages = [effect for effect in result['membership'] if effect['kind'] == 'input-stage']
        self.assertEqual(len(stages), 1)
        expected_key = 'input-stage:' + digest_bytes(canonical_json(
            [self.parent_request, str(self.video), 'projected']))
        self.assertEqual(stages[0]['key'], expected_key)
        self.assertTrue(any(effect.get('supersedes') for effect in result['membership']))
        self.assertEqual(self.ledger()['results'][0], self.parent)
        self.assertEqual(self.bank_count(), 1)
        report = json.loads((self.paths.resolve_active().review / 'financial-review.json').read_text())
        self.assertEqual(len(report['video_materials']), 1)
        self.assertEqual(report['coverage']['from'], '2025-12-20')

    def test_successful_child_retry_is_noop_even_after_helper_becomes_unavailable(self):
        self.helper_script(known=True)
        result, status = self.repair()
        committed = self.paths.read_pointer()
        self.helper.unlink()
        retry, status = self.repair(expected=self.original_pointer)
        self.assertEqual(status, 0, retry)
        self.assertEqual(retry, result)
        self.assertEqual(self.paths.read_pointer(), committed)
        self.assertEqual(len(self.ledger()['results']), 2)
        self.assertEqual(self.bank_count(), 1)

    def test_child_identity_is_stable_and_delimiter_safe(self):
        identity = child_identity(self.paths.workspace_id, self.parent_request, str(self.video))
        self.assertEqual(identity, child_identity(self.paths.workspace_id, self.parent_request, str(self.video)))
        self.assertNotEqual(identity[0], identity[1])
        self.assertNotEqual(child_identity(self.paths.workspace_id, 'a:b', 'c'),
                            child_identity(self.paths.workspace_id, 'a', 'b:c'))

    def test_cli_repairs_with_inherited_fd_zero(self):
        self.helper_script(known=True)
        paths = create_workspace(self.root / 'cli-workspace')
        video = self.root / 'cli-video.mov'; video.write_bytes(b'cli-video-fixture')
        parent_request = str(uuid.uuid4())
        self.helper_script(known=False)
        with MaintenanceGate(paths).acquire('cli-fixture-import') as token, patch.dict(
                os.environ, {'BANKING_VIDEO_HELPER': str(self.helper)}):
            parent, status = execute_workspace(paths.workspace, paths.read_pointer(),
                str(uuid.uuid4()), parent_request, None,
                lambda transaction, selected: import_materials(transaction.root, transaction.review,
                    selected, retained=True, input_ids=[str(video)]), [str(video)], token=token)
        self.assertEqual((status, parent['outcome']), (0, 'partial'), parent)
        video.unlink()
        self.helper_script(known=True)
        expected = self.root / 'expected.json'; expected.write_text(json.dumps(paths.read_pointer()))
        result_file = self.root / 'result.json'
        with MaintenanceGate(paths).acquire('cli-repair') as token:
            completed = subprocess.run([sys.executable, 'scripts/workspace_cli.py',
                '--workspace', str(paths.workspace), '--inherited-fd', '0', 'repair-input',
                '--parent-request-id', parent_request, '--input-id', str(video),
                '--expected-pointer-json', str(expected), '--result-file', str(result_file)],
                stdin=token.fd, capture_output=True, text=True, timeout=10,
                env={**os.environ, 'BANKING_VIDEO_HELPER': str(self.helper)})
        self.assertEqual(completed.returncode, 0, completed.stderr + completed.stdout)
        result = json.loads(result_file.read_text())
        self.assertEqual((result['phase'], result['parent_request_id']), ('committed', parent_request))
        self.assertEqual(result['state_id'], paths.read_pointer()['state_id'])
