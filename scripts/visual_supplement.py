"""Import visually transcribed images with retained frames; never invokes OCR."""
import argparse
import io
import json
from collections import defaultdict
from pathlib import Path

from PIL import Image

try:
    from .payment_evidence import digest, make_observation
    from .payment_materials import snapshot, write_asset
except ImportError:
    from payment_evidence import digest, make_observation
    from payment_materials import snapshot, write_asset


def bank_matches(rows, banks, mapping):
    """Require scoped funding confirmation and unique amount/date/direction."""
    result = {}
    if mapping.get("status") != "confirmed":
        return result
    grouped = defaultdict(list)
    for index, row in enumerate(rows):
        grouped[(row["timestamp"][:10], row["amount_cents"], row.get("kind") == "refund")].append(index)
    for (date, cents, credit), indexes in grouped.items():
        matches = [b for b in banks if b["date"] == date and b["amount_cents"] == cents
                   and bool(b["is_credit"]) == credit and b["currency"] == "CNY"
                   and str(b["account_number"]).replace(" ", "").endswith(mapping["bank_account_suffix"])]
        if all("铁路" in rows[i]["merchant"] for i in indexes):
            matches = [b for b in matches if b["description"] == "TL CHN CN"]
        if len(matches) == len(indexes) == 1:
            result[indexes[0]] = [f"bank:{matches[0]['id']}"]
        elif credit and len(matches) == len(indexes) > 1 and len({rows[i]["timestamp"] for i in indexes}) == 1:
            # Identical refund occurrences cannot distinguish individual bank
            # rows. Link the entire multiset without claiming an individual pair.
            for index in indexes:
                result[index] = [f"bank:{b['id']}" for b in matches]
    return result


def run(manifest, output):
    manifest, output = Path(manifest), Path(output)
    raw = json.loads(manifest.read_text())
    report = json.loads((output / "payment-evidence.json").read_text())
    state = json.loads((output / "review-state.json").read_text())
    source = snapshot(Path(raw["source"]), output)
    annotations = snapshot(manifest, output)
    mapping = state[raw["mapping_key"]]
    if source["sha256"] not in mapping.get("source_sha256s", []):
        raise ValueError("Visual source lies outside the funding confirmation")
    rows = raw["rows"]
    matches = bank_matches(rows, report["bank_records"], mapping)
    observations, links, materials = [], [], []
    for index, row in enumerate(rows):
        key = digest("visual-supplement-v1", source["sha256"], row)
        platform = raw["platform"]
        cluster = platform + ":" + key
        prefix = "materials/records/" + key + "/"
        frame = Path(row.get("frame") or raw["source"])
        original = Image.open(frame)
        box = row.get("crop") or [0, 0, original.width, original.height]
        crop = original.crop((box[0], box[1], box[0] + box[2], box[1] + box[3]))
        buffer = io.BytesIO(); crop.save(buffer, format="PNG")
        image = write_asset(output, prefix + "record.png", buffer.getvalue())
        frame_asset = snapshot(frame, output)
        locator = {"kind": "video_region" if row.get("frame") else "image",
                   "actual_seconds": row.get("seconds"), "crop_pixels": box,
                   "date_basis": "visible_date_context", "boundaries": "visually_checked_complete_row"}
        text = row["literal_text"]
        evidence = {"evidence_id": key, "kind": "video_crop" if row.get("frame") else "image_crop",
                    "source": source, "image": image, "locator": locator, "crop_complete": True,
                    "frame": frame_asset, "annotation_snapshot": annotations,
                    "raw": write_asset(output, prefix + "record.json", json.dumps(
                        {"literal_text": text, "visual_reading": row, "source": source, "locator": locator,
                         "reading_method": "direct_visual_no_local_ocr"}, ensure_ascii=False, indent=2))}
        status = row.get("status") or "账单支出"
        observation = make_observation(platform, Path(raw["source"]).name, source["sha256"], index,
            {"source_profile_id": None, "observed_at": None, "owner_id": None, "all_users_covered": None},
            {"原始文字": text, "当前状态": status, "收/支": "收入" if row.get("kind") == "refund" else "支出"},
            timestamp=row["timestamp"], success_time=None, amount=row["amount_cents"], order_amount=None,
            paid_amount=None, reference=key, merchant_reference=None, merchant=row["merchant"],
            title=row.get("title") or row["merchant"], method=mapping["wallet_method"],
            direction="收入" if row.get("kind") == "refund" else "支出", status=status)
        if row.get("kind") == "refund": observation["event_kind"] = "refund"
        observation.update(source_evidence=evidence, video_overlap_pending=index not in matches,
                           date_basis="visible_date_context", reading_method="direct_visual_no_local_ocr")
        observation["time_precision"] = row.get("time_precision", "minute")
        if row.get("time_precision") == "day":
            observation["transaction_time"] = row["timestamp"][:10]
        observations.append({"cluster_id": cluster, "representative": observation})
        materials.append({"id": cluster, "platform": platform, "title": observation["title"],
                          "date": observation["transaction_time"], "amount_cents": row["amount_cents"],
                          "status": status, "date_basis": "visible_date_context", "source_evidence": evidence})
        if index in matches:
            links.append({"record_ids": [cluster], "bank_ids": matches[index], "review_required": False,
                          "association_status": "rule_supported", "basis": "用户确认资金来源、日期金额方向及唯一性",
                          "funding_confirmation": mapping})
    result = {"observations": observations, "links": links, "materials": materials,
              "summary": {"raw_complete_crops": len(rows), "deduplicated_materials": len(rows),
                          "wallet_links": len(links), "unparsed_crops": 0, "undated_materials": 0}}
    folder = output / "supplemental-evidence-imports"; folder.mkdir(exist_ok=True)
    (folder / (source["sha256"] + ".json")).write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    imports = [json.loads(p.read_text()) for p in sorted(folder.glob("*.json"))]
    merged = {k: [r for item in imports for r in item[k]] for k in ("observations", "links", "materials")}
    merged["summary"] = {k: sum(item["summary"][k] for item in imports) for k in result["summary"]}
    (output / "supplemental-evidence.json").write_text(json.dumps(merged, ensure_ascii=False, indent=2) + "\n")
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--manifest", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(run(args.manifest, args.output)["summary"], ensure_ascii=False))
