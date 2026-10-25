"""Import official WeChat XLSX and Alipay CSV exports into bill staging tables.

The exports contain payments made through several accounts.  They therefore do
not belong in ``transactions`` directly: the latter is the bank/Pulse ledger.
This module keeps the original row in ``bill_details`` so a later matcher can
decide whether a row corresponds to a bank transaction or should remain
unmatched.
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
import sqlite3
from datetime import date, datetime
from decimal import Decimal, InvalidOperation, ROUND_HALF_UP
from pathlib import Path
from typing import Iterable, Sequence

import openpyxl


WECHAT_GLOB = "微信支付账单流水文件*.xlsx"
ALIPAY_GLOB = "支付宝交易明细*.csv"

_TIME_FORMATS = (
    "%Y-%m-%d %H:%M:%S",
    "%Y-%m-%d %H:%M",
    "%Y/%m/%d %H:%M:%S",
    "%Y/%m/%d %H:%M",
)
_EXPORT_WINDOW_RE = re.compile(
    r"起始时间：?\[?(?P<from>\d{4}[-/]\d{2}[-/]\d{2} \d{2}:\d{2}:\d{2})\]?"
    r"\s*终止时间：?\[?(?P<to>\d{4}[-/]\d{2}[-/]\d{2} \d{2}:\d{2}:\d{2})\]?"
)


def clean(value: object) -> str:
    """Return an export cell as stable text (including CSV trailing tabs)."""

    if value is None:
        return ""
    return str(value).replace("\u00a0", " ").strip()


def amount_to_cents(value: object) -> int:
    text = clean(value).replace(",", "").replace("¥", "").replace("￥", "")
    if not text:
        raise ValueError("amount is empty")
    try:
        amount = Decimal(text).quantize(Decimal("0.01"), rounding=ROUND_HALF_UP)
    except InvalidOperation as exc:
        raise ValueError(f"invalid amount: {value!r}") from exc
    return int(amount * 100)


def parse_timestamp(value: object) -> tuple[str, str]:
    if isinstance(value, datetime):
        parsed = value
    elif isinstance(value, date):
        parsed = datetime.combine(value, datetime.min.time())
    else:
        text = clean(value)
        parsed = None
        for fmt in _TIME_FORMATS:
            try:
                parsed = datetime.strptime(text, fmt)
                break
            except ValueError:
                continue
        if parsed is None:
            raise ValueError(f"invalid transaction time: {value!r}")
    return parsed.strftime("%Y-%m-%d %H:%M:%S"), parsed.date().isoformat()


def parse_export_window(values: Iterable[object]) -> tuple[str | None, str | None]:
    for value in values:
        match = _EXPORT_WINDOW_RE.search(clean(value))
        if match:
            return (
                match.group("from").replace("/", "-"),
                match.group("to").replace("/", "-"),
            )
    return None, None


def _header_index(rows: Sequence[Sequence[object]], required: str) -> tuple[int, dict[str, int]]:
    for row_number, row in enumerate(rows, start=1):
        headers = {clean(value): index for index, value in enumerate(row) if clean(value)}
        if required in headers:
            return row_number, headers
    raise ValueError(f"could not find header containing {required!r}")


def _field(row: Sequence[object], headers: dict[str, int], name: str) -> str:
    index = headers.get(name)
    if index is None or index >= len(row):
        return ""
    return clean(row[index])


def _detail(
    *,
    source_type: str,
    source_row_number: int,
    row: Sequence[object],
    headers: dict[str, int],
    time_field: str,
    category_field: str,
    merchant_field: str,
    product_field: str,
    direction_field: str,
    amount_field: str,
    payment_field: str,
    status_field: str,
    transaction_no_field: str,
    merchant_order_field: str,
    note_field: str,
) -> dict:
    transaction_time, transaction_date = parse_timestamp(_field(row, headers, time_field))
    transaction_no = _field(row, headers, transaction_no_field)
    raw = {name: _field(row, headers, name) for name in headers}
    return {
        "source_type": source_type,
        "source_row_number": source_row_number,
        "source_transaction_id": transaction_no or None,
        "transaction_time": transaction_time,
        "transaction_date": transaction_date,
        "direction": _field(row, headers, direction_field),
        "amount_cents": amount_to_cents(_field(row, headers, amount_field)),
        "merchant": _field(row, headers, merchant_field),
        "product": _field(row, headers, product_field),
        "payment_method": _field(row, headers, payment_field),
        "status": _field(row, headers, status_field),
        "category_hint": _field(row, headers, category_field) or None,
        "merchant_order_no": _field(row, headers, merchant_order_field) or None,
        "note": _field(row, headers, note_field) or None,
        "raw_json": json.dumps(raw, ensure_ascii=False, sort_keys=True),
    }


def parse_wechat(path: Path) -> dict:
    workbook = openpyxl.load_workbook(path, read_only=True, data_only=True)
    try:
        worksheet = workbook.active
        rows = list(worksheet.iter_rows(values_only=True))
    finally:
        workbook.close()

    header_row, headers = _header_index(rows, "交易时间")
    required = ("金额(元)", "收/支", "交易对方", "商品", "支付方式", "当前状态")
    missing = [name for name in required if name not in headers]
    if missing:
        raise ValueError(f"WeChat export is missing columns: {', '.join(missing)}")

    details = []
    for row_number, row in enumerate(rows[header_row:], start=header_row + 1):
        if not _field(row, headers, "交易时间"):
            continue
        details.append(
            _detail(
                source_type="wechat",
                source_row_number=row_number,
                row=row,
                headers=headers,
                time_field="交易时间",
                category_field="交易类型",
                merchant_field="交易对方",
                product_field="商品",
                direction_field="收/支",
                amount_field="金额(元)",
                payment_field="支付方式",
                status_field="当前状态",
                transaction_no_field="交易单号",
                merchant_order_field="商户单号",
                note_field="备注",
            )
        )

    exported_from, exported_to = parse_export_window(value for row in rows[:header_row] for value in row)
    return {
        "source_type": "wechat",
        "file_name": path.name,
        "file_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "exported_from": exported_from,
        "exported_to": exported_to,
        "details": details,
    }


def _read_csv_rows(path: Path) -> list[list[str]]:
    last_error: UnicodeDecodeError | None = None
    for encoding in ("gb18030", "gbk", "utf-8-sig"):
        try:
            with path.open("r", encoding=encoding, newline="") as handle:
                return list(csv.reader(handle))
        except UnicodeDecodeError as exc:
            last_error = exc
    assert last_error is not None
    raise last_error


def parse_alipay(path: Path) -> dict:
    rows = _read_csv_rows(path)
    header_row, headers = _header_index(rows, "交易时间")
    required = ("交易分类", "交易对方", "商品说明", "收/支", "金额", "收/付款方式", "交易状态")
    missing = [name for name in required if name not in headers]
    if missing:
        raise ValueError(f"Alipay export is missing columns: {', '.join(missing)}")

    details = []
    for row_number, row in enumerate(rows[header_row:], start=header_row + 1):
        if not _field(row, headers, "交易时间"):
            continue
        details.append(
            _detail(
                source_type="alipay",
                source_row_number=row_number,
                row=row,
                headers=headers,
                time_field="交易时间",
                category_field="交易分类",
                merchant_field="交易对方",
                product_field="商品说明",
                direction_field="收/支",
                amount_field="金额",
                payment_field="收/付款方式",
                status_field="交易状态",
                transaction_no_field="交易订单号",
                merchant_order_field="商家订单号",
                note_field="备注",
            )
        )

    exported_from, exported_to = parse_export_window(value for row in rows[:header_row] for value in row)
    return {
        "source_type": "alipay",
        "file_name": path.name,
        "file_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "exported_from": exported_from,
        "exported_to": exported_to,
        "details": details,
    }


def parse_export(path: Path) -> dict:
    suffix = path.suffix.lower()
    if suffix == ".xlsx":
        return parse_wechat(path)
    if suffix == ".csv":
        return parse_alipay(path)
    raise ValueError(f"unsupported export type: {path}")


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS bill_imports (
            id INTEGER PRIMARY KEY,
            source_type TEXT NOT NULL,
            file_name TEXT NOT NULL UNIQUE,
            file_sha256 TEXT NOT NULL,
            exported_from TEXT,
            exported_to TEXT,
            row_count INTEGER NOT NULL DEFAULT 0,
            imported_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS bill_details (
            id INTEGER PRIMARY KEY,
            import_id INTEGER NOT NULL REFERENCES bill_imports(id) ON DELETE CASCADE,
            source_type TEXT NOT NULL,
            source_row_number INTEGER NOT NULL,
            source_transaction_id TEXT,
            transaction_time TEXT NOT NULL,
            transaction_date TEXT NOT NULL,
            direction TEXT NOT NULL,
            amount_cents INTEGER NOT NULL,
            merchant TEXT NOT NULL DEFAULT '',
            product TEXT NOT NULL DEFAULT '',
            payment_method TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            category_hint TEXT,
            merchant_order_no TEXT,
            note TEXT,
            raw_json TEXT NOT NULL,
            matched_transaction_id INTEGER REFERENCES transactions(id) ON DELETE SET NULL,
            match_status TEXT NOT NULL DEFAULT 'unmatched',
            match_confidence REAL,
            match_reason TEXT,
            created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(import_id, source_row_number)
        );
        CREATE INDEX IF NOT EXISTS bill_details_date_amount_idx
            ON bill_details(transaction_date, amount_cents, direction);
        CREATE INDEX IF NOT EXISTS bill_details_match_status_idx
            ON bill_details(match_status);
        """
    )


