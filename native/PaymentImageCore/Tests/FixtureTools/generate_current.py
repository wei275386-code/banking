"""Generate synthetic XCTest resources. No file outside Tests is read or written."""
import copy
import hashlib
import json
from pathlib import Path
import struct
import zlib

TESTS = Path(__file__).resolve().parents[1]
STORE = TESTS / 'FinancialStoreTests' / 'Fixtures' / 'current'
CORE = TESTS / 'PaymentImageCoreTests' / 'Fixtures' / 'current'
for root in (STORE, CORE):
    root.mkdir(parents=True, exist_ok=True)

def write(root, name, value):
    (root / name).write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + '\n')

parameters = dict(baseYear=2026, birthYear=1990, targetAge=55, currentFireAssets=100000,
    afterTaxSalary=200000, annualContribution=120000, expenseModes={'normal': 70000},
    annualHardCap=100000, expenseBreakdown={'rent': 12000},
    buckets=dict(safetyBucket=0, parentMedicalBucket=0, elderCareEnabled=False, elderCareBucket=0, otherBuckets=0, includeBuckets=False),
    investing=dict(withdrawalRate=.035, annualReturn=.06, inflation=.025, maxDrawdown=.3),
    branches=dict(housing=dict(enabled=False, year=2026, totalPrice=2000000, downPaymentRatio=.2,
        loanRate=.035, loanYears=30, fees=30000, renovation=100000, annualMaintenance=6000,
        reduceRent=False, minLiquidAssets=0, ownerHomeCountsAsFireAsset=False),
        children=dict(enabled=False, count=1, birthYear=2028, annualCost=24000, educationBucket=100000, incomeImpact=20000)))

def component(id, title=None, gross=2400, refund=0, primary='日常消费', secondary='餐饮', included=True):
    return dict(id=id, title=title or id, gross_cents=gross, refund_cents=refund, net_cents=gross-refund,
        primary=primary, secondary=secondary, classification_basis='规则推断', included=included,
        reason='' if included else '来源关联待确认', recurrence='one_time', tags=[], classification_keys=[id])

def record(id, date='2026-02-01', items=None, credit=0, account='Test account A'):
    items = [component(id+':item')] if items is None else items
    return dict(id=id, date=date, title='Synthetic '+id, status='支付成立', account_views=[account], evidence_keys=[id],
        components=items, events=[dict(id=id+':event', date=date, kind='bank_credit' if credit else 'payment', source='bank',
            amount_cents=credit or sum(c['gross_cents'] for c in items), status='原始证据')],
        user_id='fixture-user', user_relation='self', non_consumption=False, unallocated_credit_cents=credit,
        payment_accounts=[account], payment_account_status='identified', payment_channels=['Test channel'])

def report(records):
    return dict(dataset_id='synthetic-integration-v1', cutoff='2026-09-30',
        records=records, taxonomy=[dict(primary=p, secondaries=s) for p,s in [
            ('待分类',['待分类']), ('日常消费',['餐饮','咖啡茶饮','交通出行']), ('生产力工具',['设备']), ('亲友代付',['代购'])]],
        fire_parameters=parameters, coverage_note='Synthetic current fixture. No family data.', coverage_complete=True,
        source_record_sets=[], source_record_set_candidates=[], refund_candidates=[])

rows = [record('pending-category', items=[component('pending-category:item', primary='待分类', secondary='待分类')]),
    record('classified-meal', items=[component('classified-meal:item', refund=300)]),
    record('recurring-meal', date='2026-03-01'), record('pending-source', items=[component('pending-source:item', included=False)]),
    record('excluded-eligible'), record('other-user')]
rows[1].update(payment_accounts=[], account_views=[], payment_account_status='unresolved')
rows[2]['components'][0]['recurrence']='recurring'
# Explicit synthetic capability exercises the same generic policy used by any member.
rows[4].update(review_exclusion_allowed=True,user_id='fixture-owner-b', payment_accounts=[], account_views=[], payment_account_status='unresolved')
rows[5].update(user_relation='other_user', user_id='fixture-other')
for i in range(4):
    coffee=record('coffee-'+str(i), date=f'2026-0{i+2}-03', items=[component('coffee-'+str(i)+':item', title='Fixture coffee 订单详情', secondary='咖啡茶饮')])
    coffee.update(payment_accounts=[], account_views=[], payment_account_status='unresolved')
    coffee['components'][0]['tags']=['Synthetic tag '+str(i)]
    if i==1: coffee['components'][0]['recurrence']='recurring'
    rows.append(coffee)
# One group has three independent bank purchases and three unpaired network observations.
for i in range(3):
    r = record('trace-purchase-'+str(i), date='2025-12-23')
    r['trace_sources']=[dict(id='network-'+str(j), association='linked', basis='整组来源已确认，未指定逐笔配对',
        platform='unionpay', date=f'2025-12-23 08:{11+j*2:02}', title='Fixture platform merchant', currency='CNY',
        event_kind='payment', status='paid', location='Synthetic observation', source_evidence=dict(kind='fixture')) for j in range(3)]
    rows.append(r)
base=report(rows)
write(STORE,'financial-review.json',base)
write(CORE,'financial-review.json',report([rows[0]]))
write(CORE,'fire-parameters.json',parameters)
write(STORE,'review-overrides.json', {'classified-meal:item': dict(primary='日常消费',secondary='餐饮',recurrence='one_time',tags=[],fixture_metadata={'version':1}),
    'preserved-unrelated':dict(primary='待分类',secondary='待分类',fixture_metadata={'version':1})})
write(STORE,'review-state.json',dict(deferred_associations=dict(candidate_ids=[])))
# A 2401 x 2 solid PNG exercises real hash verification and preview downsampling.
def chunk(tag,data):
    return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data)&0xffffffff)
