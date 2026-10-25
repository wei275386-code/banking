"""Synthetic current contract checks; no user workspace, phone or cloud access."""
import copy
import json
import tempfile
import unittest
from pathlib import Path

from scripts import release_contracts as contracts

FIXTURES = Path(__file__).resolve().parents[1] / "schemas" / "release" / "fixtures"
BINDING = "11111111-1111-4111-8111-111111111111"


def fixture(name):
    return contracts.parse_json((FIXTURES / (name + ".json")).read_bytes())


def encoded(value):
    return contracts.canonical_json(value)


class CanonicalizationTests(unittest.TestCase):
    def test_lossless_number_kind_and_unicode_scalar_golden_vectors(self):
        for vector in fixture("canonical-golden-vectors"):
            with self.subTest(vector=vector["name"]):
                raw = contracts.canonical_json(contracts.parse_json(vector["raw"].encode()))
                self.assertEqual(vector["canonical_utf8"].encode(), raw)
                self.assertEqual(vector["canonical_payload_hash"], contracts.digest_bytes(raw))

    def test_duplicate_keys_nonfinite_and_invalid_encoding_reject(self):
        for raw in (b'{"id":1,"id":2}', b'{"amount":NaN}', b'{"amount":Infinity}', b'\xff'):
            with self.assertRaises(contracts.ContractError):
                contracts.parse_json(raw)


class CoverageTests(unittest.TestCase):
    def test_automatic_expands_without_shrinking_after_revocation(self):
        empty = fixture("coverage-empty")
        first = contracts.evolve_coverage(empty, ["2025-12-20"])
        self.assertEqual(("automatic", "2025-12-20", "2025-12-20"), (first["mode"], first["from"], first["to"]))
        second = contracts.evolve_coverage(first, ["2025-12-20", "2025-11-10"])
        self.assertEqual(("2025-11-10", "2025-12-20"), (second["from"], second["to"]))
        third = contracts.evolve_coverage(second, ["2026-01-02"])
        self.assertEqual(("2025-11-10", "2026-01-02"), (third["from"], third["to"]))
        revoked = contracts.evolve_coverage(third, [])
        self.assertEqual((third["from"], third["to"]), (revoked["from"], revoked["to"]))
        self.assertIsNone(revoked["observed_from"])
        self.assertEqual(empty, fixture("coverage-empty"))
        self.assertEqual(revoked, contracts.evolve_coverage(revoked, []))

    def test_explicit_only_proposes_extension(self):
        original = fixture("coverage-explicit-pending")
        current = contracts.evolve_coverage(original, ["2026-01-01", "2026-10-01"])
        self.assertEqual(original, current)
        self.assertEqual("2026-09-13", current["to"])
        inside = contracts.evolve_coverage(current, ["2026-02-01"])
        self.assertIsNone(inside["pending_to"])
        self.assertEqual("2026-09-13", inside["to"])

    def test_nullable_dates_invalid_ranges_and_calendar_dates(self):
        for key, value in (("from", "2025-01-01"), ("observed_from", "2025-01-01"),
                           ("to", "2025-02-30"), ("mode", "automatic"), ("revision", True)):
            invalid = fixture("coverage-empty"); invalid[key] = value
            with self.subTest(key=key), self.assertRaises(contracts.ContractError):
                contracts.validate_contract("coverage", invalid)
        for invalid in ("2025-02-30", "2025-1-1", "mtime", None):
            with self.assertRaises(contracts.ContractError):
                contracts.evolve_coverage(fixture("coverage-empty"), [invalid])


class ResultCheckpointTests(unittest.TestCase):
    def test_committed_cancel_rejected_and_publication_preserves_result(self):
        before = fixture("operation-committed")
        published = copy.deepcopy(before)
        published.update(phase="published", result_generation="a" * 64)
        contracts.validate_operation_transition(before, published)
        cancelled = copy.deepcopy(before)
        cancelled.update(phase="cancelled", outcome="cancelled", result_digest=None, state_id=None)
        with self.assertRaises(contracts.ContractError):
            contracts.validate_operation_transition(before, cancelled)
        published["inputs"][0]["completed_stages"].append("new-stage")
        with self.assertRaises(contracts.ContractError):
            contracts.validate_operation_transition(before, published)

    def test_successful_membership_digest_and_no_result_self_reference(self):
        result = fixture("result-partial")
        result["result_generation"] = "a" * 64
        with self.assertRaises(contracts.ContractError):
            contracts.validate_contract("result", result)
        result = fixture("result-partial"); result["membership"][0]["digest"] = "e" * 64
        with self.assertRaises(contracts.ContractError):
            contracts.validate_contract("result", result)
        result = fixture("result-partial"); result["phase"] = "published"; result["result_generation"] = "a" * 64
        with self.assertRaises(contracts.ContractError):
            contracts.validate_contract("result", result)

    def test_partial_cannot_hide_financial_failure_or_runtime_error(self):
        for mutation in ("pdf-failure", "runtime-error", "missing-material", "false-success", "unknown-phase"):
            result = fixture("result-partial")
            if mutation == "pdf-failure": result["inputs"][0].update(outcome="failed")
            elif mutation == "runtime-error": result["inputs"][1]["reason"] = "runtime_error"
            elif mutation == "missing-material": result["inputs"][1]["retained"] = False
            elif mutation == "false-success": result["outcome"] = "success"
            else: result["phase"] = "unknown_phase"
            result["result_digest"] = contracts.business_result_digest(result)
            with self.subTest(mutation=mutation), self.assertRaises(contracts.ContractError):
                contracts.validate_contract("result", result)

    def test_stable_subtask_keys_avoid_delimiter_collision(self):
        a = contracts.stable_input_stage_key("request+a", "input", "parse")
        self.assertEqual(a, contracts.stable_input_stage_key("request+a", "input", "parse"))
        self.assertNotEqual(a, contracts.stable_input_stage_key("request", "a+input", "parse"))


