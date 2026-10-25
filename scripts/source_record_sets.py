"""Explicitly confirmed duplicate source sets, without inventing row pairings.

Keep the bank lifecycles and their refund/fact identities intact. Archive redundant
network projections with the set, and expose all source evidence collectively.
"""
import copy
from collections import Counter

try:
    from .payment_evidence import digest
except ImportError:
    from payment_evidence import digest


def signature(record):
    return digest({k: record.get(k) for k in
                   ('id', 'date', 'evidence_keys', 'events', 'non_consumption')},
                  [{k: c.get(k) for k in ('id', 'gross_cents', 'refund_cents', 'included', 'reason')}
                   for c in record['components']])


def set_signature(record, link):
    kind = link.get('kind', 'payment')
    events = [e for e in record['events'] if (e['kind'] in ('payment', 'bank_debit') if kind == 'payment'
              else e['id'] in link.get('retained_event_keys', []) or e['source'] == 'unionpay' and e['kind'] == 'refund')]
    return digest(record['id'], events, record.get('non_consumption'),
                  [{k: c.get(k) for k in ('id', 'gross_cents')} for c in record['components']] if kind == 'payment' else [])


def apply(records, confirmations, overrides=None):
    overrides = overrides or {}
    indexed = {r['id']: r for r in records}
    claims = [k for link in confirmations for k in link['retained_ids'] + link['shadow_ids']]
    repeated = {k for k, count in Counter(claims).items() if count > 1}
    removed, groups = set(), []
    for link in confirmations:
        keep, shadows = link['retained_ids'], link['shadow_ids']
        kind = link.get('kind', 'payment')
        keys = keep + shadows
        valid = (bool(keep) and bool(shadows) and kind in ('payment', 'refund') and len(set(keys)) == len(keys)
                 and not repeated.intersection(keys) and all(k in indexed and
                 set_signature(indexed[k], link) == link['signatures'].get(k) for k in keys))
        if valid and kind == 'payment':
            purchases = [indexed[k] for k in keys]
            valid = (len(keep) == len(shadows) and len({r['date'] for r in purchases}) == 1
                     and all(len(r['components']) == 1
                             and not r['non_consumption'] and not r.get('excluded_from_completion_and_statistics')
                             for r in purchases)
                     and len({r['components'][0]['gross_cents'] for r in purchases}) == 1
                     and all(sum(e['kind'] == 'bank_debit' for e in indexed[k]['events']) == 1
                             and all(e['kind'] in ('bank_debit', 'bank_credit', 'refund') for e in indexed[k]['events']) for k in keep)
                     and all(len(indexed[k]['events']) == 1 and indexed[k]['events'][0]['kind'] == 'payment'
                             and indexed[k]['events'][0]['source'] == 'unionpay' for k in shadows))
        if valid and kind == 'refund':
            event_keys = link.get('retained_event_keys', [])
            bank_events = [e for k in keep for e in indexed[k]['events'] if e['id'] in event_keys]
            network_events = [e for k in shadows for e in indexed[k]['events']]
            valid = (len(event_keys) == len(set(event_keys)) == len(shadows) == len(bank_events)
                     and {e['id'] for e in bank_events} == set(event_keys)
                     and {k for k in keep if any(e['id'] in event_keys for e in indexed[k]['events'])} == set(keep)
                     and all(e['source'] == 'bank' and e['kind'] == 'bank_credit' for e in bank_events)
                     and all(len(indexed[k]['events']) == 1 and not indexed[k]['non_consumption']
                             and all(c['gross_cents'] == c['net_cents'] == 0 for c in indexed[k]['components']) for k in shadows)
                     and all(e['source'] == 'unionpay' and e['kind'] == 'refund' for e in network_events)
                     and len({e['date'][:10] for e in bank_events + network_events}) == 1
                     and len({e['amount_cents'] for e in bank_events + network_events}) == 1
                     and all(not indexed[k].get('excluded_from_completion_and_statistics') for k in keys))
        if valid:
            shadow_components = {c['id'] for k in shadows for c in indexed[k]['components']}
            shadow_targets = set(shadows) | shadow_components
            for key, override in overrides.items():
                facts = override.get('transaction_facts') or {}
                disposition = facts.get('disposition', 'automatic')
                if key in {'transaction:' + k for k in keys} and (
                        facts.get('amounts') or (key.removeprefix('transaction:') in shadows and disposition != 'automatic')
                        or (key.removeprefix('transaction:') in keep and (disposition in ('exclude', 'duplicate', 'nonConsumption')
                            or (disposition == 'refund' and kind != 'refund')))
                        or override.get('excluded_from_completion_and_statistics')):
                    valid = False
                association = facts.get('refundAssociation') or {}
                references = {facts.get('targetID')} | set(association.get('allocations', {})) | set(association.get('sourceSignatures', {}))
                if shadow_targets.intersection(references):
                    valid = False
        if not valid:
            groups.append({**copy.deepcopy(link), 'status': 'evidence_changed'})
            continue
        evidence = sorted(set(link['retained_event_keys']) | {e for k in shadows for e in indexed[k]['evidence_keys']}) if kind == 'refund' else sorted({e for k in keys for e in indexed[k]['evidence_keys']})
        group = {**copy.deepcopy(link), 'status': 'confirmed', 'evidence_keys': evidence,
                 'shadow_records': [copy.deepcopy(indexed[k]) for k in shadows],
                 'shadow_overrides': {k: copy.deepcopy(v) for k, v in overrides.items()
                     if k in shadow_components or k in {'transaction:' + s for s in shadows}}}
        # Display metadata does not participate in native fact/refund signatures.
        for k in keep:
            indexed[k]['source_record_set'] = {field: copy.deepcopy(group[field]) for field in
                ('id', 'basis', 'retained_ids', 'shadow_ids', 'evidence_keys')}
        removed.update(shadows)
        groups.append(group)
    return [r for r in records if r['id'] not in removed], groups
