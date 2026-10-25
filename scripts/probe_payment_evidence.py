"""Developer probe. The eventual product imports through a native file picker."""

import argparse
import hashlib
import json
from collections import Counter
from pathlib import Path
import sys
import uuid

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

try:
    from .payment_evidence import digest, generate_candidates, load_bank, parse_document, reference_clusters, save_evidence
    from .payment_feedback import apply as apply_feedback, load as load_feedback, ingest_export
    from .payment_materials import text_materials, bank_materials, card_materials, snapshot
except ImportError:
    from payment_evidence import digest, generate_candidates, load_bank, parse_document, reference_clusters, save_evidence
    from payment_feedback import apply as apply_feedback, load as load_feedback, ingest_export
    from payment_materials import text_materials, bank_materials, card_materials, snapshot


def sha(path):
    checksum = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def retained_exports(root, *, verify=True):
    """Use the durable import inventory, independent of user-chosen filenames."""
    registry = root / "config/review-import-sources.json"
    if not registry.exists():
        return []
    payload = json.loads(registry.read_text())
    if not isinstance(payload.get('sources'), list):
        raise ValueError("账单来源清单格式无效")
    sources = payload["sources"]
    for source in sources:
        relative = Path(source["path"])
        path = (root / relative).resolve()
        if relative.is_absolute() or not path.is_relative_to(root.resolve()) or path.suffix.lower() not in (".csv", ".xlsx"):
            raise ValueError("账单来源路径无效")
        if not path.is_file() or (verify and sha(path) != source["sha256"]):
            raise ValueError("已保存的账单来源已改变或缺失：" + relative.name)
    return sources


def registry_dependencies(root):
    """Verified production source-registry closure for backup, state-relative.

    Every edge comes from the actual registry and its retained original, not a
    user declaration. This covers this registry only; backup must also consume
    projection/material and request-ledger registries and reject unknown files.
    """
    from scripts.release_contracts import validate_relative_path
    from scripts.workspace_state import _regular
    root = Path(root)
    registry = 'config/review-import-sources.json'
    _regular(root / registry)
    sources = retained_exports(root, verify=False)
    originals = {}
    for source in sources:
        relative = validate_relative_path(source['path'])
        if relative in originals or source.get('platform') not in {'wechat', 'alipay', 'meituan'}:
            raise ValueError('账单来源 registry 存在重复路径或未知 platform')
        actual = sha(_regular(root / relative))
        if actual != source['sha256']:
            raise ValueError('账单来源原件 hash 与 registry 不一致：' + relative)
        originals[relative] = {'path': relative, 'sha256': actual,
                               'platform': source['platform']}
    return {'files': [{'path': registry, 'dependencies': sorted(originals)}] +
                     [{'path': name, 'dependencies': []} for name in sorted(originals)],
            'sources': [originals[name] for name in sorted(originals)]}


def register_exports(root, files):
    root = Path(root).resolve()
    sources = {source["path"]: source for source in retained_exports(root, verify=False)}
    for path, platform in files:
        relative = path.resolve().relative_to(root).as_posix()
        previous = sources.get(relative)
        if previous and previous['sha256'] != sha(path): raise ValueError("registered source bytes changed")
        sources[relative] = previous or {"id": str(uuid.uuid4()), "path": relative, "sha256": sha(path), "platform": platform}
    if not files:
        return
    registry = root / "config/review-import-sources.json"
    registry.parent.mkdir(parents=True, exist_ok=True)
    temporary = registry.with_suffix(".json.tmp")
    payload = json.loads(registry.read_text()) if registry.exists() else {}
    payload["sources"] = [sources[k] for k in sorted(sources)]
    temporary.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n")
    temporary.replace(registry)


