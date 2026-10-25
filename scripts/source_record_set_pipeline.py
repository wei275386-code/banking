"""Evidence-bound, reversible network/card source projection for every import.

Source identity does not allocate a refund. Bank anchors and their human fact
decisions remain intact; one field-synced decision controls a complete set.
"""
import copy

try:
    from .audit_source_record_sets import discover, mapped_account
    from .payment_evidence import digest
    from .source_record_sets import apply, set_signature
except ImportError:
    from audit_source_record_sets import discover, mapped_account
    from payment_evidence import digest
    from source_record_sets import apply, set_signature

MATCHING_RULE = 'source-record-sets'


def reconcile(records, report, state, overrides, policy, protected_record_ids=()):
    indexed = {r['id']: r for r in records}
    rows = {c['cluster_id']: c['representative'] for c in report['clusters']}
    banks = {f"bank:{b['id']}": b for b in report['bank_records']}
    confirmed = state.get('confirmed_source_record_sets', [])
    protected = {key for g in confirmed for key in g['retained_ids'] + g['shadow_ids']}
    scan = discover({'records': [r for r in records if r['id'] not in protected]}, report, overrides, policy)
    proposals = [(g, 'confirmed', 'confirmed', True, []) for g in confirmed]
    for item in scan['candidates'] + scan['unresolved']:
        eligible = item['automatic_eligible']
        proposals.append((item['confirmation'], 'automatic' if eligible else 'candidate',
                          'confirmed' if eligible else 'candidate', not item['reasons'], item['reasons']))
    active, pending, claims = [], [], set()
    # This snapshot holds raw evidence identity. Native trace enrichment and
    # classification edits do not change the evidence fingerprint.
    source_fields = ('platform', 'transaction_time', 'event_kind', 'payment_method',
                     'currency', 'owner_id', 'date_basis', 'visually_verified_funding',
                     'profile_identity_verified', 'merchant', 'title', 'file_sha256',
                     'platform_reported_amount_cents', 'platform_paid_amount_cents',
                     'current_payment_state', 'raw_status')
    bank_fields = ('id', 'date', 'amount_cents', 'is_credit', 'account_number',
                   'currency', 'description', 'owner_id', 'reconciliation_eligible')
    for raw, origin, default, can_confirm, reasons in proposals:
        link = copy.deepcopy(raw)
        ids = link['retained_ids'] + link['shadow_ids']
        participants = [indexed[k] for k in ids if k in indexed]
        if origin == 'confirmed' and any(k not in indexed or set_signature(indexed[k], link) != link['signatures'].get(k) for k in ids):
            # Keep the old human decision in review-state. Expose a fresh,
            # evidence-bound proposal so changed but valid sources can be
            # reviewed from the app instead of becoming permanently blocked.
            link['signatures'] = {r['id']: set_signature(r, link) for r in participants}
            default = 'candidate'; reasons = ['旧确认的原始事件或金额已变化，请重新核对整组']
            _, trial = apply([copy.deepcopy(r) for r in participants], [link], overrides)
            can_confirm = trial[0]['status'] == 'confirmed'
        keys = sorted({k for r in participants for k in r['evidence_keys']})
        events = [e for r in participants for e in r['events']
                  if e['id'] in link.get('retained_event_keys', keys)]
        group_keys = sorted(set(link['retained_event_keys']) |
                            {e for k in link['shadow_ids'] if k in indexed for e in indexed[k]['evidence_keys']}) if link.get('kind') == 'refund' else keys
        source_identity = {k: ({f: rows[k].get(f) for f in source_fields} if k in rows else
                              {f: banks[k].get(f) for f in bank_fields} if k in banks else None)
                           for k in keys}
        identity = {r['id']: {k: r.get(k) for k in ('user_id', 'payment_accounts', 'payment_account_status')}
                    for r in participants}
        fingerprint = digest(MATCHING_RULE, link['id'], link.get('kind', 'payment'),
                             {r['id']: set_signature(r, link) for r in participants}, source_identity, identity)
        group = {**link, 'kind': link.get('kind', 'payment'), 'fingerprint': fingerprint, 'origin': origin, 'default_status': default,
                 'can_confirm': can_confirm, 'reasons': reasons, 'evidence_keys': group_keys,
                 'retained_records': [copy.deepcopy(indexed[k]) for k in link['retained_ids'] if k in indexed],
                 'shadow_records': [copy.deepcopy(indexed[k]) for k in link['shadow_ids'] if k in indexed],
                 'date': min((e['date'][:10] for e in events), default=''),
                 'amount_cents': events[0]['amount_cents'] if events else 0,
                 'network_count': len(link['shadow_ids']),
                 'bank_count': len(link.get('retained_event_keys', link['retained_ids']))}
        decision = (overrides.get('source-set:' + link['id'], {}).get('source_record_set_review') or {})
        disposition = decision.get('disposition', 'automatic')
        if origin == 'confirmed' and disposition != 'reject':
            # Old confirmations bound monetary events but did not carry account
            # or currency fields. Recheck these identities on each generation.
            funding = {mapped_account(rows[k].get('payment_method'), policy) if k in rows else
                       mapped_account(str(banks[k]['account_number']).replace(' ', '')[-4:], policy) if k in banks else None
                       for k in group_keys}
            currencies = {rows[k].get('currency') if k in rows else banks[k].get('currency') if k in banks else None for k in group_keys}
            owners = {r.get('user_id') for r in participants}
            if len(funding) != 1 or None in funding or len(currencies) != 1 or None in currencies or len(owners) != 1 or None in owners:
                group['status'] = 'evidence_changed'; group['can_confirm'] = False
                group['default_status'] = 'candidate'; group['reasons'] = ['旧确认的账户、币种或消费人已变化，需重新核对']
                pending.append(group); continue
        # A rejection is an intentional stop. New evidence cannot silently
        # turn the same source set back into an automatic confirmation.
        if disposition == 'reject':
            group['status'] = 'rejected'; pending.append(group); continue
        if decision and disposition not in ('confirm', 'reject', 'automatic'):
            group['status'] = 'evidence_changed'; group['reasons'] = ['人工来源决定版本无法使用，请重新保存']
            pending.append(group); continue
        if disposition == 'confirm':
            group['origin'] = 'manual'
            if decision.get('fingerprint') != fingerprint or not can_confirm:
                group['status'] = 'evidence_changed'; pending.append(group); continue
        elif default != 'confirmed':
            group['status'] = 'evidence_changed' if origin == 'confirmed' else 'candidate'; pending.append(group); continue
        # Never discard independent human classifications automatically.
        shadow_keys = {'transaction:' + k for k in link['shadow_ids']} | {
            c['id'] for k in link['shadow_ids'] if k in indexed for c in indexed[k]['components']}
        if origin == 'automatic' and disposition != 'confirm' and any(
                overrides.get(k, {}).get('primary') not in (None, '', '待分类') or
                overrides.get(k, {}).get('completion_confirmation') for k in shadow_keys):
            group['status'] = 'candidate'; group['default_status'] = 'candidate'
            group['reasons'] = ['银联来源已有人工分类或补全确认']; pending.append(group); continue
        if claims.intersection(ids):
            group['status'] = 'evidence_changed'; group['can_confirm'] = False
            pending.append(group); continue
        if set(link['shadow_ids']).intersection(protected_record_ids):
            group['status'] = 'evidence_changed'; group['can_confirm'] = False
            group['reasons'] = ['银联生命周期已有独立订单素材关联，需先复查该关联']
            pending.append(group); continue
        _, trial = apply([copy.deepcopy(r) for r in participants], [link], overrides)
        if trial[0]['status'] != 'confirmed':
            group['status'] = 'evidence_changed'; group['can_confirm'] = False
            pending.append(group); continue
        group['status'] = 'confirmed'; active.append(group); claims.update(ids)
    projected, applied = apply(records, active, overrides)
    # apply provides guarded archives; preserve transport metadata for instant
    # native undo. Never fold source archives into a financial/refund signature.
    for group, checked in zip(active, applied):
        group.update(checked)
    return projected, active, pending, scan['unresolved']
