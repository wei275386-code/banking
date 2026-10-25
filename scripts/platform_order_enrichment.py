"""Replay evidence-scoped order details without changing ledger events or totals."""
import copy
import json
from pathlib import Path

try:
    from .payment_evidence import digest
except ImportError:
    from payment_evidence import digest


def signature(record):
    return digest({k: record.get(k) for k in ('id', 'date', 'user_id', 'evidence_keys', 'events')},
                  [{k: c.get(k) for k in ('id', 'gross_cents', 'refund_cents', 'net_cents')}
                   for c in record['components']])


def _verify_trace_materials(trace, output, verified):
    from scripts.payment_materials import checksum
    from scripts.release_contracts import validate_relative_path
    evidence = trace['source_evidence']
    references = [evidence['source'], evidence['raw']]
    references += [evidence[key] for key in ('image', 'text', 'annotation_snapshot') if key in evidence]
    root = Path(output).resolve()
    for reference in references:
        relative = validate_relative_path(reference['path'])
        path = (root / relative).resolve()
        if not path.is_relative_to(root):
            raise ValueError('Enrichment material outside review directory')
        if relative not in verified:
            verified[relative] = checksum(path)
        if verified[relative] != reference['sha256']:
            raise ValueError('Enrichment material bytes changed: ' + relative)


def apply(result, output, overrides=None):
    path = Path(output) / 'platform-order-enrichment.json'
    if not path.exists():
        return
    document = json.loads(path.read_text())
    override_path = Path(output) / 'review-overrides.json'
    if overrides is None:
        overrides = json.loads(override_path.read_text()) if override_path.exists() else {}
    records = {r['id']: r for r in result['records']}
    skipped = []
    applied = []
    verified = {}
    for entry in document['entries']:
        record = records.get(entry['transaction_id'])
        if record is None or signature(record) != entry['transaction_signature']:
            skipped.append({'id': entry['transaction_id'], 'reason': '交易证据或金额已改变'})
            continue
        original = {t['id']: t for t in record.get('trace_sources', [])}
        provided = {t['id']: t for t in entry.get('new_traces', [])}
        for trace in provided.values():
            _verify_trace_materials(trace, output, verified)
        # Supplemental traces can be the very sources this entry introduces.
        # Existing observations take precedence and cannot be replaced to pass
        # a stale signature. Missing sources require exact supplied trace hashes
        # and retained material bytes, never a new inferred association.
        bound = {**provided, **original}
        if any(key not in bound or digest(bound[key]) != expected
               for key, expected in entry.get('source_signatures', {}).items()):
            skipped.append({'id': record['id'], 'reason': '用于补全的关联来源已改变'})
            continue
        if entry.get('title'):
            for component in record['components']:
                if component['id'] == entry['component_id']:
                    prior = next((overrides[k] for k in component.get('classification_keys', [component['id']])
                                  if isinstance(overrides.get(k), dict) and 'primary' in overrides[k]), {})
                    # A later explicit title edit takes precedence over this batch.
                    title = prior.get('title') or entry['title']
                    component['title'] = title
                    record['title'] = title
        record['order_details'] = copy.deepcopy(entry['details'])
        for trace in entry.get('new_traces', []):
            if trace['id'] not in original:
                record.setdefault('trace_sources', []).append(copy.deepcopy(trace))
        applied.append(record['id'])
    result['platform_order_enrichment'] = {'applied': applied, 'skipped': skipped,
        'verified_assets': [{'path': path, 'sha256': sha256} for path, sha256 in sorted(verified.items())],
        'basis': '已关联原始来源及直接读取的真机订单；付款时间、下单时间及服务时间分别保留'}