def run(root: Path, output: Path, mapping_status=None, *, parsed_documents=None):
    root, output = root.resolve(), output.resolve()
    bank_path = root / "banking.sqlite3"
    bank_before = sha(bank_path)
    feedback = load_feedback(output / "review-state.json")
    mapping_status = mapping_status or feedback.get("account_mapping", {}).get("status", "unconfirmed")
    files = sorted({p for pattern in ("微信支付账单流水文件*.xlsx", "支付宝交易明细*.csv", "美团账单*.csv")
                    for p in root.glob(pattern)})
    registered = {source["path"]: source for source in retained_exports(root, verify=False)}
    files = sorted(set(files) | {root / name for name in registered})
    parsed_documents = parsed_documents or {}
    documents = [(parsed_documents.get(path) or parse_document(path)) | {"source_path": path.relative_to(root).as_posix()} for path in files]
    for document in documents:
        expected = registered.get(document["source_path"], {}).get("sha256")
        if expected and document["file_sha256"] != expected:
            raise ValueError("已保存的账单来源已改变：" + document["source_path"])
        source_id = registered.get(document["source_path"], {}).get("id")
        if source_id:
            document["source_id"] = source_id
            for row in document["observations"]: row["source_id"] = source_id
    ownership = feedback.get("source_owner_confirmations", {})
    for document in documents:
        confirmation = ownership.get(document["file_sha256"])
        if confirmation:
            user = confirmation["user_id"]
            document.update(owner_id=user, profile_identity_verified=True, ownership_basis=confirmation["basis"])
            for row in document["observations"]:
                row.update(owner_id=user, profile_identity_verified=True, ownership_basis=confirmation["basis"])
    text_count = text_materials(root, output, documents) if documents else 0
    observations = [o for d in documents for o in d["observations"]]
    clusters = reference_clusters(observations)
    all_bank = load_bank(bank_path)
    from scripts.coverage_policy import reliable_date, reliable_observations, recompute
    bank = [b for b in all_bank if reliable_date(b.get("date"))]
    material_summary = bank_materials(root, output, bank) if bank else {"bank_crops": 0, "unlocated_bank_records": []}
    material_summary["text_excerpts"] = text_count
    dated_clusters = [c for c in clusters if reliable_date(c["representative"].get("transaction_time"))]
    from scripts.household_settings import load_processor_settings, project_funding
    settings, setting_sources = load_processor_settings(root,
        referenced_member_ids=sorted({r['owner_id'] for r in observations + bank if r.get('owner_id')}))
    project_funding([c['representative'] for c in dated_clusters], bank, settings, setting_sources)
    report = generate_candidates(dated_clusters, bank, mapping_status=mapping_status, meituan_funding=feedback.get("meituan_apple_pay_mapping"))
    algorithm_hash = digest(*(sha(Path(__file__).with_name(name)) for name in
                            ("probe_payment_evidence.py", "payment_evidence.py", "payment_feedback.py", "payment_materials.py", "household_settings.py")))
    report.update({
        "dataset_id": digest(sorted({d["file_sha256"] for d in documents}), bank_before, mapping_status, algorithm_hash,
                             settings.profile_bytes.decode() if settings else None,
                             settings.policies_bytes.decode() if settings else None, setting_sources),
        "algorithm_hash": algorithm_hash,
        "documents": [{k: v for k, v in d.items() if k != "observations"} | {"row_count": len(d["observations"])} for d in documents],
        "clusters": clusters, "bank_records": bank,
        "undated_bank_records": [b for b in all_bank if not reliable_date(b.get("date"))],
        "materials_summary": material_summary,
        "backfill_cutoff_date": max((b["date"] for b in bank if reliable_date(b["date"])), default=None),
        "summary": {
            "source_files": len(files), "observations": len(observations), "reference_clusters": len(clusters),
            "repeated_observations": len(observations) - len(clusters),
            "conflicting_clusters": sum(bool(c["conflicting_fields"]) for c in clusters),
            "unresolved_state_order": sum(c["status_order_unresolved"] for c in clusters),
            "candidate_kinds": dict(Counter(c["kind"] for c in report["candidates"])),
            "wallet_bank_aggregator_description_candidates": sum(c["kind"] == "wallet_bank" and c["evidence"]["bank_description_has_wallet_route"] for c in report["candidates"]),
            "platform_counts": dict(Counter(c["platform"] for c in clusters)),
            "refund_events": dict(Counter(c["platform"] for c in clusters if c["representative"]["event_kind"] == "refund")),
            "bank_date_from": min((b["date"] for b in bank if reliable_date(b["date"])), default=None), "bank_date_to": max((b["date"] for b in bank if reliable_date(b["date"])), default=None),
        },
        "validation": {"bank_sha256_before": bank_before, "bank_sha256_after": sha(bank_path),
                       "formal_ledger_written": False, "owners_assigned": any(r.get("owner_id") for r in observations),
                       "ownership_scope": "仅确认来源及可靠关联的实际交易；银行原始数据库不变"},
        "known_gaps": ["各来源用户归属与 shared account 全部用户覆盖未知",
                       "视频全量卡片定位、跟踪与漏单率尚未验证"],
        "deferred_questions": [],
    })
    if mapping_status != "confirmed" and any("0732" in (row.get("payment_method") or "") for row in observations):
        report["known_gaps"].append("银联(0732) 与银行9707的账户映射待确认")
    previous_coverage = json.loads((output / "coverage.json").read_text()) if (output / "coverage.json").exists() else None
    coverage = recompute(previous_coverage, reliable_observations(report))
    report["backfill_cutoff_date"] = coverage["to"]
    report["coverage"] = coverage
    apply_feedback(report, feedback)
    report["dataset_id"] = digest(report["dataset_id"], feedback)
    ocr_path = output / "ocr" / "results.json"
    if ocr_path.exists():
        ocr = json.loads(ocr_path.read_text())
        rows = ocr["results"]
        manifest = json.loads((output / "ocr/manifest.json").read_text())
        card_evidence = card_materials(root, output, manifest["jobs"])
        raw_ocr = snapshot(ocr_path, output)
        raw_annotations = snapshot(output / "ocr/manifest.json", output)
        for e in card_evidence.values():
            e["ocr_result"] = raw_ocr
            e["annotation_snapshot"] = raw_annotations
        report["ocr_probe"] = {
            "results_path": "ocr/results.json", "system_version": ocr["systemVersion"],
            "sample_count": len(rows), "manual_complete_crop_sample": True,
            "field_matches": {field: sum(r.get("parsed", {}).get(field) == r["expected"][field] for r in rows)
                              for field in ("amountCents", "status", "orderedMinute")},
            "recognition_seconds": sum(r.get("recognized", {}).get("elapsedSeconds", 0) for r in rows),
            "samples": [{"card_id": r["cardID"], "image": "ocr/" + Path(r["imagePath"]).name,
                         "visible_title": (r.get("recognized", {}).get("lines") or [{"text": "订单卡片"}])[0]["text"],
                         "expected": r["expected"], "parsed": r.get("parsed"), "error": r.get("error"),
                         "source_evidence": card_evidence[r["cardID"]],
                         "ocr_result_path": "ocr/results.json", "record_date_scope": "within_cutoff" if r["expected"]["orderedMinute"][:10] <= (report["backfill_cutoff_date"] or "") else "after_cutoff"}
                        for r in rows],
            "limits": "人工选取8张完整卡片；未验证自动截取、商家商品解析和退款取消卡片。",
        }
        report["dataset_id"] = digest(report["dataset_id"], sha(ocr_path))
        report["materials_summary"]["order_card_crops"] = len(card_evidence)
    if report["validation"]["bank_sha256_before"] != report["validation"]["bank_sha256_after"]:
        raise RuntimeError("Formal database changed during probe; investigate before using the report")
    output.mkdir(parents=True, exist_ok=True)
    save_evidence(output / "payment-evidence.sqlite3", documents, report)
    (output / "payment-evidence.json").write_text(json.dumps(report, ensure_ascii=False, indent=2))
    # App reads the evidence store directly. Retire the generated browser view,
    # including an old file left by an earlier run; source evidence stays intact.
    (output / "payment-review.html").unlink(missing_ok=True)
    return {"report": str(output / "payment-evidence.json"), "web_observation_retired": True, **report["summary"],
            "review": report["review_summary"], "materials": material_summary,
            "backfill_cutoff": report["backfill_cutoff_date"], "ocr": (report.get("ocr_probe") or {}).get("field_matches")}


