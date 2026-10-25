"""Effective statistical range derived from reliable dates, never today's clock."""
from __future__ import annotations

import copy
from datetime import date


def reliable_date(value):
    if not isinstance(value, str) or len(value) < 10:
        return None
    day = value[:10]
    try:
        return day if date.fromisoformat(day).isoformat() == day else None
    except ValueError:
        return None


def empty_coverage():
    return {'mode': 'empty', 'from': None, 'to': None,
            'observed_from': None, 'observed_to': None, 'pending_from': None,
            'pending_to': None, 'basis': {'kind': 'no-reliable-dates',
                'source_ids': []}, 'revision': 0}


def _finish(previous, result):
    from scripts.release_contracts import validate_contract
    if previous:
        old = {k: v for k, v in previous.items() if k != 'revision'}
        new = {k: v for k, v in result.items() if k != 'revision'}
        result['revision'] = previous['revision'] + (old != new)
    validate_contract('coverage', result)
    return result


def recompute(previous, observations):
    """Recompute observed dates; automatic ranges grow and explicit ranges wait.

    observations is an iterable of (source_id, ISO date) verified by the caller.
    Revoked decisions must be omitted by the caller on the next recomputation.
    """
    from scripts.release_contracts import evolve_coverage
    baseline = previous or empty_coverage()
    pairs = [(str(key), day) for key, value in observations
             if (day := reliable_date(value)) is not None]
    result = evolve_coverage(baseline, [day for _, day in pairs])
    if result['mode'] in ('empty', 'automatic'):
        result['basis'] = {'kind': 'reliable-observations' if result['mode'] == 'automatic' else 'no-reliable-dates',
                          'source_ids': sorted({key for key, _ in pairs})}
    return _finish(baseline, result)


def set_explicit(previous, start, end, *, basis=None):
    """Apply an already confirmed host decision, including a deliberate narrowing."""
    if reliable_date(start) != start or reliable_date(end) != end or start > end:
        raise ValueError('统计范围需要有效且顺序正确的起止日期')
    result = copy.deepcopy(previous or empty_coverage())
    result.update(mode='explicit', **{'from': start, 'to': end},
                  pending_from=None, pending_to=None,
                  basis=basis or {'kind': 'user-confirmed', 'source_ids': []})
    if result['observed_from'] and (result['observed_from'] < start or result['observed_to'] > end):
        result['pending_from'] = min(start, result['observed_from'])
        result['pending_to'] = max(end, result['observed_to'])
    return _finish(previous, result)


def accept_pending(previous):
    if previous['mode'] != 'explicit':
        raise ValueError('仅 explicit 范围可接受待扩展建议')
    return set_explicit(previous, previous['pending_from'] or previous['from'],
                        previous['pending_to'] or previous['to'])


def reliable_observations(report):
    """Official parsed exports, validated bank rows, and signature-checked dates."""
    official = {d['file_sha256'] for d in report.get('documents', [])}
    values = []
    for row in report.get('bank_records', []):
        if row.get('reconciliation_eligible', True):
            values.append(('bank:' + str(row['id']), row.get('date')))
    for cluster in report.get('clusters', []):
        row = cluster['representative']
        if cluster.get('conflicting_fields') or row.get('date_basis') in {
                'year_label_conflicts_weekday', 'unknown', 'unconfirmed_year', 'filename', 'file_mtime'}:
            continue
        if row.get('file_sha256') in official or row.get('date_basis') == 'user_confirmed_displayed_date':
            values.append((cluster['cluster_id'], row.get('transaction_time')))
    return values
