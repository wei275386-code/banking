"""Read-only reference implementation for payment evidence and link candidates.

This module never imports an order into the bank ledger. Provider references
cluster observations; clusters and cross-provider links are not confirmed
transaction identities. The product implementation can reuse this JSON contract.
"""

from __future__ import annotations

import csv
import hashlib
import itertools
import io
import json
import re
import sqlite3
from collections import Counter, defaultdict
from datetime import datetime
from decimal import Decimal, InvalidOperation
from pathlib import Path

try:
    from .import_wechat_alipay import parse_export
except ImportError:
    from import_wechat_alipay import parse_export

MISSING = {"", "/", "-", "--"}
STAMP = r"\d{4}[-/]\d{2}[-/]\d{2}(?: \d{2}:\d{2}:\d{2})?"


def digest(*values: object) -> str:
    encoded = json.dumps(values, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode()).hexdigest()


def optional_text(value: object) -> str | None:
    value = "" if value is None else str(value).strip()
    return None if value in MISSING else value


def cents(value: object) -> int | None:
    text = optional_text(value)
    if text is None:
        return None
    text = text.replace("¥", "").replace("￥", "").replace(",", "")
    try:
        number = Decimal(text)
    except InvalidOperation as exc:
        raise ValueError(f"Invalid money: {text!r}") from exc
    if not number.is_finite() or number * 100 != (number * 100).to_integral_value():
        raise ValueError(f"Money is not a finite integer number of cents: {text!r}")
    return int(number * 100)


def metadata(lines: list[str], platform: str) -> dict:
    def find(label):
        match = re.search(label + r"[：:]\s*\[?(" + STAMP + r")\]?", "\n".join(lines))
        return match.group(1).replace("/", "-") if match else None

    account_label = {"wechat": "微信昵称", "alipay": "支付宝账户", "meituan": "美团用户名"}[platform]
    hint = next((line.split("：", 1)[1].strip("[] ") for line in lines if line.startswith(account_label + "：")), None)
    return {
        "observed_at": find("导出时间"), "declared_from": find("起始时间"),
        "declared_to": find("终止时间"), "timezone": "Asia/Shanghai",
        "source_profile_id": digest(platform, account_label, hint) if hint else None,
        "profile_hint_kind": account_label if hint else None,
        "profile_identity_verified": False, "owner_id": None,
        "all_users_covered": None,
    }


def event_semantics(platform: str, raw: dict) -> dict:
    status = raw.get("当前状态", raw.get("交易状态", raw.get("交易类型", "")))
    category = raw.get("交易类型", raw.get("交易分类", ""))
    direction = raw.get("收/支", "")
    current_state = "unknown"
    if "全额退款" in status:
        current_state = "fully_refunded"
    elif "部分退款" in status:
        current_state = "partially_refunded"
    elif "已退款" in status:
        current_state = "refund_reported"
    elif "关闭" in status or "取消" in status:
        current_state = "cancelled"
    elif status in ("支付成功", "交易成功", "支付"):
        current_state = "successful"

    if platform == "meituan":
        kind = {"支付": "payment", "退款": "refund"}.get(status, "unknown")
    elif platform == "alipay" and status == "退款成功":
        kind = "refund"
    elif platform == "wechat" and direction == "收入" and "退款" in status:
        kind = "refund"
    elif "还款" in category or "还款" in status:
        kind = "repayment"
    elif "解冻" in status or "冻结" in status:
        kind = "authorization"
    elif "转账" in category or "红包" in category:
        kind = "transfer_or_gift"
    elif platform == "alipay" and "亲情卡" in raw.get("收/付款方式", "") and current_state == "successful":
        # 不计收支 describes the beneficiary's cash balance, not whether the
        # merchant payment happened. Funding is in the family-card payer export.
        kind = "payment"
    elif direction == "支出":
        kind = "payment"
    elif direction == "收入":
        kind = "receipt"
    else:
        kind = "unknown"
    # A refunded original expense is still an original payment observation.
    return {"event_kind": kind, "current_payment_state": current_state,
            "bank_cash_effect": "unknown", "expense_effect": "not_decided"}


