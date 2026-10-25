"""Derived event identity and complete settlement-set reconciliation.

Raw events remain the evidence/signature input. Never pair equal bank occurrences
arbitrarily: a complete set can replace bank-only shadows while purchases retain
their own IDs, times and classification, and share explicitly unpaired evidence.
"""
from collections import Counter, defaultdict
import re

try:
    from .payment_evidence import digest, has_resolved_funding
except ImportError:
    from payment_evidence import digest, has_resolved_funding


def date_confirmation(row):
    return digest('displayed-date-v1', row['transaction_time'], row.get('file_sha256'),
                  row.get('event_kind'), row.get('platform_reported_amount_cents'))


def apply_date_confirmations(report, state):
    accepted = state.get('confirmed_displayed_dates', {})
    confirmed = []
    for c in report['clusters']:
        r = c['representative']
        if r.get('date_basis') == 'year_label_conflicts_weekday' and accepted.get(c['cluster_id']) == date_confirmation(r):
            r['date_basis'] = 'user_confirmed_displayed_date'
            confirmed.append(c['cluster_id'])
    return confirmed


def reconcile_card_sources(report, state, policy):
    """Join distinct source observations of an explicitly identified card payment.

    Require bidirectional uniqueness, exact currency/amount/direction, compatible
    merchants and a shared displayed minute. Equal bank dates alone cannot join.
    """
    if not policy:
        return []
    try:
        from .account_consolidation import canonical
        from .source_reconciliation import compatible, amount, times
    except ImportError:
        from account_consolidation import canonical
        from source_reconciliation import compatible, amount, times
    rows = {c['cluster_id']: c['representative'] for c in report['clusters']}
    banks = {f"bank:{b['id']}": b for b in report['bank_records']}
    conflicts = {c['cluster_id'] for c in report['clusters'] if c.get('conflicting_fields') or c.get('status_order_unresolved')}
    parents = {k: k for k in rows | banks}
    def find(k):
        while parents[k] != k:
            parents[k] = parents[parents[k]]; k = parents[k]
        return k
    def merge(keys):
        for k in keys[1:]: parents[find(k)] = find(keys[0])
    for c in report['candidates']:
        if not c['review_required'] and c['association_status'] in ('supported_by_user', 'rule_supported'):
            merge(c['record_ids'] + c['bank_ids'])
    protected = {k for r in policy.get('excluded_records', {}).values() for k in r['evidence_keys']}
    forbidden = [set(c['record_ids'] + c['bank_ids']) for c in report['candidates'] if c.get('association_status') == 'rejected_by_user']
    unresolved = {k for c in report['candidates'] if c['review_required'] and c.get('association_status') != 'rejected_by_user'
                  for k in c['record_ids'] + c['bank_ids']}
    cards = {}
    buckets = defaultdict(list)
    for k, r in rows.items():
        method = r.get('payment_method') or ''
        card = canonical(method, policy)
        if re.search(r'\d{4}', method) and card in policy['canonical_accounts']:
            cards[k] = card
        if (k not in conflicts | protected and k in cards and r['event_kind'] == 'payment'
                and r['current_payment_state'] in ('successful', 'unknown', 'fully_refunded', 'partially_refunded')
                and r.get('date_basis') != 'year_label_conflicts_weekday' and r.get('currency') and amount(r) is not None):
            buckets[(cards[k], r['transaction_time'][:10], amount(r), r['currency'])].append(k)
    edges = set()
    members = defaultdict(list)
    for k in parents: members[find(k)].append(k)
    def safe(a, b):
        roots = {find(a), find(b)}
        keys = {k for root in roots for k in members[root]}
        if keys & protected or any(f <= keys for f in forbidden): return False
        if len([k for k in keys if k in banks]) > 1: return False
        owners = {rows[k].get('owner_id') for k in keys if k in rows}
        owners |= {banks[k]['owner_id'] for k in keys if k in banks and banks[k].get('owner_id')}
        if len(owners) > 1: return False
        # Independent occurrences within a platform cannot be collapsed.
        count = Counter(rows[k]['platform'] for k in keys if k in rows and rows[k]['event_kind'] == 'payment')
        return max(count.values(), default=0) <= 1
    for keys in buckets.values():
        for i, a in enumerate(keys):
            for b in keys[i + 1:]:
                if find(a) == find(b) or rows[a]['platform'] == rows[b]['platform'] or not safe(a, b): continue
                ra, rb = rows[a], rows[b]
                if not compatible((ra.get('merchant') or '') + ' ' + (ra.get('title') or ''),
                                  (rb.get('merchant') or '') + ' ' + (rb.get('title') or '')): continue
                ta, tb = times(ra), times(rb)
                minute = ra['platform'] == 'unionpay' or rb['platform'] == 'unionpay'
                matched = any((x.strftime('%Y-%m-%d %H:%M') == y.strftime('%Y-%m-%d %H:%M')) if minute
                              else abs((x-y).total_seconds()) <= 2 for x in ta for y in tb)
                if matched: edges.add(tuple(sorted((a, b))))
    neighbors = defaultdict(set)
    for a, b in edges:
        neighbors[find(a)].add(find(b)); neighbors[find(b)].add(find(a))
    added = []
    for a, b in sorted(edges):
        if len(neighbors[find(a)]) != 1 or len(neighbors[find(b)]) != 1: continue
        c = {'candidate_id': digest('explicit-card-source-v1', a, b), 'kind': 'card_source_reconciliation',
             'record_ids': [a, b], 'bank_ids': [], 'review_required': False,
             'association_status': 'rule_supported', 'basis': '明确相同卡号、币种金额、方向、商户路由及支付时间双向唯一'}
        added.append(c)
    for c in added: merge(c['record_ids'])
    covered = {canonical(str(b['account_number']).replace(' ', '')[-4:], policy) for b in banks.values()}
    linked_roots = {find(k) for c in added for k in c['record_ids']}
    bank_roots = {find(k) for k in banks}
    for k, card in cards.items():
        if k in protected or k in conflicts: continue
        r = rows[k]
        if r['event_kind'] != 'payment': continue
        if find(k) in bank_roots or find(k) in linked_roots or (card not in covered and k not in unresolved and not neighbors[find(k)]):
            r['video_overlap_pending'] = False
    report['candidates'] += added
    return added


