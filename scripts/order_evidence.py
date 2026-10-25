"""Retain geometrically complete order cards and enrich unique export orders."""
import argparse
import json
import re
from collections import defaultdict
from pathlib import Path

try:
    from .payment_evidence import digest, make_observation
    from .payment_materials import snapshot, write_asset
except ImportError:
    from payment_evidence import digest, make_observation
    from payment_materials import snapshot, write_asset


def merchant(row):
    lines = [x for x in row['recognition']['lines'] if x['pixelBox']['y'] < row['crop'][3] * .25
             and x['visionBox']['x'] < .6 and len(x['text']) > 2]
    text = max(lines, key=lambda x: x['pixelBox']['height'])['text'] if lines else ''
    return re.sub(r'(已完成|支付成功|已退款|已取消|[>＞]).*$', '', text).strip()


def compatible(a, b):
    def clean(x):
        return re.sub(r'[^a-z0-9\u4e00-\u9fff]', '', x.lower())
    a, b = clean(a), clean(b)
    return len(a) >= 3 and len(b) >= 3 and (a[:4] == b[:4] or a in b or b in a)


def run(root, output, video_folder):
    output, video_folder = Path(output), Path(video_folder)
    raw = json.loads((video_folder / 'video-records.json').read_text())
    report = json.loads((output / 'payment-evidence.json').read_text())
    source = snapshot(Path(raw['source']), output)
    raw_snapshot = snapshot(video_folder / 'video-records.json', output)
    groups = defaultdict(list)
    for row in raw['rows']:
        fields = row.get('parsed') or {}
        # Geometric corner tests have already excluded viewport fragments.
        name = merchant(row)
        groups[(fields.get('orderedMinute'), fields.get('amountCents'), name[:4])].append(row)
    observations, links, materials = [], [], []
    for group in groups.values():
        row = max(group, key=lambda r: (-len(r['parsed']['reviewReasons']), len(r['text'])))
        fields, name = row['parsed'], merchant(row)
        key = digest('complete-order-card-v2', source['sha256'], row['image_sha256'], row['crop'])
        prefix = 'materials/records/' + key + '/'
        image = write_asset(output, prefix + 'record.png', (video_folder / row['image']).read_bytes())
        if image['sha256'] != row['image_sha256']: raise ValueError('Order crop checksum changed')
        locator = {'kind':'video_region', 'requested_seconds':row['requested_second'],
                   'actual_seconds':row['actual_second'], 'crop_pixels':row['crop'],
                   'boundaries':row['completeness'], 'date_basis':'visible_order_date'}
        payload = {'literal_text':row['text'], 'source':source, 'locator':locator, 'parsed':fields}
        raw_asset = write_asset(output, prefix + 'record.json', json.dumps(payload, ensure_ascii=False, indent=2))
        evidence = {'evidence_id':key, 'kind':'video_crop', 'source':source, 'image':image,
                    'raw':raw_asset, 'locator':locator, 'ocr_result':raw_snapshot, 'crop_complete':True}
        stamp = fields.get('orderedMinute')
        materials.append({'id':'order-card:'+key, 'platform':'card', 'title':name or '订单卡片',
                          'date':stamp or '日期未确定', 'amount_cents':fields.get('amountCents') or 0,
                          'status':fields.get('status') or '状态待确认', 'date_basis':'visible_order_date',
                          'source_evidence':evidence})
        if not stamp: continue
        raw_status = fields.get('status') or '状态待确认'
        observation = make_observation('meituan_card', Path(raw['source']).name, source['sha256'], row['requested_second'],
            {'source_profile_id':None, 'observed_at':None, 'owner_id':None, 'all_users_covered':None},
            {'原始文字':row['text'], '当前状态':raw_status, '收/支':'支出'},
            timestamp=stamp+':00', success_time=None, amount=fields.get('amountCents'),
            order_amount=None, paid_amount=None, reference=key, merchant_reference=None,
            merchant=name, title=row['text'], method='支付方式待确认', direction='支出', status=raw_status)
        observation.update(source_evidence=evidence, video_overlap_pending=True, date_basis='visible_order_date')
        cluster = 'order-card:'+key
        observations.append({'cluster_id':cluster, 'representative':observation})
        matches = [c['cluster_id'] for c in report['clusters'] if c['platform']=='meituan'
                   and c['representative']['event_kind']=='payment'
                   and c['representative']['transaction_time'][:16]==stamp
                   and c['representative']['platform_reported_amount_cents']==fields.get('amountCents')
                   and compatible(name, c['representative'].get('title') or '')]
        # A refund-state screenshot cannot silently overwrite a payment export.
        if len(matches)==1 and raw_status in ('已完成','支付成功') and not fields['reviewReasons']:
            links.append({'record_ids':[cluster,matches[0]], 'bank_ids':[], 'review_required':False,
                          'association_status':'rule_supported', 'basis':'下单分钟、金额、商户兼容且唯一'})
    result = {'source':source, 'observations':observations, 'links':links, 'materials':materials,
              'summary':{'raw_complete_crops':len(raw['rows']), 'deduplicated_materials':len(materials),
                         'wallet_links':len(links), 'unparsed_crops':sum(bool(r['parsed']['reviewReasons']) for r in raw['rows']),
                         'undated_materials':sum(not r['parsed'].get('orderedMinute') for r in raw['rows']),
                         'recall_status':raw['recall_status']}}
    imports = output / 'order-evidence-imports'; imports.mkdir(exist_ok=True)
    (imports / (source['sha256']+'.json')).write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
    results = [json.loads(p.read_text()) for p in sorted(imports.glob('*.json'))]
    merged = {k: [r for item in results for r in item[k]] for k in ('observations','links','materials')}
    merged['summary'] = {k:sum(item['summary'][k] for item in results) for k in result['summary'] if k!='recall_status'}
    merged['summary']['recall_status']='自动完整裁剪已验证；全量召回率仍需更多布局样本验证'
    (output / 'order-evidence.json').write_text(json.dumps(merged,ensure_ascii=False,indent=2)+'\n')
    return merged


if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--root',type=Path,required=True); parser.add_argument('--output',type=Path,required=True); parser.add_argument('--video-folder',type=Path,required=True)
    args=parser.parse_args(); result=run(args.root,args.output,args.video_folder)
    print(json.dumps(result['summary'],ensure_ascii=False,indent=2))
