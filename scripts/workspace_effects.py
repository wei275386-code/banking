"""Current-state business membership, independent of receipts and DB page bytes.

Evidence membership refers to real records or exact decision/projection files.
Each operation introduces a new effect identity and explicitly supersedes prior
versions of the same entity. A historical result remains historical after edit.
"""
from __future__ import annotations

import struct
import uuid
from collections import Counter
from pathlib import Path

from scripts.release_contracts import canonical_json, digest_bytes, digest_file, parse_json
from scripts.workspace_state import WorkspaceError, _files, _sqlite, readonly_sqlite


def _value(value):
    if isinstance(value, bytes):
        return {'sqlite_blob_hex': value.hex()}
    if isinstance(value, float):
        return {'sqlite_float_bits': struct.pack('>d', value).hex()}
    return value


def current_entities(root):
    root = Path(root)
    entities = {}
    for relative, path in _files(root):
        if relative in {'state-manifest.json', 'operation-results.json', 'review/field-state.json',
                        'review/revision-inventory.json'} or relative.startswith(
                ('sources/', 'inputs/', 'review/materials/', 'review/ocr/', 'review/videos/', 'history/edits/')):
            continue
        if _sqlite(path):
            with readonly_sqlite(path) as connection:
                connection.execute('BEGIN')
                tables = connection.execute("SELECT name,sql FROM sqlite_master WHERE type='table' "
                                            "AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
                for name, definition in tables:
                    quoted = '"' + name.replace('"', '""') + '"'
                    columns = connection.execute('PRAGMA table_info(' + quoted + ')').fetchall()
                    primary = [row[1] for row in sorted(columns, key=lambda row: row[5]) if row[5]]
                    cursor = connection.execute('SELECT * FROM ' + quoted)
                    names = [item[0] for item in cursor.description]
                    row_hashes = Counter()
                    for row in cursor:
                        document = dict(zip(names, map(_value, row)))
                        digest = digest_bytes(canonical_json(document))
                        if primary:
                            identity = digest_bytes(canonical_json([document[key] for key in primary]))
                            key = 'database:' + relative + ':' + name + ':' + identity
                            if key in entities:
                                raise WorkspaceError('duplicate SQLite primary-key identity')
                            entities[key] = digest
                        else:
                            row_hashes[digest] += 1
                    entities['table-schema:' + relative + ':' + name] = digest_bytes(canonical_json(
                        {'sql': definition, 'columns': [list(row) for row in columns]}))
                    if not primary:
                        entities['table:' + relative + ':' + name] = digest_bytes(canonical_json(dict(row_hashes)))
        elif path.suffix == '.json':
            value = parse_json(path.read_bytes())
            entities['document:' + relative] = digest_file(path)
            if relative == 'review/financial-review.json':
                seen = set()
                for record in value.get('records', []):
                    identity = record.get('id')
                    if not isinstance(identity, str) or not identity or identity in seen:
                        raise WorkspaceError('projection has missing or duplicate stable record IDs')
                    seen.add(identity)
                    entities['record:' + identity] = digest_bytes(canonical_json(record))
    return entities


def derive_membership(transaction, request_id, ledger):
    before = current_entities(transaction.parent.root) if transaction.parent else {}
    after = current_entities(transaction.root)
    prior = {}
    superseded = {key for result in ledger['results'] for effect in result['membership']
                  for key in effect.get('supersedes', [])}
    for result in ledger['results']:
        for effect in result['membership']:
            entity = effect.get('entity_key')
            if entity and effect['key'] not in superseded:
                prior.setdefault(entity, []).append(effect['key'])
    changed = {entity for entity in set(before) | set(after) if before.get(entity) != after.get(entity)}
    # A no-input projection refresh has a real, verifiable output even when its
    # business rows are unchanged. Its exact report hash is not a dummy effect.
    changed.add('document:review/financial-review.json')
    changed.add('document:review/payment-evidence.json')
    result = []
    for entity in sorted(changed):
        digest = after.get(entity)
        deleted = digest is None
        if deleted and not prior.get(entity):
            # There is no historical membership to invalidate. A nonexistent
            # entity alone cannot prove that an operation has business effects.
            continue
        if deleted:
            digest = digest_bytes(canonical_json({'entity': entity, 'deleted': True}))
        effect = {'key': 'effect:' + digest_bytes(canonical_json([request_id, entity, digest])),
                  'entity_key': entity, 'digest': digest,
                  'kind': 'tombstone' if deleted else ('record' if entity.startswith(('record:', 'database:')) else 'revision')}
        if prior.get(entity):
            effect['supersedes'] = sorted(prior[entity])
        result.append(effect)
    return result


def verify_current_membership(root, ledger):
    """Verify effective business entities; superseded history proves no presence."""
    entities = current_entities(root)
    root = Path(root)
    effects = {}
    superseded = set()
    requests = {}
    for result in ledger['results']:
        if not any(effect.get('entity_key') for effect in result['membership']):
            raise WorkspaceError('historical result lacks verifiable business entity membership')
        parent_id = result.get('parent_request_id')
        parent = requests.get(parent_id) if parent_id else None
        if parent_id:
            if parent is None or parent['outcome'] != 'partial' or len(result['inputs']) != 1:
                raise WorkspaceError('repair lacks earlier partial request')
            selected = result['inputs'][0]
            parents = [entry for entry in parent['inputs'] if entry['input_id'] == selected['input_id']]
            if len(parents) != 1 or parents[0]['outcome'] != 'pending' or selected['outcome'] != 'success':
                raise WorkspaceError('repair input is not an earlier pending stage')
            if any(parents[0].get(key) != selected.get(key) for key in
                   ('sha256', 'kind', 'required_financial', 'source_path')):
                raise WorkspaceError('repair source identity differs from partial request')
            key = digest_bytes(canonical_json([result['workspace_id'], parent_id, selected['input_id'], 'projected']))
            namespace = uuid.UUID(result['workspace_id'])
            if result['request_id'] != str(uuid.uuid5(namespace, 'request:' + key)) or result['operation_id'] != str(uuid.uuid5(namespace, 'operation:' + key)):
                raise WorkspaceError('repair identity is not stable')
        expected_stages = {}
        for entry in result['inputs']:
            relative = entry.get('source_path')
            prefix = ('inputs/' if entry['kind'] == 'review' else 'sources/') + entry['sha256'] + '/'
            if not relative or not relative.startswith(prefix):
                raise WorkspaceError('historical input lacks a retained source reference')
            from scripts.workspace_state import _regular, _safe
            from scripts.release_contracts import validate_relative_path
            source = _regular(_safe(root / validate_relative_path(relative)))
            if digest_file(source) != entry['sha256']:
                raise WorkspaceError('result input bytes are missing or changed')
            stages = entry['completed_stages']
            if stages != (['retained'] if entry['outcome'] == 'pending' else ['retained', 'projected']):
                raise WorkspaceError('input stages do not match outcome')
            for stage in stages:
                if parent_id and stage == 'retained':
                    continue
                key = 'input-stage:' + digest_bytes(canonical_json([parent_id or result['request_id'], entry['input_id'], stage]))
                expected_stages[key] = digest_bytes(canonical_json({'input_id': entry['input_id'], 'sha256': entry['sha256'], 'stage': stage}))
        actual_stages = {effect['key']: effect['digest'] for effect in result['membership'] if effect['kind'] == 'input-stage'}
        if actual_stages != expected_stages:
            raise WorkspaceError('input-stage membership differs from retained stages')
        identity = [{key: entry[key] for key in ('input_id', 'sha256', 'kind', 'required_financial')} for entry in result['inputs']]
        if result['input_hash'] != digest_bytes(canonical_json(identity)):
            raise WorkspaceError('result input identity hash mismatch')
        introduced = set()
        introduced_entities = set()
        for effect in result['membership']:
            if effect['key'] in effects or effect['key'] in introduced:
                raise WorkspaceError('effect identity is repeated across operations')
            introduced.add(effect['key'])
            entity = effect.get('entity_key')
            if effect['kind'] == 'input-stage':
                if entity is not None or effect.get('supersedes'):
                    raise WorkspaceError('input-stage cannot supersede business entities')
            elif not entity or not entity.startswith(('document:', 'record:', 'database:', 'table:', 'table-schema:')):
                raise WorkspaceError('effect lacks a verifiable entity')
            elif entity in introduced_entities:
                raise WorkspaceError('result has duplicate business entity')
            else:
                introduced_entities.add(entity)
            if effect['kind'] == 'tombstone':
                if not effect.get('supersedes') or effect['digest'] != digest_bytes(canonical_json({'entity': entity, 'deleted': True})):
                    raise WorkspaceError('tombstone lacks exact digest or historical entity membership')
            elif effect['kind'] != 'input-stage' and effect['kind'] not in {'record', 'revision'}:
                raise WorkspaceError('business entity effect has unsupported kind')
            for key in effect.get('supersedes', []):
                # Supersession can only point to an earlier result, never a
                # later/self result; this also excludes cycles and dangling keys.
                if key not in effects or effects[key].get('entity_key') != effect.get('entity_key'):
                    raise WorkspaceError('effect supersession has no matching historical entity')
                superseded.add(key)
        effects.update({effect['key']: effect for effect in result['membership']})
        if result['request_id'] in requests:
            raise WorkspaceError('duplicate historical request')
        requests[result['request_id']] = result
    heads = set()
    for key, effect in effects.items():
        entity = effect.get('entity_key')
        if key in superseded or entity is None:
            continue
        if entity in heads:
            raise WorkspaceError('multiple effective business heads without supersession')
        heads.add(entity)
        if effect['kind'] == 'tombstone':
            if not effect.get('supersedes'):
                raise WorkspaceError('tombstone lacks historical entity membership')
            if effect['digest'] != digest_bytes(canonical_json({'entity': entity, 'deleted': True})):
                raise WorkspaceError('tombstone digest is invalid')
            if entity in entities:
                raise WorkspaceError('tombstoned entity is present')
        elif entities.get(entity) != effect['digest']:
            raise WorkspaceError('current business effect is missing or changed: ' + entity)
    return True
