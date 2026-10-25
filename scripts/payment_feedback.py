"""Reusable, scoped human decisions; never infer payer or user coverage."""

import json
from datetime import datetime, timezone
from pathlib import Path

try:
    from .payment_evidence import digest
except ImportError:
    from payment_evidence import digest


def bank_signature(bank):
    fields = ("id", "date", "post_date", "amount_cents", "is_credit", "currency", "account_number", "description")
    return digest({key: bank.get(key) for key in fields})


def signature(candidate, report):
    records = {c["cluster_id"]: c["representative"] for c in report["clusters"]}
    banks = {f"bank:{b['id']}": b for b in report["bank_records"]}
    fields = ("platform", "provider_reference", "source_profile_id", "transaction_time", "success_time",
              "raw_direction", "event_kind", "currency", "platform_reported_amount_cents", "payment_method")
    bank_fields = ("id", "date", "post_date", "amount_cents", "is_credit", "currency", "account_number", "description")
    return digest(candidate["kind"],
                  [{k: records[r].get(k) for k in fields} for r in sorted(candidate["record_ids"])],
                  [{k: banks[b].get(k) for k in bank_fields} for b in sorted(candidate["bank_ids"])])


def alias(candidate, report):
    records = {c["cluster_id"]: c["representative"] for c in report["clusters"]}
    banks = {f"bank:{b['id']}": b for b in report["bank_records"]}
    row, bank = records[candidate["record_ids"][0]], banks[candidate["bank_ids"][0]]
    if not row.get("source_profile_id"):
        return None
    channel = candidate["evidence"].get("bank_description_has_wallet_route", False)
    # Merchant-specific bank descriptions require the same observed merchant;
    # aggregator descriptions can cover different merchants within this source.
    return {"platform": row["platform"], "source_profile_id": row["source_profile_id"],
            "bank_account_suffix": str(bank["account_number"])[-4:],
            "bank_description": bank["description"], "direction": row["raw_direction"],
            "event_kind": row["event_kind"], "wallet_merchant": None if channel else row["merchant"]}


def accept(report, decisions, state, note):
    """Called only for direct user authorization or their exported review file."""
    by_id = {c["candidate_id"]: c for c in report["candidates"]}
    if set(decisions) - set(by_id):
        raise ValueError("Review refers to candidates outside its source dataset")
    now = datetime.now(timezone.utc).isoformat()
    state.setdefault("decisions", {})
    for key, judgment in decisions.items():
        if judgment not in {"supports", "rejects", "needs_evidence", "pending"}:
            raise ValueError("Invalid review judgment")
        state["decisions"][key] = {"judgment": judgment, "evidence_signature": signature(by_id[key], report),
                                   "source_dataset_id": report["dataset_id"], "reviewed_at": now,
                                   "basis": "direct_human_confirmation", "note": note,
                                   "scope": "candidate_association_only"}
    # Learn only aliases from individually unambiguous, supported single links.
    learned = {digest(a["condition"]): a for a in state.get("bank_alias_rules", [])}
    for key in list(learned):
        rule = learned[key]
        rule["basis_candidate_ids"] = [case for case in rule["basis_candidate_ids"]
                                       if state["decisions"].get(case, {}).get("judgment") == "supports"]
        if not rule["basis_candidate_ids"]:
            del learned[key]
    for c in report["candidates"]:
        decision = state["decisions"].get(c["candidate_id"], {})
        if c["kind"] != "wallet_bank" or decision.get("judgment") != "supports" or c["competing_candidate_ids"] or decision.get("evidence_signature") != signature(c, report):
            continue
        condition = alias(c, report)
        if condition:
            rule = learned.setdefault(digest(condition), {"condition": condition, "basis_candidate_ids": []})
            rule["basis_candidate_ids"] = sorted(set(rule["basis_candidate_ids"] + [c["candidate_id"]]))
    state["bank_alias_rules"] = [learned[k] for k in sorted(learned)]
    state["all_users_covered"] = None
    return state


