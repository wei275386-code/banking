"""Attach retained order material to existing transactions without payment events."""
import json
from pathlib import Path

try:
    from .payment_evidence import digest
    from .payment_materials import checksum
except ImportError:
    from payment_evidence import digest
    from payment_materials import checksum


def transaction_signature(record):
    return digest('material-target-v1', {key: record[key] for key in
        ('id', 'date', 'status', 'events', 'non_consumption', 'unallocated_credit_cents')},
        [key for key in record['evidence_keys'] if not key.startswith('image-order:')],
        [{key: component[key] for key in ('id', 'gross_cents', 'refund_cents', 'net_cents')}
         for component in record['components']])


def apply(records, materials, output):
    output = Path(output)
    path = output / 'material-associations.json'
    if not path.exists():
        return []
    document = json.loads(path.read_text())
    by_record = {record['id']: record for record in records}
    by_material = {material['id']: material for material in materials}
    prepared, seen = [], set()
    for link in document['links']:
        record = by_record.get(link['transaction_id'])
        ids = link['material_ids']
        if (record is None or transaction_signature(record) != link['transaction_signature']
                or not ids or len(ids) != len(set(ids)) or seen.intersection(ids)
                or any(key not in by_material for key in ids)):
            raise ValueError('Material association target changed: ' + link['id'])
        for key in ids:
            evidence = by_material[key]['source_evidence']
            if digest(evidence) != link['material_signatures'].get(key):
                raise ValueError('Material association source changed: ' + key)
            for asset in ('source', 'raw', 'image'):
                reference = evidence[asset]
                resolved = (output / reference['path']).resolve()
                if not resolved.is_relative_to(output.resolve()) or checksum(resolved) != reference['sha256']:
                    raise ValueError('Material bytes changed: ' + key)
        total = sum(by_material[key]['amount_cents'] for key in ids)
        if total != link['matched_amount_cents'] or total not in {
                event['amount_cents'] for event in record['events'] if event['kind'] in ('payment', 'bank_debit')}:
            raise ValueError('Material amount does not reconcile: ' + link['id'])
        seen.update(ids)
        prepared.append((record, link))
    for record, link in prepared:
        record['evidence_keys'] = sorted(set(record['evidence_keys']) | set(link['material_ids']))
        record.setdefault('supporting_order_material_links', [])
        if link not in record['supporting_order_material_links']:
            record['supporting_order_material_links'].append(link)
        for key in link['material_ids']:
            material = by_material[key]
            material['linked_transaction_ids'] = [record['id']]
            material['association_basis'] = link['basis']
            # Display support alongside payment provenance without creating an event.
            trace = record.setdefault('trace_sources', [])
            if not any(source['id'] == key for source in trace):
                trace.append({'id': key, 'association': 'linked', 'basis': link['basis'],
                              'platform': 'card', 'date': material.get('date', ''),
                              'post_date': None, 'merchant': material.get('title'),
                              'title': material.get('title'), 'amount_cents': material['amount_cents'],
                              'currency': 'CNY', 'payment_method': None, 'event_kind': 'order_material',
                              'status': material.get('status', ''), 'provider_reference': None,
                              'merchant_reference': None,
                              'source_name': material['source_evidence']['source'].get('original_name'),
                              'location': '订单卡片；日期为服务日期，金额为订单显示价',
                              'source_evidence': material['source_evidence']})
    return [link for _, link in prepared]