def make_observation(platform, file_name, file_hash, row, meta, raw, *, timestamp,
                     success_time, amount, order_amount, paid_amount, reference,
                     merchant_reference, merchant, title, method, direction, status):
    return {
        "observation_id": digest(platform, file_hash, row),
        "platform": platform, "file_name": file_name, "file_sha256": file_hash,
        "source_device_id": None, "payer_id": None, "beneficiary_id": None,
        "funding_account_id": None,
        "source_row": row, **meta, "raw": raw,
        "transaction_time": timestamp, "success_time": optional_text(success_time),
        "time_precision": "second" if re.search(r"\d{2}:\d{2}:\d{2}", timestamp) else "minute",
        "platform_reported_amount_cents": amount, "order_amount_cents": order_amount,
        "platform_paid_amount_cents": paid_amount, "bank_charged_amount_cents": None,
        "currency": "CNY", "provider_reference": optional_text(reference),
        "merchant_reference": optional_text(merchant_reference),
        "merchant": merchant, "title": title, "payment_method": method,
        "raw_direction": direction, "raw_status": status, **event_semantics(platform, raw),
    }


def parse_document(path: Path) -> dict:
    csv_rows = None
    if path.suffix.lower() == ".csv":
        data = path.read_bytes()
        try:
            text = data.decode("utf-8-sig")
        except UnicodeDecodeError:
            text = data.decode("gb18030")
        csv_rows = list(csv.reader(io.StringIO(text)))
    if csv_rows is not None and any("交易创建时间" in row for row in csv_rows):
        platform = "meituan"
        rows = csv_rows
        header = next(i for i, r in enumerate(rows) if "交易创建时间" in r)
        required = {"交易创建时间", "交易成功时间", "交易类型", "订单标题", "收/支", "支付方式",
                    "订单金额", "实付金额", "交易单号", "商家单号"}
        if not required.issubset(rows[header]):
            raise ValueError(f"Missing Meituan columns in {path.name}")
        file_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        meta = metadata([" ".join(row) for row in rows[:header]], platform)
        observations = []
        for row_num, row in enumerate(rows[header + 1:], header + 2):
            if not row or not row[0].strip():
                continue
            if len(row) != len(rows[header]):
                raise ValueError(f"Unexpected column count: {path.name}:{row_num}")
            raw = {k: v.strip() for k, v in zip(rows[header], row)}
            datetime.fromisoformat(raw["交易创建时间"])
            if optional_text(raw["交易成功时间"]):
                datetime.fromisoformat(raw["交易成功时间"])
            observations.append(make_observation(
                platform, path.name, file_hash, row_num, meta, raw,
                timestamp=raw["交易创建时间"], success_time=raw["交易成功时间"],
                amount=cents(raw["实付金额"]), order_amount=cents(raw["订单金额"]),
                paid_amount=cents(raw["实付金额"]), reference=raw["交易单号"],
                merchant_reference=raw["商家单号"], merchant=None, title=raw["订单标题"],
                method=raw["支付方式"], direction=raw["收/支"], status=raw["交易类型"],
            ))
        total_line = next((r[0] for r in rows[:header] if r and r[0].startswith("共：")), None)
        if total_line and int(re.search(r"共：(\d+)笔", total_line).group(1)) != len(observations):
            raise ValueError(f"Declared row count differs in {path.name}")
        # Export totals can legitimately differ according to its disclaimer.
        checks = []
        for direction in ("支出", "收入", "不计收支"):
            text = next((r[0] for r in rows[:header] if r and r[0].startswith(direction + "：")), None)
            if text:
                declared = cents(re.search(r"笔\s+([\d,.]+)元", text).group(1))
                values = [o["platform_reported_amount_cents"] for o in observations if o["raw_direction"] == direction]
                actual = sum(values) if all(v is not None for v in values) else None
                checks.append({"direction": direction, "declared_cents": declared,
                               "row_sum_cents": actual, "agree": actual == declared})
    else:
        parsed = parse_export(path)
        platform, file_hash = parsed["source_type"], parsed["file_sha256"]
        if platform == "wechat":
            import openpyxl
            workbook = openpyxl.load_workbook(path, read_only=True, data_only=True)
            try:
                lines = []
                for row in workbook.active.iter_rows(values_only=True):
                    if "交易时间" in row:
                        break
                    lines.extend(str(value).strip() for value in row if value is not None)
            finally:
                workbook.close()
        else:
            try:
                from_encoding = path.read_bytes().decode("utf-8-sig")
            except UnicodeDecodeError:
                from_encoding = path.read_bytes().decode("gb18030")
            lines = from_encoding.splitlines()[:25]
        meta = metadata(lines, platform)
        observations = []
        for detail in parsed["details"]:
            raw = json.loads(detail["raw_json"])
            amount = cents(raw["金额(元)" if platform == "wechat" else "金额"])
            observations.append(make_observation(
                platform, path.name, file_hash, detail["source_row_number"], meta, raw,
                timestamp=detail["transaction_time"], success_time=None, amount=amount,
                order_amount=None, paid_amount=None,
                reference=detail["source_transaction_id"], merchant_reference=detail["merchant_order_no"],
                merchant=detail["merchant"], title=detail["product"], method=detail["payment_method"],
                direction=detail["direction"], status=detail["status"],
            ))
        checks = []
    return {"platform": platform, "file_name": path.name, "file_sha256": file_hash,
            **meta, "observations": observations, "checks": checks}