def decorate_payment_accounts(records):
    for r in records:
        accounts = r.get('payment_accounts', [])
        if len(accounts) != 1: continue
        for e in r.get('payment_events', []):
            e['payment_account'] = accounts[0]


def event_projection(events, accepted, rows=None):
    rows = rows or {}
    indexed = {e['id']: e for e in events}
    parents = {key: key for key in indexed}
    def find(key):
        while parents[key] != key:
            parents[key] = parents[parents[key]]
            key = parents[key]
        return key
    for c in accepted:
        keys = [k for k in c['record_ids'] + c['bank_ids'] if k in indexed]
        if len(keys) < 2:
            continue
        values = [indexed[k] for k in keys]
        kinds = {e['kind'] for e in values}
        if not (kinds <= {'payment', 'bank_debit'} or kinds <= {'refund', 'bank_credit'}):
            continue
        if len({e['amount_cents'] for e in values}) != 1:
            continue
        roots = {find(k) for k in keys}
        members = [e for k, e in indexed.items() if find(k) in roots]
        # Two orders/wallet occurrences on one route are separate events,
        # even when a shared bank settlement has been confirmed.
        if max(Counter(e['source'] for e in members).values()) > 1:
            continue
        for k in keys[1:]:
            parents[find(k)] = find(keys[0])
    groups = defaultdict(list)
    for key, event in indexed.items():
        groups[find(key)].append(event)
    result = []
    for values in groups.values():
        preferred = sorted(values, key=lambda e: ({'meituan': 0, 'wechat': 1, 'alipay': 1, 'unionpay': 2, 'bank': 3}.get(e['source'], 4), e['id']))[0]
        event = dict(preferred)
        event['evidence_keys'] = sorted(e['id'] for e in values)
        event['sources'] = sorted({e['source'] for e in values})
        if len(values) > 1:
            event['status'] = '同一次退款' if event['kind'] in ('refund', 'bank_credit') else '同一次付款'
        methods = {rows.get(e['id'], {}).get('payment_method') for e in values}
        apple_pay = 'ApplePay' in methods or any(e['source'] == 'bank' and 'APPLE PAY' in e['status'].upper() for e in values)
        method = 'ApplePay' if apple_pay else rows.get(preferred['id'], {}).get('payment_method')
        if method and method.startswith('云闪付-'):
            method = '云闪付'
        if method in ('ApplePay', '微信支付', '支付宝支付', '云闪付'):
            event['source'] = method
        roles = {'meituan': '美团下单', 'unionpay': '云闪付记账' if apple_pay else '云闪付记录', 'bank': '银行入账',
                 'wechat': '微信支付记录', 'alipay': '支付宝支付记录'}
        if len(values) > 1:
            event['status'] += ' · ' + ' · '.join(roles.get(s, s) for s in event['sources'])
        result.append(event)
    return sorted(result, key=lambda e: (e['date'], e['id']))


