"""Household transaction lifecycles derived from retained evidence, not account rows.

The bank ledger is never rewritten. Accepted observations enrich one lifecycle;
combined settlement retains purchase components. Uncertain overlap, cash transfers
and unallocated refunds are explicit, not silently included in consumption.
"""
from __future__ import annotations

import argparse
import copy
import json
import re
import sqlite3
from collections import defaultdict
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.coverage_policy import reliable_date, reliable_observations, recompute

try:
    from .category_catalog import Catalog, seed_taxonomy
    from .financial_review_inputs import FinancialReviewInputs
    from .review_annotations import purpose_category
    from .payment_evidence import digest, has_resolved_funding
    from .review_annotations import annotate, confirmed_rule, normalized, InferencePolicy
    from .source_reconciliation import reconcile, account_identity, explicit_refund_pairs
    from .account_consolidation import apply as consolidate_accounts, snapshot_policy, unresolved_items
    from .transaction_dedup import event_projection, reconcile_settlements, apply_date_confirmations, reconcile_card_sources, decorate_payment_accounts
except ImportError:
    from category_catalog import Catalog, seed_taxonomy
    from financial_review_inputs import FinancialReviewInputs
    from review_annotations import purpose_category
    from payment_evidence import digest, has_resolved_funding
    from review_annotations import annotate, confirmed_rule, normalized, InferencePolicy
    from source_reconciliation import reconcile, account_identity, explicit_refund_pairs
    from account_consolidation import apply as consolidate_accounts, snapshot_policy, unresolved_items
    from transaction_dedup import event_projection, reconcile_settlements, apply_date_confirmations, reconcile_card_sources, decorate_payment_accounts



RULES = [
    ("日常消费", "咖啡茶饮", r"LUCKIN|瑞幸|咖啡|COFFEE|\bCAFE\b|HEYTEA|喜茶|茶咖|奈雪|蜜雪|STARBUCKS|霸王茶姬|奶茶"),
    ("日常消费", "交通出行", r"DI DI|滴滴|地铁|乘车|打车|出租车|铁路|火车票|12306|站[-–].*站|骑行|单车|港鐵"),
    ("日常消费", "商超食品", r"7\W?ELEVEN|SEVEN.?ELEVEN|ELEVEN 7|711便利|赛壹便利|ローソン|罗森|美宜佳|便利店|超市|AEON|盒马|叮咚买菜|山姆|沃尔玛|菜市场|纯净水|Wellcome"),
    ("日常消费", "衣物日用", r"UNIQLO|优衣库|衣服|裤子|衣物|纸巾|洗衣|清洁用品"),
    ("日常消费", "个人护理", r"理发|剪发|护发|牙膏|洗发水"),
    ("生产力工具", "AI与软件订阅", r"OPENAI|ANTHROPIC|CLAUDE|CURSOR|软件订阅|云服务器|阿里云|火山引擎|DeepSeek.*API"),
    ("生产力工具", "知识付费", r"知识付费|知识星球|课程|电子书|图书|书籍"),
    ("医疗健康", "医美", r"医美|美容医院"),
    ("医疗健康", "医疗药品", r"医院|药房|药店|体检|牙科|眼科|挂号"),
    ("医疗健康", "保险", r"保险|INSURANCE"),
    ("住房相关", "通信宽带", r"CHINA UNITED|CHINA UNICOM|中国联通|中国移动|中国电信|宽带|话费"),
    ("住房相关", "房租", r"房租|租金"),
    ("住房相关", "水电物业", r"水费|电费|物业费|燃气"),
    ("日常消费", "交通出行", r"AIRLINES|机票"),
    ("旅行", "交通住宿", r"CTRIP|TRIP\.COM|HOTEL|酒店"),
    ("亲友支持", "亲友支持", r"亲友支持|亲友赠与"),
    ("日常消费", "餐饮", r"外卖|麻辣烫|麻辣拌|餐厅|餐饮|海底捞|麦当劳|MCDONALD|SUSHIRO|SUSHI CATERING|寿司|ELEME PLATFORM|肯德基|烧烤|饭店|吃货卡|水煮鱼|沙县|鸡排|比萨|螺蛳粉|砂锅粥|汤粉|铁板烧|烧肉|生蚝|饺子|牛肉粉|小吃|手工面|拉面|烤肉|鸡柳|新疆菜|川菜|鸡爪|吉野家|洋食|焼肉|カレー"),
    ("日常消费", "休闲娱乐", r"动物园|動物園|门票|博物馆"),
]
EXPLICIT_CATEGORIES = {"出去吃": ("日常消费", "外卖餐饮"), "请客": ("日常消费", "人情请客"),
          "买衣服": ("日常消费", "衣物日用"), "理发": ("日常消费", "个人护理"),
          "超市": ("日常消费", "商超食品"), "知识付费": ("生产力工具", "知识付费"),
          "医美": ("医疗健康", "医美")}


