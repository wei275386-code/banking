"""Finish one saved pending recording without replaying its original import."""
from __future__ import annotations

import json
import uuid
from pathlib import Path

from scripts.import_review_materials import project_video
from scripts.financial_review import run as build_review
from scripts.probe_payment_evidence import run as build_evidence
from scripts.processor_result import InputProcessingError, execute_workspace
from scripts.release_contracts import canonical_json, digest_bytes, parse_json, validate_relative_path
from scripts.workspace_state import MaintenanceGate, StateConflict, WorkspacePaths

ALGORITHM_VERSION = 'pending-video-projection-v1'


def child_identity(workspace_id, parent_request_id, input_id):
    """Canonical tuple encoding prevents ambiguous delimiter-based identities."""
    key = digest_bytes(canonical_json([workspace_id, parent_request_id, input_id, 'projected']))
    namespace = uuid.UUID(workspace_id)
    return (str(uuid.uuid5(namespace, 'request:' + key)),
            str(uuid.uuid5(namespace, 'operation:' + key)))


def repair_input(workspace, expected_pointer, parent_request_id, input_id, *,
                 result_file=None, token=None, inherited_fd=0, cancelled=None,
                 timeout_seconds=None, failure_hook=None):
    paths = WorkspacePaths(workspace)
    owner = token is None
    gate = token or MaintenanceGate(paths).adopt_inherited(inherited_fd)
    try:
        gate.validate(paths)
        handle = paths.resolve_active()
        ledger = parse_json((handle.root / 'operation-results.json').read_bytes())
        parents = [result for result in ledger['results'] if result['request_id'] == parent_request_id]
        if len(parents) != 1 or parents[0]['outcome'] != 'partial':
            raise StateConflict('当前资料缺少唯一的已保存 partial 请求')
        inputs = [item for item in parents[0]['inputs'] if item['input_id'] == input_id]
        if len(inputs) != 1 or inputs[0]['kind'] != 'video' or inputs[0]['outcome'] != 'pending' or not inputs[0]['retained']:
            raise StateConflict('仅可修复原请求中已保留的待处理录屏')
        selected = inputs[0]
        relative = validate_relative_path(selected.get('source_path', ''))
        if not relative.startswith('sources/' + selected['sha256'] + '/'):
            raise StateConflict('待处理原件路径与 hash 不一致')
        request_id, operation_id = child_identity(handle.workspace_id, parent_request_id, input_id)

        def action(transaction, retained):
            try:
                project_video(transaction.root, transaction.review, retained[0],
                              checksum=selected['sha256'], retry=True)
            except Exception as error:
                raise InputProcessingError(input_id, str(error)) from error
            # Only this video's missing stage is repeated. No bank insertion or
            # export import occurs; the entire derived state is rebuilt next.
            evidence = build_evidence(transaction.root, transaction.review)
            financial = build_review(transaction.root, transaction.review)
            inventory = transaction.review / 'import-inventory.json'
            if inventory.exists():
                rows = json.loads(inventory.read_text())
                for row in rows:
                    if row['sha256'] == selected['sha256']:
                        row['status'] = '已提取完整素材，异常见资料页'
                inventory.write_text(json.dumps(rows, ensure_ascii=False, indent=2) + '\n')
            return {'parent_request_id': parent_request_id, 'input_id': input_id,
                    'completed_stage': 'projected', 'lifecycles': len(financial['records']),
                    'cutoff': financial['cutoff'], 'review': evidence['review'],
                    'pending_video_sources': []}

        return execute_workspace(workspace, expected_pointer, operation_id, request_id,
            result_file, action, [{'path': str(handle.path(relative)), 'input_id': input_id,
                'sha256': selected['sha256'], 'kind': 'video', 'retained_source_path': relative}],
            token=gate, cancelled=cancelled, timeout_seconds=timeout_seconds,
            failure_hook=failure_hook, algorithm_version=ALGORITHM_VERSION,
            stage_parent_request=parent_request_id)
    finally:
        if owner:
            gate.close()