w,h=2401,2
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',w,h,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+b'\x36\x72\xa0'*w)*h))+chunk(b'IEND',b'')
(STORE/'preview.png').write_bytes(png)
image=dict(kind='fixture',image=dict(path='preview.png',sha256=hashlib.sha256(png).hexdigest()))
payment=dict(dataset_id=base['dataset_id'],backfill_cutoff_date=base['cutoff'],review_summary={},
    clusters=[dict(cluster_id='wallet-high',representative=dict(platform='alipay',transaction_time='2026-02-01',merchant='Fixture coffee', title='Synthetic purchase',platform_reported_amount_cents=2400,raw_status='paid',source_evidence=image)),
        dict(cluster_id='wallet-unknown',representative=dict(platform='wechat',transaction_time='',merchant='Fixture unknown',title='Amount pending',raw_status='pending',source_evidence=dict(kind='fixture')))],
    bank_records=[dict(id=1,date='2026-02-01',description='Synthetic debit',amount_cents=5000,is_credit=0,source_evidence=dict(kind='fixture')),
        dict(id=2,date='2026-02-02',description='Synthetic credit',amount_cents=-500,is_credit=1,source_evidence=dict(kind='fixture'))],
    candidates=[dict(candidate_id='link-high',kind='payment',record_ids=['wallet-high'],bank_ids=['bank:1'],association_status='candidate',review_required=True),
        dict(candidate_id='link-low',kind='payment',record_ids=['wallet-unknown'],bank_ids=['bank:2'],association_status='candidate',review_required=True)],
    ocr_probe=dict(samples=[]))
for root in (STORE,CORE): write(root,'payment-evidence.json',payment)
refund_rows=[record('refund-single',date='2026-04-01',items=[],credit=300),
    record('refund-group-a',date='2026-04-02',items=[],credit=200),record('refund-group-b',date='2026-04-03',items=[],credit=400),
    record('refund-multi-a',date='2026-04-04',items=[],credit=250),record('refund-multi-b',date='2026-04-05',items=[],credit=350),
    record('purchase-single'),record('purchase-group'),record('purchase-multi-a'),record('purchase-multi-b')]
def candidate(id,sources,targets,grouped):
    return dict(id=id,source_ids=sources,targets=[dict(record_id=r,component_id=r+':item',refund_cents=a) for r,a in targets],basis='Synthetic complete allocation',confidence='high',grouped=grouped,competing=False)
refund=report(refund_rows)
refund['refund_candidates']=[candidate('single',['refund-single'],[('purchase-single',300)],False),
    candidate('group-one',['refund-group-a','refund-group-b'],[('purchase-group',600)],True),
    candidate('group-two',['refund-multi-a','refund-multi-b'],[('purchase-multi-a',200),('purchase-multi-b',400)],True),
    candidate('single-alternative',['refund-single'],[('purchase-group',300)],False)]
refund['refund_candidates'][0]['competing']=True
refund['refund_candidates'][3]['competing']=True
refund_rows[6]['components'][0].update(refund_cents=100,net_cents=2300)
refund_rows[8]['components'][0].update(gross_cents=400,net_cents=400)

refund_rows[0]['trace_sources']=[dict(id='refund-network',association='linked',basis='Synthetic linked refund',platform='unionpay',date='2026-04-01 03:29',title='Fixture platform merchant',currency='CNY',event_kind='refund',status='refunded',location='Synthetic observation',source_evidence=image)]
refund_rows.extend(copy.deepcopy(rows[-3:]))
write(STORE,'refund-review.json',refund)
# Account consolidation: known/unknown funding for two channels, plus a frozen exclusion.
account_rows=[]
for i,(channel,known) in enumerate([('微信支付',True),('微信支付',False),('ApplePay',True),('ApplePay',False)]):
    r=record('account-'+str(i),account='9001（银联7001）' if known else channel,
        items=[] if i==3 else None,credit=200 if i==3 else 0)
    if i==0: r['components'][0].update(refund_cents=500,net_cents=1900)
    if i==1: r['components'][0].update(included=False,reason='来源关联待确认')
    r.update(user_id='fixture-owner-a' if i==0 else 'fixture-user',payment_channels=[channel],payment_accounts=['9001（银联7001）'] if known else [],payment_account_status='identified' if known else 'unresolved')
    account_rows.append(r)
frozen=record('account-frozen',account='Frozen account');frozen.update(user_id='fixture-other',user_relation='other_user')
account_rows.append(frozen)
old=report(account_rows)
new=copy.deepcopy(old)
new['account_consolidation']=dict(display_name_prefixes=['fixture-owner-b · '],aliases={'余额宝':'余额宝','余额宝&红包':'余额宝','红包':None,'9001':'Synthetic bank card(9001)',
    '9001（银联7001）':'Synthetic bank card(9001)','9001（已确认来源的美团ApplePay）':'Synthetic bank card(9001)','微信支付':None,'ApplePay':None},excluded_lifecycle_ids=['account-frozen'])
for r in new['records'][:-1]:
    r['account_identity_before_consolidation']={k:copy.deepcopy(r[k]) for k in ['user_id','user_relation','payment_accounts','payment_account_status','account_views']}
    r['payment_accounts']=['Synthetic bank card(9001)'] if r['payment_account_status']=='identified' else []
    r['account_views']=r['payment_accounts']
write(STORE,'accounts-before.json',old)
write(STORE,'accounts-after.json',new)
account_draft=dict(primary='日常消费',secondary='餐饮',recurrence='one_time',tags=[])
write(STORE,'accounts-overrides.json',{'account-0:item':dict(**account_draft,completion_confirmation=dict(draft=account_draft,origin='manual'))})
(CORE/'preview.png').write_bytes(png)
