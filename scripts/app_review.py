"""Persist a native UI association decision and refresh derived review data."""
import argparse
import json
from pathlib import Path
import sys

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.processor_result import add_workspace_arguments
from scripts.workspace_initialization import execute_request

try:
    from .payment_feedback import ingest_export
    from .probe_payment_evidence import run as evidence
    from .financial_review import run as financial
except ImportError:
    from payment_feedback import ingest_export
    from probe_payment_evidence import run as evidence
    from financial_review import run as financial


def run(root, output, review):
    ingest_export(review, output)
    evidence(root, output)
    result = financial(root, output)
    return {'dataset_id': result['dataset_id'], 'review_saved': True}

if __name__ == '__main__':
    parser=argparse.ArgumentParser(); parser.add_argument('--root',type=Path); parser.add_argument('--output',type=Path); parser.add_argument('--review',type=Path,required=True)
    parser.add_argument('--operation-id', required=True)
    parser.add_argument('--result-file', type=Path, required=True)
    add_workspace_arguments(parser)
    args=parser.parse_args()
    if args.workspace is None:
        parser.error('--workspace is required')
    result, status = execute_request(args, lambda transaction, selected:
        run(transaction.root, transaction.review, selected[0]),
        [{"path": str(args.review), "kind": "review"}])
    print(json.dumps(result, ensure_ascii=False))
    raise SystemExit(status)