if __name__ == "__main__":
    from scripts.processor_result import add_workspace_arguments
    from scripts.workspace_initialization import execute_request
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--review-export", type=Path)
    parser.add_argument("--account-mapping", choices=("unconfirmed", "confirmed", "rejected"))
    parser.add_argument("--operation-id")
    parser.add_argument("--result-file", type=Path)
    add_workspace_arguments(parser)
    args = parser.parse_args()
    if args.workspace:
        def workspace_action(transaction, selected):
            if selected:
                ingest_export(selected[0], transaction.review)
            details = run(transaction.root, transaction.review, args.account_mapping)
            # Evidence refresh and coverage must commit with its financial projection.
            from scripts.financial_review import run as financial
            financial(transaction.root, transaction.review)
            return details
        inputs = [{"path": str(args.review_export), "kind": "review"}] if args.review_export else []
        result, status = execute_request(args, workspace_action, inputs)
        print(json.dumps(result, ensure_ascii=False))
        raise SystemExit(status)
    if args.root is None or args.output is None:
        parser.error("独立处理需要显式 --root 和 --output")
    def action():
        output = args.output
        if args.review_export:
            ingest_export(args.review_export, output)
        return run(args.root, output, args.account_mapping)
    if args.result_file or args.operation_id:
        parser.error('durable processor results require --workspace')
    print(json.dumps(action(), ensure_ascii=False, indent=2))
