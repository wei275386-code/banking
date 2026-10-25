"""First-run qualification; no business replay or in-place rollback.

Checks only the current workspace and pending task journals.
"""
from __future__ import annotations

import os
import subprocess
import uuid
from pathlib import Path
from scripts.tool_locations import system_search_path, tool_path

from scripts.release_contracts import canonical_json, digest_bytes, digest_file, parse_json, validate_contract, validate_relative_path
from scripts.installation_inventory import compatibility, safe_tree, InstallationError
from scripts.workspace_state import WorkspacePaths, _read, _safe, _files, _regular


ENVIRONMENT = {'PATH': system_search_path()}


def artifact_reference(bundle_root, receipt_path):
    """Bind a candidate to an external distribution receipt and committed release inputs."""
    from scripts.distribute_macos_release import tree_digest
    bundle, receipt_path = _safe(Path(bundle_root)), _regular(Path(receipt_path))
    receipt = _read(receipt_path)
    if (receipt.get('mode') not in ('candidate', 'developer-id') or not isinstance(receipt.get('source'), dict) or receipt['source'].get('dirty') is not False or (tree_digest(bundle) != receipt.get('app_sha256')) or (digest_file(bundle / 'Contents/Resources/build-provenance.json') != receipt.get('provenance_sha256'))):
        raise InstallationError('unverified external release artifact receipt')
    provenance = _read(bundle / 'Contents/Resources/build-provenance.json')
    for key in ('commit', 'dirty', 'source_input_sha256', 'source_files'):
        if provenance.get(key) != receipt['source'].get(key):
            raise InstallationError('artifact source authority differs from external receipt')
    root = Path(__file__).resolve().parents[1]
    head = subprocess.run([tool_path('git', system=True), 'rev-parse', 'HEAD'], cwd=root, check=True,
        capture_output=True, text=True, timeout=20, env=ENVIRONMENT).stdout.strip()
    if head != receipt['source']['commit']:
        raise InstallationError('artifact receipt is not the selected committed release')
    from scripts.release_contracts import validate_relative_path
    expected_names = set(_read(root / 'release/source-allowlist.json')['profiles']['production'])
    sources = receipt['source'].get('source_files')
    if not isinstance(sources, dict) or set(sources) != expected_names:
        raise InstallationError('artifact receipt lacks complete committed release source authority')
    for name, expected in sources.items():
        validate_relative_path(name)
        raw = subprocess.run([tool_path('git', system=True), 'cat-file', 'blob', head + ':' + name], cwd=root,
            check=True, capture_output=True, timeout=20, env=ENVIRONMENT).stdout
        if digest_bytes(raw) != expected:
            raise InstallationError('artifact source differs from selected committed release')
    import json
    source_hash = digest_bytes(json.dumps(sources, sort_keys=True, separators=(',', ':')).encode())
    if source_hash != receipt['source'].get('source_input_sha256'):
        raise InstallationError('artifact source closure digest differs')
    manifest_hash = digest_file(bundle / 'Contents/Resources/runtime-manifest.json')
    if provenance.get('runtime_manifest_sha256') != manifest_hash:
        raise InstallationError('artifact runtime provenance hash differs')
    return {'app_sha256': receipt['app_sha256'], 'runtime_manifest_sha256': manifest_hash,
            'provenance_sha256': receipt['provenance_sha256'], 'commit': head}


def runtime_health(bundle_root, *, artifact_reference=None, runner=subprocess.run):
    """Execute the signed candidate's actual isolated imports/functional doctor."""
    from scripts.runtime_doctor import load_manifest, bundle_path
    from scripts.distribute_macos_release import tree_digest
    bundle = _safe(Path(bundle_root))
    if not isinstance(artifact_reference, dict) or tree_digest(bundle) != artifact_reference.get('app_sha256'):
        raise InstallationError('runtime qualification requires independent artifact authority')
    # The receipt/manifest cannot authorize arbitrary unsigned executable code.
    runner([tool_path('codesign', system=True), '--verify', '--deep', '--strict', str(bundle)],
           check=True, capture_output=True, timeout=20, env=ENVIRONMENT)
    manifest = load_manifest(bundle)
    manifest_path = bundle / 'Contents/Resources/runtime-manifest.json'
    before = digest_file(manifest_path)
    if (before != artifact_reference.get('runtime_manifest_sha256')
            or digest_file(bundle / 'Contents/Resources/build-provenance.json') != artifact_reference.get('provenance_sha256')):
        raise InstallationError('runtime differs from qualified artifact reference')
    policy = compatibility(runtime_version=manifest['runtime_version'])
    if not policy['writable']:
        raise InstallationError('unsupported candidate runtime')
    command = [str(bundle_path(bundle, manifest['python']['path'])), '-I', '-B', '-S',
        str(bundle_path(bundle, manifest['bootstrap']['path'])), '--bundle-root', str(bundle),
        '--entry', 'runtime_doctor.py', '--', '--bundle-root', str(bundle)]
    result = runner(command, check=True, capture_output=True, timeout=20,
        env=ENVIRONMENT)
    if len(result.stdout) > 1024 * 1024:
        raise InstallationError('oversized runtime doctor output')
    report = parse_json(result.stdout)
    if (not isinstance(report, dict) or report.get('ok') is not True or report.get('runtime_version') != manifest['runtime_version'] or (not isinstance(report.get('checks'), list)) or (not report['checks']) or any((not isinstance(item, dict) or item.get('ok') is not True for item in report['checks'])) or (digest_file(manifest_path) != before)):
        raise InstallationError('runtime self-test qualification failed')
    return {'verified': True, 'runtime_manifest_sha256': before, 'report': report}


