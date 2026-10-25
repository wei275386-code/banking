"""Retain visually checked order screenshots as supporting materials only.

Service dates and displayed order prices do not establish payment events.
The manifest records source hashes, pixel crops, literal text and limitations.
"""
import argparse
import io
import json
from datetime import datetime
from pathlib import Path

from PIL import Image

try:
    from .payment_evidence import digest
    from .payment_materials import snapshot, write_asset, checksum
except ImportError:
    from payment_evidence import digest
    from payment_materials import snapshot, write_asset, checksum


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n')
    temporary.replace(path)


def run(manifest, output):
    manifest, output = Path(manifest), Path(output)
    raw = json.loads(manifest.read_text())
    prepared = []
    for entry in raw['sources']:
        path = Path(entry['path'])
        if checksum(path) != entry['sha256']:
            raise ValueError('Source hash changed: ' + path.name)
        with Image.open(path) as original:
            if list(original.size) != entry['size_pixels']:
                raise ValueError('Source dimensions changed')
            for row in entry['cards']:
                x, y, width, height = row['crop_pixels']
                if min(x, y) < 0 or min(width, height) <= 0 or x + width > original.width or y + height > original.height:
                    raise ValueError('Invalid crop: ' + row['card_id'])
        prepared.append((entry, path))
    annotation = snapshot(manifest, output)
    imported = []
    for entry, path in prepared:
        source = snapshot(path, output)
        materials = []
        with Image.open(path) as original:
            for row in entry['cards']:
                key = digest('image-order-material-v1', source['sha256'], row)
                prefix = 'materials/records/' + key + '/'
                x, y, width, height = row['crop_pixels']
                crop = original.crop((x, y, x + width, y + height))
                buffer = io.BytesIO()
                crop.save(buffer, format='PNG')
                image = write_asset(output, prefix + 'record.png', buffer.getvalue())
                locator = {'kind': 'image_region', 'crop_pixels': row['crop_pixels'],
                           'coordinate_convention': 'top_left_xywh_right_bottom_exclusive',
                           'source_size_pixels': entry['size_pixels'],
                           'date_basis': row['date_basis'], 'boundaries': row['boundaries']}
                payload = {'literal_text': row['literal_text'],
                           'source': source, 'locator': locator, 'visual_reading': row,
                           'reading_method': 'direct_visual_no_local_ocr',
                           'role': 'order_classification_and_association_support',
                           'payment_time': None, 'order_time': None, 'owner_id': None,
                           'actual_paid_amount_cents': None}
                evidence = {'evidence_id': key, 'kind': 'image_crop', 'source': source,
                            'image': image, 'raw': write_asset(output, prefix + 'record.json', json.dumps(payload, ensure_ascii=False, indent=2)),
                            'text': write_asset(output, prefix + 'record.txt', row['literal_text']),
                            'annotation_snapshot': annotation, 'locator': locator,
                            'crop_complete': row['crop_complete']}
                materials.append({'id': 'image-order:' + key, 'platform': 'card',
                                  'source_platform': raw['platform'],
                                  'title': raw['platform_label'] + ' · ' + row['title'],
                                  'date': row['service_date_from'], 'amount_cents': row['displayed_amount_cents'],
                                  'status': row['status'] + (' · 部分可见' if not row['crop_complete'] else ''),
                                  'date_basis': row['date_basis'], 'source_evidence': evidence})
        complete = sum(m['source_evidence']['crop_complete'] for m in materials)
        result = {'source': source, 'observations': [], 'links': [],
                  'materials': materials, 'summary': {'raw_complete_crops': complete,
                  'deduplicated_materials': len(materials), 'wallet_links': 0, 'unparsed_crops': 0,
                  'undated_materials': 0, 'partial_crops': len(materials) - complete}}
        folder = output / 'supplemental-evidence-imports'
        folder.mkdir(exist_ok=True)
        atomic_json(folder / (source['sha256'] + '.json'), result)
        imported.append(result)
    imports = [json.loads(p.read_text()) for p in sorted(folder.glob('*.json'))]
    merged = {key: [item for result in imports for item in result[key]] for key in ('observations', 'links', 'materials')}
    merged['summary'] = {key: sum(result['summary'].get(key, 0) for result in imports)
                         for key in ('raw_complete_crops', 'deduplicated_materials', 'wallet_links', 'unparsed_crops', 'undated_materials', 'partial_crops')}
    atomic_json(output / 'supplemental-evidence.json', merged)
    inventory_path = output / 'import-inventory.json'
    inventory = json.loads(inventory_path.read_text()) if inventory_path.exists() else []
    for result in imported:
        source = result['source']
        previous = next((item for item in inventory if item['sha256'] == source['sha256']), None)
        inventory = [item for item in inventory if item['sha256'] != source['sha256']]
        inventory.append({'name': source['original_name'], 'sha256': source['sha256'], 'kind': 'image',
                          'platform': raw['platform'], 'status': '订单支持素材已保存，裁剪已目视核验',
                          'source_snapshot': source, 'summary': result['summary'],
                          'reading_method': 'direct_visual_no_local_ocr',
                          'imported_at': previous['imported_at'] if previous else datetime.now().isoformat()})
    atomic_json(inventory_path, inventory)
    return imported


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps([result['summary'] for result in run(args.manifest, args.output)], ensure_ascii=False))
