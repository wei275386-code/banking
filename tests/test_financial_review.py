import unittest
from scripts.financial_review import build as _build, classify, summarize
from scripts.payment_evidence import reference_clusters


SYNTHETIC_TAXONOMY = [
    {"primary": "住房相关", "secondaries": ["房租", "水电物业", "通信宽带"]},
    {"primary": "日常消费", "secondaries": ["餐饮", "咖啡茶饮", "商超食品", "衣物日用", "交通出行", "住宿", "个人护理", "首饰配饰", "网购", "购物", "休闲娱乐"]},
    {"primary": "旅行", "secondaries": ["交通住宿", "旅行活动"]},
    {"primary": "生产力工具", "secondaries": ["AI与软件订阅", "设备", "知识付费"]},
    {"primary": "医疗健康", "secondaries": ["医疗药品", "保险", "医美"]},
    {"primary": "亲友支持", "secondaries": ["亲友支持"]},
    {"primary": "亲友代付", "secondaries": ["亲友代付"]},
    {"primary": "杂项冗余", "secondaries": ["其他可选消费"]},
    {"primary": "待分类", "secondaries": ["待分类"]},
]


def build(report, bank_categories=None, overrides=None, taxonomy=None, catalog=None):
    return _build(report, bank_categories=bank_categories, overrides=overrides,
                  taxonomy=SYNTHETIC_TAXONOMY if taxonomy is None else taxonomy,
                  catalog=catalog)


def payment(key, amount=1000, platform="alipay", method="合成银行信用卡(0000)", **changes):
    return {"platform": platform, "transaction_time": "2026-02-12 13:00:00", "event_kind": "payment",
            "current_payment_state": "successful", "platform_reported_amount_cents": amount,
            "platform_paid_amount_cents": amount, "payment_method": method, "provider_reference": key,
            "merchant_reference": None, "merchant": "瑞幸", "title": "咖啡", "raw_status": "交易成功", **changes}


def bank(key=1, amount=1000, credit=0, description="Luckin Coffee"):
    return {"id": key, "date": "2026-02-12", "amount_cents": amount, "is_credit": credit,
            "description": description, "account_number": "0000"}


def source(rows=None, banks=None, links=None):
    return {"backfill_cutoff_date": "2026-09-13",
            "clusters": [{"cluster_id": key, "representative": row} for key, row in (rows or {}).items()],
            "bank_records": banks or [], "candidates": [{"record_ids": ids, "bank_ids": bank_ids,
                "review_required": False, "association_status": "supported_by_user"} for ids, bank_ids in (links or [])]}


