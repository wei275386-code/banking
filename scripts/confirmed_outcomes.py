"""Evidence-scoped current decisions. No source report or format selector is read."""
from __future__ import annotations

import copy
import hashlib
from scripts.inferred_associations import evidence_signature
from scripts.release_contracts import canonical_json, validate_contract

DOCUMENT = 'confirmed-outcomes.json'
RECORD_FIELDS = {'account_identity_before_consolidation', 'payment_account_status', 'unallocated_credit_cents'}
COMPONENT_FIELDS = {'primary', 'secondary', 'tags', 'recurrence', 'classification_basis',
                    'classification_evidence_basis', 'tag_basis', 'completion_confirmation', 'included', 'reason'}


def coverage_scope(coverage):
    return {key: coverage[key] for key in ("from", "to", "mode", "revision")}


def record_signature(record):
    fields = ('id', 'date', 'user_id', 'user_relation', 'non_consumption', 'events', 'evidence_keys')
    value = {k: record[k] for k in fields}
    value['components'] = [{k: c[k] for k in ('id', 'gross_cents', 'refund_cents', 'net_cents')}
                           for c in record['components']]
    return hashlib.sha256(canonical_json(value)).hexdigest()


def records(document):
    for record in document['records']:
        yield (), record
    for collection in ('source_record_sets', 'source_record_set_candidates'):
        for group in document.get(collection, []):
            for field in ('retained_records', 'shadow_records'):
                for record in group.get(field, []):
                    yield (group['id'], field), record


def bound_signatures(record, signatures):
    traces = {t['id']: t for t in record.get('trace_sources', [])}
    return {key: signatures[key] if key in signatures else
            hashlib.sha256(canonical_json({'id': key, 'source_evidence': traces[key]['source_evidence']})).hexdigest()
            for key in record['evidence_keys']}


class ConfirmedOutcomes:
    def __init__(self, document, rows, banks):
        validate_contract("confirmed-outcomes", document)
        if set(document) != {'purpose', 'records', 'coverage'} or document['purpose'] != 'confirmed-outcomes':
            raise ValueError('Invalid confirmed outcomes document')
        seen = set()
        for entry in document['records']:
            if (set(entry) - {'id', 'container', 'signature', 'evidence_signatures', 'fields', 'components'} or
                    not {'id', 'signature', 'evidence_signatures', 'fields', 'components'} <= set(entry)):
                raise ValueError('Invalid confirmed record fields')
            key = tuple(entry.get('container', [])), entry['id']
            if key in seen or set(entry['fields']) - RECORD_FIELDS:
                raise ValueError('Duplicate confirmed record or unsupported field')
            seen.add(key)
            components = set()
            for component in entry['components']:
                if (set(component) != {'id', 'fields', 'override_values', 'catalog_sha256'} or
                        component['id'] in components or set(component['fields']) - COMPONENT_FIELDS):
                    raise ValueError('Invalid confirmed component')
                components.add(component['id'])
        self.document = document
        self.signatures = {k: evidence_signature(k, rows, banks) for k in rows.keys() | banks.keys()}

    def apply(self, result, overrides, catalog_sha256):
        index = {(container, r['id']): r for container, r in records(result)}
        applied = 0
        same_range = coverage_scope(result["coverage"]) == self.document["coverage"]
        for entry in self.document['records']:
            record = index.get((tuple(entry.get('container', [])), entry['id']))
            # Later fact edits supersede this decision only for this lifecycle.
            if (record is None or record_signature(record) != entry['signature'] or
                    bound_signatures(record, self.signatures) != entry['evidence_signatures']):
                continue
            record.update(copy.deepcopy(entry['fields']))
            components = {c['id']: c for c in record['components']}
            for decision in entry['components']:
                component = components[decision['id']]
                if any(overrides.get(k) != v for k, v in decision['override_values'].items()):
                    continue
                same_catalog = catalog_sha256 == decision['catalog_sha256']
                fields = {k: copy.deepcopy(v) for k, v in decision['fields'].items()
                          if (same_catalog or k in {'included', 'reason', 'completion_confirmation'})
                          and (k not in {'included', 'reason'} or (same_range and not record.get('excluded_from_completion_and_statistics', False)))}
                component.update(fields)
                component['confirmed_outcome'] = copy.deepcopy(decision)
                applied += 1
        result['confirmed_outcomes'] = {'components_applied': applied}
