"""Turn complete video record crops into retained observations and scoped links.

Calendar conflicts remain explicit. Only exact account/date/minute/amount with
compatible merchant text can enrich an existing wallet observation. No identity
or family coverage is inferred from a funding card or an absent order.
"""
import argparse
import json
import re
from datetime import date
from pathlib import Path
from collections import defaultdict, Counter

try:
    from .payment_evidence import digest, cents, make_observation
    from .payment_materials import snapshot, write_asset
except ImportError:
    from payment_evidence import digest, cents, make_observation
    from payment_materials import snapshot, write_asset

WEEKDAYS = {"一": 0, "二": 1, "三": 2, "四": 3, "五": 4, "六": 5, "日": 6, "天": 6}


def parsed_row(row):
    text = row["text"].replace("［", "[").replace("］", "]").replace("−", "-").replace("－", "-").replace("＋", "+")
    amount = re.search(r"([+-]?)\s*[¥￥]\s*([\d,]+\.\d{2})", text)
    clock = re.search(r"\b(\d{2}:\d{2})\b", text)
    account = re.search(r"银行\s*\[(\d{4})\]", text)
    if not amount or not clock or not account:
        return None
    names = [line.strip() for line in text.splitlines() if line.strip() and not re.search(r"银行|^[+-]?[¥￥]|^\d{2}\.\d{2}|^冻结$|^解冻$|^周[一二三四五六日]$", line)]
    # Icons occasionally recognize as short characters; retain the longest
    # merchant line and preserve the entire unmodified text as evidence.
    merchant = max(names, key=len) if names else "商户未知"
    kind = "authorization" if "冻结" in text or "解冻" in text else "transfer_or_gift" if "银联转账" in text else "receipt" if amount[1] == "+" else "payment" if amount[1] == "-" else "unknown"
    context = row.get("date_context")
    year = int((row.get("year_context") or "0")[:4])
    stamp, confidence = None, "date_missing"
    if context and year:
        month, day = map(int, context.split("."))
        try:
            stamp = date(year, month, day).isoformat(); confidence = "visible_date_context"
            weekday = (row.get("weekday") or "")[-1:]
            if weekday in WEEKDAYS and date(year, month, day).weekday() != WEEKDAYS[weekday]:
                alternatives = []
                for candidate_year in (year - 1, year, year + 1):
                    try:
                        if date(candidate_year, month, day).weekday() == WEEKDAYS[weekday]: alternatives.append(candidate_year)
                    except ValueError: pass
                if len(alternatives) == 1:
                    stamp = date(alternatives[0], month, day).isoformat(); confidence = "year_label_conflicts_weekday"
                else: stamp = None
        except ValueError: stamp = None
    return {"date": stamp, "date_basis": confidence, "clock": clock[1], "account_suffix": account[1],
            "amount_cents": cents(amount[2]), "merchant": merchant, "kind": kind,
            "direction": "支出" if kind == "payment" else "收入" if kind == "receipt" else "不计收支"}


def merchant_compatible(a, b):
    def clean(value):
        value = re.sub(r"[_（(].*$", "", value or "")
        return re.sub(r"[^a-z0-9\u4e00-\u9fff]", "", value.lower())
    raw_a, raw_b = a or "", b or ""
    a, b = clean(a), clean(b)
    if len(a) >= 4 and len(b) >= 4 and (a in b or b in a): return True
    # Masked wallet merchant text can identify only the visible prefix. This
    # helper is used together with exact account, minute and cents, never alone.
    for raw, other in ((raw_a, b), (raw_b, a)):
        if "*" in raw:
            prefix = clean(raw.split("*", 1)[0])
            if len(prefix) >= 2 and other.startswith(prefix): return True
    return len(a) >= 4 and len(b) >= 4 and (a in b or b in a)


