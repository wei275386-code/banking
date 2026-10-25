"""Production projection validation before a workspace state can be activated.

These shapes mirror the Swift Codable product models. Unknown metadata remains
available, while required fields, present optional fields, identities and material
references must decode consistently. This is read-only and never repairs data.
"""
from __future__ import annotations

import math
import re
import sqlite3
from contextlib import closing
from decimal import Decimal
from pathlib import Path

from scripts.release_contracts import digest_file, parse_json, validate_contract, validate_relative_path
from scripts.workspace_state import WorkspaceError, _regular


class ProductValidationError(WorkspaceError):
    pass


def nullable(shape):
    return ('nullable', shape)


def mapping(shape):
    return ('mapping', shape)


def _decode(value, shape, location):
    if isinstance(shape, tuple):
        if shape[0] == 'nullable':
            if value is not None:
                _decode(value, shape[1], location)
        else:
            if not isinstance(value, dict):
                raise ProductValidationError(location + ': expected object')
            for key, child in value.items():
                _decode(child, shape[1], location + '/' + key)
    elif isinstance(shape, dict):
        if not isinstance(value, dict):
            raise ProductValidationError(location + ': expected object')
        for name, child in shape.items():
            optional = name.endswith('?')
            key = name[:-1] if optional else name
            if key not in value:
                if optional:
                    continue
                raise ProductValidationError(location + ': missing ' + key)
            if optional and value[key] is None:
                continue
            _decode(value[key], child, location + '/' + key)
    elif isinstance(shape, list):
        if not isinstance(value, list):
            raise ProductValidationError(location + ': expected array')
        for index, child in enumerate(value):
            _decode(child, shape[0], location + '/' + str(index))
    elif shape == 'number':
        if (type(value) not in (int, float) and not isinstance(value, Decimal)) or not math.isfinite(float(value)):
            raise ProductValidationError(location + ': expected finite Double')
    elif type(value) is not shape or (shape is int and not -(2**63) <= value < 2**63):
        raise ProductValidationError(location + ': invalid Swift scalar')


ASSET = {'path': str, 'sha256': str}
SOURCE = dict(ASSET, original_name=str)
REFERENCE = {'kind': str, 'preview?': ASSET, 'raw?': ASSET, 'image?': ASSET,
             'source?': SOURCE, 'crop_complete?': bool, 'ocr_result?': ASSET}
EVENT = {'id': str, 'date': str, 'kind': str, 'source': str, 'amount_cents': int,
         'status': str, 'payment_account?': str}
COMPONENT = {'id': str, 'title': str, 'gross_cents': int, 'refund_cents': int,
             'net_cents': int, 'reimbursement_cents?': int, 'primary': str,
             'secondary': str, 'classification_basis': str, 'included': bool,
             'reason': str, 'recurrence?': str, 'classification_keys?': [str],
             'tags?': [str], 'tag_basis?': mapping(str)}
COMPONENT['completion_confirmation?'] = {'origin': str, 'sourceID?': str,
    'draft': {'primary': str, 'secondary': str, 'recurrence': str, 'tags': [str]}}
TRACE = {'id': str, 'association': str, 'basis': str, 'owner_id?': str,
         'platform': str, 'date': str, 'post_date?': str, 'merchant?': str,
         'title?': str, 'amount_cents?': int, 'currency': str,
         'payment_method?': str, 'event_kind': str, 'status': str,
         'provider_reference?': str, 'merchant_reference?': str,
         'source_name?': str, 'location': str, 'source_evidence?': REFERENCE}
LIFECYCLE = {'id': str, 'date': str, 'title': str, 'status': str,
             'account_views': [str], 'evidence_keys': [str], 'components': [COMPONENT],
             'events': [EVENT], 'payment_events?': [EVENT], 'trace_sources?': [TRACE],
             'user_relation': str, 'non_consumption': bool, 'unallocated_credit_cents': int,
             'bank_settlement_group?': {'id': str, 'count': int, 'bank_keys': [str], 'basis': str},
             'account_identity_before_consolidation?': {'user_id?': str, 'user_relation': str,
                 'payment_accounts?': [str], 'payment_account_status?': str, 'account_views': [str]}}
for name in ('user_id', 'payment_account_status', 'user_display_name', 'fact_review_status'):
    LIFECYCLE[name + '?'] = str
for name in ('payment_accounts', 'payment_channels', 'payment_account_pending_reasons'):
    LIFECYCLE[name + '?'] = [str]
LIFECYCLE['excluded_from_completion_and_statistics?'] = bool
SOURCE_SET = {'id': str, 'retained_ids': [str], 'shadow_ids': [str],
              'signatures?': mapping(str), 'retained_event_keys?': [str],
              'evidence_keys?': [str], 'shadow_records?': [LIFECYCLE],
              'retained_records?': [LIFECYCLE], 'can_confirm?': bool, 'reasons?': [str]}
for name in ('kind', 'basis', 'status', 'origin', 'default_status', 'fingerprint', 'date', 'review_reason'):
    SOURCE_SET[name + '?'] = str
for name in ('amount_cents', 'network_count', 'bank_count'):
    SOURCE_SET[name + '?'] = int
