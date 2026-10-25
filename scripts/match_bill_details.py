"""Match staged wallet rows through explicit household funding configuration.

Date/amount/direction and unique allocation are necessary but never invent an
account route. Unconfigured or ambiguous funding stays unresolved.
"""

from __future__ import annotations

import argparse
import sqlite3
from collections import Counter
from pathlib import Path

try:
    from .import_wechat_alipay import init_db
except ImportError:  # pragma: no cover - direct ``python scripts/...`` execution
    from import_wechat_alipay import init_db


try:
    from .household_settings import load_processor_settings, project_funding
    from .payment_evidence import has_resolved_funding
except ImportError:
    from household_settings import load_processor_settings, project_funding
    from payment_evidence import has_resolved_funding


def expected_credit(direction: str) -> int | None:
    if direction == "支出":
        return 0
    if direction == "收入":
        return 1
    return None


def reset_match_state(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        UPDATE bill_details
           SET matched_transaction_id = NULL,
               match_status = 'unmatched',
               match_confidence = NULL,
               match_reason = NULL,
               updated_at = datetime('now')
        """
    )


def candidate_transactions(
    conn: sqlite3.Connection,
    *,
    transaction_date: str,
    amount_cents: int,
    is_credit: int,
    currency: str,
) -> list[sqlite3.Row]:
    return conn.execute(
        """
        SELECT t.id,
               COALESCE(t.trans_date, t.post_date) AS transaction_date,
               t.amount_cents,
               t.is_credit,
               t.description,
               s.account_number, s.file_sha256 AS statement_sha256, t.currency
          FROM transactions AS t
          JOIN statements AS s ON s.id = t.statement_id
         WHERE COALESCE(t.trans_date, t.post_date) = ?
           AND t.amount_cents = ?
           AND t.is_credit = ?
           AND t.currency = ?
           AND (
             UPPER(t.description) LIKE '%UNIONPAY%'
             OR UPPER(t.description) LIKE '%ALIPAY%'
             OR UPPER(t.description) LIKE '%TENPAY%'
           )
           AND UPPER(t.description) NOT LIKE '%IFS PAYMENT%'
         ORDER BY t.id
        """,
        (transaction_date, amount_cents, is_credit, currency),
    ).fetchall()


def match_details(conn: sqlite3.Connection, *, settings=None, sources=None, currency=None) -> dict[str, int]:
    """Match all staged rows and return counts by ``match_status``.

    The pass is deterministic and starts from a clean match state.  A PDF
    transaction can be assigned at most once in this run; duplicate exact
    rows are therefore either paired one-to-one or reported as ambiguous.
    """

    previous_factory = conn.row_factory
    conn.row_factory = sqlite3.Row
    try:
        reset_match_state(conn)
        used_transaction_ids: set[int] = set()
        counts: Counter[str] = Counter()

        rows = conn.execute(
            """
            SELECT d.id, d.direction, d.amount_cents, d.transaction_date, d.payment_method, d.status,
                   d.source_type AS platform, i.file_sha256
              FROM bill_details d JOIN bill_imports i ON i.id = d.import_id
             ORDER BY d.transaction_date, d.transaction_time, d.id
            """
        ).fetchall()
        for row in rows:
            detail_id = int(row["id"])
            direction = row["direction"] or ""
            expected = expected_credit(direction)
            if expected is None:
                status = "not_applicable"
                reason = f"direction {direction or 'empty'} is not income/expense"
                conn.execute(
                    "UPDATE bill_details SET match_status=?, match_reason=?, updated_at=datetime('now') WHERE id=?",
                    (status, reason, detail_id),
                )
                counts[status] += 1
                continue

            source_status = row["status"] or ""
            if "关闭" in source_status or "取消" in source_status:
                status = "not_applicable"
                reason = f"source status {source_status} is closed/cancelled"
                conn.execute(
                    "UPDATE bill_details SET match_status=?, match_reason=?, updated_at=datetime('now') WHERE id=?",
                    (status, reason, detail_id),
                )
                counts[status] += 1
                continue

            funding = dict(row) | {'currency': currency}
            project_funding([funding], [], settings, sources or {})
            if not has_resolved_funding(funding):
                status = "not_applicable"
                reason = "funding configuration is absent, unmatched or needs review"
                conn.execute(
                    "UPDATE bill_details SET match_status=?, match_reason=?, updated_at=datetime('now') WHERE id=?",
                    (status, reason, detail_id),
                )
                counts[status] += 1
                continue

            all_candidates = candidate_transactions(
                conn,
                transaction_date=row["transaction_date"],
                amount_cents=int(row["amount_cents"]),
                is_credit=expected,
                currency=currency,
            )
            resolved = [dict(candidate) for candidate in all_candidates]
            project_funding([], resolved, settings, sources or {})
            candidates = [candidate for candidate in resolved if has_resolved_funding(candidate)
                          and candidate['funding_account_id'] == funding['funding_account_id']
                          and int(candidate['id']) not in used_transaction_ids]
            if len(candidates) == 1:
                candidate = candidates[0]
                transaction_id = int(candidate["id"])
                used_transaction_ids.add(transaction_id)
                status = "matched"
                reason = "configured funding account + exact date/amount/direction + unique unused bank row"
                conn.execute(
                    """
                    UPDATE bill_details
                       SET matched_transaction_id=?, match_status=?, match_confidence=1.0,
                           match_reason=?, updated_at=datetime('now')
                     WHERE id=?
                    """,
                    (transaction_id, status, reason, detail_id),
                )
            elif len(candidates) > 1:
                status = "ambiguous"
                reason = f"{len(candidates)} exact PDF candidates"
                conn.execute(
                    """
                    UPDATE bill_details
                       SET match_status=?, match_confidence=0.5, match_reason=?, updated_at=datetime('now')
                     WHERE id=?
                    """,
                    (status, reason, detail_id),
                )
            else:
                status = "unmatched"
                reason = "no unused exact PDF candidate" if all_candidates else "no exact PDF candidate"
                conn.execute(
                    """
                    UPDATE bill_details
                       SET match_status=?, match_confidence=0.0, match_reason=?, updated_at=datetime('now')
                     WHERE id=?
                    """,
                    (status, reason, detail_id),
                )
            counts[status] += 1

        return dict(sorted(counts.items()))
    finally:
        conn.row_factory = previous_factory


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--settings-root", type=Path, required=True, help="Explicit processor input root containing household settings and source registry")
    parser.add_argument("--currency", required=True, help="Declared currency of this staged wallet source; no FX conversion")
    args = parser.parse_args()

    conn = sqlite3.connect(args.db)
    try:
        init_db(conn)
        with conn:
            settings, sources = load_processor_settings(args.settings_root)
            counts = match_details(conn, settings=settings, sources=sources, currency=args.currency)
        summary = ", ".join(f"{key}={value}" for key, value in counts.items()) or "no bill details"
        print(f"Matched bill details in {args.db}: {summary}")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
