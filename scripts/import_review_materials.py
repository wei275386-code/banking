"""Internal processor invoked by the native App's file picker, never by the user."""
import argparse
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
from datetime import datetime
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.processor_result import add_workspace_arguments
from scripts.workspace_initialization import execute_request

try:
    from .processor_result import InputProcessingError
    from .import_pulse_statements import init_db, import_statement, parse_pdf
    from .probe_payment_evidence import run as build_evidence, register_exports
    from .financial_review import run as build_review
    from .payment_evidence import parse_document
    from .video_evidence import run as build_video
    from .order_evidence import run as build_orders
except ImportError:
    from processor_result import InputProcessingError
    from import_pulse_statements import init_db, import_statement, parse_pdf
    from probe_payment_evidence import run as build_evidence, register_exports
    from financial_review import run as build_review
    from payment_evidence import parse_document
    from video_evidence import run as build_video
    from order_evidence import run as build_orders


def file_sha256(source):
    """Bound memory even for multi-gigabyte screen recordings."""
    digest = hashlib.sha256()
    with Path(source).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def video_helper(root):
    # The isolated bundle bootstrap supplies this controlled absolute path.
    # Standalone development is explicitly rooted and uses a Release product.
    configured = os.environ.get("BANKING_VIDEO_HELPER")
    if configured is not None:
        binary = Path(configured)
        if not binary.is_absolute():
            raise ValueError("视频处理器配置必须为绝对路径")
    else:
        binary = Path(root) / "native/PaymentImageCore/.build/release/VideoRecords"
    if not binary.is_file() or not os.access(binary, os.X_OK):
        raise ValueError("本机 Release 视频处理器缺失或不可执行")
    return binary


def retain(source, folder):
    checksum = file_sha256(source)
    folder.mkdir(parents=True, exist_ok=True)
    dest = folder / source.name
    if dest.exists() and file_sha256(dest) != checksum:
        dest = folder / (source.stem + "_import-" + checksum[:12] + source.suffix)
    if not dest.exists(): shutil.copy2(source, dest)
    return dest


class PendingVideoExtraction(ValueError):
    """Only a completed extractor's identified domain limitation permits partial."""
    def __init__(self, code, message):
        if code not in {'unsupported_video_layout', 'unconfirmed_video_fields'}:
            raise ValueError('未知的录屏待处理原因')
        super().__init__(message)
        self.code = code


def project_video(root, output, video, *, checksum=None, retry=False, input_id=None):
    """Keep runtime and I/O errors distinct from supported pending domain states."""
    try:
        return _project_video(root, output, video, checksum=checksum, retry=retry)
    except PendingVideoExtraction:
        raise
    except Exception as error:
        raise InputProcessingError(input_id or str(video), str(error)) from error


def _project_video(root, output, video, *, checksum=None, retry=False):
    """Project one already retained recording; unknown layouts stay pending."""
    root, output, video = Path(root), Path(output), Path(video)
    checksum = checksum or file_sha256(video)
    if (output / "supplemental-evidence-imports" / (checksum + ".json")).exists():
        return {'visually_reviewed': True}
    folder = output / "video-imports" / checksum
    result_path = folder / "video-records.json"
    if retry or not result_path.exists():
        binary = video_helper(root)
        subprocess.run([str(binary), str(video), str(folder)], check=True)
    raw = json.loads(result_path.read_text())
    if (not isinstance(raw, dict) or not isinstance(raw.get("rows"), list)
            or not isinstance(raw.get("source"), str) or not raw["source"]
            or not isinstance(raw.get("recall_status"), str)
            or any(not isinstance(row, dict) or not isinstance(row.get("id"), str)
                   or not isinstance(row.get("text"), str) for row in raw["rows"])):
        raise ValueError("录屏 extraction JSON schema 无效")
    if "errors" in raw:
        if not isinstance(raw["errors"], list) or any(not isinstance(error, str) for error in raw["errors"]):
            raise ValueError("录屏 extraction errors schema 无效")
        if raw["errors"]:
            raise RuntimeError("录屏 extraction 存在运行错误：" + "; ".join(raw["errors"]))
    if not raw["rows"]:
        raise PendingVideoExtraction("unsupported_video_layout", "没有找到完整记录，录屏布局需检查")
    # Extraction metadata contains a local source locator. Relocate it to the
    # current staging input, never a vanished older staging directory.
    if raw.get("source") != str(video):
        raw["source"] = str(video)
        result_path.write_text(json.dumps(raw, ensure_ascii=False, indent=2) + "\n")
    result = build_orders(root, output, folder) if raw["rows"][0].get("platform") == "meituan_card" else build_video(root, output, folder)
    if not result.get('materials'):
        raise PendingVideoExtraction('unsupported_video_layout', '录屏布局尚未识别，素材继续等待处理')
    return result