def reference_clusters(observations: list[dict]) -> list[dict]:
    buckets = defaultdict(dict)
    for o in observations:
        # Unverified profile hints do not establish ownership. An identical
        # provider reference with incompatible facts remains a conflict.
        key = digest(o["platform"], o["provider_reference"]) if o["provider_reference"] else o["observation_id"]
        buckets[key][o["observation_id"]] = o
    result = []
    for key, unique in sorted(buckets.items()):
        rows = sorted(unique.values(), key=lambda o: (o["observed_at"] or "", o["observation_id"]))
        immutable = ("transaction_time", "platform_reported_amount_cents", "raw_direction", "currency")
        conflicts = [field for field in immutable if len({o[field] for o in rows}) > 1]
        if len({o['owner_id'] for o in rows if o.get('owner_id')}) > 1:
            conflicts.append('owner_id')
        profiles = {o["source_profile_id"] for o in rows if o["source_profile_id"]}
        if len(profiles) > 1:
            conflicts.append("source_profile_id")
        state_variants = {o["current_payment_state"] for o in rows}
        unknown_state_time = len(state_variants) > 1 and any(not o["observed_at"] for o in rows)
        result.append({"cluster_id": key, "platform": rows[0]["platform"],
                       "observation_ids": [o["observation_id"] for o in rows],
                       "representative": rows[-1], "conflicting_fields": conflicts,
                       "status_order_unresolved": unknown_state_time,
                       "identity_status": "reference_cluster_not_confirmed_transaction"})
    return result


def load_bank(path: Path) -> list[dict]:
    conn = sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        return [dict(row) for row in conn.execute("""
            SELECT t.id, COALESCE(t.trans_date,t.post_date) AS date, t.post_date,
                   t.amount_cents,t.is_credit,t.currency,t.description,t.raw_line,
                   t.post_date_raw,t.trans_date_raw,
                   s.account_number,s.file_name AS statement_file,s.statement_date,s.file_sha256 AS statement_sha256,
                   CASE WHEN UPPER(t.description) LIKE '%IFS PAYMENT%' THEN 0 ELSE 1 END AS reconciliation_eligible
              FROM transactions t JOIN statements s ON s.id=t.statement_id
             ORDER BY t.id
        """)]
    finally:
        conn.close()


def bank_key(row):
    return f"bank:{row['id']}"


def has_resolved_funding(row):
    resolution = row.get('funding_resolution', {})
    return bool(row.get('funding_account_id') and resolution.get('status') == 'resolved'
                and resolution.get('account_id') == row['funding_account_id'])


