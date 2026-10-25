import argparse
import hashlib
import json
import re
import sqlite3
from datetime import datetime
from decimal import Decimal
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import pypdf


ACCOUNT_RE = re.compile(
    r"Account number (?P<account_number>(?:\d{4} ){3}\d{4}) "
    r"(?P<account_type>RMB|HKD) Sub-account Statement balance "
    r"(?P<currency>[A-Z]{3})(?P<balance>[\d,]+\.\d{2})(?P<cr>CR)?"
)
STATEMENT_DATE_RE = re.compile(r"Statement date Statement balance\n(\d{1,2} [A-Z]{3} \d{4})")
TX_RE = re.compile(
    r"^(?P<post>\d{2}[A-Z]{3}) (?P<trans>\d{2}[A-Z]{3}) "
    r"(?P<description>.+?) (?P<amount>[\d,]+\.\d{2})(?P<cr>CR)?$"
)
SUMMARY_RE = {
    "credit_payment": re.compile(r"^CREDIT/PAYMENT : ([\d,]+\.\d{2})(CR)?$", re.MULTILINE),
    "purchases_and_instalments": re.compile(r"^PURCHASES AND INSTALMENTS : ([\d,]+\.\d{2})(CR)?$", re.MULTILINE),
    "total_account_balance": re.compile(r"^TOTAL ACCOUNT BALANCE : ([\d,]+\.\d{2})(CR)?$", re.MULTILINE),
}
MONTHS = {
    "JAN": "01",
    "FEB": "02",
    "MAR": "03",
    "APR": "04",
    "MAY": "05",
    "JUN": "06",
    "JUL": "07",
    "AUG": "08",
    "SEP": "09",
    "OCT": "10",
    "NOV": "11",
    "DEC": "12",
}


def amount_to_cents(value: str) -> int:
    return int((Decimal(value.replace(",", "")) * 100).quantize(Decimal("1")))


def parse_statement_date(text: str, fallback: Path) -> str:
    match = STATEMENT_DATE_RE.search(text)
    if match:
        return datetime.strptime(match.group(1), "%d %b %Y").date().isoformat()
    return fallback.name.split("_", 1)[0]


def compact_date_to_iso(raw: str, statement_date: str) -> str:
    day = raw[:2]
    mon = raw[2:]
    year = int(statement_date[:4])
    statement_month = int(statement_date[5:7])
    month = int(MONTHS[mon])
    if statement_month == 1 and month == 12:
        year -= 1
    return f"{year:04d}-{month:02d}-{day}"


def extract_text(path: Path) -> str:
    reader = pypdf.PdfReader(str(path))
    return "\n".join(page.extract_text() or "" for page in reader.pages)


def parse_pdf(path: Path) -> dict:
    text = extract_text(path)
    statement_date = parse_statement_date(text, path)
    account = None
    for match in ACCOUNT_RE.finditer(text):
        if match.group("currency") == "CNY":
            account = match.groupdict()
            break

    rows = []
    current = None
    in_cny_table = False
    for line in (part.strip() for part in text.splitlines()):
        if line == "Post date Trans date Description of transaction Amount (CNY)":
            in_cny_table = True
            continue
        if not in_cny_table:
            continue
        if line.startswith("Post date Trans date Description of transaction Amount ("):
            in_cny_table = False
            continue
        if line.startswith(("Note:", "**** REWARDCASH", "Change of correspondence", "Information for ", "STATEMENT BALANCE", "*****")):
            if current:
                rows.append(current)
                current = None
            in_cny_table = False
            continue
        if not line or line.startswith(("Account number ", "Statement of ", "Page ")):
            continue

        match = TX_RE.match(line)
        if match:
            if current:
                rows.append(current)
            gd = match.groupdict()
            current = {
                "post_date_raw": gd["post"],
                "post_date": compact_date_to_iso(gd["post"], statement_date),
                "trans_date_raw": gd["trans"],
                "trans_date": compact_date_to_iso(gd["trans"], statement_date),
                "description": gd["description"],
                "amount_cents": amount_to_cents(gd["amount"]),
                "is_credit": 1 if gd["cr"] else 0,
                "currency": "CNY",
                "raw_parts": [line],
            }
        elif current and not re.fullmatch(r"\d+", line):
            current["description"] = f'{current["description"]} | {line}'
            current["raw_parts"].append(line)
    if current:
        rows.append(current)

    summaries = {}
    for key, regex in SUMMARY_RE.items():
        match = regex.search(text)
        if match:
            summaries[key] = amount_to_cents(match.group(1))

    for row in rows:
        row["raw_line"] = " / ".join(row.pop("raw_parts"))

    return {
        "file_name": path.name,
        "file_sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
        "statement_date": statement_date,
        "account_number": account["account_number"] if account else None,
        "account_type": account["account_type"] if account else "RMB",
        "currency": "CNY",
        "statement_balance_cents": amount_to_cents(account["balance"]) if account else None,
        "statement_balance_is_credit": 1 if account and account["cr"] else 0,
        "transactions": rows,
        "summaries": summaries,
    }


