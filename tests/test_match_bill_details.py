import sqlite3
import unittest

from scripts.import_wechat_alipay import init_db
from scripts.match_bill_details import match_details
from test_processor_household_settings import make_settings


class MatchBillDetailsTest(unittest.TestCase):
    def setUp(self):
        self.settings = make_settings()
        self.conn = sqlite3.connect(":memory:")
        self.conn.executescript(
            """
            PRAGMA foreign_keys = ON;
            CREATE TABLE statements (
                id INTEGER PRIMARY KEY,
                file_name TEXT NOT NULL UNIQUE,
                account_number TEXT NOT NULL,
                file_sha256 TEXT
            );
            CREATE TABLE transactions (
                id INTEGER PRIMARY KEY,
                statement_id INTEGER NOT NULL REFERENCES statements(id),
                trans_date TEXT,
                post_date TEXT,
                description TEXT NOT NULL,
                amount_cents INTEGER NOT NULL,
                is_credit INTEGER NOT NULL,
                currency TEXT NOT NULL,
                raw_line TEXT NOT NULL
            );
            INSERT INTO statements (id, file_name, account_number)
            VALUES (1, 'pulse.pdf', '9001');
            INSERT INTO transactions
                (id, statement_id, trans_date, description, amount_cents, is_credit, currency, raw_line)
            VALUES
                (10, 1, '2026-02-03', 'UNIONPAY MERCHANT CHN CN', 1234, 0, 'CNY', 'row 10'),
                (11, 1, '2026-02-03', 'UNIONPAY MERCHANT CHN CN', 1234, 0, 'CNY', 'row 11'),
                (12, 1, '2026-02-04', 'UNIONPAY MERCHANT CHN CN', 500, 1, 'CNY', 'row 12');
            """
        )
        init_db(self.conn)
        self.conn.execute(
            "INSERT INTO bill_imports (id, source_type, file_name, file_sha256, row_count) VALUES (1, 'alipay', 'a.csv', 'a', 4)"
        )
        self.conn.executemany(
            """
            INSERT INTO bill_details (
                id, import_id, source_type, source_row_number, source_transaction_id,
                transaction_time, transaction_date, direction, amount_cents,
                merchant, product, payment_method, status, raw_json
            ) VALUES (?, 1, 'alipay', ?, ?, ?, ?, ?, ?, '', '', ?, ?, '{}')
            """,
            [
                (1, 1, 'a-1', '2026-02-03 10:00:00', '2026-02-03', '支出', 1234, 'Synthetic wallet card', '交易成功'),
                (2, 2, 'a-2', '2026-02-03 10:01:00', '2026-02-03', '支出', 1234, 'Synthetic wallet card', '交易成功'),
                (3, 3, 'a-3', '2026-02-03 10:02:00', '2026-02-03', '支出', 999, 'Unconfigured synthetic card (9003)', '交易成功'),
                (4, 4, 'a-4', '2026-02-04 10:00:00', '2026-02-04', '收入', 500, 'Synthetic wallet card', '交易成功'),
            ],
        )
        self.conn.commit()

    def tearDown(self):
        self.conn.close()

    def test_matches_unique_candidate_and_does_not_reuse_pdf_transaction(self):
        # Two exact candidates make both rows ambiguous rather than silently
        # assigning an arbitrary bank line.
        first = match_details(self.conn, settings=self.settings, currency="CNY")
        self.assertEqual(first["ambiguous"], 2)
        self.assertEqual(self.conn.execute("SELECT matched_transaction_id FROM bill_details WHERE id IN (1, 2)").fetchall(), [(None,), (None,)])

        # Remove one candidate and rerun: the remaining exact row is paired.
        self.conn.execute("DELETE FROM transactions WHERE id = 11")
        result = match_details(self.conn, settings=self.settings, currency="CNY")
        self.assertEqual(result["matched"], 2)
        self.assertEqual(
            self.conn.execute(
                "SELECT match_status, matched_transaction_id FROM bill_details WHERE id = 1"
            ).fetchone(),
            ("matched", 10),
        )
        self.assertEqual(
            self.conn.execute("SELECT match_status FROM bill_details WHERE id = 2").fetchone(),
            ("unmatched",),
        )

    def test_unconfigured_account_is_not_guessed(self):
        result = match_details(self.conn, settings=self.settings, currency="CNY")

        self.assertEqual(result["not_applicable"], 1)
        self.assertEqual(
            self.conn.execute(
                "SELECT match_status, match_reason FROM bill_details WHERE id = 3"
            ).fetchone()[0],
            "not_applicable",
        )
        self.assertEqual(
            self.conn.execute(
                "SELECT match_status, matched_transaction_id FROM bill_details WHERE id = 4"
            ).fetchone(),
            ("matched", 12),
        )


if __name__ == "__main__":
    unittest.main()
