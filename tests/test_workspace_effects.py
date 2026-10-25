"""Real entity and stage proofs; forged receipts do not establish membership."""
import copy
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

from scripts.release_contracts import canonical_json, digest_bytes
from scripts.workspace_effects import current_entities, verify_current_membership
from scripts.workspace_state import WorkspaceError


class WorkspaceEffectTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        (self.root / 'review').mkdir()
        (self.root / 'review/financial-review.json').write_text('{"records":[]}')
        self.entity = 'document:review/financial-review.json'
        self.digest = current_entities(self.root)[self.entity]

    def tearDown(self):
        self.temp.cleanup()

    def result(self, request='first', supersedes=None):
        effect = {'key': request + '-effect', 'entity_key': self.entity, 'kind': 'revision', 'digest': self.digest}
        if supersedes is not None:
            effect['supersedes'] = supersedes
        return {'request_id': request, 'operation_id': 'operation-' + request,
                'workspace_id': '55555555-5555-4555-8555-555555555555',
                'input_hash': digest_bytes(canonical_json([])), 'inputs': [], 'outcome': 'success',
                'membership': [effect]}

    def verify(self, *results):
        return verify_current_membership(self.root, {'results': list(results)})

    def test_real_document_and_earlier_same_entity_supersession(self):
        first = self.result()
        second = self.result('second', [first['membership'][0]['key']])
        self.assertTrue(self.verify(first, second))
        (self.root / 'review/financial-review.json').write_text('{"records":[],"changed":true}')
        with self.assertRaises(WorkspaceError):
            self.verify(first, second)

    def test_duplicate_future_self_and_unfenced_heads_are_rejected(self):
        first = self.result()
        for second in [self.result('second'), self.result('second', ['second-effect']),
                       self.result('second', ['missing']), first]:
            with self.subTest(second=second):
                with self.assertRaises(WorkspaceError):
                    self.verify(first, second)

    def test_forged_tombstone_cannot_prove_nonexistent_business_effect(self):
        result = self.result()
        effect = result['membership'][0]
        effect.update(kind='tombstone', entity_key='record:never-existed',
                      digest=digest_bytes(canonical_json({'entity': 'record:never-existed', 'deleted': True})))
        with self.assertRaises(WorkspaceError):
            self.verify(result)

    def test_superseded_history_still_requires_valid_tombstone_proof(self):
        first = self.result()
        deleted = self.result('deleted', ['first-effect'])
        deleted['membership'][0].update(kind='tombstone', digest='0' * 64)
        restored = self.result('restored', ['deleted-effect'])
        with self.assertRaisesRegex(WorkspaceError, 'tombstone'):
            self.verify(first, deleted, restored)

    def test_stage_receipt_matches_actual_retained_bytes_and_path(self):
        content = b'synthetic movie'
        sha = digest_bytes(content)
        relative = 'sources/' + sha + '/sample.mov'
        file = self.root / relative
        file.parent.mkdir(parents=True)
        file.write_bytes(content)
        entry = {'input_id': 'movie', 'sha256': sha, 'kind': 'video', 'required_financial': False,
                 'source_path': relative, 'outcome': 'pending', 'completed_stages': ['retained']}
        result = self.result()
        result.update(inputs=[entry], outcome='partial', input_hash=digest_bytes(canonical_json(
            [{key: entry[key] for key in ('input_id', 'sha256', 'kind', 'required_financial')}])))
        stage = {'key': 'input-stage:' + digest_bytes(canonical_json(['first', 'movie', 'retained'])),
                 'kind': 'input-stage', 'digest': digest_bytes(canonical_json({'input_id': 'movie', 'sha256': sha, 'stage': 'retained'}))}
        result['membership'].append(stage)
        self.assertTrue(self.verify(result))
        for mutate in [lambda r: r['membership'][-1].update(digest='0' * 64),
                       lambda r: r['inputs'][0].update(source_path='review/financial-review.json'),
                       lambda r: r['inputs'][0].update(completed_stages=['retained', 'projected']),
                       lambda r: r.update(parent_request_id='missing')]:
            bad = copy.deepcopy(result)
            mutate(bad)
            with self.assertRaises(WorkspaceError):
                self.verify(bad)

    def test_sqlite_generated_columns_and_nul_are_preserved_and_nullable_pk_rejected(self):
        file = self.root / 'samples.sqlite3'
        with sqlite3.connect(file) as db:
            db.executescript("CREATE TABLE sample(id TEXT PRIMARY KEY,value TEXT,derived TEXT GENERATED ALWAYS AS (value || ' generated') STORED); INSERT INTO sample(id,value) VALUES('one','before'||char(0)||'after');")
        initial = current_entities(self.root)
        with sqlite3.connect(file) as db:
            db.execute("UPDATE sample SET value='before'||char(0)||'changed'")
        self.assertNotEqual(initial, current_entities(self.root))
        with sqlite3.connect(file) as db:
            db.executescript("INSERT INTO sample(id,value) VALUES(NULL,'first'); INSERT INTO sample(id,value) VALUES(NULL,'second');")
        with self.assertRaisesRegex(WorkspaceError, 'duplicate SQLite primary-key identity'):
            current_entities(self.root)
