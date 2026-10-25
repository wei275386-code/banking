import copy
import unittest
from scripts.confirmed_outcomes import ConfirmedOutcomes, record_signature, records
from test_financial_review import build, source, payment


class ConfirmedOutcomesTests(unittest.TestCase):
    def fixture(self):
        report = source({'p': payment('purchase', 300)})
        rows, _ = build(report)
        current = {'records': rows, 'coverage': {'from': None, 'to': None, 'mode': 'empty', 'revision': 0}}
        record = rows[0]
        from scripts.confirmed_outcomes import bound_signatures
        from scripts.inferred_associations import evidence_signature
        evidence = {c['cluster_id']: c['representative'] for c in report['clusters']}
        banks = {f"bank:{b['id']}": b for b in report['bank_records']}
        signatures = {k: evidence_signature(k, evidence, banks) for k in evidence.keys() | banks.keys()}
        component = record['components'][0]
        entry = {'id': record['id'], 'signature': record_signature(record),
            'evidence_signatures': bound_signatures(record, signatures), 'fields': {'unallocated_credit_cents': 0},
            'components': [{'id': component['id'], 'fields': {'primary': 'Food', 'secondary': 'Coffee'},
                            'override_values': {component['id']: None}, 'catalog_sha256': 'a' * 64}]}
        document = {'purpose': 'confirmed-outcomes', 'records': [entry], 'coverage': copy.deepcopy(current['coverage'])}
        return current, document, evidence, banks

    def test_current_decision_needs_no_report_source_and_does_not_apply_to_new_records(self):
        current, document, rows, banks = self.fixture()
        new = copy.deepcopy(current['records'][0]); new['id'] = 'new'
        before = copy.deepcopy(new); current['records'].append(new)
        ConfirmedOutcomes(document, rows, banks).apply(current, {}, 'a' * 64)
        self.assertEqual(current['records'][0]['components'][0]['secondary'], 'Coffee')
        self.assertEqual(current['records'][1], before)

    def test_later_edit_only_supersedes_affected_component(self):
        current, document, rows, banks = self.fixture()
        key = current['records'][0]['components'][0]['id']
        decision = ConfirmedOutcomes(document, rows, banks)
        untouched = copy.deepcopy(current)
        decision.apply(untouched, {'unrelated': {'primary': 'New'}}, 'a' * 64)
        self.assertEqual(untouched['records'][0]['components'][0]['secondary'], 'Coffee')
        before = copy.deepcopy(current)
        decision.apply(current, {key: {'primary': 'New'}}, 'a' * 64)
        self.assertEqual(current['records'], before['records'])

    def test_changed_amount_or_evidence_does_not_reapply_saved_value(self):
        current, document, rows, banks = self.fixture()
        current['records'][0]['components'][0]['gross_cents'] += 1
        before = copy.deepcopy(current)
        ConfirmedOutcomes(document, rows, banks).apply(current, {}, 'a' * 64)
        self.assertEqual(current['records'], before['records'])

    def test_unknown_control_fields_and_duplicate_decisions_fail(self):
        current, document, rows, banks = self.fixture()
        document['format_version'] = 1
        with self.assertRaises(ValueError): ConfirmedOutcomes(document, rows, banks)
        del document['format_version']
        document['records'].append(copy.deepcopy(document['records'][0]))
        with self.assertRaises(ValueError): ConfirmedOutcomes(document, rows, banks)

    def test_wrong_decision_value_types_are_rejected_before_application(self):
        for field, value in [('unallocated_credit_cents', '100'), ('unallocated_credit_cents', True)]:
            current, document, rows, banks = self.fixture()
            document['records'][0]['fields'][field] = value
            with self.assertRaises(ValueError): ConfirmedOutcomes(document, rows, banks)
        current, document, rows, banks = self.fixture()
        document['records'][0]['components'][0]['fields']['included'] = 'yes'
        with self.assertRaises(ValueError): ConfirmedOutcomes(document, rows, banks)

    def test_later_range_and_record_exclusion_supersede_saved_inclusion_only(self):
        for change_range in (True, False):
            current, document, rows, banks = self.fixture()
            component = current['records'][0]['components'][0]
            component.update(included=False, reason='current user scope')
            document['records'][0]['components'][0]['fields'].update(included=True, reason='')
            if change_range:
                current['coverage']['revision'] += 1
            else:
                current['records'][0]['excluded_from_completion_and_statistics'] = True
            ConfirmedOutcomes(document, rows, banks).apply(current, {}, 'a' * 64)
            self.assertFalse(component['included'])
            self.assertEqual(component['reason'], 'current user scope')
            self.assertEqual(component['secondary'], 'Coffee')
