"""Scoped source ownership and visual payment reconciliation; never runs OCR.

The visual manifest retains occurrences (including indistinguishable refunds).
Only explicit funding routes or a visually verified route can reach a bank row.
"""
import argparse
import csv
import json
import re
from collections import Counter, defaultdict
from datetime import datetime
from decimal import Decimal
from pathlib import Path

try:
    from .payment_evidence import digest, has_resolved_funding, make_observation
    from .payment_materials import snapshot, write_asset
except ImportError:
    from payment_evidence import digest, has_resolved_funding, make_observation
    from payment_materials import snapshot, write_asset


def channel(text):
    text = (text or '').upper()
    for name, pattern in [('rail', r'铁路|\bTL CHN'), ('meituan', r'美团|MEITUAN'),
                          ('eleme', r'淘宝闪购|饿了么|拉扎斯|ELEME'),
                          ('jd', r'京东|JINGDONG'), ('pdd', r'拼多多|PINDUODUO'),
                          ('red', r'小红书|RED BOOK'),
                          ('qunar', r'去哪儿')]:
        if re.search(pattern, text): return name
    return None


def compatible(a, b):
    ca, cb = channel(a), channel(b)
    return not ca or not cb or ca == cb


def amount(row):
    return row.get('platform_paid_amount_cents') if row.get('platform_paid_amount_cents') is not None else row.get('platform_reported_amount_cents')


def times(row):
    return [datetime.fromisoformat(row[k]) for k in ('transaction_time', 'success_time')
            if row.get(k) and len(row[k]) >= 16]


def explicit_refund_pairs(rows):
    original = defaultdict(list)
    for key, r in rows.items():
        if r['event_kind'] == 'payment':
            for field in ('provider_reference', 'merchant_reference'):
                if r.get(field): original[(r['platform'], field, r[field])].append(key)
    pairs = []
    for key, r in rows.items():
        if r['event_kind'] != 'refund': continue
        matches = set(); reference = r.get('provider_reference') or ''
        if r['platform'] == 'alipay' and '_' in reference:
            matches.update(original[('alipay', 'provider_reference', reference.split('_', 1)[0])])
        if r.get('merchant_reference'):
            matches.update(original[(r['platform'], 'merchant_reference', r['merchant_reference'])])
        if len(matches) != 1: continue
        target = next(iter(matches)); p = rows[target]
        if p['transaction_time'] > r['transaction_time']: continue
        if r.get('owner_id') and p.get('owner_id') and r['owner_id'] != p['owner_id']: continue
        if r.get('source_profile_id') and p.get('source_profile_id') and r['source_profile_id'] != p['source_profile_id']: continue
        pairs.append((key, target))
    return pairs