class FinancialReviewTests(unittest.TestCase):
    def test_public_defaults_support_projection_without_private_seed(self):
        rows, _ = _build(source(banks=[bank(description="合成咖啡店")]))
        self.assertEqual(rows[0]['components'][0]['primary'], '日常消费')
        self.assertEqual(rows[0]['components'][0]['secondary'], '咖啡茶饮')


    def test_order_wallet_bank_are_one_lifecycle(self):
        p = source({"wx": payment("wx", platform="wechat"), "mt": payment("mt", platform="meituan")},
                   [bank()], [(["wx", "mt"], ["bank:1"])])
        rows, _ = build(p)
        self.assertEqual(len(rows), 1)
        self.assertEqual(summarize(rows, p["backfill_cutoff_date"])["net_cents"], 1000)
        self.assertEqual(len(rows[0]["events"]), 3)

    def test_combined_settlement_retains_two_purchase_components(self):
        p = source({"meal": payment("meal", 2818), "card": payment("card", 10, title="超级吃货卡")},
                   [bank(amount=2828)], [(["meal", "card"], ["bank:1"])])
        rows, _ = build(p)
        self.assertEqual([c["gross_cents"] for c in rows[0]["components"]], [2818, 10])
        self.assertEqual(summarize(rows, p["backfill_cutoff_date"])["net_cents"], 2828)

    def test_explicit_refund_reference_updates_original_lifecycle(self):
        p = source({"p": payment("original"), "r": payment("original_refund", 300, event_kind="refund",
            transaction_time="2026-03-01 13:00:00", raw_status="退款成功")})
        rows, links = build(p)
        self.assertEqual(len(rows), 1)
        self.assertEqual(len(links), 1)
        self.assertEqual(rows[0]["date"], "2026-02-12")
        self.assertEqual(rows[0]["components"][0]["net_cents"], 700)

    def test_full_refund_original_is_not_counted_twice(self):
        p = source({"p": payment("original", current_payment_state="fully_refunded"),
                    "r": payment("original_refund", event_kind="refund")})
        rows, _ = build(p)
        self.assertEqual(summarize(rows, p["backfill_cutoff_date"])["net_cents"], 0)

    def test_repayment_and_unallocated_bank_credit_are_not_consumption(self):
        p = source(banks=[bank(1, 100000, 1, "PAID BY AUTOPAY - THANK YOU"), bank(2, 2000, 1)])
        rows, _ = build(p)
        totals = summarize(rows, p["backfill_cutoff_date"])
        self.assertEqual(totals["net_cents"], 0)
        self.assertEqual(totals["unallocated_credit_cents"], 2000)

    def test_other_user_bank_purchase_and_unmatched_wallet_are_retained(self):
        b = bank(); b["human_transaction_confirmation"] = {"user_relation": "other_user"}
        p = source({"p": payment("p", 2000)}, [b])
        rows, _ = build(p)
        self.assertEqual(summarize(rows, p["backfill_cutoff_date"])["net_cents"], 3000)
        self.assertIn("other_user", [r["user_relation"] for r in rows])

    def test_possible_order_overlap_is_visible_but_not_double_counted(self):
        p = source({"mt": payment("mt", platform="meituan", method="ApplePay")}, [bank()])
        rows, _ = build(p)
        totals = summarize(rows, p["backfill_cutoff_date"])
        self.assertEqual(len(rows), 2)
        self.assertEqual(totals["net_cents"], 1000)
        self.assertEqual(totals["pending_gross_cents"], 1000)

    def test_channel_and_refund_status_are_not_categories(self):
        self.assertEqual(classify("MEITUAN | APPLE PAY-MOBILE:9076")[0], "待分类")
        self.assertEqual(classify("Alipay", "已退款")[0], "待分类")
        self.assertEqual(classify("OPENAI")[1], "AI与软件订阅")


if __name__ == "__main__":
    unittest.main()

class ConfirmedRefundAndCategoryTests(unittest.TestCase):
    def test_partial_bank_refund_is_linked_without_rewriting_gross(self):
        from scripts.payment_feedback import bank_signature
        debit = {**bank(1,268900,description='SYNTHETIC MERCHANT CHN CN'),'currency':'CNY'}
        credit = {**bank(2,266800,1,'SYNTHETIC MERCHANT CHN CN'),'currency':'CNY','date':'2026-02-13'}
        p = source(banks=[debit,credit])
        p['confirmed_bank_refund_links']=[{'original':'bank:1','refunds':['bank:2'],
            'bank_signatures':{'bank:1':bank_signature(debit),'bank:2':bank_signature(credit)}}]
        rows, links = build(p)
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]['components'][0]['id'],'bank:1')
        self.assertEqual(rows[0]['status'],'部分退款')
        totals=summarize(rows,p['backfill_cutoff_date'])
        self.assertEqual(totals['gross_cents'],268900)
        self.assertEqual(totals['refund_cents'],266800)
        self.assertEqual(totals['net_cents'],2100)
        self.assertEqual(totals['unallocated_credit_cents'],0)
        credit['amount_cents']=268900
        with self.assertRaises(ValueError):build(p)

    def test_split_refund_and_full_refund_state_do_not_double_subtract(self):
        from scripts.payment_feedback import bank_signature
        banks=[{**bank(1,9900,description='TL CHN CN'),'currency':'CNY'},
               {**bank(2,4950,1,'TL CHN CN'),'currency':'CNY'},
               {**bank(3,4950,1,'TL CHN CN'),'currency':'CNY'}]
        p=source({'ticket':payment('ticket',9900,platform='nihao_china',merchant='中国铁路',
                                  title='中国铁路',current_payment_state='fully_refunded')},banks,[(['ticket'],['bank:1'])])
        p['confirmed_bank_refund_links']=[{'original':'bank:1','refunds':['bank:2','bank:3'],
            'bank_signatures':{f"bank:{b['id']}":bank_signature(b) for b in banks}}]
        rows,_=build(p)
        self.assertEqual(len(rows),1)
        self.assertEqual(rows[0]['components'][0]['primary'],'待分类')
        self.assertEqual(rows[0]['components'][0]['secondary'],'待分类')
        self.assertEqual(rows[0]['components'][0]['refund_cents'],9900)
        self.assertEqual(summarize(rows,p['backfill_cutoff_date'])['net_cents'],0)

    def test_parent_payment_category_precedes_product_inference(self):
        p=source({'family':payment('family',title='咖啡',raw={'交易分类':'亲友代付'})})
        rows,_=build(p)
        self.assertEqual(rows[0]['components'][0]['primary'],'亲友代付')
        self.assertEqual(classify('马少火原汤牛肉面')[1],'待分类')

    def test_supplement_preserves_bank_classification_and_override_id(self):
        p=source({'screen':payment('screen',platform='nihao_china',merchant='迅销（中国）商贸UNI…',title='迅销（中国）商贸UNI…')},
                 [bank(description='FAST RETAILING UNIQLO CHN CN')],[(['screen'],['bank:1'])])
        rows,_=build(p)
        self.assertEqual(rows[0]['components'][0]['id'],'bank:1')
        self.assertEqual(rows[0]['components'][0]['secondary'],'衣物日用')