def import_export(conn: sqlite3.Connection, parsed: dict) -> dict:
    existing = conn.execute(
        "SELECT id, file_sha256 FROM bill_imports WHERE file_name = ?",
        (parsed["file_name"],),
    ).fetchone()
    if existing and existing[1] == parsed["file_sha256"]:
        return {"action": "skipped", "count": 0, "import_id": existing[0]}

    if existing:
        conn.execute("DELETE FROM bill_imports WHERE id = ?", (existing[0],))

    cursor = conn.execute(
        """
        INSERT INTO bill_imports (
            source_type, file_name, file_sha256, exported_from, exported_to, row_count
        ) VALUES (?, ?, ?, ?, ?, ?)
        """,
        (
            parsed["source_type"],
            parsed["file_name"],
            parsed["file_sha256"],
            parsed["exported_from"],
            parsed["exported_to"],
            len(parsed["details"]),
        ),
    )
    import_id = cursor.lastrowid
    conn.executemany(
        """
        INSERT INTO bill_details (
            import_id, source_type, source_row_number, source_transaction_id,
            transaction_time, transaction_date, direction, amount_cents,
            merchant, product, payment_method, status, category_hint,
            merchant_order_no, note, raw_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            (
                import_id,
                row["source_type"],
                row["source_row_number"],
                row["source_transaction_id"],
                row["transaction_time"],
                row["transaction_date"],
                row["direction"],
                row["amount_cents"],
                row["merchant"],
                row["product"],
                row["payment_method"],
                row["status"],
                row["category_hint"],
                row["merchant_order_no"],
                row["note"],
                row["raw_json"],
            )
            for row in parsed["details"]
        ],
    )
    return {
        "action": "replaced" if existing else "fresh",
        "count": len(parsed["details"]),
        "import_id": import_id,
    }


def default_exports(root: Path) -> list[Path]:
    return sorted(root.glob(WECHAT_GLOB)) + sorted(root.glob(ALIPAY_GLOB))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("files", nargs="+", type=Path, help="Explicit WeChat .xlsx and/or Alipay .csv exports")
    parser.add_argument("--db", type=Path, required=True)
    args = parser.parse_args()

    files = args.files

    conn = sqlite3.connect(args.db)
    try:
        init_db(conn)
        total = 0
        skipped = 0
        replaced = 0
        with conn:
            for path in files:
                parsed = parse_export(path)
                result = import_export(conn, parsed)
                total += result["count"]
                if result["action"] == "skipped":
                    skipped += 1
                    print(f"{path.name}: skipped (unchanged, sha256 matches)")
                elif result["action"] == "replaced":
                    replaced += 1
                    print(f"{path.name}: {result['count']} rows (replaced)")
                else:
                    print(f"{path.name}: {result['count']} rows")
        print(
            f"Processed {len(files)} exports ({skipped} skipped, {replaced} replaced), "
            f"{total} rows into {args.db}"
        )
    finally:
        conn.close()


if __name__ == "__main__":
    main()