def init_db(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        PRAGMA foreign_keys = ON;
        CREATE TABLE IF NOT EXISTS statements (
            id INTEGER PRIMARY KEY,
            file_name TEXT NOT NULL UNIQUE,
            file_sha256 TEXT,
            statement_date TEXT,
            account_number TEXT,
            account_type TEXT,
            currency TEXT,
            statement_balance_cents INTEGER,
            statement_balance_is_credit INTEGER NOT NULL DEFAULT 0,
            imported_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
        );
        CREATE TABLE IF NOT EXISTS transactions (
            id INTEGER PRIMARY KEY,
            statement_id INTEGER NOT NULL REFERENCES statements(id) ON DELETE CASCADE,
            post_date_raw TEXT NOT NULL,
            post_date TEXT,
            trans_date_raw TEXT NOT NULL,
            trans_date TEXT,
            description TEXT NOT NULL,
            amount TEXT,
            amount_cents INTEGER NOT NULL,
            is_credit INTEGER NOT NULL,
            currency TEXT NOT NULL,
            outgoing_party TEXT,
            transaction_category TEXT,
            raw_line TEXT NOT NULL
        );
        CREATE TABLE IF NOT EXISTS summaries (
            id INTEGER PRIMARY KEY,
            statement_id INTEGER NOT NULL REFERENCES statements(id) ON DELETE CASCADE,
            currency TEXT NOT NULL,
            credit_payment TEXT,
            purchases_and_instalments TEXT,
            total_account_balance TEXT,
            credit_payment_cents INTEGER,
            purchases_and_instalments_cents INTEGER,
            total_account_balance_cents INTEGER,
            UNIQUE(statement_id, currency)
        );
        """
    )


def overrides_table_exists(conn: sqlite3.Connection) -> bool:
    return (
        conn.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'fire_transaction_overrides'"
        ).fetchone()
        is not None
    )


def import_statement(conn: sqlite3.Connection, parsed: dict) -> dict:
    """导入单份账单。

    返回 {"action": "fresh"|"replaced"|"skipped", "count", "migrated", "dropped"}。
    相同 file_sha256 直接跳过；同名不同内容重导入时，交易会被级联删除
    （连带 fire_transaction_overrides），因此先按自然键快照旧覆盖，
    新行插入完成后再把覆盖迁移到新交易 id 上，迁移不掉的显式报告 dropped。
    """
    existing = conn.execute(
        "SELECT id, file_sha256 FROM statements WHERE file_name = ?",
        (parsed["file_name"],),
    ).fetchone()
    if existing and existing[1] == parsed["file_sha256"]:
        return {"action": "skipped", "count": 0, "migrated": 0, "dropped": 0}

    old_overrides: list[tuple[tuple, str]] = []
    if existing and overrides_table_exists(conn):
        rows = conn.execute(
            """
            SELECT t.post_date_raw, t.trans_date_raw, t.description, t.amount_cents, t.is_credit, o.fire_category
              FROM transactions t
              JOIN fire_transaction_overrides o ON o.transaction_id = t.id
             WHERE t.statement_id = ?
            """,
            (existing[0],),
        ).fetchall()
        old_overrides = [(row[:5], row[5]) for row in rows]

    if existing:
        conn.execute("DELETE FROM statements WHERE id = ?", (existing[0],))
    cur = conn.execute(
        """
        INSERT INTO statements (
            file_name, file_sha256, statement_date, account_number, account_type,
            currency, statement_balance_cents, statement_balance_is_credit
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            parsed["file_name"],
            parsed["file_sha256"],
            parsed["statement_date"],
            parsed["account_number"],
            parsed["account_type"],
            parsed["currency"],
            parsed["statement_balance_cents"],
            parsed["statement_balance_is_credit"],
        ),
    )
    statement_id = cur.lastrowid
    conn.executemany(
        """
        INSERT INTO transactions (
            statement_id, post_date_raw, post_date, trans_date_raw, trans_date,
            description, amount, amount_cents, is_credit, currency, outgoing_party, raw_line, spender
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
            (
                statement_id,
                row["post_date_raw"],
                row["post_date"],
                row["trans_date_raw"],
                row["trans_date"],
                row["description"],
                f'{row["amount_cents"] / 100:.2f}',
                row["amount_cents"],
                row["is_credit"],
                row["currency"],
                "Pulse",
                row["raw_line"],
                "未知",
            )
            for row in parsed["transactions"]
        ],
    )
    conn.execute(
        """
        INSERT INTO summaries (
            statement_id, currency, credit_payment_cents,
            purchases_and_instalments_cents, total_account_balance_cents,
            credit_payment, purchases_and_instalments, total_account_balance
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            statement_id,
            parsed["currency"],
            parsed["summaries"].get("credit_payment"),
            parsed["summaries"].get("purchases_and_instalments"),
            parsed["summaries"].get("total_account_balance"),
            cents_to_text(parsed["summaries"].get("credit_payment")),
            cents_to_text(parsed["summaries"].get("purchases_and_instalments")),
            cents_to_text(parsed["summaries"].get("total_account_balance")),
        ),
    )

    migrated = 0
    dropped = 0
    if old_overrides:
        new_rows = conn.execute(
            """
            SELECT id, post_date_raw, trans_date_raw, description, amount_cents, is_credit
              FROM transactions
             WHERE statement_id = ?
            """,
            (statement_id,),
        ).fetchall()
        new_ids = {row[1:]: row[0] for row in new_rows}
        for key, category in old_overrides:
            new_id = new_ids.get(key)
            if new_id is None:
                dropped += 1
                continue
            conn.execute(
                """
                INSERT INTO fire_transaction_overrides (transaction_id, fire_category)
                VALUES (?, ?)
                ON CONFLICT(transaction_id) DO UPDATE SET
                  fire_category = excluded.fire_category,
                  updated_at = datetime('now')
                """,
                (new_id, category),
            )
            migrated += 1

    return {
        "action": "replaced" if existing else "fresh",
        "count": len(parsed["transactions"]),
        "migrated": migrated,
        "dropped": dropped,
    }