def classify(title, existing_category=None, rules=(), *, policy=None):
    title = normalized(title)
    rule = confirmed_rule(title, rules)
    if rule:
        return rule["primary"], rule["secondary"], "已确认商户规则"
    if policy is not None:
        matches = policy.matching("category", text=title, category_text=re.sub(r"APPLE PAY-MOBILE:\d+|APPLE PAY|UNIONPAY QR", "", title, flags=re.I), existing_category=existing_category)
        if matches:
            effect = matches[0]
            return effect["primary"], effect["secondary"], effect.get("basis", "家庭规则")
    if existing_category in EXPLICIT_CATEGORIES:
        return *EXPLICIT_CATEGORIES[existing_category], "已有显式分类"
    # Apple Pay is a payment route, not an Apple purchase or a software category.
    text = re.sub(r"APPLE PAY-MOBILE:\d+|APPLE PAY|UNIONPAY QR", "", title, flags=re.I)
    for primary, secondary, pattern in RULES:
        if re.search(pattern, text, re.I):
            return primary, secondary, "规则推断"
    return "待分类", "待分类", "证据不足"


def valid_override(value, taxonomy=None, catalog=None):
    if not isinstance(value, dict) or not isinstance(value.get("primary"), str) or not isinstance(value.get("secondary"), str):
        return False
    if catalog is not None:
        return catalog.contains(value["primary"], value["secondary"]) or catalog.contains(*purpose_category(value["primary"], value["secondary"], value.get("purpose", "")))
    # Compatibility for callers producing an initial, unpersisted review.
    initial = Catalog.from_taxonomy(taxonomy if taxonomy is not None else seed_taxonomy())
    p, s = purpose_category(value["primary"], value["secondary"], value.get("purpose", ""))
    return initial.contains(p, s)


