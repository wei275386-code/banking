"""User-confirmed agency-purchase receipts, separate from merchant refunds."""
import copy

try:
    from .inferred_associations import evidence_signature
except ImportError:
    from inferred_associations import evidence_signature


def apply(records, report, links):
    rows = {c['cluster_id']: c['representative'] for c in report['clusters']}
    used = set()
    for link in links:
        payment, receipt = link['payment'], link['receipt']
        keys = [payment, receipt]
        if len(set(keys)) != 2 or used.intersection(keys):
            raise ValueError('代购回款重复关联')
        if any(k not in rows or evidence_signature(k, rows, {}) != link['evidence_signatures'].get(k) for k in keys):
            raise ValueError('代购回款原始证据已更新')
        p, r = rows[payment], rows[receipt]
        if p['event_kind'] != 'payment' or r.get('raw_direction') != '收入' or r['event_kind'] not in ('receipt', 'transfer_or_gift'):
            raise ValueError('代购付款或回款方向不符')
        if not p.get('owner_id') or p['owner_id'] != r.get('owner_id') or p['currency'] != r['currency']:
            raise ValueError('代购付款与回款用户或币种不符')
        target = next(x for x in records if payment in x['evidence_keys'])
        source = next(x for x in records if receipt in x['evidence_keys'])
        component = next(c for c in target['components'] if c['id'] == payment)
        if source['id'] == target['id'] or not source['non_consumption'] or any(c['gross_cents'] for c in source['components']):
            raise ValueError('代购回款已有消费归属')
        cents = r['platform_reported_amount_cents']
        if not isinstance(cents, int) or cents <= 0:
            raise ValueError('代购回款金额无效')
        component['reimbursement_cents'] = cents
        component['net_cents'] = component['gross_cents'] - component['refund_cents'] - cents
        target['reimbursement_link'] = {**copy.deepcopy(link), 'related_lifecycle_id': source['id']}
        source['reimbursement_link'] = {**copy.deepcopy(link), 'related_lifecycle_id': target['id']}
        # Preserve raw lifecycle IDs, events and signatures; enrich only the display.
        event = copy.deepcopy(next(e for e in source['events'] if e['id'] == receipt))
        event.update(kind='agency_receipt', status='用户确认代购回款 · ' + event['status'], payment_account='微信零钱')
        target['payment_events'] = sorted([e for e in target.get('payment_events', target['events']) if e['id'] != receipt] + [event], key=lambda e: (e['date'], e['id']))
        used.update(keys)