def link(kind, record_ids, bank_ids, evidence, *, mapping_status=None):
    return {"candidate_id": digest(kind, sorted(record_ids), sorted(bank_ids)),
            "kind": kind, "record_ids": sorted(record_ids), "bank_ids": sorted(bank_ids),
            "evidence": evidence, "association_status": "unconfirmed",
            "account_mapping_status": mapping_status, "owner_scope": "unknown",
            "all_users_covered": None}


def generate_candidates(clusters, bank, *, mapping_status="unconfirmed", meituan_funding=None):
    if mapping_status not in {"unconfirmed", "confirmed", "rejected"}:
        raise ValueError("Invalid account mapping status")
    eligible = [(c["cluster_id"], c["representative"]) for c in clusters
                if not c["conflicting_fields"]]
    candidates, unmatched, withheld = [], [], []
    wx_index = defaultdict(list)
    for key, row in eligible:
        if row["platform"] == "wechat":
            wx_index[(row["raw_direction"], row["platform_reported_amount_cents"])].append((key, row))
    for key, row in eligible:
        if row["platform"] != "meituan" or row["payment_method"] != "微信支付":
            continue
        matches = 0
        times = [datetime.fromisoformat(row[t]) for t in ("transaction_time", "success_time") if row[t]]
        for wk, w in wx_index[(row["raw_direction"], row["platform_reported_amount_cents"])]:
            if row["platform_reported_amount_cents"] is None or row["event_kind"] != w["event_kind"]:
                continue
            delta = min(abs((datetime.fromisoformat(w["transaction_time"]) - t).total_seconds()) for t in times)
            if delta > 120:
                continue
            candidates.append(link("meituan_wechat", [key, wk], [], {
                "same_amount": True, "same_direction": True, "same_event_kind": True,
                "closest_time_delta_seconds": delta,
                "merchant_context": "美团" in ((w["merchant"] or "") + (w["title"] or "")),
                "stable_cross_provider_identifier_confirmed": False,
                "wechat_current_status": w["raw_status"],
            }))
            matches += 1
        if not matches:
            unmatched.append({"record_id": key, "reason": "no_wechat_candidate_not_missing_order"})

    bank_index = defaultdict(list)
    scope_bank = []
    for b in bank:
        if has_resolved_funding(b) and b.get("reconciliation_eligible", True):
            scope_bank.append(b)
            bank_index[(b["funding_account_id"], b["date"], b["amount_cents"], "收入" if b["is_credit"] else "支出")].append(b)
    def coverage(account):
        days = [b['date'] for b in scope_bank if b['funding_account_id'] == account]
        return (min(days, default=None), max(days, default=None))
    funding = meituan_funding or {}
    for key, row in eligible:
        if row["platform"] != "meituan" or row["payment_method"] != "ApplePay":
            continue
        if not has_resolved_funding(row):
            continue
        if row["event_kind"] not in {"payment", "refund"} or row["current_payment_state"] == "cancelled" or row["raw_direction"] not in {"支出", "收入"}:
            continue
        amount = row["platform_reported_amount_cents"]
        if amount is None: continue
        matches = [b for b in bank_index[(row["funding_account_id"], row["transaction_time"][:10], amount, row["raw_direction"]) ]
                   if "MEITUAN" in b["description"].upper() and "APPLE PAY" in b["description"].upper()]
        for b in matches:
            candidates.append(link("meituan_bank", [key], [bank_key(b)], {
                "same_date": True, "same_amount": True, "same_direction": True,
                "bank_description": b["description"], "account_route": row["funding_account_id"],
                "funding_resolution": row["funding_resolution"],
            }, mapping_status="confirmed"))
        if not matches:
            unmatched.append({"record_id": key, "reason": "no_meituan_applepay_bank_candidate_not_invalid_expense"})
    route_rows = []
    for key, row in eligible:
        if row["platform"] not in {"wechat", "alipay"}:
            continue
        method = row["payment_method"].replace("（", "(").replace("）", ")").replace(" ", "")
        if not has_resolved_funding(row):
            withheld.append({"record_id": key, "reason": "funding_settings_need_review"})
            continue
        if row["current_payment_state"] == "cancelled" or row["event_kind"] not in {"payment", "refund"}:
            continue
        if row["platform_reported_amount_cents"] is None:
            withheld.append({"record_id": key, "reason": "missing_amount"})
            continue
        if mapping_status == "rejected":
            withheld.append({"record_id": key, "reason": "account_mapping_rejected"})
            continue
        date = row["transaction_time"][:10]
        span = coverage(row['funding_account_id'])
        if not span[0] or not span[0] <= date <= span[1]:
            withheld.append({"record_id": key, "reason": "outside_provided_bank_date_range"})
            continue
        # A refund signal marked 不计收支 is not guessed into a bank credit.
        if row["raw_direction"] not in {"支出", "收入"}:
            withheld.append({"record_id": key, "reason": "cash_direction_not_established"})
            continue
        route_rows.append((key, row, method))
        matches = bank_index[(row["funding_account_id"], date, row["platform_reported_amount_cents"], row["raw_direction"]) ]
        for b in matches:
            candidates.append(link("wallet_bank", [key], [bank_key(b)], {
                "same_date": True, "same_amount": True, "same_direction": True,
                "account_route": row["funding_account_id"], "bank_post_date": b["post_date"],
                "bank_description": b["description"],
                "bank_description_has_wallet_route": any(s in b["description"].upper() for s in ("UNIONPAY", "ALIPAY", "TENPAY")),
                "bank_description_has_apple_pay": "APPLE PAY" in b["description"].upper(),
            }, mapping_status="confirmed"))
        if not matches:
            unmatched.append({"record_id": key, "reason": "no_single_bank_candidate_not_missing_expense"})

    # Bounded, exact-second groups within one declared source profile, merchant,
    # funding method, currency and direction. No arbitrary daily subset sums.
    groups = defaultdict(list)
    for key, row, method in route_rows:
        if row["raw_direction"] != "支出" or row["time_precision"] != "second" or row["event_kind"] != "payment":
            continue
        scope = (row["platform"], row["source_profile_id"], row["transaction_time"],
                 row["merchant"], method, row["currency"], row["funding_account_id"])
        if row["merchant"] and row["source_profile_id"]:
            groups[scope].append((key, row))
    for scope, rows in groups.items():
        if len(rows) > 8:
            withheld.append({"record_ids": [key for key, _ in rows], "reason": "group_too_large_requires_review"})
            continue
        for size in range(2, min(3, len(rows)) + 1):
            for members in itertools.combinations(rows, size):
                amounts = [r["platform_reported_amount_cents"] for _, r in members]
                if any(a <= 0 for a in amounts):
                    continue
                date = scope[2][:10]
                for b in bank_index[(scope[6], date, sum(amounts), "支出")]:
                    candidates.append(link("grouped_wallet_bank", [key for key, _ in members], [bank_key(b)], {
                        "same_second": True, "same_merchant": True, "same_funding_method": True,
                        "same_declared_source_profile": True, "component_amounts_cents": amounts,
                        "bank_amount_cents": b["amount_cents"], "bank_post_date": b["post_date"],
                        "checkout_identity_confirmed": False,
                    }, mapping_status="confirmed"))
    incidence = defaultdict(set)
    for c in candidates:
        for key in c["record_ids"] + c["bank_ids"]:
            incidence[(c["kind"] in {"wallet_bank", "grouped_wallet_bank", "meituan_bank"}, key)].add(c["candidate_id"])
    for c in candidates:
        family = c["kind"] in {"wallet_bank", "grouped_wallet_bank", "meituan_bank"}
        competing = set().union(*(incidence[(family, key)] for key in c["record_ids"] + c["bank_ids"]))
        c["competing_candidate_ids"] = sorted(competing - {c["candidate_id"]})
    return {"candidates": sorted(candidates, key=lambda c: c["candidate_id"]),
            "unmatched": unmatched, "withheld": withheld,
            "source_coverage": "unknown", "ledger_changes": []}