def build(report, bank_categories=None, overrides=None, taxonomy=None, catalog=None):
    bank_categories, overrides = bank_categories or {}, overrides or {}
    policy = InferencePolicy(report.get("inference_policy"))
    managed = catalog is not None
    catalog = catalog or Catalog.from_taxonomy(taxonomy if taxonomy is not None else seed_taxonomy())
    def valid(value):
        if not isinstance(value, dict) or not isinstance(value.get("primary"), str) or not isinstance(value.get("secondary"), str):
            return False
        if managed:
            return catalog.contains(value["primary"], value["secondary"]) or catalog.contains(*purpose_category(value["primary"], value["secondary"], value.get("purpose", ""), policy=policy))
        return catalog.contains(*purpose_category(value["primary"], value["secondary"], value.get("purpose", ""), policy=policy))
    cutoff = report["backfill_cutoff_date"]
    clusters = {c["cluster_id"]: c for c in report["clusters"]}
    rows = {key: c["representative"] for key, c in clusters.items()}
    banks = {f"bank:{b['id']}": b for b in report["bank_records"]}
    observations = {**rows, **banks}
    parents = {key: key for key in observations}
    # Event identity is narrower than purchase lifecycle identity. Linking two
    # refunds to one original purchase does not make them the same refund.
    refund_parents = {key: key for key in observations if
                      (key in rows and rows[key]["event_kind"] == "refund") or
                      (key in banks and banks[key]["is_credit"])}

    def refund_event(key):
        if refund_parents[key] != key:
            refund_parents[key] = refund_event(refund_parents[key])
        return refund_parents[key]

    def find(key):
        if parents[key] != key:
            parents[key] = find(parents[key])
        return parents[key]

    def union(keys):
        for key in keys[1:]:
            parents[find(key)] = find(keys[0])

    accepted = [c for c in report["candidates"] if not c["review_required"] and c["association_status"] in ("supported_by_user", "rule_supported")]
    covered_funding = {(b['funding_account_id'], b['currency']) for b in banks.values()
                       if has_resolved_funding(b)}
    for c in accepted:
        keys = c["record_ids"] + c["bank_ids"]
        union(keys)
        same_refund = [key for key in keys if key in refund_parents]
        for key in same_refund[1:]:
            refund_parents[refund_event(key)] = refund_event(same_refund[0])

    # Bank-only refund links are scoped to immutable evidence signatures.
    try:
        from .payment_feedback import bank_signature
    except ImportError:
        from payment_feedback import bank_signature
    bank_refund_links = []
    for link in report.get("confirmed_bank_refund_links", []):
        debit = banks.get(link["original"])
        credits = [banks.get(k) for k in link["refunds"]]
        if not debit or debit["is_credit"] or any(not b or not b["is_credit"] for b in credits):
            raise ValueError("Invalid confirmed bank refund link")
        keys = [link["original"]] + link["refunds"]
        if any(bank_signature(banks[k]) != link["bank_signatures"].get(k) for k in keys):
            raise ValueError("Confirmed refund evidence changed")
        if any(b["account_number"] != debit["account_number"] or b["currency"] != debit["currency"] or b["date"] < debit["date"] for b in credits):
            raise ValueError("Refund account, currency or time differs")
        union(keys)
        bank_refund_links.append(link)

    # Provider references remain scoped to compatible source users/profiles.
    refund_links = list(bank_refund_links)
    for key, target in explicit_refund_pairs(rows):
        union([target, key])
        refund_links.append({"refund": key, "original": target, "basis": "原始订单编号及来源用户一致"})

    groups = defaultdict(list)
    for key in observations:
        groups[find(key)].append(key)
    records = []
    for keys in groups.values():
        br = [(k, banks[k]) for k in keys if k in banks]
        wr = [(k, rows[k]) for k in keys if k in rows]
        pay = [(k, r) for k, r in wr if r["event_kind"] == "payment" and r.get('duplicate_settlement_key') not in keys]
        refunds = [(k, r) for k, r in wr if r["event_kind"] == "refund"]
        dates = [d for _, r in pay if (d := reliable_date(r.get("transaction_time")))] or [d for _, b in br if (d := reliable_date(b.get("date")))] or [d for _, r in wr if (d := reliable_date(r.get("transaction_time")))]
        if not dates:
            continue
        date = min(dates)
        wallet_types = {r["event_kind"] for _, r in wr}
        bank_desc = " | ".join(dict.fromkeys(b["description"] for _, b in br))
        repayment = bool(re.search(r"IFS PAYMENT|PAID BY AUTOPAY|PAYMENT - THANK YOU", bank_desc, re.I)) or (wallet_types == {"repayment"})
        non_consumption = repayment or (wr and not pay and not br and wallet_types.issubset({"receipt", "transfer_or_gift", "authorization", "repayment"}))
        bank_debits = [(k, b) for k, b in br if not b["is_credit"]]
        bank_credits = [(k, b) for k, b in br if b["is_credit"] and not repayment]
        gross = sum(b["amount_cents"] for _, b in bank_debits)
        if not bank_debits:
            # Meituan and its payment wallet describe the same purchase. Use the
            # settlement wallet, or the order alone, never sum both observations.
            settlement = [(k, r) for k, r in pay if r["platform"] in ("wechat", "alipay")] or [(k, r) for k, r in pay if r["platform"] == "meituan"] or [(k, r) for k, r in pay if r["platform"] == "unionpay"] or pay
            gross = sum(r["platform_paid_amount_cents"] if r.get("platform_paid_amount_cents") is not None else (r.get("platform_reported_amount_cents") or 0) for _, r in settlement)
        else:
            settlement = [(k, r) for k, r in pay if r["platform"] in ("wechat", "alipay")] or [(k, r) for k, r in pay if r["platform"] == "meituan"] or [(k, r) for k, r in pay if r["platform"] == "unionpay"] or pay
        reasons = []
        for key, _ in wr:
            cluster = clusters[key]
            if cluster.get("conflicting_fields"):
                reasons.append("来源记录字段冲突：" + "、".join(cluster["conflicting_fields"]))
            if cluster.get("status_order_unresolved"):
                reasons.append("支付状态先后待确定")
        if any(r.get('settlement_overlap_pending') for _, r in wr):
            reasons.append('亲情卡多条来源资金事件配对待确定')

        refund_groups, route_events = defaultdict(lambda: defaultdict(int)), defaultdict(set)
        for key, row in refunds:
            # Both family-card accounts export the same Alipay refund. Keep
            # both pieces of evidence, count the identified funding event once.
            if row.get('duplicate_settlement_key') in keys:
                continue
            event = refund_event(key)
            refund_groups[event][row["platform"]] += row.get("platform_reported_amount_cents") or 0
            route_events[row["platform"]].add(event)
            if row.get("platform_reported_amount_cents") is None:
                reasons.append("退款金额待确定")
        for key, row in bank_credits:
            event = refund_event(key)
            refund_groups[event]["bank"] += row["amount_cents"]
            route_events["bank"].add(event)
        refund_amount = 0
        for amounts in refund_groups.values():
            if len(set(amounts.values())) > 1:
                reasons.append("已关联退款事件金额冲突")
            refund_amount += amounts.get("bank", max(amounts.values()))
        # Equal amounts alone cannot deduplicate independent partial refunds.
        # Unpaired refund events on different routes need an association review.
        routes = list(route_events.values())
        if any(a - b and b - a for i, a in enumerate(routes) for b in routes[i + 1:]):
            reasons.append("跨来源退款事件关联待确定")
        full_refund = any(r["current_payment_state"] == "fully_refunded" for _, r in pay)
        if full_refund:
            refund_amount = max(refund_amount, gross)
        cancelled = bool(pay) and all(r["current_payment_state"] == "cancelled" for _, r in pay) and not bank_debits
        non_consumption = non_consumption or cancelled
        if not bank_debits and pay and any(r.get("platform_paid_amount_cents") is None and r.get("platform_reported_amount_cents") is None for _, r in settlement): reasons.append("支付金额待确定")
        if not br and any(r['event_kind'] == 'unknown' and r.get('duplicate_settlement_key') not in keys for _, r in wr): reasons.append("交易类型待确定")
        if cutoff is None or date > cutoff:
            reasons.append("截止日之后")
        if any(r.get("video_overlap_pending") for _, r in settlement):
            reasons.append("录屏记录与已有来源的关联待确定")
        if any(r.get("date_basis") == "year_label_conflicts_weekday" for _, r in settlement):
            reasons.append("年份筛选与日期星期不一致")
        if not bank_debits and any(r["platform"] == "meituan" and r.get("payment_method") in ("ApplePay", "微信支付") for _, r in settlement):
            reasons.append("订单与已有支付记录可能重叠")
        if not bank_debits and any(has_resolved_funding(r) and
                (r['funding_account_id'], r['currency']) in covered_funding for _, r in settlement):
            reasons.append("与已覆盖银行账户的关联待确定")
        if not bank_debits and pay and any(r.get('funding_resolution', {}).get('status') in ('needs_review', 'non_funding') for _, r in settlement):
            reasons.append("资金账户规则待确认")
        if any(r["current_payment_state"] in ("partially_refunded", "refund_reported") for _, r in pay) and not refunds:
            reasons.append("退款金额待确定")
        if any(r["current_payment_state"] == "cancelled" for _, r in pay) and not bank_debits:
            gross = 0
        standalone_refund = (bool(refunds) or bool(bank_credits)) and not pay and not bank_debits
        if standalone_refund and not repayment:
            reasons.append("退款或贷记待关联原交易")
        if refund_amount > gross and gross:
            reasons.append("退款超过原支付金额")
        owners = sorted({r["owner_id"] for _, r in wr if r.get("owner_id")})
        owners += [b["owner_id"] for _, b in br if b.get("owner_id") and b["owner_id"] not in owners]
        if len(owners) > 1:
            reasons.append("交易用户归属冲突")
        included = not reasons and not non_consumption and not standalone_refund and cutoff is not None and date <= cutoff
        net = max(0, gross - refund_amount)
        components = []
        multiple = len(settlement) > 1 and sum(r.get("platform_reported_amount_cents") or 0 for _, r in settlement) == gross
        items = settlement if multiple else [(settlement[0][0], settlement[0][1])] if settlement else [(bank_debits[0][0], None)] if bank_debits else [(br[0][0], None)] if br else [(wr[0][0], wr[0][1])]
        for key, source in items:
            title = " · ".join(dict.fromkeys(x for x in ([source.get("merchant"), source.get("title")] if source else [bank_desc.split(" | APPLE PAY")[0]]) if x)) or "原始交易"
            title_rules = policy.matching("title", text=title, source_kind="wallet" if source else "bank")
            if title_rules:
                title = title_rules[0]["prefix"] + title
            if not source and re.search(r"\bTL CHN CN\b", title):
                title = "铁路车票 · " + title
            # Prefer order details when the lifecycle has a verified order link.
            order = next((r for _, r in pay if r["platform"] == "meituan"), None)
            if order and not multiple:
                title = order.get("title") or title
            classification_text = title + (" | " + bank_desc if source and source["platform"] == "nihao_china" else "")
            existing_category = bank_categories.get(br[0][1]["id"]) if br else None
            rules = report.get("classification_rules", [])
            primary, secondary, basis = classify(classification_text, existing_category, rules, policy=policy)
            if re.search(r"\bTL CHN CN\b", bank_desc, re.I):
                primary, secondary, basis = classify(bank_desc, existing_category, rules, policy=policy)
            amount = (source.get("platform_reported_amount_cents") or 0) if multiple else gross
            component_id = bank_debits[0][0] if len(bank_debits) == 1 and not multiple else key
            classification_keys = list(dict.fromkeys([component_id, key] +
                (sorted(k for k, _ in pay) if not multiple else [])))
            override = next((overrides[k] for k in classification_keys if valid(overrides.get(k))), None)
            if source and source.get("raw", {}).get("交易分类") == "亲友代付":
                primary, secondary, basis = "亲友代付", "亲友代付", "用户确认：亲友代付独立一级分类"
            if valid(override):
                primary, secondary, basis = override["primary"], override["secondary"], "人工分类"
                title = override.get("title") or title
            tag_text = title + " | " + bank_desc
            if source: tag_text += " | " + (source.get("merchant") or "") + " | " + (source.get("title") or "")
            primary, secondary, tags, tag_basis = annotate(primary, secondary, tag_text,
                existing_category=existing_category, platform=source["platform"] if source else None,
                rules=rules, override=override, policy=policy)
            # Explicit categories remain bound to identities in the selected catalog.
            if managed and valid(override) and catalog.contains(override["primary"], override["secondary"]):
                primary, secondary = override["primary"], override["secondary"]
            # Grouped purchases retain their individual costs. Refund allocation
            # across multiple items requires evidence, not pro-rata guessing.
            allocated_refund = refund_amount if not multiple else 0
            component_included = included and not (multiple and refund_amount)
            components.append({"id": component_id, "classification_keys": classification_keys,
                               "title": title, "gross_cents": amount,
                               "refund_cents": min(amount, allocated_refund), "net_cents": max(0, amount - allocated_refund),
                               "primary": primary, "secondary": secondary, "classification_basis": basis,
                               "tags": tags, "tag_basis": tag_basis,
                               "recurrence": override.get("recurrence", "unconfirmed") if valid(override) else "unconfirmed",
                               "included": component_included, "reason": "；".join(dict.fromkeys(reasons + (["组合退款分配待确定"] if multiple and refund_amount else [])))})
            if valid(override) and override.get("completion_confirmation"):
                components[-1]["completion_confirmation"] = copy.deepcopy(override["completion_confirmation"])
            catalog.applying(components[-1])
        events = []
        for key, row in wr:
            events.append({"id": key, "date": row["transaction_time"], "kind": row["event_kind"], "source": row["platform"],
                           "amount_cents": row.get("platform_reported_amount_cents") or 0, "status": row["raw_status"]})
        for key, bank in br:
            events.append({"id": key, "date": bank["date"], "kind": "repayment" if repayment else "bank_credit" if bank["is_credit"] else "bank_debit",
                           "source": "bank", "amount_cents": bank["amount_cents"], "status": bank["description"]})
        account_views = sorted({str(b["account_number"])[-4:] for _, b in br} | {r["payment_method"] for _, r in wr if r.get("payment_method") not in (None, "", "/")})
        relation = next((b["human_transaction_confirmation"].get("user_relation") for _, b in br if b.get("human_transaction_confirmation")), None)
        status = "已取消" if cancelled else "非消费资金流" if non_consumption else "退款待关联" if standalone_refund else "全额退款" if gross and net == 0 else "部分退款" if refund_amount else "支付成立"
        records.append({"id": digest("lifecycle-v1", sorted(keys)), "date": date,
                        "title": components[0]["title"], "status": status,
                        "account_views": account_views, "evidence_keys": sorted(keys), "components": components,
                        "events": sorted(events, key=lambda e: (e["date"], e["id"])),
                        "payment_events": event_projection(events, accepted, rows),
                        "user_id": owners[0] if len(owners) == 1 else None,
                        "user": owners[0] if len(owners) == 1 else None,
                        "user_basis": "用户指定素材归属，经可靠关联传播" if len(owners) == 1 else "归属冲突" if owners else "未确认",
                        "user_relation": relation or "unknown", "non_consumption": bool(non_consumption),
                        "unallocated_credit_cents": refund_amount if standalone_refund else 0})
    return sorted(records, key=lambda r: (r["date"], r["id"]), reverse=True), refund_links


