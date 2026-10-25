"""Apply evidence-scoped, user-confirmed date corrections and duplicate identities.

The source files and observations remain immutable. Retained lifecycle IDs and
human classifications win; redundant projections are archived with all evidence.
"""
import copy
import json
from datetime import date
from pathlib import Path

try:
    from .payment_evidence import digest
except ImportError:
    from payment_evidence import digest


def signature(record):
    return digest({k: record[k] for k in ('id', 'date', 'evidence_keys', 'events', 'non_consumption')},
                  [{k: c[k] for k in ('id', 'gross_cents', 'refund_cents', 'net_cents')} for c in record['components']])


def restore_traces(result):
    applied = result.get('confirmed_transaction_corrections')
    if not applied:
        return
    document = applied['decision']
    originals = applied['original_records']
    index = {r['id']: r for r in result['records']}
    corrected_keys = {key: item['date'] for item in document['dates']
                      for key in originals[item['id']]['evidence_keys']}
    for merge in document['merges']:
        record = index[merge['retained_id']]
        traces = record.setdefault('trace_sources', [])
        seen = {t['id'] for t in traces}
        for shadow in merge['shadow_ids']:
            for trace in originals[shadow].get('trace_sources', []):
                if trace['association'] == 'linked' and trace['id'] not in seen:
                    traces.append(copy.deepcopy(trace)); seen.add(trace['id'])
        for trace in traces:
            if trace['id'] in merge['evidence_keys']:
                trace['association'] = 'linked'
                trace['basis'] = merge['basis']
    for record in result['records']:
        for trace in record.get('trace_sources', []):
            corrected = corrected_keys.get(trace['id'])
            if corrected:
                if trace['date'][:10] != corrected:
                    trace['original_date'] = trace['date']
                    trace['date'] = corrected + trace['date'][10:]
                note = '年份经用户确认更正，原材料保留'
                if note not in trace['basis']:
                    trace['basis'] += '；' + note


def apply(result, document):
    if not document:
        return
    previous = result.get('confirmed_transaction_corrections')
    if previous:
        if previous['decision'] != document:
            raise ValueError('A different correction batch is already applied')
        restore_traces(result)
        return
    index = {r['id']: r for r in result['records']}
    claims = [s for m in document['merges'] for s in m['shadow_ids']]
    retained = {m['retained_id'] for m in document['merges']}
    if len(claims) != len(set(claims)) or retained.intersection(claims):
        raise ValueError('Overlapping duplicate decisions')
    dated_ids = [item['id'] for item in document['dates']]
    if len(dated_ids) != len(set(dated_ids)) or not (set(dated_ids) | retained | set(claims)) <= set(document['signatures']):
        raise ValueError('All correction participants must have an evidence signature')
    # Validate the entire batch before modifying anything.
    for key, expected in document['signatures'].items():
        if key not in index or signature(index[key]) != expected:
            raise ValueError('Confirmed correction evidence changed: ' + key)
    for item in document['dates']:
        if date.fromisoformat(item['date']).isoformat() != item['date']:
            raise ValueError('Invalid confirmed date')
    for merge in document['merges']:
        keep = index[merge['retained_id']]
        expected_dates = {item['id']: item['date'] for item in document['dates']}
        for shadow_id in merge['shadow_ids']:
            shadow = index[shadow_id]
            shadow_time = expected_dates.get(shadow_id, shadow['date']) + shadow['events'][0]['date'][10:]
            keep_time = expected_dates.get(keep['id'], keep['date']) + keep['events'][0]['date'][10:]
            if (len(keep['components']) != 1 or len(shadow['components']) != 1
                    or keep['non_consumption'] or shadow['non_consumption']
                    or keep['unallocated_credit_cents'] or shadow['unallocated_credit_cents']
                    or [(c['gross_cents'], c['refund_cents']) for c in keep['components']]
                    != [(c['gross_cents'], c['refund_cents']) for c in shadow['components']]
                    or len(keep['events']) != 1 or len(shadow['events']) != 1
                    or keep['events'][0]['kind'] != 'payment' or shadow['events'][0]['kind'] != 'payment'
                    or shadow_time[:16] != keep_time[:16]):
                raise ValueError('Duplicate payment facts do not agree: ' + shadow_id)
    original = {key: copy.deepcopy(index[key]) for key in document['signatures']}
    for item in document['dates']:
        record = index[item['id']]
        old_date = record['date']; record['date'] = item['date']
        for field in ('events', 'payment_events'):
            for event in record.get(field, []):
                if event['date'][:10] == old_date:
                    event['date'] = item['date'] + event['date'][10:]
        record['fact_review_status'] = '事实已确认：年份经用户确认更正'
    for merge in document['merges']:
        keep = index[merge['retained_id']]
        keep['evidence_keys'] = sorted(set(keep['evidence_keys']) | set(merge['evidence_keys']))
        # A single retained payment remains a single event and a single amount.
        for event in keep.get('payment_events', []):
            event['evidence_keys'] = sorted(set(event.get('evidence_keys', [])) | set(merge['evidence_keys']))
        keep['fact_review_status'] = '事实已确认：重复来源已归并'
    result['records'] = [r for r in result['records'] if r['id'] not in set(claims)]
    links = {s: m['retained_id'] for m in document['merges'] for s in m['shadow_ids']}
    for material in result.get('video_materials', []):
        if material['id'] in {k for r in original.values() for k in r['evidence_keys']}:
            if material['id'] in {k for item in document['dates'] for k in original[item['id']]['evidence_keys']}:
                day = next(item['date'] for item in document['dates'] if material['id'] in original[item['id']]['evidence_keys'])
                material['date'] = day
                material['date_basis'] = 'user_confirmed_displayed_date'
            for merge in document['merges']:
                if material['id'] in merge['evidence_keys']:
                    material['linked_transaction_ids'] = [merge['retained_id']]
                    material['association_basis'] = merge['basis']
    result['confirmed_transaction_corrections'] = {
        'decision': copy.deepcopy(document), 'original_records': original,
        'shadow_to_retained': links, 'corrected_date_count': len(document['dates']),
        'removed_duplicate_count': len(claims)}
    restore_traces(result)


def load(output):
    path = Path(output) / 'confirmed-transaction-corrections.json'
    return json.loads(path.read_text()) if path.exists() else None