def apply(report, state):
    for bank in report.get("bank_records", []):
        confirmation = state.get("bank_record_confirmations", {}).get(f"bank:{bank['id']}")
        bank.pop("human_transaction_confirmation", None)
        if confirmation and confirmation.get("bank_evidence_signature") == bank_signature(bank):
            bank["human_transaction_confirmation"] = confirmation
    candidates = report["candidates"]
    for c in candidates:
        decision = state.get("decisions", {}).get(c["candidate_id"])
        c["human_review"] = decision
        c["review_required"] = True
        if decision and decision["evidence_signature"] == signature(c, report):
            c["association_status"] = {"supports": "supported_by_user", "rejects": "rejected_by_user",
                                        "needs_evidence": "needs_evidence", "pending": "unconfirmed"}[decision["judgment"]]
            c["review_required"] = decision["judgment"] in {"needs_evidence", "pending"}
        elif decision:
            c["review_reason"] = "evidence_changed_since_confirmation"
    rejected = {c["candidate_id"] for c in candidates if c["association_status"] == "rejected_by_user"}
    aliases = {digest(a["condition"]): a for a in state.get("bank_alias_rules", [])}
    for c in candidates:
        active = [key for key in c["competing_candidate_ids"] if key not in rejected]
        c["active_competing_candidate_ids"] = active
        if c["association_status"] == "rejected_by_user":
            continue
        if active:
            c["review_required"] = True
            c["allocation_status"] = "unresolved_competing_links"
            c["review_reason"] = "competing_bank_allocations" if c["bank_ids"] else "competing_order_links"
        elif c["association_status"] == "supported_by_user":
            c["allocation_status"] = "supported"
        elif c["association_status"] == "unconfirmed" and not c.get("human_review") and c["kind"] == "meituan_bank" and c["account_mapping_status"] == "confirmed" and c["evidence"].get("funding_resolution", {}).get("status") == "resolved":
            c["association_status"] = "rule_supported"
            c["allocation_status"] = "supported_by_scoped_rule"
            c["rule_basis"] = {"funding_resolution": c["evidence"]["funding_resolution"],
                               "condition": "日期、金额、方向、美团 ApplePay 路由与双向唯一性"}
            c["review_required"] = False
        elif c["association_status"] == "unconfirmed" and not c.get("human_review") and c["kind"] == "wallet_bank" and c["account_mapping_status"] == "confirmed":
            condition = alias(c, report)
            rule = aliases.get(digest(condition)) if condition else None
            if rule:
                c["association_status"] = "rule_supported"
                c["allocation_status"] = "supported_by_scoped_rule"
                c["rule_basis"] = {**rule}
                c["review_required"] = False
    report["feedback_state"] = {"account_mapping": state.get("account_mapping"),
                                 "meituan_apple_pay_mapping": state.get("meituan_apple_pay_mapping"),
                                 "bank_record_confirmations": state.get("bank_record_confirmations", {}),
                                 "all_users_covered": None}
    report["review_summary"] = {
        "human_supported": sum(c["association_status"] == "supported_by_user" for c in candidates),
        "rule_supported": sum(c["association_status"] == "rule_supported" for c in candidates),
        "needs_review": sum(c["review_required"] for c in candidates),
        "reused_human_decisions": sum(c.get("human_review") is not None and c["association_status"] == "supported_by_user" for c in candidates),
    }
    return report


def load(path: Path):
    return json.loads(path.read_text()) if path.exists() else {}


def ingest_export(path: Path, output: Path):
    import sqlite3
    exported = json.loads(path.read_text())
    if (set(exported) - {"dataset_id", "decisions", "expected_projection", "metadata"} or
            not isinstance(exported.get("dataset_id"), str) or not isinstance(exported.get("decisions"), dict)):
        raise ValueError("Unsupported review export")
    conn = sqlite3.connect((output / "payment-evidence.sqlite3").resolve().as_uri() + "?mode=ro", uri=True)
    try:
        row = conn.execute("SELECT payload_json FROM evidence_runs WHERE dataset_id=?", (exported.get("dataset_id"),)).fetchone()
    finally:
        conn.close()
    if not row:
        raise ValueError("Review dataset is not available in this evidence store")
    report = json.loads(row[0])
    state_path = output / "review-state.json"
    state = accept(report, {key: value["judgment"] for key, value in exported["decisions"].items()}, load(state_path),
                   "用户导出的复核记录：" + path.name)
    state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2))
    return len(exported["decisions"])
