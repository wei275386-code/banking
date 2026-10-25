"""Display-only provenance. Never changes transaction identity or associations."""
from collections import defaultdict
import argparse
import copy
import json
from pathlib import Path

try:
    from .payment_evidence import has_resolved_funding, digest
except ImportError:
    from payment_evidence import has_resolved_funding, digest


def project(records, report, materials=()):
    rows = {c['cluster_id']: c['representative'] for c in report['clusters']}
    for material in materials:
        if material['id'] not in rows:
            rows[material['id']] = dict(platform=material.get('platform') or 'card',
                transaction_time=material.get('date', ''), title=material['title'],
                platform_reported_amount_cents=material.get('amount_cents'),
                event_kind='supporting_material', raw_status=material.get('status', ''),
                source_evidence=material.get('source_evidence'))
    banks = {f"bank:{b['id']}": b for b in report['bank_records']}
    observations = {**rows, **banks}
    pending = defaultdict(set)
    rejected = set()
    accepted_bank = defaultdict(set)
    for candidate in report['candidates']:
        keys = candidate['record_ids'] + candidate['bank_ids']
        if candidate['association_status'] in ('rejected_by_user', 'rejected'):
            rejected.update((a, b) for a in keys for b in keys)
        elif candidate['association_status'] in ('supported_by_user', 'rule_supported') and not candidate['review_required']:
            for key in candidate['record_ids']:
                accepted_bank[key].update(candidate['bank_ids'])
        else:
            for key in keys:
                pending[key].update(keys)
    # Previously unlinked recording observations remain search leads only.
    # Only explicit configured funding participates; raw observations stay leads.
    route_rows = defaultdict(list)
    for key, row in rows.items():
        if (row.get('platform') == 'unionpay' and has_resolved_funding(row)
                and row.get('owner_id') and row.get('currency', 'CNY') == 'CNY'
                and row.get('date_basis') != 'year_label_conflicts_weekday'
                and row.get('event_kind') in ('payment', 'refund')):
            route_rows[(row['funding_account_id'], row['transaction_time'][:10], row.get('platform_reported_amount_cents'),
                        row['event_kind'], row['owner_id'])].append(key)

    def source(key, association, basis):
        row = observations[key]
        bank = key in banks
        evidence = row.get('source_evidence')
        video = evidence and evidence.get('kind') == 'video_frame'
        locator = (evidence or {}).get('locator') or {}
        location = []
        if locator.get('page') is not None: location.append(f"第 {locator['page']} 页")
        if locator.get('record_ordinal') is not None: location.append(f"第 {locator['record_ordinal']} 条")
        if locator.get('frame_reference') is not None: location.append('录屏帧 ' + str(locator['frame_reference']))
        if locator.get('row_occurrence') is not None: location.append(f"记录 {locator['row_occurrence']}")
        return dict(id=key, association=association, basis=basis,
                    owner_id=row.get('owner_id'),
                    platform='bank' if bank else row['platform'],
                    date=row.get('date') if bank else row.get('transaction_time', ''),
                    post_date=row.get('post_date') if bank else row.get('success_time'),
                    merchant=row.get('description') if bank else row.get('merchant'),
                    title=row.get('description') if bank else row.get('title'),
                    amount_cents=row.get('amount_cents') if bank else row.get('platform_reported_amount_cents'),
                    currency=row.get('currency', 'CNY'),
                    payment_method=(row.get('funding_account_name') or '银行账户（未映射）') if bank else row.get('payment_method'),
                    event_kind=('bank_credit' if row['is_credit'] else 'bank_debit') if bank else row.get('event_kind'),
                    status=('贷记／收入方向' if row['is_credit'] else '银行扣款') if bank else row.get('raw_status', ''),
                    # Recording provider_reference is an internal digest, not an order number.
                    provider_reference=None if bank or video else row.get('provider_reference'),
                    merchant_reference=None if bank or video else row.get('merchant_reference'),
                    source_name=(row.get('statement_file') if bank else row.get('file_name')) or (evidence or {}).get('source', {}).get('original_name'),
                    location=' · '.join(location), source_evidence=evidence)

    for record in records:
        linked = set(record['evidence_keys'])
        group = record.get('source_record_set', {})
        linked.update(group.get('evidence_keys', []))
        reimbursement = record.get('reimbursement_link')
        if reimbursement:
            linked.update([reimbursement['payment'], reimbursement['receipt']])
        leads = set().union(*(pending[k] for k in linked)) - linked
        for key in linked & banks.keys():
            bank = banks[key]
            if (not has_resolved_funding(bank)
                    or not bank['description'].upper().startswith('UNIONPAY')):
                continue
            match = (bank['funding_account_id'], bank['date'], bank['amount_cents'], 'refund' if bank['is_credit'] else 'payment', record.get('user_id'))
            for row_key in route_rows[match]:
                if row_key not in linked and not (accepted_bank[row_key] - linked) and (key, row_key) not in rejected:
                    leads.add(row_key)
        leads = {k for k in leads if k in observations and not any((a, k) in rejected for a in linked)}
        record['trace_sources'] = [source(k, 'linked',
            group['basis'] + '；整组来源已确认，未指定逐笔配对' if k in group.get('evidence_keys', [])
            else '交易已关联的原始证据') for k in sorted(linked) if k in observations]
        record['trace_sources'] += [source(k, 'candidate',
            '现有待核关联候选，不代表已确认交易身份' if any(k in pending[a] for a in linked)
            else '日期、金额及账户路线相符；不代表已逐笔配对') for k in sorted(leads)]


