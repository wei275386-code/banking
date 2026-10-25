"""Apply only user-confirmed merchant labels to the reviewed existing components.

Uses the native NSFileCoordinator writer, preserves effective annotations, and
records a batch audit. This does not turn unreviewed research into live rules.
"""
import argparse
import datetime
import hashlib
import json
from pathlib import Path
import subprocess


ROOT = Path(__file__).resolve().parents[1]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main(source, research, decisions_path, evidence_root):
    SOURCE, RESEARCH = Path(source).resolve(), Path(research).resolve()
    evidence_root = Path(evidence_root).resolve()
    decisions = json.loads(Path(decisions_path).read_text())["decisions"]
    candidates = json.loads((RESEARCH / "review-candidates.json").read_text())
    automatic = json.loads((RESEARCH / "automatic-labels.json").read_text())
    report = json.loads((SOURCE / "financial-review.json").read_text())
    summary = json.loads((RESEARCH / "summary.json").read_text())
    if report["dataset_id"] != summary["dataset_id"]:
        raise RuntimeError("Research source changed; review updated candidates before applying")
    lookup = {c["id"]: (r, c) for r in report["records"] for c in r["components"]}
    target = SOURCE / "review-overrides.json"
    expected = target.read_bytes()
    before = json.loads(expected)
    after = json.loads(expected)
    changes = []
    seen = set()
    timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()
    for group in candidates + automatic:
        decision = decisions.get(group["label"], {})
        if decision.get("decision") != "merchant":
            continue
        tag = decision["tag"]
        if not isinstance(tag, str) or not 1 <= len(tag.strip()) <= 40:
            raise ValueError("Invalid confirmed tag")
        for member in group["members"]:
            key = member["component_id"]
            if (key, tag) in seen:
                continue
            seen.add((key, tag))
            record, component = lookup[key]
            if record["id"] != member["lifecycle_id"] or component["title"] != member["title"]:
                raise RuntimeError("Reviewed component identity changed")
            keys = list(dict.fromkeys([key] + component.get("classification_keys", [])))
            prior = next((after[k] for k in keys if k in after), {})
            old_tags = prior.get("tags", component.get("tags", []))
            superseded = set()
            correction = decision.get("supersedes_assignment")
            if correction and correction["tag"] in old_tags:
                relative = Path(correction["plan"])
                if relative.is_absolute() or '..' in relative.parts:
                    raise ValueError('Correction plan must be relative to the explicit evidence root')
                plan = (evidence_root / relative).resolve()
                if not plan.is_relative_to(evidence_root):
                    raise ValueError('Correction plan escapes the explicit evidence root')
                provenance = json.loads(plan.read_text())
                matching = [change for change in provenance["changes"] if change["component_id"] == key
                    and change["matched_name"] == group["label"] and change["label"] == correction["tag"]]
                if len(matching) != 1 or correction["tag"] in matching[0]["before"].get("tags", component.get("tags", [])):
                    raise RuntimeError("Cannot establish that superseded tag was newly added by this batch")
                if prior.get("tag_basis", {}).get(correction["tag"]) != matching[0]["after"]["tag_basis"][correction["tag"]]:
                    raise RuntimeError("Superseded tag provenance changed")
                superseded.add(correction["tag"])
            if tag in old_tags and not superseded:
                continue
            tags = sorted((set(old_tags) - superseded) | {tag})
            if len(tags) > 30:
                raise ValueError("Too many tags")
            value = dict(prior)
            value.setdefault("primary", component["primary"])
            value.setdefault("secondary", component["secondary"])
            value.setdefault("recurrence", component.get("recurrence", "unconfirmed"))
            value["tags"] = tags
            value["tag_basis"] = {**component.get("tag_basis", {}), **prior.get("tag_basis", {}), tag: "用户确认标签（2026-10-10）"}
            for removed in superseded:
                value["tag_basis"].pop(removed, None)
            value["edited_at"] = timestamp
            after[key] = value
            changes.append({"component_id": key, "lifecycle_id": record["id"], "label": tag,
                            "matched_name": group["label"], "removed_tags": sorted(superseded), "before": prior, "after": value})
    if not changes:
        print(json.dumps({"changed_components": 0}, ensure_ascii=False))
        return
    run = RESEARCH / ("applied-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    run.mkdir()
    protected_names = ["financial-review.json", "financial-review.sqlite3", "review-state.json", "fire-parameters-user.json"]
    protected = {name: sha(SOURCE / name) for name in protected_names}
    (run / "before.json").write_bytes(expected)
    (run / "prepared.json").write_text(json.dumps(after, ensure_ascii=False, indent=2) + "\n")
    (run / "plan.json").write_text(json.dumps({"changes": changes, "protected_sha256": protected}, ensure_ascii=False, indent=2) + "\n")
    result = subprocess.run(["swift", str(ROOT / "scripts/apply_review_tag_document.swift"), str(target),
        str(run / "before.json"), str(run / "prepared.json")], capture_output=True, text=True, timeout=15, check=True)
    saved = json.loads(target.read_text())
    changed = {k for k in before.keys() | saved.keys() if before.get(k) != saved.get(k)}
    wanted = {c["component_id"] for c in changes}
    if changed != wanted:
        raise RuntimeError("Saved annotations differ from the confirmed batch; inspect audit")
    for key in wanted:
        if saved[key] != after[key]:
            raise RuntimeError("Saved entry differs from the prepared batch")
    for change in changes:
        for key, value in change["before"].items():
            if key not in ("tags", "tag_basis", "edited_at") and change["after"].get(key) != value:
                raise RuntimeError("Existing annotation field changed")
    unchanged = {name: sha(SOURCE / name) == value for name, value in protected.items()}
    if not all(unchanged.values()):
        raise RuntimeError("Protected files changed during the batch; inspect source state")
    counts = {tag: len({c["component_id"] for c in changes if c["label"] == tag}) for tag in sorted({c["label"] for c in changes})}
    audit = {"changed_components": len(wanted), "changed_lifecycles": len({c["lifecycle_id"] for c in changes}),
        "counts_by_tag": counts, "protected_unchanged": unchanged, "history_backup": result.stdout.strip(),
        "skipped_names": [name for name, d in decisions.items() if d["decision"] == "no_tag"]}
    (run / "audit.json").write_text(json.dumps(audit, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({**audit, "audit_file": str(run / "audit.json")}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for option in ('source', 'research', 'decisions', 'evidence-root'):
        parser.add_argument('--' + option, type=Path, required=True)
    args = parser.parse_args()
    main(args.source, args.research, args.decisions, args.evidence_root)
