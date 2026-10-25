import unittest

from scripts.coverage_policy import (empty_coverage, recompute, set_explicit,
    accept_pending, reliable_observations)
from scripts.financial_review import summarize


class CoveragePolicyTests(unittest.TestCase):
    def test_empty_and_wallet_first_then_earlier_bank_cross_year(self):
        empty = recompute(None, [('unknown', None), ('filename', 'not-a-date')])
        self.assertEqual(empty, empty_coverage())
        wallet = recompute(empty, [('wallet', '2025-12-20')])
        self.assertEqual((wallet['mode'], wallet['from'], wallet['to']),
                         ('automatic', '2025-12-20', '2025-12-20'))
        full = recompute(wallet, [('bank', '2025-11-10'), ('wallet', '2025-12-20'), ('new-year', '2026-01-02')])
        self.assertEqual((full['from'], full['to']), ('2025-11-10', '2026-01-02'))
        revoked = recompute(full, [('wallet', '2025-12-20')])
        self.assertEqual((revoked['from'], revoked['to']), ('2025-11-10', '2026-01-02'))
        self.assertEqual((revoked['observed_from'], revoked['observed_to']), ('2025-12-20', '2025-12-20'))
        self.assertEqual(recompute(revoked, [('wallet', '2025-12-20')]), revoked)

    def test_explicit_pending_accept_and_narrow_preserve_observed(self):
        auto = recompute(None, [('old', '2025-11-10'), ('new', '2026-01-02')])
        narrow = set_explicit(auto, '2025-12-01', '2025-12-31')
        self.assertEqual((narrow['pending_from'], narrow['pending_to']), ('2025-11-10', '2026-01-02'))
        found = recompute(narrow, [('old', '2025-10-01'), ('new', '2026-02-01')])
        self.assertEqual((found['from'], found['to']), ('2025-12-01', '2025-12-31'))
        expanded = accept_pending(found)
        self.assertEqual((expanded['mode'], expanded['from'], expanded['to']),
                         ('explicit', '2025-10-01', '2026-02-01'))
        self.assertIsNone(expanded['pending_from'])
        self.assertIsNone(expanded['pending_to'])

    def test_explicit_single_sided_extension_has_a_complete_suggested_range(self):
        explicit = set_explicit(recompute(None, [('wallet', '2025-12-20')]), '2025-12-01', '2025-12-31')
        earlier = recompute(explicit, [('bank', '2025-11-10')])
        self.assertEqual((earlier['pending_from'], earlier['pending_to']), ('2025-11-10', '2025-12-31'))
        later = recompute(explicit, [('wallet', '2026-01-02')])
        self.assertEqual((later['pending_from'], later['pending_to']), ('2025-12-01', '2026-01-02'))

    def test_only_official_or_active_confirmed_dates_are_observed(self):
        report = {'documents': [{'file_sha256': 'official'}], 'bank_records': [],
                  'clusters': [
                      {'cluster_id': 'wallet', 'representative': {'file_sha256': 'official', 'transaction_time': '2025-12-21 10:00:00'}},
                      {'cluster_id': 'unconfirmed-video', 'representative': {'file_sha256': 'video', 'transaction_time': '2026-01-01', 'date_basis': 'year_label_conflicts_weekday'}},
                      {'cluster_id': 'confirmed-video', 'representative': {'file_sha256': 'video', 'transaction_time': '2025-12-20', 'date_basis': 'user_confirmed_displayed_date'}}]}
        coverage = recompute(None, reliable_observations(report))
        self.assertEqual((coverage['from'], coverage['to']), ('2025-12-20', '2025-12-21'))
        report['clusters'][2]['representative']['date_basis'] = 'year_label_conflicts_weekday'
        after = recompute(coverage, reliable_observations(report))
        self.assertEqual(after['observed_from'], '2025-12-21')
        self.assertEqual(after['from'], '2025-12-20')

    def test_summary_empty_and_range_include_older_year(self):
        self.assertEqual(summarize([], None)['net_cents'], 0)
        self.assertIsNone(summarize([], None)['from'])
        record = {'date': '2025-12-20', 'non_consumption': False, 'unallocated_credit_cents': 0,
                  'components': [{'included': True, 'gross_cents': 100, 'refund_cents': 0,
                      'net_cents': 100, 'primary': 'p', 'secondary': 's'}]}
        self.assertEqual(summarize([record], '2026-01-02')['net_cents'], 100)
        self.assertEqual(summarize([record], '2026-01-02', '2026-01-01')['net_cents'], 0)