def _refresh_locked(output):
    """Enrich the current projection without rerunning unrelated reconciliation."""
    import sqlite3
    output = Path(output)
    path = output / 'financial-review.json'
    original = path.read_bytes()
    financial = json.loads(original)
    before = copy.deepcopy(financial)
    report = json.loads((output / 'payment-evidence.json').read_text())
    for name in ('video-evidence.json', 'order-evidence.json', 'supplemental-evidence.json'):
        source = output / name
        if source.exists():
            video = json.loads(source.read_text())
            report['clusters'] += video['observations']; report['candidates'] += video['links']
    project(financial['records'], report, financial.get('video_materials', []))
    try:
        from .confirmed_transaction_corrections import restore_traces
    except ImportError:
        from confirmed_transaction_corrections import restore_traces
    restore_traces(financial)
    stripped = copy.deepcopy(financial)
    for document in (before, stripped):
        for record in document['records']: record.pop('trace_sources', None)
    assert before == stripped, 'Trace refresh changed financial facts'
    financial.pop('dataset_id', None)
    financial['dataset_id'] = digest(financial)
    if path.read_bytes() != original: raise RuntimeError('Projection changed during trace refresh; retry')
    backup = output / 'trace-refresh-before.json'
    if not backup.exists(): backup.write_bytes(original)
    with sqlite3.connect(output / 'financial-review.sqlite3') as db:
        db.execute('INSERT OR IGNORE INTO review_runs VALUES (?,?)', (financial['dataset_id'], json.dumps(financial, ensure_ascii=False)))
        db.executemany('UPDATE lifecycle_projection SET payload_json=? WHERE id=?',
                       [(json.dumps(r, ensure_ascii=False), r['id']) for r in financial['records']])
    temporary = path.with_suffix('.json.trace-tmp')
    temporary.write_text(json.dumps(financial, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)
    return {'records': len(financial['records']), 'trace_sources': sum(len(r['trace_sources']) for r in financial['records']),
            'financial_facts_unchanged': True, 'dataset_id': financial['dataset_id']}


def refresh(output):
    import fcntl
    with (Path(output) / '.review-processor.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        return _refresh_locked(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(refresh(args.output), ensure_ascii=False))