def reconcile_settlements(records, report, state, overrides, excluded_ids=(), previous=None):
    previous = {r['id']: r for r in (previous or [])}
    if not any(has_resolved_funding(b) for b in report['bank_records']):
        return records, []
    rows = {c['cluster_id']: c['representative'] for c in report['clusters']}
    conflicts = {c['cluster_id'] for c in report['clusters'] if c.get('conflicting_fields') or c.get('status_order_unresolved')}
    banks = {f"bank:{b['id']}": b for b in report['bank_records']}
    protected_targets = {v['transaction_facts'].get('targetID') for v in overrides.values()
                         if isinstance(v, dict) and isinstance(v.get('transaction_facts'), dict)}
    purchases, bank_sets = defaultdict(list), defaultdict(list)
    for record in records:
        if record['id'] in excluded_ids:
            continue
        keys = record['evidence_keys']
        if len(keys) == 1 and keys[0] in banks:
            b = banks[keys[0]]
            if (not b['is_credit'] and b.get('reconciliation_eligible', True) and b.get('currency') == 'CNY'
                    and has_resolved_funding(b)
                    and 'MEITUAN' in b['description'].upper() and 'APPLE PAY' in b['description'].upper()):
                bank_sets[(b['funding_account_id'], record['date'], b['amount_cents'], b['currency'])].append(record)
        if any(k in banks or k in conflicts for k in keys) or len(record['components']) != 1:
            continue
        source = [rows[k] for k in keys if k in rows]
        if Counter(r['platform'] for r in source) != Counter({'meituan': 1, 'unionpay': 1}):
            continue
        order = next(r for r in source if r['platform'] == 'meituan')
        wallet = next(r for r in source if r['platform'] == 'unionpay')
        if (order.get('payment_method') != 'ApplePay' or not has_resolved_funding(wallet)
                or not wallet.get('visually_verified_funding') or not wallet.get('profile_identity_verified')
                or not wallet.get('owner_id') or any(r.get('owner_id') not in (None, wallet['owner_id']) for r in source)
                or wallet.get('date_basis') == 'year_label_conflicts_weekday'
                or order['current_payment_state'] != 'successful'
                or wallet['current_payment_state'] not in ('successful', 'unknown')
                or any(r['event_kind'] != 'payment' or r.get('currency') != 'CNY' for r in source)
                or wallet.get('platform_reported_amount_cents') != order.get('platform_paid_amount_cents')):
            continue
        c = record['components'][0]
        if c['refund_cents'] or c['gross_cents'] <= 0:
            continue
        purchases[(wallet['funding_account_id'], record['date'], c['gross_cents'], wallet['currency'])].append(record)
    removed, groups = set(), []
    for bucket, orders in purchases.items():
        shadows = bank_sets[bucket]
        if len(orders) < 2 or len(orders) != len(shadows):
            continue
        keys = {k for r in orders + shadows for k in r['evidence_keys']}
        account, day, cents, currency = bucket
        # Check the complete source bucket too: an unlinked third order or
        # funding observation may never have generated a bank candidate.
        competing_rows = [k for k, r in rows.items() if k not in keys and
            r['transaction_time'][:10] == day and r.get('currency') == currency and
            r['event_kind'] == 'payment' and r['current_payment_state'] != 'cancelled' and
            (r.get('platform_paid_amount_cents') if r.get('platform_paid_amount_cents') is not None
             else r.get('platform_reported_amount_cents')) == cents and
            ((r['platform'] == 'meituan' and r.get('payment_method') == 'ApplePay') or
             (r['platform'] == 'unionpay' and has_resolved_funding(r) and r['funding_account_id'] == account and
              ('美团' in ((r.get('merchant') or '') + (r.get('title') or '')) or
               'MEITUAN' in ((r.get('merchant') or '') + (r.get('title') or '')).upper())))]
        if competing_rows:
            continue
        bank_keys = sorted(k for r in shadows for k in r['evidence_keys'])
        group_id = digest('bank-settlement-set-v1', sorted(keys))
        def previously_settled(record):
            old = previous.get(record['id'], {})
            return (old.get('bank_settlement_group', {}).get('id') == group_id and
                old.get('events') == record['events'] and old.get('date') == record['date'] and
                [(c['id'], c['gross_cents'], c['refund_cents']) for c in old.get('components', [])] ==
                [(c['id'], c['gross_cents'], c['refund_cents']) for c in record['components']])
        owner = {rows[k]['owner_id'] for r in orders for k in r['evidence_keys']
                 if rows[k].get('owner_id')}
        if len(owner) != 1 or any(banks[k].get('owner_id') not in (None, next(iter(owner))) for k in bank_keys):
            continue
        # Human bank classification and fact decisions must never disappear.
        if any(k in overrides for k in bank_keys) or any(
                (overrides.get('transaction:' + r['id'], {}).get('transaction_facts') and not previously_settled(r)) or
                ((r['id'] in protected_targets or any(c['id'] in protected_targets for c in r['components'])) and not previously_settled(r))
                for r in orders + shadows):
            continue
        # Incomplete candidate sets, foreign competitors and human rejections
        # prevent collective allocation just as they prevent individual pairing.
        if any((set(c['record_ids'] + c['bank_ids']) & keys) and
               (c.get('association_status') == 'rejected_by_user' or not set(c['record_ids'] + c['bank_ids']) <= keys)
               for c in report['candidates'] if c.get('review_required', True) or c.get('association_status') == 'rejected_by_user'):
            continue
        group = {'id': group_id, 'date': day,
                 'amount_cents_each': cents, 'count': len(orders), 'currency': currency,
                 'purchase_ids': sorted(r['id'] for r in orders), 'bank_keys': bank_keys,
                 'basis': '同日、同币种、同卡片、美团ApplePay路由、金额及笔数完全一致；银行无时间，未指定单笔配对'}
        for record in orders:
            record['bank_settlement_group'] = group
            record['evidence_keys'] = sorted(set(record['evidence_keys']) | set(bank_keys))
            c = record['components'][0]
            reasons = [s for s in c['reason'].split('；') if s and s not in (
                '订单与已有支付记录可能重叠', '与已覆盖银行账户的关联待确定', '录屏记录与已有来源的关联待确定')]
            c['reason'] = '；'.join(reasons)
            c['included'] = not reasons and not record['non_consumption'] and record['date'] <= report['backfill_cutoff_date']
        removed.update(r['id'] for r in shadows)
        groups.append(group)
    return [r for r in records if r['id'] not in removed], groups
