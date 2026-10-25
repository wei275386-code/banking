"""Read-only discovery of complete network/card source sets for review.

The result is evidence-bound input to source_record_sets.apply, not an automatic
refund allocation or an arbitrary pairing of equal bank occurrences.
"""
import argparse
import copy
from collections import defaultdict
import json
from pathlib import Path
import re

try:
    from .payment_evidence import digest
    from .account_consolidation import canonical, load_policy
    from .source_reconciliation import channel
    from .source_record_sets import apply, set_signature
except ImportError:
    from payment_evidence import digest
    from account_consolidation import canonical, load_policy
    from source_reconciliation import channel
    from source_record_sets import apply, set_signature


def mapped_account(method, policy):
    # Funding identity comes from an approved account policy, never from equal
    # suffixes, amounts, or an implicit 0732-specific rule.
    if not policy or not method or not re.search(r'\d{4}', str(method)):
        return None
    value = canonical(str(method), policy)
    return value if value in policy['canonical_accounts'] else None


def discover(financial, report, overrides, policy=None):
    def account(method):
        return mapped_account(method, policy)
    rows = {c['cluster_id']: c['representative'] for c in report['clusters']}
    conflicts = {c['cluster_id'] for c in report['clusters'] if c.get('conflicting_fields') or c.get('status_order_unresolved')}
    banks = {f"bank:{b['id']}": b for b in report['bank_records']}
    by_key = {e: r for r in financial['records'] for e in r['evidence_keys']}
    network, card = defaultdict(list), defaultdict(list)
    raw_network = defaultdict(set)
    foreign = defaultdict(set)
    for key, row in rows.items():
        funding = account(row.get('payment_method'))
        amount = row.get('platform_paid_amount_cents') if row.get('platform_paid_amount_cents') is not None else row.get('platform_reported_amount_cents')
        if row['platform'] == 'unionpay' and funding:
            raw_network[(funding, row['transaction_time'][:10], row.get('platform_reported_amount_cents'), row['event_kind'], row.get('currency'))].add(key)
        elif row['platform'] != 'unionpay':
            # Unknown funding is still a competing observation. Index once,
            # instead of rescanning every imported source for each bucket.
            foreign[(row['transaction_time'][:10], amount, row['event_kind'], row.get('currency'))].add(key)
    for record in financial['records']:
        for e in record['events']:
            if e['id'] in banks:
                b = banks[e['id']]
                funding = account(str(b['account_number']).replace(' ', '')[-4:])
                if funding and b.get('reconciliation_eligible', True):
                    card[(funding, e['date'][:10], e['amount_cents'], 'refund' if b['is_credit'] else 'payment', b.get('currency'))].append((record, e))
            elif e['id'] in rows and len(record['events']) == len(record['evidence_keys']) == 1:
                row = rows[e['id']]
                funding = account(row.get('payment_method'))
                if row['platform'] == 'unionpay' and funding and e['kind'] in ('payment', 'refund'):
                    network[(funding, e['date'][:10], e['amount_cents'], e['kind'], row.get('currency'))].append((record, e))
    candidates, unresolved = [], []
    for bucket, sources in sorted(network.items(), key=lambda item: tuple('' if value is None else str(value) for value in item[0])):
        targets = card[bucket]
        if not targets:
            continue
        funding, day, cents, kind, currency = bucket
        source_keys = {e['id'] for _, e in sources}
        target_keys = {e['id'] for _, e in targets}
        all_keys = source_keys | target_keys
        reasons = []
        if not currency or cents is None or cents <= 0 or len(sources) != len(targets) or source_keys != raw_network[bucket]:
            reasons.append('币种金额或完整集合笔数不一致')
        if any(key in conflicts or not rows[key].get('visually_verified_funding') or not rows[key].get('profile_identity_verified')
               or not rows[key].get('owner_id') or rows[key].get('date_basis') == 'year_label_conflicts_weekday' for key in source_keys):
            reasons.append('银联资金来源、身份或日期未核实')
        owners = {r.get('user_id') for r, _ in sources + targets}
        if len(owners) != 1 or None in owners:
            reasons.append('交易消费人不一致或未明确')
        for record, _ in sources + targets:
            facts = (overrides.get('transaction:' + record['id'], {}).get('transaction_facts') or {})
            if ((facts.get('date') and facts['date'] != record['date']) or
                    (facts.get('userID') and facts['userID'] != record.get('user_id')) or
                    (facts.get('account') and account(facts['account']) != funding)):
                reasons.append('人工日期、消费人或账户更正与来源集合不一致')
                break
        routes = {channel((rows[key].get('merchant') or '') + ' ' + (rows[key].get('title') or '')) for key in source_keys}
        bank_routes = {channel(banks[key]['description']) for key in target_keys}
        generic = all(banks[key]['description'].upper().startswith('UNIONPAY MERCHANT') for key in target_keys)
        if len(routes) != 1 or None in routes or (bank_routes != routes and not generic):
            reasons.append('商户路由不一致或银行商户不明')
        retained_ids = {r['id'] for r, _ in targets}
        def accepted_inside_retained(c):
            return (not c.get('review_required', True) and c.get('association_status') in ('rule_supported', 'supported_by_user')
                    and all(k in by_key and by_key[k]['id'] in retained_ids for k in c['record_ids'] + c['bank_ids']))
        if any((set(c['record_ids'] + c['bank_ids']) & all_keys) and
               (c.get('association_status') == 'rejected_by_user' or
                (not set(c['record_ids'] + c['bank_ids']) <= all_keys and not accepted_inside_retained(c)))
               for c in report['candidates']):
            reasons.append('人工拒绝或其他关联竞争')
        if any(key not in all_keys and (key not in by_key or by_key[key]['id'] not in retained_ids)
               for key in foreign[(day, cents, kind, currency)]):
            reasons.append('相同资金事件另有未归并来源')
        retained = {r['id']: r for r, _ in targets}
        shadows = {r['id']: r for r, _ in sources}
        link = dict(id=digest('reviewed-source-record-set-v1', sorted(all_keys)), kind=kind,
                    retained_ids=sorted(retained), shadow_ids=sorted(shadows),
                    basis=f'来源复查：{day} 同一已确认{funding}账户、币种、方向、金额和完整笔数的银联与银行双来源')
        if kind == 'refund':
            link['retained_event_keys'] = sorted(target_keys)
        link['signatures'] = {k: set_signature(r, link) for k, r in {**retained, **shadows}.items()}
        if not reasons:
            _, trial = apply([copy.deepcopy(r) for r in {**retained, **shadows}.values()], [link], overrides)
            if trial[0]['status'] != 'confirmed':
                reasons.append('现有生命周期结构或人工事实确认不允许归档')
        detail = dict(date=day, amount_cents=cents, kind=kind, network_count=len(sources), bank_count=len(targets),
                      account=funding, currency=currency, evidence_keys=sorted(all_keys), reasons=reasons,
                      automatic_eligible=not generic and not reasons)
        if reasons:
            unresolved.append({**detail, 'confirmation': link})
        else:
            candidates.append({**detail, 'confirmation': link})
    return dict(mapped_unlinked_lifecycles=sum(len(v) for v in network.values()), candidates=candidates, unresolved=unresolved)


def scan(output):
    output = Path(output)
    financial = json.loads((output / 'financial-review.json').read_text())
    report = json.loads((output / 'payment-evidence.json').read_text())
    for name in ('video-evidence.json', 'order-evidence.json', 'supplemental-evidence.json'):
        path = output / name
        if path.exists():
            source = json.loads(path.read_text())
            report['clusters'] += source['observations']; report['candidates'] += source['links']
    return discover(financial, report, json.loads((output / 'review-overrides.json').read_text()),
                    load_policy(Path(__file__).resolve().parents[1]))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(scan(args.output), ensure_ascii=False, indent=2))