def _journal_operation(context):
    """Validate the internal producer context without rewriting its raw journal.

    A processing context is distinct from a public operation envelope. During
    retaining it can legitimately lack the final input hash. Journal recovery
    never gives it current-result membership or permission to replay.
    """
    if not isinstance(context, dict):
        raise InstallationError('invalid task processing context')
    fields = {'operation_id', 'request_id', 'algorithm_version', 'input_hash', 'inputs', 'stage'}
    if (set(context) != fields or context['stage'] not in ('retaining', 'processing') or any((not isinstance(context[key], str) or not context[key] for key in ('operation_id', 'request_id', 'algorithm_version'))) or (not isinstance(context['inputs'], list))):
        raise InstallationError('invalid internal task processing contract')
    identity, seen = [], set()
    for item in context['inputs']:
        if (not isinstance(item, dict) or not isinstance(item.get('input_id'), str)
                or not item['input_id'] or item['input_id'] in seen
                or item.get('kind') not in ('pdf', 'csv', 'xlsx', 'video', 'review')
                or type(item.get('required_financial')) is not bool
                or item['required_financial'] != (item['kind'] != 'video')
                or item.get('retained') is not True
                or item.get('outcome') not in ('unknown', 'success', 'pending', 'failed')
                or item.get('completed_stages') not in (['retained'], ['retained', 'projected'])):
            raise InstallationError('invalid internal task input identity')
        sha = item.get('sha256')
        if not isinstance(sha, str) or len(sha) != 64 or any(c not in '0123456789abcdef' for c in sha):
            raise InstallationError('invalid internal task input hash')
        relative = validate_relative_path(item.get('source_path'))
        prefix = ('inputs/' if item['kind'] == 'review' else 'sources/') + sha + '/'
        if not relative.startswith(prefix):
            raise InstallationError('invalid internal task retained source reference')
        seen.add(item['input_id'])
        identity.append({key: item[key] for key in ('input_id', 'sha256', 'kind', 'required_financial')})
    expected = digest_bytes(canonical_json(identity))
    if context['input_hash'] != expected and not (
            context['input_hash'] is None and context['stage'] == 'retaining'):
        raise InstallationError('internal task input identity hash mismatch')
    return context['inputs']


def _journal_health(paths, pointer, *, current_operations=()):
    current = set(current_operations)
    dispositions = {}
    if not paths.journals.exists():
        return dispositions
    for name, path in _files(paths.journals):
        if '/' in name or not name.endswith('.json'):
            raise InstallationError('unexpected task journal path')
        doc = _read(path)
        if (not isinstance(doc, dict) or doc.get('workspace_id') != pointer['workspace_id'] or doc.get('phase') not in ('processing', 'prepared', 'committed', 'failed', 'cancelled', 'needsReview', 'no-op')):
            raise InstallationError('invalid task journal recovery contract')
        try:
            uuid.UUID(doc['state_id'])
        except (ValueError, TypeError, KeyError, AttributeError) as error:
            raise InstallationError('invalid task journal state') from error
        target = doc.get('target_pointer')
        if target is not None:
            validate_contract('active-state', target)
            if target['workspace_id'] != pointer['workspace_id']:
                raise InstallationError('foreign task candidate pointer')
        expected = doc.get('expected_pointer')
        if expected is None:
            if not target or target['local_revision'] != 0 or target['state_id'] != doc['state_id']:
                raise InstallationError('task journal lacks an initial-state recovery point')
        else:
            validate_contract('active-state', expected)
            if expected['workspace_id'] != pointer['workspace_id']:
                raise InstallationError('foreign task recovery point')
        context = doc.get('operation')
        if context is not None:
            inputs = _journal_operation(context)
            # Retained request inputs must still have their exact original.
            for item in inputs:
                original = paths.sources / item['sha256']
                if not original.is_file() or digest_file(_regular(original)) != item['sha256']:
                    raise InstallationError('task journal has missing or corrupt input')
        result = doc.get('result')
        operation = doc.get('operation_id') or (context or {}).get('operation_id') or (result or {}).get('operation_id')
        if operation is None and context is None and result is None:
            operation = doc['state_id']  # Explicit non-operation state transaction.
        if not isinstance(operation, str) or not operation:
            raise InstallationError('missing task operation identity')
        if operation in current or target == pointer:
            dispositions[name] = 'included-current'
        elif doc['phase'] in ('failed', 'cancelled'):
            dispositions[name] = 'uncommitted-terminal'
        else:
            dispositions[name] = 'uncommitted-needs-review-no-replay'
    return dispositions