def import_visual(root, output, table, *, source_path, funding_method, origin_namespace="visual-source-v1"):
    root, output, table = Path(root), Path(output), Path(table)
    source_path = Path(source_path)
    if not funding_method: raise ValueError('visual funding method must be explicitly supplied')
    existing = output / 'supplemental-evidence-imports' / (snapshot(source_path, output)['sha256'] + '.json')
    if existing.exists(): raise ValueError('retained visual origins require explicit adoption; refusing to rewrite them')
    source, annotation = snapshot(source_path, output), snapshot(table, output)
    state = json.loads((output / 'review-state.json').read_text())
    owner = state.get('source_owner_confirmations', {}).get(source['sha256'])
    if not owner: raise ValueError('录屏来源用户尚未确认')
    observations, materials = [], []
    for index, (frame, day, minute, value, merchant) in enumerate(csv.reader(table.open(), delimiter='\t')):
        frame_path = table.parent / (f'frames/frame-{int(frame):03d}.jpg' if frame.isdigit() else frame + '.jpg')
        frame_asset = snapshot(frame_path, output)
        cents = abs(int(Decimal(value) * 100)); refund = Decimal(value) > 0
        # index is part of the key: two identical displayed refunds are two events.
        key = digest(origin_namespace, source['sha256'], index, day, minute, value, merchant)
        cluster = 'unionpay:' + key
        literal = f'{day} {minute} {merchant} {value} {funding_method}'
        raw = {'原始文字': literal, '当前状态': '退款' if refund else '账单支出', '收/支': '收入' if refund else '支出'}
        evidence = {'kind': 'video_frame', 'source': source, 'image': frame_asset, 'frame': frame_asset,
                    'annotation_snapshot': annotation, 'crop_complete': False,
                    'locator': {'frame_reference': frame, 'row_occurrence': index, 'date_basis': 'visible_date_context',
                                'boundaries': 'full_frame_retained', 'reading_method': 'direct_visual_no_local_ocr'}}
        evidence['raw'] = write_asset(output, f'materials/records/{key}/record.json',
            json.dumps({'raw': raw, 'source': source, 'frame': frame_asset, 'locator': evidence['locator']}, ensure_ascii=False, indent=2))
        row = make_observation('unionpay', source_path.name, source['sha256'], index,
            {'owner_id': owner['user_id'], 'source_profile_id': None, 'observed_at': None,
             'ownership_basis': owner['basis'], 'profile_identity_verified': True}, raw,
            timestamp=day + ' ' + minute, success_time=None, amount=cents, order_amount=None, paid_amount=None,
            reference=key, merchant_reference=None, merchant=merchant, title=merchant, method=funding_method,
            direction=raw['收/支'], status=raw['当前状态'])
        row.update(event_kind='refund' if refund else 'payment', source_evidence=evidence,
                   video_overlap_pending=True, date_basis='visible_date_context', reading_method='direct_visual_no_local_ocr',
                   visually_verified_funding=True)
        observations.append({'cluster_id': cluster, 'representative': row})
        materials.append({'id': cluster, 'platform': 'unionpay', 'title': merchant, 'date': row['transaction_time'],
                          'amount_cents': cents, 'status': raw['当前状态'], 'date_basis': 'visible_date_context', 'source_evidence': evidence})
    verification_path = table.parent / 'monthly-verification.json'
    monthly_verified = False
    verification_asset = None
    if verification_path.exists():
        verification = json.loads(verification_path.read_text())
        totals = defaultdict(lambda: [0, 0, 0])
        for item in observations:
            r = item['representative']; values = totals[r['transaction_time'][:7]]
            values[r['event_kind'] == 'refund'] += amount(r); values[2] += 1
        monthly_verified = bool(verification.get('amount_totals_match')) and all(
            totals[m['month']] == [m['observed_month_debit_cents'], m['observed_month_refund_cents'], m['row_count']]
            for m in verification['months']) and set(totals) == {m['month'] for m in verification['months']}
        if not monthly_verified: raise ValueError('视觉标注与月度核验合计不一致')
        verification_asset = snapshot(verification_path, output)
    dates = sorted(item['representative']['transaction_time'][:10] for item in observations)
    result = {'observations': observations, 'links': [], 'materials': materials,
              'summary': dict(raw_complete_crops=0, deduplicated_materials=len(observations), wallet_links=0, unparsed_crops=0, undated_materials=0),
              'visual_reading': {'method': 'direct_visual_no_local_ocr', 'scope': [dates[0], dates[-1]] if dates else [],
                                 'full_source_retained': True, 'full_recording_row_recall_verified': False,
                                 'visual_scan_complete': monthly_verified, 'monthly_amount_totals_verified': monthly_verified,
                                 'monthly_verification': verification_asset,
                                 'verification_basis': '逐笔金额方向及行数与视觉月度核验一致；全量召回概率未测量'}}
    folder = output / 'supplemental-evidence-imports'; folder.mkdir(exist_ok=True)
    (folder / (source['sha256'] + '.json')).write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    imports = [json.loads(p.read_text()) for p in sorted(folder.glob('*.json'))]
    merged = {k: [r for item in imports for r in item[k]] for k in ('observations', 'links', 'materials')}
    merged['summary'] = {k: sum(item['summary'][k] for item in imports) for k in result['summary']}
    (output / 'supplemental-evidence.json').write_text(json.dumps(merged, ensure_ascii=False, indent=2) + '\n')
    return len(observations)