def run(root, output, paths, *, retained=False, input_ids=None):
    root, output = Path(root), Path(output)
    prepared = []
    input_ids = input_ids or [str(path) for path in paths]
    identities = {str(path): str(input_id) for path, input_id in zip(paths, input_ids)}
    # Validate every selected file before changing the bank ledger. Fixed batches
    # bound work; the native App presents one import operation to the household.
    for start in range(0, len(paths), 4):
        for name in paths[start:start + 4]:
            try:
                source = Path(name).resolve()
                if not source.is_file(): raise ValueError("找不到素材：" + source.name)
                ext = source.suffix.lower()
                if ext == ".pdf":
                    parsed = parse_pdf(source)
                    if not parsed["transactions"]: raise ValueError("账单未解析出明细：" + source.name)
                    sums = parsed["summaries"]
                    debit = sum(t["amount_cents"] for t in parsed["transactions"] if not t["is_credit"])
                    credit = sum(t["amount_cents"] for t in parsed["transactions"] if t["is_credit"])
                    if debit != sums.get("purchases_and_instalments") or credit != sums.get("credit_payment"):
                        raise ValueError("账单明细与汇总不一致，尚未导入：" + source.name)
                    prepared.append((source, "bank", parsed, identities[str(name)]))
                elif ext in (".csv", ".xlsx"):
                    prepared.append((source, "export", parse_document(source), identities[str(name)]))
                elif ext in (".mov", ".mp4", ".m4v"):
                    prepared.append((source, "video", None, identities[str(name)]))
                else: raise ValueError("目前支持官方 PDF、CSV、XLSX 和录屏素材：" + source.name)
            except Exception as exc:
                raise InputProcessingError(identities[str(name)], str(exc)) from exc
    if not retained and any(kind == "bank" for _, kind, _, _ in prepared):
        backup = root / "backups" / ("before-app-import-" + datetime.now().strftime("%Y%m%d-%H%M%S-%f") + ".sqlite3")
        backup.parent.mkdir(exist_ok=True)
        src = sqlite3.connect(root / "banking.sqlite3"); dest = sqlite3.connect(backup)
        src.backup(dest); src.close(); dest.close()
    banks = []; videos = []; exports = []; parsed_documents = {}
    for source, kind, parsed, input_id in prepared:
        dest = source if retained and kind != "bank" else retain(source, root / "pulse_statements" if kind == "bank" else root)
        if kind == "bank":
            parsed["file_name"] = dest.name
            banks.append(parsed)
        elif kind == "video": videos.append((dest, input_id))
        elif kind == "export":
            parsed["file_name"] = dest.name
            for observation in parsed["observations"]:
                observation["file_name"] = dest.name
            parsed_documents[dest.resolve()] = parsed
            exports.append((dest, parsed["platform"]))
    if banks:
        conn = sqlite3.connect(root / "banking.sqlite3")
        try:
            init_db(conn)
            with conn:
                for parsed in banks: import_statement(conn, parsed)
        finally: conn.close()
    register_exports(root, exports)
    evidence = build_evidence(root, output, parsed_documents=parsed_documents)
    video_failures = []
    for video, input_id in videos:
        try:
            project_video(root, output, video, input_id=input_id)
        except PendingVideoExtraction as exc:
            video_failures.append({"name":video.name,"input_id":input_id,
                                   "reason_code":exc.code,"reason":str(exc)})
    review = build_review(root, output)
    inventory_path = output / "import-inventory.json"
    inventory = json.loads(inventory_path.read_text()) if inventory_path.exists() else []
    for source, kind, parsed, input_id in prepared:
        key = parsed.get("file_sha256") if parsed else None
        key = key or file_sha256(source)
        inventory = [x for x in inventory if x["sha256"] != key]
        if not any(x["sha256"] == key for x in inventory):
            inventory.append({"name": source.name, "sha256": key, "kind": kind,
                              "status": "素材已保存，提取待处理" if any(x["input_id"]==input_id for x in video_failures) else "已提取完整素材，异常见资料页" if kind=="video" else "已导入",
                              "imported_at": datetime.now().isoformat()})
    inventory_path.write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n")
    return {"selected_files": len(paths), "lifecycles": len(review["records"]), "cutoff": review["cutoff"],
            "pending_video_sources": video_failures, "review": evidence["review"]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--files-json", type=Path, required=True)
    parser.add_argument("--operation-id", required=True)
    parser.add_argument("--result-file", type=Path, required=True)
    add_workspace_arguments(parser)
    args = parser.parse_args()
    if args.workspace is None:
        parser.error('--workspace is required')
    try:
        paths = json.loads(args.files_json.read_text())
    except Exception:
        paths = []
    def workspace_action(transaction, selected):
        if not paths:
            json.loads(args.files_json.read_text())
        return run(transaction.root, transaction.review, selected, retained=True, input_ids=paths)
    result, status = execute_request(args, workspace_action, paths)
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(status)