class LifecycleRegressionTests(unittest.TestCase):
    def refunded_purchase(self, linked_refunds=True, amount=2000):
        rows = {
            'wx': payment('wx-original', 10000, platform='wechat', merchant_reference='wx-order'),
            'mt': payment('mt-original', 10000, platform='meituan', merchant_reference='mt-order'),
            'wx-refund': payment('wx-refund', amount, platform='wechat', merchant_reference='wx-order',
                                 event_kind='refund', transaction_time='2026-03-01 13:00:00'),
            'mt-refund': payment('mt-refund', amount, platform='meituan', merchant_reference='mt-order',
                                 event_kind='refund', transaction_time='2026-03-01 13:00:00'),
        }
        links = [(['wx', 'mt'], ['bank:1'])]
        banks = [bank(amount=10000)]
        if linked_refunds:
            banks.append({**bank(2, amount, 1), 'date': '2026-03-01'})
            links += [(['wx-refund', 'mt-refund'], []), (['wx-refund'], ['bank:2'])]
        return source(rows, banks, links)

    def test_same_partial_refund_in_order_wallet_and_bank_counts_once(self):
        p = self.refunded_purchase()
        rows, _ = build(p)
        totals = summarize(rows, p['backfill_cutoff_date'])
        self.assertEqual(len(rows), 1)
        self.assertEqual(totals['refund_cents'], 2000)
        self.assertEqual(totals['net_cents'], 8000)
        self.assertEqual(len(rows[0]['events']), 6)

    def test_full_refund_observed_in_multiple_sources_is_not_over_refunded(self):
        p = self.refunded_purchase(amount=10000)
        rows, _ = build(p)
        totals = summarize(rows, p['backfill_cutoff_date'])
        self.assertEqual(totals['included_components'], 1)
        self.assertEqual(totals['refund_cents'], 10000)
        self.assertEqual(totals['net_cents'], 0)
        self.assertEqual(totals['pending_components'], 0)

    def test_unconfirmed_cross_source_refund_identity_is_pending(self):
        p = self.refunded_purchase(linked_refunds=False)
        rows, _ = build(p)
        self.assertFalse(rows[0]['components'][0]['included'])
        self.assertIn('退款事件关联待确定', rows[0]['components'][0]['reason'])

    def test_equal_independent_refunds_in_same_wallet_are_both_counted(self):
        p = source({'p': payment('original', 10000),
                    'r1': payment('original_refund1', 2000, event_kind='refund'),
                    'r2': payment('original_refund2', 2000, event_kind='refund')})
        rows, _ = build(p)
        self.assertEqual(rows[0]['components'][0]['refund_cents'], 4000)
        self.assertEqual(rows[0]['components'][0]['net_cents'], 6000)

    def test_different_refund_events_each_seen_in_two_sources_keep_both(self):
        p = self.refunded_purchase()
        p['clusters'] += [
            {'cluster_id': 'wx-refund2', 'representative': payment('wx-refund2', 2000,
                platform='wechat', merchant_reference='wx-order', event_kind='refund',
                transaction_time='2026-03-02 13:00:00')},
            {'cluster_id': 'mt-refund2', 'representative': payment('mt-refund2', 2000,
                platform='meituan', merchant_reference='mt-order', event_kind='refund',
                transaction_time='2026-03-02 13:00:00')},
        ]
        p['candidates'] += source(links=[(['wx-refund2', 'mt-refund2'], [])])['candidates']
        rows, _ = build(p)
        self.assertEqual(rows[0]['components'][0]['refund_cents'], 4000)
        self.assertEqual(rows[0]['components'][0]['net_cents'], 6000)

    def conflict_report(self, amounts=(1000, 2000), states=('successful', 'successful')):
        observations = []
        for i, (amount, state) in enumerate(zip(amounts, states)):
            observations.append(payment('same-order', amount, current_payment_state=state,
                observation_id=f'observation-{i}', observed_at=None, raw_direction='支出',
                currency='CNY', source_profile_id='profile-a'))
        p = source()
        p['clusters'] = reference_clusters(observations)
        return p

    def test_conflicting_amount_is_retained_but_excluded_from_consumption(self):
        p = self.conflict_report()
        rows, _ = build(p)
        self.assertEqual(len(rows), 1)
        self.assertEqual(summarize(rows, p['backfill_cutoff_date'])['net_cents'], 0)
        self.assertIn('来源记录字段冲突', rows[0]['components'][0]['reason'])

    def test_unordered_payment_status_is_not_assumed_to_be_fully_refunded(self):
        p = self.conflict_report((1000, 1000), ('successful', 'fully_refunded'))
        rows, _ = build(p)
        self.assertFalse(rows[0]['components'][0]['included'])
        self.assertIn('支付状态先后待确定', rows[0]['components'][0]['reason'])

    def test_conflict_in_refund_evidence_cannot_silently_reduce_bank_purchase(self):
        p = self.refunded_purchase()
        next(c for c in p['clusters'] if c['cluster_id'] == 'wx-refund')['conflicting_fields'] = ['platform_reported_amount_cents']
        rows, _ = build(p)
        self.assertFalse(rows[0]['components'][0]['included'])
        self.assertIn('来源记录字段冲突', rows[0]['components'][0]['reason'])

    def test_bank_classification_and_recurrence_survive_wallet_link(self):
        override = {'bank:1': {'primary': '生产力工具', 'secondary': '设备', 'recurrence': 'one_time'}}
        for platform in ('wechat', 'alipay', 'meituan'):
            with self.subTest(platform=platform):
                p = source({'wallet': payment('wallet', platform=platform)}, [bank()], [(['wallet'], ['bank:1'])])
                rows, _ = build(p, overrides=override)
                c = rows[0]['components'][0]
                self.assertEqual(c['id'], 'bank:1')
                self.assertEqual((c['primary'], c['secondary'], c['recurrence']), ('生产力工具', '设备', 'one_time'))

    def test_old_wallet_override_is_available_after_canonical_bank_id(self):
        override = {'wallet': {'primary': '生产力工具', 'secondary': '设备', 'recurrence': 'one_time'}}
        p = source({'wallet': payment('wallet')}, [bank()], [(['wallet'], ['bank:1'])])
        rows, _ = build(p, overrides=override)
        c = rows[0]['components'][0]
        self.assertEqual(c['id'], 'bank:1')
        self.assertIn('wallet', c['classification_keys'])
        self.assertEqual(c['recurrence'], 'one_time')
        self.assertEqual(c['primary'], '生产力工具')

    def test_combined_purchases_do_not_inherit_one_bank_override(self):
        p = source({'meal': payment('meal', 2818), 'card': payment('card', 10)},
                   [bank(amount=2828)], [(['meal', 'card'], ['bank:1'])])
        rows, _ = build(p, overrides={'bank:1': {'primary': '生产力工具', 'secondary': '设备'}})
        self.assertEqual({c['id'] for c in rows[0]['components']}, {'meal', 'card'})
        self.assertTrue(all(c['primary'] != '生产力工具' for c in rows[0]['components']))