def summarize(records, cutoff, since=None):
    if since is None and cutoff is not None:
        since = min((r["date"] for r in records if reliable_date(r.get("date"))), default=None)
    included, pending = [], []
    by_month, by_primary, by_secondary, by_tag = defaultdict(int), defaultdict(int), defaultdict(int), defaultdict(int)
    unallocated = 0
    for r in records:
        if since is None or cutoff is None or not since <= r["date"] <= cutoff or r["non_consumption"]:
            continue
        unallocated += r["unallocated_credit_cents"]
        for c in r["components"]:
            if c["included"]:
                included.append(c)
                by_month[r["date"][:7]] += c["net_cents"]
                by_primary[c["primary"]] += c["net_cents"]
                by_secondary[c["primary"] + " / " + c["secondary"]] += c["net_cents"]
                for tag in set(c.get("tags", [])): by_tag[tag] += c["net_cents"]
            elif c["reason"]:
                pending.append(c)
    return {"from": since, "to": cutoff, "included_components": len(included),
            "gross_cents": sum(c["gross_cents"] for c in included), "refund_cents": sum(c["refund_cents"] for c in included),
            "net_cents": sum(c["net_cents"] for c in included), "pending_components": len(pending),
            "pending_gross_cents": sum(c["gross_cents"] for c in pending), "unallocated_credit_cents": unallocated,
            "unclassified_cents": by_primary.get("待分类", 0), "by_month": dict(sorted(by_month.items())),
            "by_primary": dict(by_primary), "by_secondary": dict(by_secondary), "by_tag": dict(by_tag)}