VIDEO = {'id': str, 'title': str, 'date': str, 'platform?': str, 'amount_cents': int,
         'status': str, 'payment_account?': str, 'date_basis': str, 'source_evidence': REFERENCE}
VIDEO_SUMMARY = {name: int for name in ('raw_complete_crops', 'deduplicated_materials',
                 'wallet_links', 'unparsed_crops', 'undated_materials')}
VIDEO_SUMMARY['recall_status'] = str
FIRE = {name: nullable(int) for name in ('baseYear', 'birthYear', 'targetAge')}
FIRE.update({name: nullable('number') for name in ('currentFireAssets', 'afterTaxSalary',
                                      'annualContribution', 'annualHardCap')})
FIRE.update(expenseModes=mapping(nullable('number')), expenseBreakdown=mapping(nullable('number')),
    buckets={'safetyBucket': nullable('number'), 'parentMedicalBucket': nullable('number'),
             'elderCareEnabled': bool, 'elderCareBucket': nullable('number'), 'otherBuckets': nullable('number'),
             'includeBuckets': bool},
    investing={name: nullable('number') for name in ('withdrawalRate', 'annualReturn', 'inflation', 'maxDrawdown')},
    branches={'housing': {'enabled': bool, 'year': nullable(int), 'totalPrice': nullable('number'),
        'downPaymentRatio': nullable('number'), 'loanRate': nullable('number'), 'loanYears': nullable(int),
        'fees': nullable('number'), 'renovation': nullable('number'), 'annualMaintenance': nullable('number'),
        'reduceRent': bool, 'minLiquidAssets': nullable('number'), 'ownerHomeCountsAsFireAsset': bool,
        'annualRentReduction?': nullable('number')},
        'children': {'enabled': bool, 'count': nullable(int), 'birthYear': nullable(int),
            'annualCost': nullable('number'), 'educationBucket': nullable('number'), 'incomeImpact': nullable('number')}})
FINANCIAL = {'dataset_id': str, 'source_dataset_id': str,
             'cutoff': nullable(str), 'records': [LIFECYCLE],
             'taxonomy': [{'primary': str, 'secondaries': [str]}], 'fire_parameters': FIRE,
             'coverage_note': str, 'coverage_complete': bool, 'video_materials?': [VIDEO],
             'video_summary?': VIDEO_SUMMARY, 'source_record_sets?': [SOURCE_SET],
             'source_record_set_candidates?': [SOURCE_SET],
             'account_consolidation?': {'aliases': mapping(nullable(str)),
                                        'excluded_lifecycle_ids': [str]},
             'refund_candidates?': [{'id': str, 'source_ids': [str],
                 'targets': [{'record_id': str, 'component_id': str, 'refund_cents': int}],
                 'basis': str, 'confidence': str, 'grouped': bool, 'competing': bool}]}
OBSERVATION = {'platform': str, 'transaction_time': str, 'merchant?': str, 'title?': str,
               'platform_reported_amount_cents?': int, 'raw_status': str, 'source_evidence': REFERENCE}
CLUSTER = {'cluster_id': str, 'representative': OBSERVATION}
CANDIDATE = {'candidate_id': str, 'kind': str, 'record_ids': [str], 'bank_ids': [str],
             'association_status': str, 'review_required': bool, 'active_competing_candidate_ids?': [str]}
EVIDENCE = {'dataset_id': str, 'backfill_cutoff_date': nullable(str),
            'clusters': [CLUSTER], 'bank_records': [{'id': int, 'date': str, 'description': str,
                'amount_cents': int, 'is_credit': int, 'source_evidence': REFERENCE,
                'human_transaction_confirmation?': {'user_relation': str}}],
            'candidates': [CANDIDATE], 'review_summary': mapping(int),
            'ocr_probe?': {'samples': [{'card_id': str, 'visible_title?': str,
                'parsed?': {'amountCents?': int, 'status?': str, 'orderedMinute?': str},
                'source_evidence': REFERENCE}]}}


def _identities(items, key, label):
    seen = set()
    for item in items:
        identity = item[key]
        if identity == '' or identity in seen:
            raise ProductValidationError(label + ': empty or duplicate ' + key)
        seen.add(identity)
    return seen


def _references(keys, available, label):
    if len(keys) != len(set(keys)) or set(keys) - available:
        raise ProductValidationError(label + ': duplicate or dangling reference')