def cents_to_text(value: int | None) -> str | None:
    if value is None:
        return None
    return f"{value / 100:.2f}"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pdf-dir", type=Path, required=True)
    parser.add_argument("--db", type=Path)
    parser.add_argument("--operation-id")
    parser.add_argument("--result-file", type=Path)
    from scripts.processor_result import add_workspace_arguments
    add_workspace_arguments(parser)
    args = parser.parse_args()

    pdfs = sorted(args.pdf_dir.glob("*.pdf"))
    if not pdfs:
        raise SystemExit(f"No PDFs found under {args.pdf_dir}")

    if args.workspace:
        if args.db is not None:
            parser.error("--workspace 不能与 --db 一起使用")
        from scripts.workspace_initialization import execute_request
        from scripts.import_review_materials import run as import_materials
        result, status = execute_request(args, lambda transaction, selected:
            import_materials(transaction.root, transaction.review, selected, retained=True,
                input_ids=[str(pdf) for pdf in pdfs]), [str(pdf) for pdf in pdfs])
        print(json.dumps(result, ensure_ascii=False))
        raise SystemExit(status)
    if args.db is None:
        parser.error("独立处理路径需要显式 --db")
    conn = sqlite3.connect(args.db)
    try:
        init_db(conn)
        total = 0
        replaced = 0
        skipped = 0
        with conn:
            for pdf in pdfs:
                result = import_statement(conn, parse_pdf(pdf))
                total += result["count"]
                if result["action"] == "skipped":
                    skipped += 1
                    print(f"{pdf.name}: skipped (unchanged, sha256 matches)")
                elif result["action"] == "replaced":
                    replaced += 1
                    suffix = f", overrides migrated: {result['migrated']}"
                    if result["dropped"]:
                        suffix += f", overrides dropped: {result['dropped']}"
                    print(f"{pdf.name}: {result['count']} CNY transactions{suffix}")
                else:
                    print(f"{pdf.name}: {result['count']} CNY transactions")
        print(
            f"Processed {len(pdfs)} statements ({skipped} skipped, {replaced} re-imported), "
            f"{total} CNY transactions into {args.db}"
        )
    finally:
        conn.close()


if __name__ == "__main__":
    main()
