"""Concrete read boundary for financial_review.run, not a workspace backup.

JSON snapshots own their decoded values and byte hashes. Bank categories are
read in one SQLite transaction; their hash covers the selected rows, not database
file bytes (which would omit WAL). Existing file-backed domain APIs retain their
validation and catalog persistence. Their dependencies are recorded here too.
Read-set collection does not write business state.
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
from pathlib import Path

try:
    from .category_catalog import MAX_BYTES, load as load_catalog
    from .inferred_associations import apply as apply_inferred
    from .material_associations import apply as apply_materials
    from .platform_order_enrichment import apply as apply_enrichment
    from .refund_candidates import project as project_refunds
except ImportError:
    from category_catalog import MAX_BYTES, load as load_catalog
    from inferred_associations import apply as apply_inferred
    from material_associations import apply as apply_materials
    from platform_order_enrichment import apply as apply_enrichment
    from refund_candidates import project as project_refunds


def _hash(data):
    return hashlib.sha256(data).hexdigest()


def _json_bytes(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode()


class FinancialReviewInputs:
    """One run's inputs, in read order, with explicit bootstrap defaults.

    `previous` is optional for a first projection, but an existing projection is
    historical input, not disposable cache. Keep its records for settlement
    protection and catalog initialization. Never replace them with a copied report.
    The manifest is the projection slice of WorkspaceDependencyManifest only.
    """

    def __init__(self, root, output):
        self.root, self.output = Path(root), Path(output)
        self.dependencies = []
        self._documents = {}
        self.catalog_source = None

    def _entry(self, base, name, role, required, reader):
        entry = {"base": base, "path": name, "role": role,
                 "required": required, "reader": reader,
                 "absent_behavior": "fail" if required else "bootstrap_or_domain_default",
                 "read_order": len(self.dependencies) + 1}
        self.dependencies.append(entry)
        return entry

    def _json(self, base, name, role, default=None, required=False):
        key = (base, name)
        if key in self._documents:
            return self._documents[key]
        path = (self.root if base == "root" else self.output) / name
        entry = self._entry(base, name, role, required, "snapshot")
        if not required:
            entry["missing_default"] = default
        try:
            data = path.read_bytes()
        except FileNotFoundError:
            entry["present"] = False
            if required:
                raise
            value = default
        else:
            entry.update(present=True, bytes=len(data), sha256=_hash(data), hash_kind="file_bytes")
            # Retain only the decoded document; do not retain or copy raw reports.
            value = json.loads(data)
        self._documents[key] = value
        return value

    def _file_api(self, name, role, reader):
        """Inventory an existing file API without replacing its validation.

        Only the small decision/export files are read twice for byte provenance.
        Large evidence and previous reports use _json once. File APIs and their
        source assets are not frozen against concurrent writers by this boundary.
        """
        key = ("output", name)
        if key in self._documents:
            return
        entry = self._entry("output", name, role, False, reader)
        entry["hash_observation"] = "before_domain_read"
        path = self.output / name
        if name == "category-catalog.json" and path.exists():
            if path.is_symlink() or not path.is_file() or path.stat().st_size > MAX_BYTES:
                raise ValueError("分类目录文件不安全或过大")
        try:
            with path.open("rb") as handle:
                sha = hashlib.sha256()
                size = 0
                while chunk := handle.read(65536):
                    sha.update(chunk)
                    size += len(chunk)
        except FileNotFoundError:
            entry["present"] = False
        else:
            entry.update(present=True, bytes=size, sha256=sha.hexdigest(), hash_kind="file_bytes")

    @classmethod
    def load(cls, root, output):
        inputs = cls(root, output)
        inputs.report = inputs._json("output", "payment-evidence.json", "evidence", required=True)
        inputs.video_results = []
        for name in ("video-evidence.json", "order-evidence.json", "supplemental-evidence.json"):
            video = inputs._json("output", name, "evidence")
            if inputs.dependencies[-1]["present"]:
                inputs.video_results.append(video)
                inputs.report["clusters"] += video["observations"]
                inputs.report["candidates"] += video["links"]
        inputs.state = inputs._json("output", "review-state.json", "decision", {})
        return inputs

    def inferred_associations(self):
        self._file_api("inferred-associations.json", "decision", "inferred_associations.apply")
        apply_inferred(self.report, self.output)

    def confirmed_outcomes(self):
        from scripts.confirmed_outcomes import DOCUMENT, ConfirmedOutcomes
        document = self._json('output', DOCUMENT, 'decision')
        if document is None:
            return None
        rows = {c['cluster_id']: c['representative'] for c in self.report['clusters']}
        banks = {f"bank:{b['id']}": b for b in self.report['bank_records']}
        return ConfirmedOutcomes(document, rows, banks)

    def account_policy(self):
        return self._json("root", "config/payment-account-consolidation.json", "decision")

    def household_settings(self):
        from scripts.household_settings import load_processor_settings
        def read(name):
            path = self.root / name
            entry = self._entry("root", name, "household_setting", False, "household_settings.load_processor_settings")
            if not path.exists(): entry['present'] = False; return None
            if path.is_symlink() or not path.is_file() or path.stat().st_size > 16 * 1024 * 1024:
                raise ValueError('household settings input budget or file kind')
            data = path.read_bytes()
            entry.update(present=True, bytes=len(data), sha256=_hash(data), hash_kind="file_bytes")
            return data
        previous = self.previous_projection().get('records', [])
        observed = [c['representative'] for c in self.report['clusters']] + self.report['bank_records']
        retained_members = {r['owner_id'] for r in observed if r.get('owner_id')}
        retained_members.update(r['user_id'] for r in previous if r.get('user_id'))
        retained_members.update(r['account_identity_before_consolidation']['user_id'] for r in previous
            if isinstance(r.get('account_identity_before_consolidation'), dict) and r['account_identity_before_consolidation'].get('user_id'))
        retained_accounts = {identity for r in previous for identity in r.get('funding_account_ids', [])}
        return load_processor_settings(self.root, read_bytes=read,
            referenced_member_ids=sorted(retained_members), referenced_account_ids=sorted(retained_accounts))

    def classification_rules(self):
        return self._json("output", "classification-rules.json", "decision", {}).get("rules", [])

    def inference_policy(self):
        return self._json("output", "classification-rules.json", "decision", {}).get("inference_policy")

    def overrides(self):
        return self._json("output", "review-overrides.json", "decision", {})

    def bank_categories(self):
        query = "SELECT id,transaction_category FROM transactions WHERE transaction_category IS NOT NULL"
        entry = self._entry("root", "banking.sqlite3", "fact", True, "bank_categories")
        conn = sqlite3.connect((self.root / "banking.sqlite3").resolve().as_uri() + "?mode=ro", uri=True)
        try:
            rows = conn.execute(query).fetchall()
        finally:
            conn.close()
        entry.update(present=True, selector=query, hash_kind="sqlite_rows",
                     sha256=_hash(_json_bytes(sorted(rows))), row_count=len(rows))
        return dict(rows)

    def previous_projection(self):
        return self._json("output", "financial-review.json", "historical_fact", {})

    def catalog(self, previous):
        # Preserve export > SQLite > previous taxonomy > seed precedence.
        # Existing load_catalog also persists/hydrates the selected directory.
        self._file_api("category-catalog.json", "fact", "category_catalog.load")
        has_export = (self.output / "category-catalog.json").exists()
        db_path = self.output / "financial-review.sqlite3"
        entry = self._entry("output", "financial-review.sqlite3", "historical_fact", False, "category_catalog.load")
        entry["hash_observation"] = "before_catalog_load"
        stored = None
        if db_path.exists():
            conn = sqlite3.connect(db_path.resolve().as_uri() + "?mode=ro", uri=True)
            try:
                table = conn.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='category_catalog_state'").fetchone()
                if table:
                    row = conn.execute("SELECT payload_json FROM category_catalog_state WHERE singleton=1").fetchone()
                    stored = row[0] if row else None
            finally:
                conn.close()
            entry.update(present=True, selector="category_catalog_state/singleton=1",
                         hash_kind="sqlite_payload", sha256=_hash(stored.encode()) if stored is not None else None)
        else:
            entry["present"] = False
        has_catalog = has_export or stored is not None
        taxonomy = previous.get("taxonomy", [])
        if not taxonomy and not has_catalog:
            seed = self.root / "config/category-seed.json"
            if seed.exists():
                taxonomy = self._json("root", "config/category-seed.json", "bootstrap", required=True)
            else:
                # Match the existing packaged seed fallback; make it visible.
                canonical = Path(__file__).resolve().parents[1]
                data = (canonical / "release/default-config.json").read_bytes()
                seed_entry = self._entry("runtime", "release/default-config.json", "bootstrap", True, "snapshot")
                seed_entry.update(present=True, bytes=len(data), sha256=_hash(data), hash_kind="file_bytes")
                taxonomy = json.loads(data)["defaults"]["taxonomy"]
        self.catalog_source = ("export" if has_export else "sqlite" if stored is not None
                               else "previous_taxonomy" if previous.get("taxonomy") else "seed")
        return load_catalog(self.output, taxonomy=taxonomy, records=previous.get("records", []))

    def material_targets(self):
        document = self._json("output", "material-associations.json", "decision")
        return {link["transaction_id"] for link in document["links"]} if self._present("output", "material-associations.json") else set()

    def _present(self, base, name):
        return next(e["present"] for e in self.dependencies if e["base"] == base and e["path"] == name)

    def material_associations(self, records):
        # material_targets already captured the bytes used for this dependency.
        for entry in self.dependencies:
            if entry["base"] == "output" and entry["path"] == "material-associations.json":
                entry["additional_reader"] = "material_associations.apply"
        materials = [m for v in self.video_results for m in v["materials"]]
        links = apply_materials(records, materials, self.output)
        by_id = {m["id"]: m for m in materials}
        seen = set()
        for link in links:
            for key in link["material_ids"]:
                for asset in ("source", "raw", "image"):
                    reference = by_id[key]["source_evidence"][asset]
                    path = reference["path"]
                    if path in seen:
                        continue
                    seen.add(path)
                    entry = self._entry("output", path, "immutable_material", True, "material_associations.apply")
                    entry.update(present=True, sha256=reference["sha256"], hash_kind="file_bytes",
                                 verified_by="material_associations.apply")
        return links

    def coverage(self):
        return self._json("output", "coverage.json", "decision")

    def fire_parameters(self):
        return self._json("root", "config/fire-parameters.json", "parameter", required=True)

    def refund_candidates(self, records):
        document = self._json("root", "config/hsbc-refund-candidates.json", "decision")
        return project_refunds(records, self.report["bank_records"], document["leads"]) if self._present("root", "config/hsbc-refund-candidates.json") else []

    def corrections(self):
        return self._json("output", "confirmed-transaction-corrections.json", "decision")

    def enrich_orders(self, result, overrides):
        self._file_api("platform-order-enrichment.json", "decision", "platform_order_enrichment.apply")
        apply_enrichment(result, self.output, overrides=overrides)
        for reference in result.get('platform_order_enrichment', {}).get('verified_assets', []):
            entry = self._entry('output', reference['path'], 'immutable_material', True, 'platform_order_enrichment.apply')
            entry.update(present=True, sha256=reference['sha256'], hash_kind='file_bytes',
                         verified_by='platform_order_enrichment.apply')

    @classmethod
    def dependency_registry(cls, root, output):
        """Code-owned projection readers, with present optional facts preserved.

        Returns state-relative dependency edges for the financial projection.
        No processing or decision writes occur. Material reference closure is a
        separate domain registry and cannot be inferred from absent options.
        """
        from scripts.release_contracts import validate_relative_path
        from scripts.workspace_state import _regular
        root, output = Path(root), Path(output)
        output_prefix = output.relative_to(root).as_posix()
        required_root = ['banking.sqlite3', 'config/fire-parameters.json']
        optional_root = ['config/family-profile.json', 'config/account-policies.json', 'config/review-import-sources.json', 'config/payment-account-consolidation.json',
                         'config/hsbc-refund-candidates.json', 'config/category-seed.json']
        required_output = ['payment-evidence.json']
        optional_output = ['video-evidence.json', 'order-evidence.json', 'supplemental-evidence.json',
            'review-state.json', 'inferred-associations.json', 'classification-rules.json',
            'review-overrides.json', 'financial-review.json', 'financial-review.sqlite3',
            'category-catalog.json', 'material-associations.json', 'coverage.json',
            'confirmed-transaction-corrections.json', 'platform-order-enrichment.json',
            'confirmed-outcomes.json']
        dependencies = []
        absent_optional = []
        for prefix, names, required in [('', required_root, True), ('', optional_root, False),
                (output_prefix, required_output, True), (output_prefix, optional_output, False)]:
            for name in names:
                relative = validate_relative_path((prefix + '/' if prefix else '') + name)
                path = root / relative
                if path.exists():
                    _regular(path)
                    dependencies.append(relative)
                elif required:
                    raise ValueError('缺少 projection 必需输入：' + relative)
                else:
                    absent_optional.append(relative)
        enrichment = output / 'platform-order-enrichment.json'
        if enrichment.exists():
            document = json.loads(enrichment.read_bytes())
            for entry in document['entries']:
                for trace in entry.get('new_traces', []):
                    evidence = trace['source_evidence']
                    references = [evidence['source'], evidence['raw']]
                    references += [evidence[k] for k in ('image', 'text', 'annotation_snapshot') if k in evidence]
                    for reference in references:
                        name = validate_relative_path(reference['path'])
                        _regular(output / name)
                        dependencies.append(validate_relative_path(output_prefix + '/' + name))
        projection = validate_relative_path(output_prefix + '/financial-review.json')
        return {'files': [{'path': projection,
                    'dependencies': sorted(set(dependencies) - {projection})}],
                'absent_optional': sorted(absent_optional)}

    def manifest(self):
        return {"scope": "financial_review.run",
                "kind": "projection_input_read_set", "atomic_snapshot": False,
                "catalog_source": self.catalog_source,
                "previous_protection": {"path": "financial-review.json", "base": "output",
                    "fields": ["records", "taxonomy"], "retain_when_present": True,
                    "bootstrap_default": {}},
                "files": self.dependencies,
                "limitations": ["Diagnostic read-set only.",
                    "File-backed domain APIs retain their own reads and asset validation.",
                    "SQLite hashes cover selected input data, not database or WAL file bytes."]}