def run(root, output, video_folder):
    root, output, video_folder = Path(root), Path(output), Path(video_folder)
    raw = json.loads((video_folder / "video-records.json").read_text())
    report = json.loads((output / "payment-evidence.json").read_text())
    source = snapshot(Path(raw["source"]), output)
    raw_snapshot = snapshot(video_folder / "video-records.json", output)
    wallets = {c["cluster_id"]: c["representative"] for c in report["clusters"]}
    groups, unparsed = defaultdict(list), []
    for row in raw["rows"]:
        value = parsed_row(row)
        if value:
            key = digest(value["date"], value["clock"], value["account_suffix"], value["amount_cents"], value["merchant"], value["kind"])
            groups[key].append((row, value))
        else: unparsed.append(row["id"])
    observations, links, materials, unresolved = [], [], [], []
    for group in groups.values():
        row, value = max(group, key=lambda x: (len(x[0]["text"]), x[0]["crop"][3]))
        key = digest("complete-video-record-v2", source["sha256"], row["image_sha256"], row["crop"], value)
        prefix = "materials/records/" + key + "/"
        image_bytes = (video_folder / row["image"]).read_bytes()
        image = write_asset(output, prefix + "record.png", image_bytes)
        if image["sha256"] != row["image_sha256"]: raise ValueError("Video crop checksum changed")
        locator = {"kind": "video_region", "requested_seconds": row["requested_second"], "actual_seconds": row["actual_second"],
                   "crop_pixels": row["crop"], "boundaries": row["completeness"], "date_basis": value["date_basis"]}
        payload = {"literal_text": row["text"], "source": source, "locator": locator, "parsed": value}
        raw_asset = write_asset(output, prefix + "record.json", json.dumps(payload, ensure_ascii=False, indent=2))
        evidence = {"evidence_id": key, "kind": "video_crop", "source": source, "image": image, "raw": raw_asset,
                    "locator": locator, "ocr_result": raw_snapshot, "crop_complete": True}
        materials.append({"id": "video:" + key, "platform": "unionpay", "title": value["merchant"], "date": value["date"] or "日期未确定",
                          "amount_cents": value["amount_cents"], "status": value["kind"], "date_basis": value["date_basis"], "source_evidence": evidence})
        if not value["date"]:
            unresolved.append(key); continue
        meta = {"source_profile_id": None, "observed_at": None, "all_users_covered": None, "owner_id": None}
        status = "交易成功" if value["kind"] == "payment" else "冻结／解冻" if value["kind"] == "authorization" else value["kind"]
        observation = make_observation("unionpay", Path(raw["source"]).name, source["sha256"], row["requested_second"], meta,
            {"原始文字": row["text"], "交易类型": value["kind"], "当前状态": status, "收/支": value["direction"]},
            timestamp=value["date"] + " " + value["clock"] + ":00", success_time=None, amount=value["amount_cents"],
            order_amount=None, paid_amount=value["amount_cents"], reference=key, merchant_reference=None,
            merchant=value["merchant"], title=value["merchant"], method="银行(" + value["account_suffix"] + ")",
            direction=value["direction"], status=status)
        observation.update({"event_kind": value["kind"], "source_evidence": evidence, "date_basis": value["date_basis"]})
        cluster = "video:" + key
        observations.append({"cluster_id": cluster, "representative": observation})
        matches = [k for k, r in wallets.items() if r["event_kind"] == value["kind"]
                   and r["transaction_time"][:16] == observation["transaction_time"][:16]
                   and r.get("platform_reported_amount_cents") == value["amount_cents"]
                   and value["account_suffix"] in (r.get("payment_method") or "")
                   and merchant_compatible(value["merchant"], r.get("merchant"))]
        if len(matches) == 1:
            links.append({"record_ids": [cluster, matches[0]], "bank_ids": [], "review_required": False,
                          "association_status": "rule_supported", "basis": "同账户、日期、分钟、金额、商户兼容且唯一"})
        else:
            # A new recording can repeat exports from another route; retain it
            # for review rather than guessing away an existing household cost.
            observation["video_overlap_pending"] = value["kind"] == "payment"
    result = {"source": source, "raw_snapshot": raw_snapshot,
              "observations": observations, "links": links, "materials": materials,
              "summary": {"raw_complete_crops": len(raw["rows"]), "deduplicated_materials": len(materials),
                          "wallet_links": len(links), "unparsed_crops": len(unparsed), "undated_materials": len(unresolved),
                          "date_basis": dict(Counter(m["date_basis"] for m in materials)), "recall_status": raw["recall_status"]}}
    imports = output / "video-evidence-imports"; imports.mkdir(exist_ok=True)
    (imports / (source["sha256"] + ".json")).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    results = [json.loads(p.read_text()) for p in sorted(imports.glob("*.json"))]
    merged = {k: [r for item in results for r in item[k]] for k in ("observations", "links", "materials")}
    merged["summary"] = {k: sum(item["summary"][k] for item in results) for k in ("raw_complete_crops", "deduplicated_materials", "wallet_links", "unparsed_crops", "undated_materials")}
    merged["summary"]["recall_status"] = raw["recall_status"]
    (output / "video-evidence.json").write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(); parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True); parser.add_argument("--video-folder", type=Path, required=True)
    args = parser.parse_args(); result = run(args.root, args.output, args.video_folder)
    print(json.dumps(result["summary"], ensure_ascii=False, indent=2))
