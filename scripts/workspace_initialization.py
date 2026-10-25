"""Create a production-readable empty workspace without private Seed resources."""
from __future__ import annotations

import json
import os
import sqlite3
from pathlib import Path

from scripts.coverage_policy import empty_coverage
from scripts.import_pulse_statements import init_db
from scripts.workspace_state import WorkspacePaths


def fire_template():
    return {'status': 'needs_input', 'note': '请填写家庭资产、收入和支出参数。',
        'baseYear': None, 'birthYear': None, 'targetAge': None, 'currentFireAssets': None,
        'afterTaxSalary': None, 'annualContribution': None, 'expenseModes': {},
        'annualHardCap': None, 'expenseBreakdown': {},
        'buckets': {'safetyBucket': None, 'parentMedicalBucket': None, 'elderCareEnabled': False,
            'elderCareBucket': None, 'otherBuckets': None, 'includeBuckets': False},
        'investing': {'withdrawalRate': 0.035, 'annualReturn': None, 'inflation': None,
            'maxDrawdown': None},
        'branches': {'housing': {'enabled': False, 'year': None, 'totalPrice': None,
            'downPaymentRatio': None, 'loanRate': None, 'loanYears': None, 'fees': None,
            'renovation': None, 'annualMaintenance': None, 'reduceRent': False,
            'minLiquidAssets': None, 'ownerHomeCountsAsFireAsset': False},
            'children': {'enabled': False, 'count': None, 'birthYear': None, 'annualCost': None,
                'educationBucket': None, 'incomeImpact': None}}}


def initialize_empty_state(transaction):
    """Use the actual production projections so their schemas cannot diverge."""
    root, output = transaction.root, transaction.review
    config = root / 'config'
    config.mkdir()
    (config / 'review-import-sources.json').write_text(json.dumps({'sources': [], 'currency_codes': ['CNY']}))
    (config / 'fire-parameters.json').write_text(json.dumps(fire_template(), ensure_ascii=False))
    from scripts.release_contracts import canonical_json
    (config / 'family-profile.json').write_bytes(canonical_json({ 'household_name': '', 'members': []}))
    (config / 'account-policies.json').write_bytes(canonical_json({ 'accounts': [], 'routes': [], 'aliases': [], 'source_owners': {}, 'unknown_account_policy': {'mode': 'needs_review', 'exclusion_member_ids': []}}))
    # This is the public taxonomy only; never copy financial defaults or QA Seed.
    bundle = os.environ.get('BANKING_RUNTIME_BUNDLE')
    defaults_path = (Path(bundle) / 'Contents/Resources/defaults/default-config.json' if bundle else
                     Path(__file__).resolve().parents[1] / 'release/default-config.json')
    defaults = json.loads(defaults_path.read_text())['defaults']
    taxonomy = defaults['taxonomy']
    (config / 'category-seed.json').write_text(json.dumps(taxonomy, ensure_ascii=False))
    (output / 'coverage.json').write_text(json.dumps(empty_coverage()))
    with sqlite3.connect(root / 'banking.sqlite3') as db:
        init_db(db)
    from scripts.probe_payment_evidence import run as evidence
    from scripts.financial_review import run as financial
    evidence(root, output)
    financial(root, output)
    from scripts.workspace_validation import validate_transaction
    validate_transaction(transaction)


def create_workspace(destination, *, before_publish=None):
    return WorkspacePaths.create(destination, initialize_empty_state, before_publish=before_publish)


def execute_request(args, action, inputs):
    """Shared CLI boundary: all business paths are transaction-owned staging."""
    from scripts.processor_result import execute_workspace
    if getattr(args, "root", None) is not None or getattr(args, "output", None) is not None:
        raise ValueError('--workspace 不能与 --root/--output 一起使用')
    if args.expected_pointer_json is None or not args.request_id or not args.operation_id:
        raise ValueError('workspace 请求需要 expected pointer、request ID 和 operation ID')
    return execute_workspace(args.workspace, args.expected_pointer_json,
        args.operation_id, args.request_id, args.result_file, action, inputs,
        inherited_fd=args.gate_fd,
        cancelled=(lambda: args.cancel_file.exists()) if args.cancel_file else None,
        timeout_seconds=args.timeout_seconds)
