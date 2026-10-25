"""Evidence-bound associations authorized by the user after candidate review."""
import json
from pathlib import Path

try:
    from .payment_evidence import digest
    from .payment_feedback import bank_signature
except ImportError:
    from payment_evidence import digest
    from payment_feedback import bank_signature


def evidence_signature(key, rows, banks):
    if key in banks:
        return bank_signature(banks[key])
    row = rows[key]
    fields = ('platform', 'observation_id', 'file_sha256', 'source_profile_id',
              'owner_id', 'transaction_time', 'success_time', 'event_kind',
              'currency', 'platform_reported_amount_cents', 'platform_paid_amount_cents',
              'payment_method', 'title', 'merchant', 'provider_reference', 'merchant_reference', 'raw')
    return digest({field: row.get(field) for field in fields})


def apply(report, output):
    path = Path(output) / 'inferred-associations.json'
    if not path.exists():
        return
    document = json.loads(path.read_text())
    rows = {c['cluster_id']: c['representative'] for c in report['clusters']}
    banks = {f"bank:{b['id']}": b for b in report['bank_records']}
    added = []
    for link in document['links']:
        keys = link['record_ids'] + link['bank_ids']
        # Refuse a stale decision instead of silently reusing it on changed facts.
        if not keys or len(keys) != len(set(keys)) or any(
                key not in rows and key not in banks or
                evidence_signature(key, rows, banks) != link['evidence_signatures'].get(key)
                for key in keys):
            raise ValueError('Inferred association evidence changed: ' + link['id'])
        added.append({**link, 'review_required': False,
                      'association_status': 'rule_supported'})
    # Check rejection across the complete accepted graph, including indirect
    # historical bridges. Do not turn an old rule into a way around a human veto.
    parents = {key: key for key in rows | banks}
    def find(key):
        while parents[key] != key:
            parents[key] = parents[parents[key]]
            key = parents[key]
        return key
    def merge(keys):
        root = find(keys[0])
        for key in keys[1:]:
            parents[find(key)] = root
    forbidden = []
    for candidate in report['candidates']:
        keys = candidate['record_ids'] + candidate['bank_ids']
        if candidate.get('association_status') == 'rejected_by_user':
            forbidden.append(keys)
        elif not candidate['review_required'] and candidate['association_status'] in ('supported_by_user', 'rule_supported'):
            merge(keys)
    for link in added:
        if link.get('decision_origin') != 'confirmed_association':
            merge(link['record_ids'] + link['bank_ids'])
    for link in added:
        if link.get('decision_origin') != 'confirmed_association':
            continue
        keys = link['record_ids'] + link['bank_ids']
        roots = {find(k) for k in keys}
        if any(len(pair) >= 2 and {find(k) for k in pair} <= roots for pair in forbidden):
            link.update(review_required=True, association_status='rejected_by_user',
                        review_reason='existing_human_rejection')
        else:
            merge(keys)
    report['candidates'].extend(added)