def health_check(workspace, *, runtime_bundle=None, effective_projection_helper=None,
                 effective_projection_pin=None, expected_pointer=None, doctor=None,
                 runtime_validator=runtime_health, artifact_reference=None):
    """Inspect the selected committed state, runtime and unfinished task journals.

    Unknown schema returns opaque read-only before calling a writer or doctor.
    Missing runtime means local-reader qualification, never processor health.
    The returned report grants neither cloud host nor processor authority.
    """
    def doctor_workspace(paths, *, expected_pointer, **unused):
        from scripts.workspace_cli import _state
        actual = _state(paths)
        if actual != {key: expected_pointer[key] for key in actual}:
            raise InstallationError("health source pointer changed")
        return {"source_pointer": expected_pointer, "operation_membership_verified": True,
                "full_backup_eligible": True}
    paths = workspace if isinstance(workspace, WorkspacePaths) else WorkspacePaths(workspace)
    metadata = _read(paths.workspace / 'workspace.json')
    try:
        validate_contract('workspace', metadata)
    except ValueError as error:
        raise InstallationError('invalid current workspace metadata') from error
    def contract_policy(document):
        result = compatibility()
        for key in ('min_writer_version',):
            if key not in document:
                continue
            next_policy = compatibility(minimum_writer=document[key])
            result = {**result, 'writable': result['writable'] and next_policy['writable'],
                      'reasons': result['reasons'] + next_policy['reasons']}
        if 'min_reader_version' in document:
            reader = compatibility(minimum_writer=document['min_reader_version'])
            if not reader['writable']:
                result = {**result, 'readable': False, 'writable': False,
                          'reasons': result['reasons'] + ['minimum-reader-newer-than-app']}
        return result
    policy = contract_policy(metadata)
    if not policy['readable']:
        return {'status': 'read-only', 'compatibility': policy,
                'processor_health_qualified': False, 'runtime_verified': False,
                'pending_gates': ['compatible-reader-required'], 'business_replayed': False}
    pointer = paths.read_pointer()
    if expected_pointer is not None and expected_pointer != pointer:
        raise InstallationError('health expected pointer changed')
    # doctor_workspace owns the single fixed gate; do not nest another lease.
    qualification = (doctor or doctor_workspace)(paths, expected_pointer=pointer,
        effective_projection_helper=effective_projection_helper,
        effective_projection_pin=effective_projection_pin)
    for name in ('review/financial-review.json', 'review/payment-evidence.json'):
        document_policy = contract_policy(_read(paths.states / pointer['state_id'] / name))
        policy = {**policy, 'writable': policy['writable'] and document_policy['writable'],
                  'readable': policy['readable'] and document_policy['readable'],
                  'reasons': policy['reasons'] + document_policy['reasons']}
    ledger = _read(paths.states / pointer['state_id'] / 'operation-results.json')
    journals = _journal_health(paths, pointer, current_operations=(entry['operation_id'] for entry in ledger['results'])
                               if qualification['operation_membership_verified'] else ())
    runtime = runtime_validator(runtime_bundle, artifact_reference=artifact_reference) if runtime_bundle is not None else {'verified': False}
    if paths.read_pointer() != pointer:
        raise InstallationError('health pointer changed during qualification')
    viewing = metadata.get('access', 'writable') == 'viewing'
    eligible = not viewing
    writable = policy['writable'] and not viewing and qualification['operation_membership_verified']
    pending = []
    if not runtime['verified']:
        pending.append('runtime-self-test-required')
    qualified = bool(writable and eligible and runtime['verified'] and qualification['full_backup_eligible'])
    return {'status': 'healthy' if qualified else ('local-reader-qualified' if writable else 'read-only'),
        'source_pointer': pointer, 'compatibility': policy, 'writable': writable,
        'runtime_verified': runtime['verified'], 'runtime': runtime,
        'task_journals': journals, 'backup_qualification': qualification,
        'processor_health_qualified': qualified,
        'pending_gates': pending, 'business_replayed': False,
        'cloud_authorization_granted': False}