def save_evidence(path: Path, documents: list[dict], report: dict) -> None:
    """Persist provenance in a separate derived database, never banking.sqlite3."""
    if path.resolve().name == "banking.sqlite3":
        raise ValueError("The evidence store must not be the formal bank database")
    path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(path)
    try:
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if tables - {"evidence_imports", "evidence_files", "evidence_observations", "evidence_runs", "evidence_materials", "evidence_reviews", "evidence_settings", "sqlite_sequence"}:
            raise ValueError("The evidence store must be isolated from existing application tables")
        conn.executescript("""
            PRAGMA foreign_keys = ON;
            CREATE TABLE IF NOT EXISTS evidence_imports (
                import_id TEXT PRIMARY KEY, platform TEXT NOT NULL, file_sha256 TEXT NOT NULL,
                observed_at TEXT, metadata_json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS evidence_files (
                import_id TEXT NOT NULL REFERENCES evidence_imports(import_id),
                file_name TEXT NOT NULL, PRIMARY KEY(import_id,file_name));
            CREATE TABLE IF NOT EXISTS evidence_observations (
                observation_id TEXT PRIMARY KEY,
                import_id TEXT NOT NULL REFERENCES evidence_imports(import_id),
                source_row INTEGER NOT NULL, payload_json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS evidence_runs (
                dataset_id TEXT PRIMARY KEY, payload_json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS evidence_materials (
                record_key TEXT NOT NULL, evidence_id TEXT NOT NULL, payload_json TEXT NOT NULL,
                PRIMARY KEY(record_key,evidence_id));
            CREATE TABLE IF NOT EXISTS evidence_reviews (
                review_id TEXT PRIMARY KEY, candidate_id TEXT NOT NULL, payload_json TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS evidence_settings (
                key TEXT PRIMARY KEY, payload_json TEXT NOT NULL);
        """)
        with conn:
            for d in documents:
                key = digest(d["platform"], d["file_sha256"])
                meta = {k: v for k, v in d.items() if k != "observations"}
                conn.execute("INSERT OR IGNORE INTO evidence_imports VALUES (?,?,?,?,?)", (
                    key, d["platform"], d["file_sha256"], d["observed_at"], json.dumps(meta, ensure_ascii=False)))
                conn.execute("INSERT OR IGNORE INTO evidence_files VALUES (?,?)", (key, d["file_name"]))
                for row in d["observations"]:
                    conn.execute("INSERT OR IGNORE INTO evidence_observations VALUES (?,?,?,?)", (
                        row["observation_id"], key, row["source_row"], json.dumps(row, ensure_ascii=False)))
            conn.execute("DELETE FROM evidence_runs")
            conn.execute("INSERT INTO evidence_runs VALUES (?,?)", (
                report["dataset_id"], json.dumps(report, ensure_ascii=False)))
            materials = [(r["observation_id"], r.get("source_evidence")) for d in documents for r in d["observations"]]
            materials += [(f"bank:{r['id']}", r.get("source_evidence")) for r in report.get("bank_records", [])]
            materials += [("card:" + r["card_id"], r.get("source_evidence")) for r in (report.get("ocr_probe") or {}).get("samples", [])]
            for key, material in materials:
                if material:
                    conn.execute("INSERT OR IGNORE INTO evidence_materials VALUES (?,?,?)",
                                 (key, digest(material), json.dumps(material, ensure_ascii=False)))
            for candidate in report.get("candidates", []):
                review = candidate.get("human_review")
                if review:
                    conn.execute("INSERT OR IGNORE INTO evidence_reviews VALUES (?,?,?)",
                                 (digest(candidate["candidate_id"], review), candidate["candidate_id"], json.dumps(review, ensure_ascii=False)))
            if "feedback_state" in report:
                conn.execute("INSERT INTO evidence_settings VALUES (?,?) ON CONFLICT(key) DO UPDATE SET payload_json=excluded.payload_json",
                             ("feedback_state", json.dumps(report["feedback_state"], ensure_ascii=False)))
    finally:
        conn.close()
