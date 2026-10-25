"""Settings-only family snapshot equality; never host/reader activation authority.

The caller must independently verify checkpoint ancestry, replay origin closure,
ordinary business membership, assets and its context authority before activation.
This module only returns immutable settings. Only the current snapshot shape is accepted.
"""
from __future__ import annotations

from dataclasses import dataclass
import re

if __package__:
    from .household_settings import HouseholdSettings, SettingsContext, decode_settings
    from .release_contracts import ContractError, canonical_json, digest_bytes, normalized_uuid, parse_json, validate_contract, validate_relative_path
else:
    from household_settings import HouseholdSettings, SettingsContext, decode_settings
    from release_contracts import ContractError, canonical_json, digest_bytes, normalized_uuid, parse_json, validate_contract, validate_relative_path


SETTINGS_PATHS = (
    ('config/family-profile.json', 'family-profile.json', 'settings/family-profile'),
    ('config/account-policies.json', 'account-policies.json', 'settings/account-policies'),
)
_LIMIT = 16 * 1024 * 1024
_HASH = re.compile(r'[a-f0-9]{64}\Z')
_PROOF_KEYS = {'purpose', 'workspace_id', 'binding_id', 'host_id',
               'state_id', 'local_revision', 'state_manifest_hash', 'request_results', 'asset_manifest',
               'documents', 'databases', 'settings_documents'}


@dataclass(frozen=True)
class SettingsSnapshotPins:
    workspace_id: str
    binding_id: str
    host_id: str
    generation: str


def _canonical(raw):
    if not isinstance(raw, bytes) or len(raw) > _LIMIT:
        raise ContractError('snapshot requires bounded raw bytes')
    try:
        value = parse_json(raw)
        pending = [(value, 0)]
        while pending:
            child, depth = pending.pop()
            if depth > 128:
                raise ContractError('snapshot JSON depth limit')
            children = child.values() if isinstance(child, dict) else child if isinstance(child, list) else ()
            pending.extend((item, depth + 1) for item in children)
        if canonical_json(value) != raw:
            raise ContractError('snapshot JSON is not canonical')
        return value
    except RecursionError:
        raise ContractError('snapshot JSON depth limit') from None


def _object(raw):
    value = _canonical(raw)
    if not isinstance(value, dict):
        raise ContractError('snapshot object required')
    return value


def _hash(value):
    if not isinstance(value, str) or not _HASH.fullmatch(value):
        raise ContractError('invalid snapshot hash')
    return value


def settings_field_values(settings: HouseholdSettings) -> dict[str, str]:
    return {SETTINGS_PATHS[0][2]: settings.profile_bytes.decode('utf-8'),
            SETTINGS_PATHS[1][2]: settings.policies_bytes.decode('utf-8')}


def settings_document_rows(settings: HouseholdSettings) -> list[dict[str, str]]:
    values = settings_field_values(settings)
    return [dict(state_path=state, snapshot_path=snapshot, field_key=field,
                 sha256=digest_bytes(values[field].encode('utf-8'))) for state, snapshot, field in SETTINGS_PATHS]