def reconcile(report, state):
    rows = {c['cluster_id']: c['representative'] for c in report['clusters']}
    conflicts = {c['cluster_id'] for c in report['clusters'] if c.get('conflicting_fields') or c.get('status_order_unresolved')}
    banks = {f"bank:{b['id']}": b for b in report['bank_records']}
    parents = {key: key for key in rows | banks}
    root_owners = {k: {r['owner_id']} if r.get('owner_id') else set() for k, r in (rows | banks).items()}
    root_banks = {k: {k} if k in banks else set() for k in parents}
    row_times = {k: times(r) for k, r in rows.items()}
    def find(key):
        while parents[key] != key:
            parents[key] = parents[parents[key]]; key = parents[key]
        return key
    def merge(keys):
        target = find(keys[0])
        for key in keys[1:]:
            source = find(key)
            if source != target:
                parents[source] = target
                root_owners[target].update(root_owners.pop(source))
                root_banks[target].update(root_banks.pop(source))
    def assign_bank_owner(key, evidence, basis):
        owners = {rows[k].get('owner_id') for k in evidence if rows[k].get('owner_id') and rows[k].get('profile_identity_verified')}
        if len(owners) != 1: return
        owner = next(iter(owners))
        if banks[key].get('owner_id') not in (None, owner): return
        banks[key].update(owner_id=owner, ownership_basis=basis, ownership_evidence_keys=evidence)
        root_owners[find(key)].add(owner)
    for c in report['candidates']:
        if not c['review_required'] and c['association_status'] in ('supported_by_user', 'rule_supported'):
            merge(c['record_ids'] + c['bank_ids'])
    # These are lifecycle relationships, not event identity. They are used
    # here only to guard new associations against merging independent purchases.
    for c in report.get('confirmed_bank_refund_links', []):
        keys = [c['original']] + c['refunds']
        if all(k in parents for k in keys): merge(keys)
    for refund, original in explicit_refund_pairs(rows): merge([refund, original])
    added = []
    forbidden = [c['record_ids'] + c['bank_ids'] for c in report['candidates'] if c.get('association_status') == 'rejected_by_user']
    withheld = []
    def add(keys, bank_keys, basis):
        roots = {find(k) for k in keys + bank_keys}
        owners = set().union(*(root_owners[root] for root in roots))
        if len(owners) > 1:
            withheld.append({'record_ids': keys, 'bank_ids': bank_keys, 'reason': 'owner_conflict'}); return False
        if any(len(pair) >= 2 and {find(k) for k in pair}.issubset(roots) for pair in forbidden):
            withheld.append({'record_ids': keys, 'bank_ids': bank_keys, 'reason': 'existing_human_rejection'}); return False
        if len(roots) == 1: return True
        c = {'candidate_id': digest('source-reconciliation-v1', sorted(keys), sorted(bank_keys), basis),
             'kind': 'source_reconciliation', 'record_ids': keys, 'bank_ids': bank_keys,
             'review_required': False, 'association_status': 'rule_supported', 'basis': basis}
        added.append(c); merge(keys + bank_keys)
        return True
    # Alipay's family-card beneficiary export says 不计收支. The payer's
    # merchant reference points exactly to the beneficiary order, making the
    # consumer and funding observations identifiable across account profiles.
    family_index = defaultdict(list)
    for key, r in rows.items():
        if key not in conflicts and r['platform'] == 'alipay' and '亲情卡' in (r.get('title') or ''):
            family_index[r.get('merchant_reference')].append(key)
    family_proposals = []
    for key, r in rows.items():
        if key in conflicts or r['platform'] != 'alipay' or '亲情卡' not in (r.get('payment_method') or ''): continue
        if r['event_kind'] not in ('payment', 'refund'): continue
        if r['current_payment_state'] == 'cancelled': continue
        refund = r['event_kind'] == 'refund'
        if not refund and r['current_payment_state'] != 'successful': continue
        reference = r.get('provider_reference') or ''
        if refund: reference = reference.split('_', 1)[0]
        choices = [k for k in family_index[reference] if k != key and rows[k]['event_kind'] == ('refund' if refund else 'payment')
                   and bool(rows[k].get('owner_id') or r.get('owner_id'))
                   and (not rows[k].get('owner_id') or not r.get('owner_id') or rows[k]['owner_id'] == r['owner_id'])
                   and amount(rows[k]) == amount(r) and rows[k].get('currency') == r.get('currency')
                   and rows[k]['current_payment_state'] != 'cancelled' and row_times[key] and row_times[k]
                   and min(abs((a-b).total_seconds()) for a in row_times[key] for b in row_times[k]) <= (2 if refund else 300)]
        if len(choices) == 1: family_proposals.append((key, choices[0]))
    family_reverse = Counter(target for _, target in family_proposals)
    for key, target in family_proposals:
        if family_reverse[target] > 1:
            rows[key]['settlement_overlap_pending'] = True
            withheld.append({'record_ids': [key, target], 'bank_ids': [], 'reason': 'competing_family_settlements'}); continue
        if add([key, target], [], '亲情卡付款人商家订单号明确指向消费人交易订单号，金额方向及支付时间一致'):
            rows[key]['duplicate_settlement_key'] = target
    confirmed = any(has_resolved_funding(b) for b in banks.values())
    bank_index = defaultdict(list)
    for key, b in banks.items():
        if has_resolved_funding(b) and b.get('reconciliation_eligible', True):
            bank_index[(b['funding_account_id'], b['date'], b['amount_cents'], bool(b['is_credit']))].append(key)
    # An explicit 已配置资金账户 route from the user-confirmed source is sufficient only
    # with a unique allocation and compatible merchant routing.
    if confirmed:
        for c in report['candidates']:
            if c.get('human_review') or c.get('active_competing_candidate_ids') or c.get('kind') != 'wallet_bank': continue
            r = rows[c['record_ids'][0]]
            if not r.get('owner_id') or not r.get('profile_identity_verified') or not has_resolved_funding(r): continue
            b = banks[c['bank_ids'][0]]
            if not has_resolved_funding(b) or b['funding_account_id'] != r['funding_account_id'] or root_owners[find(c['bank_ids'][0])] - {r['owner_id']}: continue
            if compatible((r.get('merchant') or '') + ' ' + (r.get('title') or ''), b['description']):
                c.update(review_required=False, association_status='rule_supported', basis='用户确认来源归属、明确已配置资金账户资金来源及唯一银行记录')
                merge(c['record_ids'] + c['bank_ids'])
        # Visual rows discriminate simultaneous equal amounts by merchant route.
        visual_groups = defaultdict(list)
        for key, r in rows.items():
            if r.get('visually_verified_funding') and has_resolved_funding(r):
                visual_groups[(r['funding_account_id'], r['transaction_time'][:10], amount(r), r['event_kind'] == 'refund', channel(r['merchant']))].append(key)
        proposals, incidence = [], defaultdict(list)
        for (account, day, cents, credit, route), keys in visual_groups.items():
            choices = [k for k in bank_index[(account, day, cents, credit)] if compatible(rows[keys[0]]['merchant'], banks[k]['description'])]
            proposals.append((keys, choices, credit))
            for k in choices: incidence[k].append(len(proposals)-1)
        for i, (keys, choices, credit) in enumerate(proposals):
            # An aggregator bank row cannot be consumed independently by two
            # visual merchant groups, even if each group appears locally unique.
            if any(len(incidence[k]) > 1 for k in choices):
                withheld.append({'record_ids': keys, 'bank_ids': choices, 'reason': 'competing_visual_allocations'}); continue
            if len(keys) == len(choices) == 1:
                if add(keys, choices, '视觉可见已配置资金账户、日期金额方向与商户路由，双向唯一'):
                    rows[keys[0]]['video_overlap_pending'] = False
            elif not credit and len(keys) == len(choices) > 1:
                # Bank exports have no time. The complete matching multiset
                # establishes ownership of every occurrence, but cannot pair
                # individual seconds. Keep separate purchases and bank rows.
                owners = set().union(*(root_owners[find(k)] for k in choices + keys))
                if len(owners) != 1: continue
                for k in choices:
                    assign_bank_owner(k, keys, '视觉支出与银行等量多重集合，单笔配对未确认')
            elif credit and len(keys) == len(choices) > 1 and len({rows[k]['transaction_time'] for k in keys}) == 1:
                # A matching multiset proves account ownership, not which
                # credit belongs to which purchase. Preserve every occurrence
                # and every existing original/refund relationship separately.
                roots = {find(k) for k in choices + keys}
                owners = set().union(*(root_owners[root] for root in roots))
                if len(owners) != 1: continue
                for k in choices:
                    assign_bank_owner(k, keys, '视觉退款与银行等量多重集合，单笔及原交易配对未确认')
                withheld.append({'record_ids': keys, 'bank_ids': choices, 'reason': 'refund_pairing_ambiguous'})
    # Match order to same user's settlement. Repeated source descriptions already
    # joined to a bank record are one candidate target, not artificial competitors.
    index = defaultdict(list)
    for key, r in rows.items():
        if key not in conflicts and r['event_kind'] in ('payment', 'refund') and r['current_payment_state'] != 'cancelled':
            index[(r['transaction_time'][:10], amount(r), r['event_kind'])].append(key)
    proposals = []
    for key, r in rows.items():
        if key in conflicts or not r.get('owner_id') or r['platform'] != 'meituan' or r['current_payment_state'] == 'cancelled': continue
        method = r.get('payment_method')
        platforms = {'微信支付': {'wechat'}, '支付宝支付': {'alipay'}, 'ApplePay': {'unionpay'}, '云闪付': {'unionpay'}}.get(method, set())
        opts = []
        for k in index[(r['transaction_time'][:10], amount(r), r['event_kind'])]:
            s = rows[k]
            if s['platform'] not in platforms or s.get('owner_id') not in (None, r.get('owner_id')) or channel((s.get('merchant') or '') + ' ' + (s.get('title') or '')) != 'meituan': continue
            rt, st = row_times[key], row_times[k]
            if not rt or not st: continue
            delta = min(abs((a-b).total_seconds()) for a in rt for b in st)
            if delta <= (60 if s['platform'] == 'unionpay' else 2): opts.append(k)
        # A displayed minute represents a 60-second interval, not its first
        # second. Prefer an exact minute before permitting adjacent-minute lag.
        exact = [k for k in opts if any(a.strftime('%Y-%m-%d %H:%M') == b.strftime('%Y-%m-%d %H:%M')
                                      for a in row_times[key] for b in row_times[k])]
        if exact: opts = exact
        targets = {find(k) for k in opts}
        # Unknown ownership is an unresolved competitor, never proof that the
        # remaining known user's settlement is unique. It cannot supply a match.
        if len(targets) == 1 and root_owners[next(iter(targets))] == {r['owner_id']}:
            proposals.append((key, opts))
    reverse = defaultdict(set)
    for key, opts in proposals: reverse[find(opts[0])].add(find(key))
    for key, opts in proposals:
        if len(reverse[find(opts[0])]) == 1:
            add([key] + opts, [], '同一已确认用户、支付方式、金额方向、美团商户与唯一支付时间')
    # Bridge retained visuals only within the same resolved funding account and
    # currency. Existing independent bank occurrences remain separate.
    bridge_proposals = []
    bridge_index = defaultdict(list)
    for bucket, keys in index.items():
        bridge_index[bucket] = [k for k in keys if not rows[k].get('visually_verified_funding') and rows[k]['platform'] != 'meituan']
    for key, r in rows.items():
        if not r.get('visually_verified_funding') or not has_resolved_funding(r): continue
        candidates = []
        for k in bridge_index[(r['transaction_time'][:10], amount(r), r['event_kind'])]:
            s = rows[k]
            if k == key or s.get('visually_verified_funding') or s['platform'] == 'meituan' or s.get('owner_id') not in (None, r.get('owner_id')): continue
            if not has_resolved_funding(s) or s['funding_account_id'] != r['funding_account_id'] or s.get('currency') != r.get('currency'): continue
            if not compatible(r['merchant'], (s.get('merchant') or '') + ' ' + (s.get('title') or '')): continue
            rt, st = row_times[key], row_times[k]
            if rt and st and min(abs((a-b).total_seconds()) for a in rt for b in st) <= 60: candidates.append(k)
        targets = {find(k) for k in candidates}
        if len(targets) == 1 and candidates:
            bridge_proposals.append((key, candidates, next(iter(targets))))
    bridge_reverse = defaultdict(set)
    for key, _, root in bridge_proposals: bridge_reverse[root].add(find(key))
    for key, candidates, root in bridge_proposals:
        if len(bridge_reverse[root]) > 1:
            withheld.append({'record_ids': [key] + candidates, 'bank_ids': [], 'reason': 'competing_visual_bridge'}); continue
        if candidates:
            target_banks = root_banks[find(root)]
            own_banks = root_banks[find(key)]
            # No independent bank occurrence may be collapsed into another.
            if (not target_banks or not own_banks or target_banks == own_banks):
                linked = add([key] + candidates, [], '视觉记录与相同账户支付的日期金额方向、商户及唯一分钟匹配')
                if linked and (target_banks or own_banks):
                    for k in [key] + candidates: rows[k]['video_overlap_pending'] = False
    report['candidates'] += added
    report['reconciliation_withheld'] = withheld
    report['reconciliation_summary'] = {'withheld_count': len(withheld), 'withheld_reasons': dict(Counter(w['reason'] for w in withheld)), 'added_links': len(added), 'owned_source_records': sum(bool(r.get('owner_id')) for r in rows.values()),
        'bank_owned_by_multiset': sum(b.get('ownership_evidence_keys') is not None for b in banks.values())}
    return added


