"""Workspace processor results, committed through the active state ledger."""
import json
import os
from pathlib import Path
import time
import shutil


class InputProcessingError(ValueError):
    def __init__(self, input_id, message):
        super().__init__(message)
        self.input_id = str(input_id)


class ProcessorCancelled(RuntimeError):
    pass


def add_workspace_arguments(parser):
    """Packaged callers use workspace identity, never arbitrary active paths."""
    parser.add_argument('--workspace', type=Path)
    parser.add_argument('--expected-pointer-json', type=Path)
    parser.add_argument('--request-id')
    parser.add_argument('--gate-fd', type=int, default=0)
    parser.add_argument('--cancel-file', type=Path)
    parser.add_argument('--timeout-seconds', type=float)


def _write_result(target, result):
    if target is None:
        return
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_name(target.name + '.writing')
    with temporary.open('w') as stream:
        json.dump(result, stream, ensure_ascii=False)
        stream.write('\n')
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, target)


def execute_workspace(workspace, expected_pointer, operation_id, request_id,
                      result_file, action, inputs, *, token=None, inherited_fd=0,
                      cancelled=None, timeout_seconds=None, failure_hook=None,
                      algorithm_version='review-state', stage_parent_request=None):
    """Retain stable input snapshots and commit their effects exactly once.

    `action(transaction, retained_paths)` may mutate only staging. FD 0 is the
    coordinator's inherited maintenance lock; an in-process caller passes its
    WriteToken instead. The active ledger is authoritative even if external
    result publication or the post-commit journal update fails.
    """
    try:
        from .workspace_state import WorkspacePaths, MaintenanceGate, StateTransaction, StateConflict
        from .release_contracts import canonical_json, digest_bytes, digest_file, parse_json, business_result_digest
    except ImportError:
        from workspace_state import WorkspacePaths, MaintenanceGate, StateTransaction, StateConflict
        from release_contracts import canonical_json, digest_bytes, digest_file, parse_json, business_result_digest
    paths = WorkspacePaths(workspace)
    if not operation_id or not request_id:
        raise ValueError('workspace processing requires operation_id and request_id')
    if isinstance(expected_pointer, (str, Path)):
        expected_pointer = parse_json(Path(expected_pointer).read_bytes())
    if expected_pointer is None:
        raise ValueError('workspace processing requires an expected active pointer')
    started = time.monotonic()
    def check_cancel():
        if cancelled and cancelled():
            raise ProcessorCancelled('提交前已取消处理')
        if timeout_seconds is not None and time.monotonic() - started >= timeout_seconds:
            raise ProcessorCancelled('处理超时，未提交业务变化')
    owner = token is None
    gate = token or MaintenanceGate(paths).adopt_inherited(inherited_fd)
    transaction = None
    entries, retained_paths = [], []
    input_hash = digest_bytes(canonical_json([]))
    result = None
    included_result = None
    try:
        gate.validate(paths)
        check_cancel()
        # Enter the transaction before the action or any business file writes.
        # Source objects are durable originals, not active ledger membership.
        context = {'operation_id': operation_id, 'request_id': request_id,
                   'algorithm_version': algorithm_version, 'input_hash': None, 'inputs': [], 'stage': 'retaining'}
        transaction = StateTransaction.begin(paths, gate, failure_hook=failure_hook,
                                             operation_context=context)
        for selected in inputs:
            item = selected if isinstance(selected, dict) else {'path': str(selected)}
            source = Path(item['path'])
            input_id = str(item.get('input_id', source))
            extension = source.suffix.lower()
            kind = item.get('kind') or {'.pdf': 'pdf', '.csv': 'csv', '.xlsx': 'xlsx',
                '.mov': 'video', '.mp4': 'video', '.m4v': 'video', '.json': 'review'}.get(extension)
            if kind not in {'pdf', 'csv', 'xlsx', 'video', 'review'}:
                raise InputProcessingError(input_id, '不支持的素材类型：' + source.name)
            try:
                if item.get('retained_source_path'):
                    from scripts.release_contracts import validate_relative_path
                    relative = validate_relative_path(item['retained_source_path'])
                    if not relative.startswith('sources/') or kind != 'video':
                        raise StateConflict('重试输入必须来自已保存录屏')
                    source = transaction.parent.root / relative
                    manifest = parse_json((transaction.parent.root / 'state-manifest.json').read_bytes())
                    source_hash = manifest['files'].get(relative)
                    if source_hash is None or source_hash != item.get('sha256'):
                        raise StateConflict('已保存录屏不属于当前 active manifest')
                    # begin verified this pinned parent under the maintenance
                    # gate; attach_source verifies its content-addressed object.
                else:
                    source_hash = paths.retain_source(source, gate, expected_hash=item.get('sha256'))
                if kind == 'review':
                    destination = transaction.path('inputs/' + source_hash + '/' + source.name)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    if destination.exists():
                        if digest_file(destination) != source_hash:
                            raise StateConflict('已保留复核输入发生冲突')
                    else:
                        with (paths.sources / source_hash).open('rb') as src, destination.open('xb') as dst:
                            shutil.copyfileobj(src, dst, 1024 * 1024)
                else:
                    destination = transaction.attach_source(source_hash, 'sources/' + source_hash + '/' + source.name)
            except Exception as exc:
                raise InputProcessingError(input_id, str(exc)) from exc
            entries.append({'input_id': input_id, 'sha256': source_hash, 'kind': kind,
                'source_path': destination.relative_to(transaction.root).as_posix(),
                'required_financial': kind != 'video', 'retained': True,
                'outcome': 'unknown', 'completed_stages': ['retained']})
            retained_paths.append(destination)
            context['inputs'] = entries
            transaction.record_processing(context)
            check_cancel()
        identity = [{key: item[key] for key in ('input_id', 'sha256', 'kind', 'required_financial')}
                    for item in entries]
        input_hash = digest_bytes(canonical_json(identity))
        context.update(input_hash=input_hash, stage='processing')
        transaction.record_processing(context)
        ledger = parse_json((transaction.parent.root / 'operation-results.json').read_bytes())
        included = [entry for entry in ledger['results'] if
                    entry['request_id'] == request_id or entry['operation_id'] == operation_id]
        if included:
            if len(included) != 1 or any(included[0].get(key) != value for key, value in
                    {'request_id': request_id, 'operation_id': operation_id, 'input_hash': input_hash,
                     'algorithm_version': algorithm_version}.items()):
                raise StateConflict('已提交请求的身份或输入发生变化')
            result = included[0]
            included_result = result
            transaction.abort(phase='no-op')
            _write_result(result_file, result)
            return result, 0
        if transaction.expected != expected_pointer:
            raise StateConflict('开始处理前 active state 已改变')
        if stage_parent_request:
            parents = [entry for entry in ledger['results'] if entry['request_id'] == stage_parent_request]
            if len(parents) != 1 or parents[0]['outcome'] != 'partial' or len(entries) != 1:
                raise StateConflict('待处理修复缺少唯一已保存 partial 来源')
            parent_inputs = [item for item in parents[0]['inputs'] if item['input_id'] == entries[0]['input_id']]
            if len(parent_inputs) != 1 or parent_inputs[0]['outcome'] != 'pending' or any(
                    parent_inputs[0][key] != entries[0][key] for key in ('sha256', 'kind', 'required_financial')):
                raise StateConflict('待处理修复的原件身份与已保存输入不一致')
        details = action(transaction, retained_paths)
        check_cancel()
        pending_sources = details.get('pending_video_sources', [])
        failures = {str(item['input_id']): item.get('reason_code') or item['reason']
                    for item in pending_sources}
        if stage_parent_request and failures:
            raise InputProcessingError(entries[0]['input_id'], '录屏仍需人工确认，已保存的待处理状态保持不变')
        # A partial commit is permitted only for an explicitly pending video.
        if any(item['input_id'] in failures and item['kind'] != 'video' for item in entries):
            raise ValueError('必需财务输入失败，不能提交 partial')
        for item in entries:
            pending = failures.get(item['input_id'])
            item.update(outcome='pending' if pending else 'success',
                        completed_stages=['retained'] if pending else ['retained', 'projected'])
            if pending:
                item['reason'] = pending
                item['reason_message'] = next(source['reason'] for source in pending_sources
                                              if str(source['input_id']) == item['input_id'])
        membership = []
        for item in entries:
            for stage in item['completed_stages']:
                if stage_parent_request and stage == 'retained':
                    continue
                effect = {'input_id': item['input_id'], 'sha256': item['sha256'], 'stage': stage}
                membership.append({'key': 'input-stage:' + digest_bytes(canonical_json(
                    [stage_parent_request or request_id, item['input_id'], stage])),
                    'kind': 'input-stage', 'digest': digest_bytes(canonical_json(effect))})
        from scripts.workspace_effects import derive_membership
        membership.extend(derive_membership(transaction, request_id, ledger))
        result = {'workspace_id': paths.workspace_id, 'operation_id': operation_id,
            'request_id': request_id, 'input_hash': input_hash, 'algorithm_version': algorithm_version, 'phase': 'processing',
            'outcome': 'partial' if failures else 'success', 'inputs': entries,
            'state_id': None, 'result_digest': None, 'result_generation': None,
            'membership': membership, 'details': details,
            'message': '已保存，部分录屏提取待处理。' if failures else '已保存。'}
        if stage_parent_request:
            result['parent_request_id'] = stage_parent_request
        from scripts.workspace_validation import validate_transaction
        transaction.prepare(result, validator=validate_transaction)
        check_cancel()
        transaction.commit()
        result = transaction.result
        _write_result(result_file, result)
        return result, 0
    except BaseException as exc:
        # Pointer membership wins after the commit point, including fsync or
        # external result-file failures. Do not label committed effects failed.
        if included_result is not None or (transaction is not None and transaction.committed):
            result = included_result or transaction.result
            try:
                _write_result(result_file, result)
            except Exception:
                pass
            return result, 0
        is_cancelled = isinstance(exc, (ProcessorCancelled, KeyboardInterrupt))
        result = {'workspace_id': paths.workspace_id,
            'operation_id': operation_id, 'request_id': request_id, 'input_hash': input_hash,
            'algorithm_version': algorithm_version,
            'phase': 'cancelled' if is_cancelled else 'failed',
            'outcome': 'cancelled' if is_cancelled else 'failed', 'inputs': entries,
            'state_id': None, 'result_digest': None, 'result_generation': None,
            'membership': [], 'error_code': 'cancelled_before_commit' if is_cancelled else 'processing_failed',
            'message': str(exc)}
        result['result_digest'] = business_result_digest(result)
        if transaction is not None:
            transaction.abort(phase=result['phase'])
        _write_result(result_file, result)
        return result, 1
    finally:
        if owner:
            gate.close()