class ReviewTagTests(unittest.TestCase):
    def test_confirmed_merchant_rule_reuses_purpose_without_reclassifying_payment_channel(self):
        p = source({'meal': payment('meal', merchant='合成水煮鱼（示例甲店）', title='双人餐')})
        p['classification_rules'] = [{'merchant':'合成水煮鱼（示例甲店）','primary':'日常消费','secondary':'餐饮','tags':[]}]
        rows,_ = build(p)
        c = rows[0]['components'][0]
        self.assertEqual(c['secondary'], '餐饮')
        self.assertEqual(c['classification_basis'], '已确认商户规则')
        self.assertEqual(classify('MEITUAN CHN CN')[0], '待分类')
        self.assertEqual(classify('tencent CHN CN')[0], '待分类')
        self.assertEqual(classify('SYNTHETIC UNKNOWN CHN CN')[0], '待分类')
        masked_rule=[{'merchant':'合成***店','primary':'日常消费','secondary':'餐饮','tags':[]}]
        self.assertEqual(classify('合成***店 · /',rules=masked_rule)[0],'待分类')

    def test_multiple_tags_preserve_refund_net_and_empty_override_removes_inferred_tags(self):
        p = source({'p': payment('p', merchant='株式会社ローソン', title='合成便利店商品', amount=1000),
                    'r': payment('p_refund', merchant='株式会社ローソン', title='退款', amount=300, event_kind='refund')})
        rows,_ = build(p)
        c = rows[0]['components'][0]
        self.assertEqual(c['secondary'], '商超食品')
        self.assertTrue({'便利店','罗森'}.issubset(c['tags']))
        self.assertNotIn('旅行场景', c['tags'])
        stats = summarize(rows,p['backfill_cutoff_date'])
        self.assertEqual(stats['net_cents'],700)
        self.assertEqual(stats['by_tag']['便利店'],700)
        override = {c['id']:{'primary':'日常消费','secondary':'商超食品','tags':[]}}
        again,_ = build(p,overrides=override)
        self.assertEqual(again[0]['components'][0]['tags'],[])
        self.assertEqual(summarize(again,p['backfill_cutoff_date'])['net_cents'],700)

    def test_platform_tags_do_not_replace_specific_product_or_confirm_japan_from_date(self):
        p = source({'shop':payment('shop',merchant='小红书',title='知识星球课程'),
                    'brand':payment('brand',merchant='UNIQLO',title='Pay for others')})
        rows,_ = build(p)
        by_title={r['title']:r['components'][0] for r in rows}
        shop=next(c for c in by_title.values() if '小红书' in c['title'])
        self.assertEqual(shop['secondary'],'知识付费')
        self.assertIn('小红书',shop['tags'])
        uniqlo=next(c for c in by_title.values() if 'UNIQLO' in c['title'])
        self.assertNotIn('旅行场景',uniqlo['tags'])
        from scripts.review_annotations import inferred_tags
        station_shop,_=inferred_tags('SEVEN ELEVEN, MTR SYNTHETIC STATION',secondary='商超食品')
        self.assertIn('便利店',station_shop)
        self.assertNotIn('地铁',station_shop)

    def test_explicit_trip_rule_and_treat_context_preserve_purpose(self):
        p=source(banks=[bank(1,1000,description='合成甲站-合成乙站'),bank(2,2000,description='某餐厅')])
        p['classification_rules'] = [{'merchant':'合成甲站-合成乙站', 'primary':'日常消费', 'secondary':'交通出行', 'tags':['合成行程']}]
        rows,_=build(p,bank_categories={2:'请客'})
        rail=next(r['components'][0] for r in rows if 'bank:1' in r['evidence_keys'])
        treat=next(r['components'][0] for r in rows if 'bank:2' in r['evidence_keys'])
        self.assertEqual(rail['secondary'],'交通出行');self.assertIn('合成行程',rail['tags'])
        self.assertEqual(treat['secondary'],'餐饮');self.assertIn('请客',treat['tags'])