def account_identity(records, rows, banks, state=None):
    unresolved = []
    for r in records:
        evidence = {**rows, **banks}
        known = {evidence[k]['funding_account_name'] for k in r['evidence_keys']
                 if k in evidence and has_resolved_funding(evidence[k])}
        methods = sorted({rows[k].get('payment_method') or '' for k in r['evidence_keys'] if k in rows and rows[k]['event_kind'] == 'payment'})
        r['payment_accounts'] = sorted(known)
        r['payment_account_status'] = 'identified' if known else 'not_applicable' if r['non_consumption'] or sum(c['gross_cents'] for c in r['components']) == 0 else 'unresolved'
        if not known and not r['non_consumption'] and any(e['kind'] == 'payment' for e in r['events']) and sum(c['gross_cents'] for c in r['components']) > 0:
            unresolved.append({'id': r['id'], 'date': r['date'], 'user': r.get('user_id'), 'title': r['title'],
                'gross_cents': sum(c['gross_cents'] for c in r['components']), 'net_cents': sum(c['net_cents'] for c in r['components']),
                'status': r['status'], 'payment_methods': methods, 'evidence_keys': r['evidence_keys'],
                'reason': '支付通道存在，具体支付账户尚未确定' if any(methods) else '来源未提供支付账户',
                'within_cutoff': r['date'] <= max((b['date'] for b in banks.values()), default='')})
    return unresolved


if __name__ == '__main__':
    p = argparse.ArgumentParser(); p.add_argument('--root', type=Path, required=True); p.add_argument('--output', type=Path, required=True); p.add_argument('--table', type=Path, required=True)
    p.add_argument('--source', type=Path, required=True); p.add_argument('--funding-method', required=True)
    a = p.parse_args(); print(import_visual(a.root, a.output, a.table, source_path=a.source, funding_method=a.funding_method))