def validate_settings_snapshot(*, pins: SettingsSnapshotPins, checkpoint_raw: bytes,
                               state_manifest_raw: bytes, business_proof_raw: bytes, field_state_raw: bytes,
                               snapshot_documents: dict[str, bytes], replayed_values: dict[str, str],
                               replayed_conflict_keys: set[str], context: SettingsContext) -> HouseholdSettings:
    """Check the host baseline. Offline edits need a separate projection check.

    ``replayed_values/conflict_keys`` must come from independently verified replay,
    not by copying the untrusted field-state. No local capability is issued here.
    """
    for identity in (pins.workspace_id, pins.binding_id, pins.host_id):
        normalized_uuid(identity)
    _hash(pins.generation)
    checkpoint, state, proof, fields = map(_object, (checkpoint_raw, state_manifest_raw, business_proof_raw, field_state_raw))
    validate_contract('family-snapshot', checkpoint)
    validate_contract('state-manifest', state)
    validate_contract('field-state', fields)
    # JSON Schema's pattern uses search semantics: Python's '$' also matches
    # before a final LF. Hash pins must instead be exactly 64 lowercase hex bytes,
    # including map entries not otherwise compared to locally computed digests.
    for document, keys in ((checkpoint, ('covered_revision_inventory', 'request_results', 'asset_manifest')),
                           (checkpoint['state'], ('state_manifest_hash',)),
                           (fields, ('covered_revision_inventory',))):
        for key in keys:
            _hash(document[key])
    for mapping in (checkpoint['files'], state['files']):
        for hash_value in mapping.values():
            _hash(hash_value)
    if checkpoint['parent_generation'] is not None:
        _hash(checkpoint['parent_generation'])
    if state.get('parent_pointer') is not None:
        _hash(state['parent_pointer']['state_manifest_hash'])
    for path in checkpoint['files']:
        validate_relative_path(path)
    integers = [checkpoint['sequence'], state['local_revision'], checkpoint['state']['local_revision'], *fields['observed'].values()]
    if any(value > 2**63 - 1 for value in integers):
        raise ContractError('snapshot integer range')
    for mapping in [checkpoint['files'], state['files'], fields['values'], fields['observed'], fields['conflicts']]:
        if len(mapping) > 100000:
            raise ContractError('snapshot map budget')
    if any(len(values) > 100000 for values in [checkpoint['included_requests'], checkpoint['revision_frontier'], fields['frontier'], *fields['conflicts'].values()]):
        raise ContractError('snapshot list budget')
    if digest_bytes(checkpoint_raw) != pins.generation:
        raise ContractError('checkpoint generation differs from local pin')
    for key in ('workspace_id', 'binding_id', 'host_id'):
        if checkpoint[key] != getattr(pins, key) or proof.get(key) != getattr(pins, key):
            raise ContractError('settings proof selection mismatch')
    if set(proof) != _PROOF_KEYS or proof['purpose'] != 'client-reader':
        raise ContractError('settings reader proof version or shape')
    for key in ('state_manifest_hash', 'request_results', 'asset_manifest'):
        _hash(proof[key])
    if any(not isinstance(proof[key], list) or len(proof[key]) > maximum for key, maximum in
           (('documents', 100000), ('databases', 256), ('settings_documents', 2))):
        raise ContractError('settings reader proof collections')
    for key in ('min_reader_version', 'min_writer_version'):
        if not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', checkpoint[key]):
            raise ContractError('invalid family minimum version grammar')
        version = tuple(map(int, checkpoint[key].split('.')))
        if any(value > 2**63 - 1 for value in version) or version < (1, 3, 0):
            raise ContractError('family minimum version')
    current = checkpoint['state']
    for key in ('state_id', 'local_revision'):
        if state[key] != current[key] or proof[key] != current[key] or type(proof[key]) is not type(current[key]):
            raise ContractError('settings proof state mismatch')
    if state['workspace_id'] != pins.workspace_id or digest_bytes(state_manifest_raw) != current['state_manifest_hash'] or \
       proof['state_manifest_hash'] != current['state_manifest_hash']:
        raise ContractError('settings state manifest mismatch')
    for path, raw in (('state-manifest.json', state_manifest_raw), ('business-proof.json', business_proof_raw), ('field-state.json', field_state_raw)):
        if checkpoint['files'].get(path) != digest_bytes(raw):
            raise ContractError('settings metadata raw hash mismatch')
    for key, path in (('request_results', 'request-results.json'), ('asset_manifest', 'asset-manifest.json')):
        if proof[key] != checkpoint[key] or checkpoint['files'].get(path) != checkpoint[key]:
            raise ContractError('settings proof ledger or asset pin mismatch')
    if state['files']['operation-results.json'] != checkpoint['request_results'] or \
       fields['covered_revision_inventory'] != checkpoint['covered_revision_inventory'] or \
       fields['frontier'] != checkpoint['revision_frontier']:
        raise ContractError('settings proof state/causal pins mismatch')
    if not isinstance(snapshot_documents, dict) or set(snapshot_documents) != {row[1] for row in SETTINGS_PATHS}:
        raise ContractError('exact settings snapshot files required')
    if not isinstance(replayed_values, dict) or not isinstance(replayed_conflict_keys, (set, frozenset)):
        raise ContractError('independent replay inputs required')
    for state_path, snapshot, field in SETTINGS_PATHS:
        raw = snapshot_documents[snapshot]
        _object(raw)
        value = replayed_values.get(field)
        if field in replayed_conflict_keys or field in fields['conflicts'] or not isinstance(value, str) or \
           fields['values'].get(field) != value or value.encode('utf-8') != raw:
            raise ContractError('missing/conflicting/unequal settings field')
        hash_value = digest_bytes(raw)
        if state['files'].get(state_path) != hash_value or checkpoint['files'].get(snapshot) != hash_value:
            raise ContractError('settings four-way equality mismatch')
    settings = decode_settings(snapshot_documents['family-profile.json'], snapshot_documents['account-policies.json'], context=context)
    expected_rows = settings_document_rows(settings)
    # Row order is irrelevant, but duplicates, missing/unknown keys and mappings fail.
    rows = proof['settings_documents']
    if len(rows) != 2 or any(not isinstance(row, dict) or row not in expected_rows for row in rows) or rows[0] == rows[1]:
        raise ContractError('settings document mapping mismatch')
    seen = set()
    for row in proof['documents']:
        if not isinstance(row, dict):
            raise ContractError('reader document row required')
        if 'path' in row and not isinstance(row['path'], str):
            raise ContractError('reader document path required')
        if row.get('path') in {entry[0] for entry in SETTINGS_PATHS}:
            path = row['path']
            expected = next(item for item in expected_rows if item['state_path'] == path)
            if path in seen or row != {'path': path, 'snapshot_path': expected['snapshot_path'], 'sha256': expected['sha256']}:
                raise ContractError('ordinary settings head mapping mismatch')
            seen.add(path)
    return settings