class SchemaAndBackupTests(unittest.TestCase):
    def test_all_document_fixtures_and_release_config(self):
        names = {"active-state": "active-state", "state-manifest": "state-manifest", "workspace": "workspace", "coverage-empty": "coverage", "coverage-automatic": "coverage",
                 "coverage-explicit-pending": "coverage", "revision-inventory": "revision-inventory", "operation-committed": "operation",
                 "result-partial": "result", "field-state": "field-state", "request-results": "request-results"}
        for name, schema in names.items():
            with self.subTest(fixture=name):
                contracts.validate_contract(schema, fixture(name))
        config = contracts.parse_json((FIXTURES.parents[2] / "config" / "release-version.json").read_bytes())
        contracts.validate_contract("release-version", config)
        compatibility = contracts.parse_json((FIXTURES.parents[2] / "release" / "compatibility.json").read_bytes())
        self.assertEqual((compatibility["app_version"], compatibility["build_number"]),
                         (config["app_version"], config["build_number"]))
        self.assertEqual(config["status"], "candidate")

    def test_active_pointer_tuple_and_manifest_hash_are_both_authoritative(self):
        pointer, manifest = fixture("active-state"), fixture("state-manifest")
        contracts.validate_active_state(pointer, manifest)
        changed = copy.deepcopy(manifest)
        changed["files"]["banking.sqlite3"] = "a" * 64
        with self.assertRaises(contracts.ContractError):
            contracts.validate_active_state(pointer, changed)
        changed = copy.deepcopy(manifest); changed["local_revision"] += 1
        with self.assertRaises(contracts.ContractError):
            contracts.validate_active_state(pointer, changed)

    def test_state_manifest_parent_tuple_is_optional_but_exact_when_present(self):
        parent, manifest = fixture("active-state"), fixture("state-manifest")
        successor = copy.deepcopy(manifest)
        successor["state_id"] = "99999999-9999-4999-8999-999999999999"
        successor["local_revision"] = parent["local_revision"] + 1
        successor["parent_pointer"] = parent
        contracts.validate_contract("state-manifest", successor)
        for key, value in (("workspace_id", "88888888-8888-4888-8888-888888888888"),
                           ("state_id", successor["state_id"]),
                           ("local_revision", parent["local_revision"] + 1),
                           ("state_manifest_hash", "invalid")):
            with self.subTest(key=key):
                changed = copy.deepcopy(successor)
                changed["parent_pointer"][key] = value
                with self.assertRaises(contracts.ContractError):
                    contracts.validate_contract("state-manifest", changed)

    def test_schema_loader_is_used_for_every_ref_and_unknown_keywords_fail(self):
        root = FIXTURES.parent
        config = contracts.parse_json((FIXTURES.parents[2] / "config" / "release-version.json").read_bytes())
        loaded = []
        def loader(filename):
            loaded.append(filename)
            return contracts.parse_json((root / filename).read_bytes())
        contracts.validate_contract("release-version", config, schema_loader=loader)
        self.assertIn("release-version.schema.json", loaded)
        self.assertIn("common.schema.json", loaded)
        with self.assertRaises(contracts.ContractError):
            contracts.validate_contract("release-version", config,
                schema_loader=lambda name: {"type": "object", "unevaluatedProperties": False})

    def test_relative_paths_reject_escape_aliases_and_absolute_locations(self):
        for path in ("../escape", str(Path(__file__).resolve().parent / 'absolute'), "a/../b", "a//b", "a/./b", "a\\b", "a\x00b", "C:/evil", "a/"):
            with self.subTest(path=path), self.assertRaises(contracts.ContractError):
                contracts.validate_relative_path(path)
        self.assertEqual("中文 空格/data.json", contracts.validate_relative_path("中文 空格/data.json"))

    def test_stream_hash_matches_bytes_without_large_file_read(self):
        contents = b"synthetic-material" * 500
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "material.bin"; path.write_bytes(contents)
            self.assertEqual(contracts.digest_bytes(contents), contracts.digest_file(path, chunk_size=7))
            with self.assertRaises(contracts.ContractError):
                contracts.digest_file(path, chunk_size=0)


if __name__ == "__main__":
    unittest.main()
