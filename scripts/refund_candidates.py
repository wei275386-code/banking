"""Project evidence-bound refund leads into reviewable App candidates.

Never confirms a link or changes amounts. Shared settlement keys map to the
complete purchase set; grouped full refunds allocate to purchases without
inventing a per-bank-occurrence correspondence.
"""
import json
from pathlib import Path

try:
    from .payment_feedback import bank_signature
    from .payment_evidence import digest
except ImportError:
    from payment_feedback import bank_signature
    from payment_evidence import digest


def project(records, banks, leads):
    bank = {b['id']: b for b in banks}
    by_key = {}
    for record in records:
        for key in record['evidence_keys']:
            by_key.setdefault(key, []).append(record)
    result, seen = [], set()
    for lead in leads:
        credits, debits = lead['refund_bank_ids'], lead['original_bank_ids']
        ids = credits + debits
        if any(i not in bank or bank_signature(bank[i]) != lead['bank_signatures'].get(str(i)) for i in ids):
            continue
        if any(not bank[i]['is_credit'] for i in credits) or any(bank[i]['is_credit'] for i in debits):
            continue
        sources = {r['id']: r for i in credits for r in by_key.get(f'bank:{i}', [])}
        targets = {r['id']: r for i in debits for r in by_key.get(f'bank:{i}', [])}
        if (not sources or not targets or sources.keys() & targets.keys() or
                sum(r['unallocated_credit_cents'] for r in sources.values()) != sum(bank[i]['amount_cents'] for i in credits) or
                any(r['unallocated_credit_cents'] <= 0 or any(c['gross_cents'] for c in r['components']) for r in sources.values())):
            continue
        cents = sum(bank[i]['amount_cents'] for i in credits)
        components = [(r, c) for r in targets.values() for c in r['components'] if c['gross_cents'] > c['refund_cents']]
        if not components:
            continue
        # A single CR aimed at shared settlement evidence offers each purchase
        # explicitly, rather than selecting an arbitrary bank/order mapping.
        allocations = [[(r, c, cents)] for r, c in components if cents <= c['gross_cents'] - c['refund_cents']]
        if len(credits) > 1:
            if cents != sum(c['gross_cents'] - c['refund_cents'] for _, c in components):
                continue
            allocations = [[(r, c, c['gross_cents'] - c['refund_cents']) for r, c in components]]
        for allocation in allocations:
            if any(r['non_consumption'] or r['date'] > min(s['date'] for s in sources.values()) for r, _, _ in allocation):
                continue
            source_ids = sorted(sources)
            target_values = sorted([{'record_id': r['id'], 'component_id': c['id'], 'refund_cents': value}
                                    for r, c, value in allocation], key=lambda t: t['component_id'])
            identity = digest('refund-candidate-v1', source_ids, target_values)
            if identity in seen:
                continue
            seen.add(identity)
            result.append({'id': identity, 'source_ids': source_ids, 'targets': target_values,
                           'basis': lead['basis'], 'confidence': lead['confidence'],
                           'grouped': len(source_ids) > 1 or len(target_values) > 1})
    for candidate in result:
        candidate['competing'] = any(other['id'] != candidate['id'] and
                                     set(other['source_ids']) & set(candidate['source_ids']) for other in result)
    return result


def generate(root, records, banks):
    path = Path(root) / 'config/hsbc-refund-candidates.json'
    if not path.exists():
        return []
    return project(records, banks, json.loads(path.read_text())['leads'])
