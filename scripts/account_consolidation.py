"""User-approved funding-account normalization, after lifecycle reconciliation.

Raw evidence and lifecycle identity are never changed. The policy is persisted in
config and carried in snapshots so native clients normalize older peer edits too.
"""
import copy
import json
from pathlib import Path


def load_policy(root):
    path = Path(root) / 'config/payment-account-consolidation.json'
    return json.loads(path.read_text()) if path.exists() else None


def canonical(name, policy):
    aliases = policy['aliases']
    if name in aliases:
        return aliases[name]
    for prefix in policy.get('display_name_prefixes', []):
        if prefix and name.startswith(prefix) and name[len(prefix):] in aliases:
            return aliases[name[len(prefix):]]
    return name


def apply(records, policy):
    if not policy:
        return
    exclusions = policy['excluded_records']
    expected = set(exclusions)
    actual = {r['id'] for r in records}
    if not expected <= actual:
        raise ValueError('Excluded lifecycles missing; refusing account consolidation')
    for i, r in enumerate(records):
        if r['id'] in exclusions:
            frozen = exclusions[r['id']]
            if r['evidence_keys'] != frozen['evidence_keys'] or r['events'] != frozen['events']:
                raise ValueError('Excluded lifecycle evidence changed: ' + r['id'])
            records[i] = copy.deepcopy(frozen)
            continue
        if 'account_identity_before_consolidation' not in r:
            r['account_identity_before_consolidation'] = {key: copy.deepcopy(r.get(key)) for key in
                ('user_id', 'user_relation', 'payment_accounts', 'payment_account_status', 'account_views')}
        ownership = policy.get('ownership_overrides', {}).get(r['id'])
        if ownership and ownership.get('decision_kind') != 'confirmed_ownership':
            if r['evidence_keys'] != ownership['evidence_keys'] or r['events'] != ownership['events']:
                raise ValueError('Confirmed ownership evidence changed: ' + r['id'])
            r['user_id'] = ownership['user_id']
            r['user'] = ownership['user_id']
            r['user_basis'] = ownership['basis']
        views = r['account_views']
        channels = set(r.get('payment_channels', [])) | (set(views) & set(policy['channel_names']))
        unknown = set(r.get('payment_account_pending_reasons', [])) | (set(views) & set(policy['pending_names']))
        accounts = {canonical(a, policy) for a in r.get('payment_accounts', [])}
        # Refunds may have no payment event. Explicit funding in their own
        # evidence/view is still reliable; channel strings never supply funding.
        accounts |= {canonical(a, policy) for a in views if canonical(a, policy) in policy['canonical_accounts']}
        accounts.discard(None)
        r['payment_accounts'] = sorted(accounts)
        r['account_views'] = sorted(accounts)
        r['payment_channels'] = sorted(channels)
        r['payment_account_pending_reasons'] = sorted(unknown) if not accounts else []
        if accounts:
            r['payment_account_status'] = 'identified'
        elif channels or unknown or r.get('payment_account_status') == 'unresolved':
            r['payment_account_status'] = 'unresolved'
        r['user_display_name'] = policy.get('user_display_names', {}).get(r.get('user_id'), r.get('user_id') or '未确认')
        r['review_exclusion_allowed'] = bool(r.get('user_id') and r['user_id'] in policy.get('exclusion_member_ids', []))


def apply_confirmed_ownership(records, policy):
    """Apply evidence-scoped confirmed decisions after confirmed lifecycle edits."""
    decisions = {key: value for key, value in (policy or {}).get('ownership_overrides', {}).items()
                 if value.get('decision_kind') == 'confirmed_ownership'}
    by_id = {r['id']: r for r in records}
    if decisions.keys() - by_id.keys():
        raise ValueError('Preserved ownership lifecycle missing')
    # Validate every decision before changing any record.
    for key, decision in decisions.items():
        if any(by_id[key][field] != decision[field] for field in ('evidence_keys', 'events')):
            raise ValueError('Confirmed ownership evidence changed: ' + key)
    for key, decision in decisions.items():
        by_id[key].update(user_id=decision['user_id'], user=decision['user_id'], user_basis=decision['basis'])
    return set(decisions)


def snapshot_policy(policy):
    """No duplicated transaction payload in transport; native guards use originals."""
    return {k: copy.deepcopy(v) for k, v in policy.items() if k != 'excluded_records'} | {
        'excluded_lifecycle_ids': sorted(policy['excluded_records'])}


def unresolved_items(records):
    return [{'id': r['id'], 'date': r['date'], 'user': r.get('user_id'),
             'title': r['title'], 'gross_cents': sum(c['gross_cents'] for c in r['components']),
             'net_cents': sum(c['net_cents'] for c in r['components']),
             'status': r['status'], 'payment_methods': r.get('payment_channels', []) + r.get('payment_account_pending_reasons', []),
             'evidence_keys': r['evidence_keys'], 'reason': '实际支付/退款账户待关联'}
            for r in records if r.get('payment_account_status') == 'unresolved']
