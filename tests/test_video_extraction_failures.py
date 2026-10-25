"""Only identified video domain limitations may commit a partial operation."""
import csv
import errno
import json
import subprocess
import tempfile
import unittest
import uuid
from contextlib import ExitStack
from pathlib import Path
from unittest.mock import patch

from scripts.import_review_materials import run as import_materials
from scripts.processor_result import execute_workspace
from scripts.workspace_initialization import create_workspace
from scripts.workspace_state import MaintenanceGate


class VideoFailureBoundaryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        self.paths = create_workspace(self.root / 'workspace')
        self.before = self.paths.read_pointer()
        self.video = self.root / 'video.mov'; self.video.write_bytes(b'video-fixture')
        self.wallet = self.root / 'wallet.csv'
        with self.wallet.open('w', encoding='gb18030', newline='') as stream:
            csv.writer(stream).writerows([
                ['交易时间','交易分类','交易对方','对方账号','商品说明','收/支','金额','收/付款方式','交易状态','交易订单号','商家订单号','备注'],
                ['2025-12-20 10:00:00','餐饮美食','测试商户','','咖啡','支出','60.00','余额','交易成功','wallet-fixture','merchant-fixture','']])

    def tearDown(self):
        self.temp.cleanup()

    def execute(self, fault):
        def action(transaction, selected):
            raw_path = transaction.review / 'video-imports' / selected[1].parent.name / 'video-records.json'
            with ExitStack() as stack:
                if fault == 'missing-helper':
                    stack.enter_context(patch('scripts.import_review_materials.video_helper',
                                              side_effect=ValueError('helper unavailable')))
                elif fault in ('subprocess', 'permission'):
                    stack.enter_context(patch('scripts.import_review_materials.video_helper', return_value=self.root / 'helper'))
                    error = subprocess.CalledProcessError(1, ['helper']) if fault == 'subprocess' else PermissionError('helper permission denied')
                    stack.enter_context(patch('scripts.import_review_materials.subprocess.run', side_effect=error))
                else:
                    raw_path.parent.mkdir(parents=True)
                    if fault == 'invalid-json':
                        raw_path.write_text('{broken JSON')
                    elif fault == 'invalid-schema':
                        raw_path.write_text('{}')
                    else:
                        raw = {'source': str(selected[1]) if fault != 'disk-full' else 'old-source',
                               'rows': [{'id': 'unsupported-row', 'text': 'unknown layout'}],
                               'recall_status': 'fixture', 'errors': []}
                        if fault == 'extractor-errors':
                            raw['errors'] = ['failed to decode video frame']
                        raw_path.write_text(json.dumps(raw))
                        if fault == 'disk-full':
                            original_write = Path.write_text
                            def write(path, *args, **kwargs):
                                if path == raw_path:
                                    raise OSError(errno.ENOSPC, 'No space left on device')
                                return original_write(path, *args, **kwargs)
                            stack.enter_context(patch.object(Path, 'write_text', write))
                return import_materials(transaction.root, transaction.review, selected,
                    retained=True, input_ids=[str(self.wallet), str(self.video)])
        with MaintenanceGate(self.paths).acquire('video-fault-fixture') as token:
            return execute_workspace(self.paths.workspace, self.paths.read_pointer(),
                str(uuid.uuid4()), str(uuid.uuid4()), None, action,
                [str(self.wallet), str(self.video)], token=token)

    def assert_runtime_abort(self, fault):
        result, status = self.execute(fault)
        self.assertEqual((status, result['phase'], result['outcome']), (1, 'failed', 'failed'), result)
        self.assertEqual(result['membership'], [])
        self.assertEqual(self.paths.read_pointer(), self.before)
        state = self.paths.resolve_active()
        self.assertEqual(json.loads((state.review / 'financial-review.json').read_text())['records'], [])
        self.assertEqual(json.loads((state.root / 'operation-results.json').read_text())['results'], [])

    def test_real_unsupported_layout_can_commit_partial(self):
        result, status = self.execute('unsupported')
        self.assertEqual((status, result['phase'], result['outcome']), (0, 'committed', 'partial'), result)
        self.assertEqual(result['inputs'][0]['outcome'], 'success')
        self.assertEqual(result['inputs'][1]['reason'], 'unsupported_video_layout')
        self.assertEqual(result['inputs'][1]['completed_stages'], ['retained'])
        self.assertNotEqual(self.paths.read_pointer(), self.before)

    def test_missing_helper_aborts_whole_operation(self):
        self.assert_runtime_abort('missing-helper')

    def test_subprocess_failure_aborts_whole_operation(self):
        self.assert_runtime_abort('subprocess')

    def test_permission_failure_aborts_whole_operation(self):
        self.assert_runtime_abort('permission')

    def test_disk_full_aborts_whole_operation(self):
        self.assert_runtime_abort('disk-full')

    def test_invalid_json_aborts_whole_operation(self):
        self.assert_runtime_abort('invalid-json')

    def test_invalid_extraction_schema_aborts_whole_operation(self):
        self.assert_runtime_abort('invalid-schema')

    def test_extractor_reported_runtime_errors_abort_whole_operation(self):
        self.assert_runtime_abort('extractor-errors')