def validate_product_state(root):
    """Validate a staged or frozen production state, hashing each asset once."""
    from scripts.financial_review_inputs import FinancialReviewInputs
    from scripts.probe_payment_evidence import registry_dependencies
    root = Path(root)
    review = root / 'review'
    def read(relative):
        return parse_json(_regular(root / relative).read_bytes())
    financial, evidence, coverage = [read('review/' + name) for name in
        ('financial-review.json', 'payment-evidence.json', 'coverage.json')]
    _decode(financial, FINANCIAL, 'financial')
    _decode(evidence, EVIDENCE, 'evidence')
    validate_contract('coverage', coverage)
    if financial.get('coverage') != coverage or evidence.get('coverage') != coverage:
        raise ProductValidationError('projection coverage differs from coverage.json')
    if financial['cutoff'] != coverage['to'] or evidence['backfill_cutoff_date'] != coverage['to']:
        raise ProductValidationError('projection cutoff differs from coverage')
    if not financial['dataset_id'] or not evidence['dataset_id'] or financial['source_dataset_id'] != evidence['dataset_id']:
        raise ProductValidationError('projection dataset identity is missing or inconsistent')
    _decode(read('config/fire-parameters.json'), FIRE, 'fire configuration')
    registry = registry_dependencies(root)
    FinancialReviewInputs.dependency_registry(root, review)
    hashes = {root / source['path']: source['sha256'] for source in registry['sources']}
    registered = {source['path']: source for source in registry['sources']}
    documents = evidence.get('documents')
    _decode(documents, [{'source_path': str, 'file_sha256': str, 'platform': str}], 'source documents')
    if len(documents) != len(registered):
        raise ProductValidationError('source documents differ from retained source registry')
    for document in documents:
        source = registered.get(document['source_path'])
        if source is None or (source['sha256'], source['platform']) != (document['file_sha256'], document['platform']):
            raise ProductValidationError('source document identity differs from retained registry')
    _identities(documents, 'source_path', 'source documents')
    def assets(value):
        if isinstance(value, dict):
            if 'path' in value and 'sha256' in value:
                _decode(value, ASSET, 'evidence asset')
                relative = validate_relative_path(value['path'])
                checksum = value['sha256']
                if re.fullmatch('[0-9a-f]{64}', checksum) is None:
                    raise ProductValidationError('invalid evidence asset checksum')
                path = _regular(review / relative)
                if path not in hashes:
                    hashes[path] = digest_file(path)
                if hashes[path] != checksum:
                    raise ProductValidationError('evidence asset hash differs: ' + relative)
            for child in value.values():
                assets(child)
        elif isinstance(value, list):
            for child in value:
                assets(child)
    clusters = _identities(evidence['clusters'], 'cluster_id', 'clusters')
    banks = {'bank:' + str(identity) for identity in _identities(evidence['bank_records'], 'id', 'bank records')}
    undated = evidence.get('undated_bank_records', [])
    _decode(undated, [{'id': int}], 'undated bank records')
    undated_ids = _identities(undated, 'id', 'undated bank records')
    bank_ids = {bank['id'] for bank in evidence['bank_records']}
    with closing(sqlite3.connect((root / 'banking.sqlite3').as_uri() + '?mode=ro', uri=True)) as db:
        actual_bank_ids = {row[0] for row in db.execute('SELECT id FROM transactions')}
    if bank_ids & undated_ids or bank_ids | undated_ids != actual_bank_ids:
        raise ProductValidationError('evidence bank identities differ from formal ledger')
    cards = {'card:' + identity for identity in _identities((evidence.get('ocr_probe') or {}).get('samples', []), 'card_id', 'cards')}
    candidates = _identities(evidence['candidates'], 'candidate_id', 'candidates')
    assets(evidence)
    supplementary_links = []
    supporting_materials = set()
    for name in ('video-evidence.json', 'order-evidence.json', 'supplemental-evidence.json'):
        if not (review / name).exists():
            continue
        supplement = read('review/' + name)
        _decode(supplement, {'observations': [CLUSTER], 'materials': [VIDEO], 'links': [
            {'record_ids': [str], 'bank_ids': [str]}]}, name)
        added = _identities(supplement['observations'], 'cluster_id', name)
        if clusters & added:
            raise ProductValidationError('observation identity repeated across sources')
        clusters |= added
        supporting_materials |= _identities(supplement['materials'], 'id', name + ' materials')
        supplementary_links.extend(supplement['links'])
        assets(supplement)
    for candidate in evidence['candidates']:
        _references(candidate['record_ids'], clusters, 'candidate records')
        _references(candidate['bank_ids'], banks, 'candidate banks')
        _references(candidate.get('active_competing_candidate_ids') or [], candidates, 'competing candidates')
    for link in supplementary_links:
        _references(link['record_ids'], clusters, 'supplementary linked records')
        _references(link['bank_ids'], banks, 'supplementary linked banks')
    available = clusters | banks | cards | supporting_materials
    for record in financial['records']:
        _references(record['evidence_keys'], available, 'lifecycle evidence')
        _identities(record['components'], 'id', 'lifecycle components')
        _identities(record['events'], 'id', 'lifecycle events')
        _identities(record.get('payment_events') or [], 'id', 'payment events')
    _identities(financial['records'], 'id', 'financial lifecycles')
    _identities([component for record in financial['records'] for component in record['components']],
                'id', 'financial components')
    _identities(financial.get('video_materials') or [], 'id', 'video materials')
    _identities(financial['taxonomy'], 'primary', 'taxonomy')
    assets(financial)
    return {'financial_records': len(financial['records']), 'evidence_clusters': len(clusters),
            'verified_assets': len(hashes), 'registered_sources': len(registry['sources'])}


def validate_transaction(transaction):
    return validate_product_state(transaction.root)
