"""From-zero compound policy scenarios; no real household rules."""
import copy
import json
from pathlib import Path
import tempfile
import unittest

from scripts.financial_review import build, classify
from scripts.review_annotations import InferencePolicy, annotate
from scripts.financial_review_inputs import FinancialReviewInputs
from test_financial_review import source, bank


def synthetic_policy():
    return {'rules': [
        {'id': 'category-a', 'phase': 'category', 'when': {'all': [
            {'field': 'text', 'pattern': 'SYNTHETIC TERMINAL'},
            {'any': [{'field': 'existing_category', 'equals': 'Synthetic old category'},
                     {'field': 'text', 'pattern': 'SYNTHETIC TICKET'}]}]},
         'effect': {'primary': '日常消费', 'secondary': '交通出行'}},
        {'id': 'trip-a', 'phase': 'tags', 'when': {'all': [
            {'field': 'secondary', 'equals': '交通出行'},
            {'field': 'text', 'pattern': 'SYNTHETIC TERMINAL'}]},
         'effect': {'tags': ['Synthetic journey'], 'basis': 'Synthetic compound rule'}}]}


class InferencePolicyTests(unittest.TestCase):
    def test_new_input_and_negative_combination_after_import(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rules = {'rules': [], 'unknown_future_metadata': {'keep': True}}
            review = root / 'review'; review.mkdir()
            (review / 'classification-rules.json').write_text(json.dumps(dict(rules, inference_policy=synthetic_policy())))
            inputs = FinancialReviewInputs(root, review)
            report = source(banks=[bank(description='SYNTHETIC TERMINAL SYNTHETIC TICKET new purchase')])
            report['classification_rules'] = inputs.classification_rules()
            report['inference_policy'] = inputs.inference_policy()
            rows, _ = build(report)
            component = rows[0]['components'][0]
            self.assertEqual((component['primary'], component['secondary']), ('日常消费', '交通出行'))
            self.assertIn('Synthetic journey', component['tags'])
            self.assertEqual(json.loads((review / 'classification-rules.json').read_bytes())['unknown_future_metadata'], {'keep': True})
            policy = InferencePolicy(inputs.inference_policy())
            self.assertEqual(classify('SYNTHETIC TERMINAL', policy=policy)[0], '待分类')
            self.assertEqual(classify('SYNTHETIC TERMINAL', 'Synthetic old category', policy=policy)[1], '交通出行')
            # A new household has no personal journey inference.
            self.assertEqual(classify('SYNTHETIC TERMINAL SYNTHETIC TICKET')[0], '待分类')

    def test_confirmations_and_empty_manual_tags_take_precedence(self):
        policy = InferencePolicy(synthetic_policy())
        text = 'SYNTHETIC TERMINAL SYNTHETIC TICKET'
        confirmed = [{'merchant': text, 'primary': '日常消费', 'secondary': '餐饮'}]
        self.assertEqual(classify(text, rules=confirmed, policy=policy)[1], '餐饮')
        self.assertEqual(annotate('日常消费', '交通出行', text, policy=policy, override={'tags': []})[2], [])

    def test_unknown_control_fields_are_rejected(self):
        for invalid in [{'version': 1, 'rules': []}, {'rules': None}, {'rules': [], 'python': 'arbitrary'}]:
            with self.assertRaises(ValueError):
                InferencePolicy(invalid)

    def test_rejects_invalid_predicates_and_duplicate_ids(self):
        for key, value in [('field', 'filesystem'), ('pattern', '[')]:
            policy = synthetic_policy()
            policy['rules'][0]['when']['all'][0][key] = value
            with self.assertRaises(ValueError):
                InferencePolicy(policy)
        policy = synthetic_policy(); policy['rules'].append(copy.deepcopy(policy['rules'][0]))
        with self.assertRaises(ValueError):
            InferencePolicy(policy)