def run(root, output):
    root, output = Path(root), Path(output)
    inputs = FinancialReviewInputs.load(root, output)
    report, video_results, state = inputs.report, inputs.video_results, inputs.state
    confirmed_outcomes = inputs.confirmed_outcomes()
    undated = [c for c in report["clusters"] if not reliable_date(c["representative"].get("transaction_time"))]
    report["clusters"] = [c for c in report["clusters"] if reliable_date(c["representative"].get("transaction_time"))]
    report["bank_records"] = [b for b in report["bank_records"] if reliable_date(b.get("date"))]
    inputs.inferred_associations()
    report["confirmed_bank_refund_links"] = state.get("confirmed_bank_refund_links", [])
    account_policy = inputs.account_policy()
    from scripts.household_settings import project_funding, project_household_records
    settings, setting_sources = inputs.household_settings()
    project_funding([c['representative'] for c in report['clusters']], report['bank_records'], settings, setting_sources)
    confirmed_dates = apply_date_confirmations(report, state)
    coverage = recompute(inputs.coverage(), reliable_observations(report))
    report["backfill_cutoff_date"] = coverage["to"]
    reconciliation = reconcile(report, state)
    card_links = reconcile_card_sources(report, state, account_policy)
    reconciliation += card_links
    report["classification_rules"] = inputs.classification_rules()
    report["inference_policy"] = inputs.inference_policy()
    overrides = inputs.overrides()
    bank_categories = inputs.bank_categories()
    previous = inputs.previous_projection()
    catalog = inputs.catalog(previous)
    records, refund_links = build(report, bank_categories, overrides, catalog=catalog)
    records, settlement_groups = reconcile_settlements(records, report, state, overrides,
        (account_policy or {}).get('excluded_records', {}), previous.get('records', []))
    unresolved_accounts = account_identity(records,
        {c['cluster_id']: c['representative'] for c in report['clusters']},
        {f"bank:{b['id']}": b for b in report['bank_records']}, state)
    if account_policy:
        consolidate_accounts(records, account_policy)
        unresolved_accounts = unresolved_items(records)
    project_household_records(records, settings,
        {c['cluster_id']: c['representative'] for c in report['clusters']},
        {f"bank:{b['id']}": b for b in report['bank_records']},
        protected_ids=(account_policy or {}).get('excluded_records', {}), originals=previous.get('records', []))
    for record in records:
        if set(record["evidence_keys"]) & set(confirmed_dates):
            for c in record["components"]:
                reasons = [r for r in c["reason"].split("；") if r and r != "年份筛选与日期星期不一致"]
                c["reason"] = "；".join(reasons)
                c["included"] = not reasons and not record["non_consumption"] and report["backfill_cutoff_date"] is not None and record["date"] <= report["backfill_cutoff_date"]
    try:
        from .reimbursement_links import apply as apply_reimbursements
    except ImportError:
        from reimbursement_links import apply as apply_reimbursements
    decorate_payment_accounts(records)
    apply_reimbursements(records, report, state.get('confirmed_reimbursement_links', []))
    try:
        from .source_record_set_pipeline import reconcile as reconcile_source_record_sets
    except ImportError:
        from source_record_set_pipeline import reconcile as reconcile_source_record_sets
    material_targets = inputs.material_targets()
    records, source_record_sets, source_record_set_candidates, source_record_set_unresolved = reconcile_source_record_sets(
        records, report, state, overrides, account_policy, material_targets)
    try:
        from .transaction_trace import project as project_trace
    except ImportError:
        from transaction_trace import project as project_trace
    material_links = inputs.material_associations(records)
    params = inputs.fire_parameters()
    result = {"source_dataset_id": report["dataset_id"],
              "cutoff": report["backfill_cutoff_date"], "subject": "household", "unit": "transaction_lifecycle",
              "records": records, "refund_links": refund_links,
              "reimbursement_links": state.get('confirmed_reimbursement_links', []),
              "bank_settlement_groups": settlement_groups,
              "source_record_sets": source_record_sets,
              "source_record_set_candidates": source_record_set_candidates,
              "source_record_set_unresolved": source_record_set_unresolved,
              "confirmed_displayed_dates": confirmed_dates, "card_source_links": card_links,
              "taxonomy": catalog.taxonomy,
              "fire_parameters": params, "coverage_complete": False,
              "coverage_note": "尚未导入账单；暂无日期数据。" if not report["clusters"] and not report["bank_records"] and not video_results else "已提供来源的家庭交易；尚未确认所有家庭用户、账户均覆盖。待关联金额与未分配退款单独展示。",
              "summary": summarize(records, coverage["to"], coverage["from"]),
              "coverage": coverage, "undated_observations": undated}
    result['inferred_associations'] = [c for c in report['candidates']
                                       if c.get('decision_origin') in ('evidence_inference', 'confirmed_association')]
    result['unresolved_payment_accounts'] = unresolved_accounts
    result['material_associations'] = material_links
    result['refund_candidates'] = inputs.refund_candidates(records)
    if account_policy:
        result['account_consolidation'] = snapshot_policy(account_policy)
    result['reconciliation_summary'] = report['reconciliation_summary']
    (output / 'source-reconciliation.json').write_text(json.dumps(
        {'summary': report['reconciliation_summary'], 'links': reconciliation,
         'withheld': report.get('reconciliation_withheld', []),
         'bank_ownership': [{k: b[k] for k in ('id', 'date', 'amount_cents', 'owner_id', 'ownership_basis', 'ownership_evidence_keys')} for b in report['bank_records'] if b.get('ownership_evidence_keys')],
         'unresolved_payment_accounts': unresolved_accounts}, ensure_ascii=False, indent=2) + '\n')
    result["tag_catalog"] = sorted({tag for r in records for c in r["components"] for tag in c["tags"]})
    result["tag_statistics_note"] = "同一交易可有多个标签，各标签金额不可相加作为总消费；多标签筛选按同一购买项目匹配。"
    if video_results:
        # The retained source still shows the original year discrepancy; its
        # browsing projection must reflect the user's displayed-date decision.
        result["video_materials"] = [dict(m, date_basis="user_confirmed_displayed_date", status=m["status"] + " · 日期已确认")
            if m["id"] in confirmed_dates else m for v in video_results for m in v["materials"]]
        result["video_summary"] = {k: sum(v["summary"][k] for v in video_results) for k in ("raw_complete_crops", "deduplicated_materials", "wallet_links", "unparsed_crops", "undated_materials")}
        result["video_summary"]["recall_status"] = "完整边界素材；nihao china 录屏由视觉读取并核对月度合计，其他录屏全量召回率仍待验证"
    project_trace(records, report, result.get('video_materials', []))
    try:
        from .confirmed_transaction_corrections import apply as apply_corrections
    except ImportError:
        from confirmed_transaction_corrections import apply as apply_corrections
    apply_corrections(result, inputs.corrections())
    from scripts.account_consolidation import apply_confirmed_ownership
    preserved_owners = apply_confirmed_ownership(result['records'], account_policy)
    # Confirmed decisions bind the final lifecycle after approved date/merge
    # corrections, and grant no source-level ownership or future default.
    members = {m.id: m.display_name for m in settings.members} if settings else {}
    allowed = set(settings.exclusion_member_ids) if settings else set()
    for record in result['records']:
        if record['id'] in preserved_owners:
            record['user_display_name'] = members.get(record['user_id'], record['user_id'])
            record['review_exclusion_allowed'] = record['user_id'] in allowed
    inputs.enrich_orders(result, overrides)
    corrected = result.get('confirmed_transaction_corrections', {}).get('decision', {}).get('dates', [])
    observations = reliable_observations(report)
    corrected_keys = {key for item in corrected for key in result['confirmed_transaction_corrections']['original_records'][item['id']]['evidence_keys']}
    observations = [(key, day) for key, day in observations if key not in corrected_keys]
    observations += [('confirmed:' + item['id'], item['date']) for item in corrected]
    coverage = recompute(inputs.coverage(), observations)
    result.update(cutoff=coverage['to'], coverage=coverage)
    # Range changes affect statistics only, never delete facts or confirmations.
    for record in result['records']:
        outside = coverage['from'] is None or not coverage['from'] <= record['date'] <= coverage['to']
        for component in record['components']:
            reasons = [r for r in component['reason'].split('；') if r and r not in ('截止日之后', '统计范围之外')]
            if outside:
                reasons.append('统计范围之外')
            component['reason'] = '；'.join(reasons)
            component['included'] = not reasons and not record['non_consumption'] and not record['unallocated_credit_cents'] and not record.get('excluded_from_completion_and_statistics', False)
    if confirmed_outcomes is not None:
        from scripts.release_contracts import digest_file
        confirmed_outcomes.apply(result, overrides, digest_file(output / 'category-catalog.json'))
        result['unresolved_payment_accounts'] = unresolved_items(result['records'])
        result['refund_candidates'] = inputs.refund_candidates(result['records'])
    result['summary'] = summarize(result['records'], coverage['to'], coverage['from'])
    (output / 'coverage.json').write_text(json.dumps(coverage, ensure_ascii=False, indent=2) + '\n')
    # Keep evidence metadata on the same range without persisting temporary
    # reconciliation/date mutations or the merged video cluster list.
    evidence_path = output / 'payment-evidence.json'
    evidence_metadata = json.loads(evidence_path.read_text())
    if evidence_metadata.get('coverage') != coverage or evidence_metadata.get('backfill_cutoff_date') != coverage['to']:
        evidence_metadata.update(coverage=coverage, backfill_cutoff_date=coverage['to'])
        evidence_path.write_text(json.dumps(evidence_metadata, ensure_ascii=False, indent=2) + '\n')
    result["dataset_id"] = digest(result)
    # Durable application projection alongside the evidence DB. Raw observations
    # remain immutable; only the current derived report is retained.
    db = sqlite3.connect(output / "financial-review.sqlite3")
    with db:
        db.executescript("CREATE TABLE IF NOT EXISTS review_runs(dataset_id TEXT PRIMARY KEY,payload_json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS lifecycle_projection(id TEXT PRIMARY KEY,payload_json TEXT NOT NULL);")
        db.execute("DELETE FROM review_runs")
        db.execute("INSERT INTO review_runs VALUES (?,?)", (result["dataset_id"], json.dumps(result, ensure_ascii=False)))
        db.execute("DELETE FROM lifecycle_projection")
        db.executemany("INSERT INTO lifecycle_projection VALUES (?,?)", [(r["id"], json.dumps(r, ensure_ascii=False)) for r in result['records']])
    db.close()
    target = output / "financial-review.json"
    temp = target.with_suffix(".json.tmp")
    temp.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    temp.replace(target)
    # Read-set provenance stays outside the projection and its business digest.
    # This sidecar is diagnostic; it is not a Release commit marker.
    manifest_target = output / "financial-review-inputs.json"
    manifest_temp = manifest_target.with_suffix(".json.tmp")
    manifest_temp.write_text(json.dumps(inputs.manifest(), ensure_ascii=False, indent=2) + "\n")
    manifest_temp.replace(manifest_target)
    return result


if __name__ == "__main__":
    from scripts.processor_result import add_workspace_arguments
    from scripts.workspace_initialization import execute_request
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--operation-id")
    parser.add_argument("--result-file", type=Path)
    add_workspace_arguments(parser)
    args = parser.parse_args()
    if args.workspace:
        result, status = execute_request(args, lambda transaction, selected:
            run(transaction.root, transaction.review), [])
        print(json.dumps(result, ensure_ascii=False))
        raise SystemExit(status)
    if args.root is None or args.output is None:
        parser.error("独立处理需要显式 --root 和 --output")
    action = lambda: run(args.root, args.output)
    if args.result_file or args.operation_id:
        parser.error('durable processor results require --workspace')
    result = action()
    print(json.dumps({"lifecycles": len(result["records"]), "explicit_refund_links": len(result["refund_links"]), **result["summary"]}, ensure_ascii=False, indent=2))
