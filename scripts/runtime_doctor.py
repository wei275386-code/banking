"""Read-only bundled runtime checks; all functional probes use memory only.

Run through processor_bootstrap.py with -I -B -S. Emits a path-redacted JSON report
to stdout. It never opens a ledger, creates a workspace or downloads packages.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.metadata
import io
import json
import os
from pathlib import Path, PurePosixPath
import platform
import sqlite3
import subprocess
import sys
if __package__:
    from .tool_locations import system_search_path, tool_path
else:
    from tool_locations import system_search_path, tool_path

MANIFEST = "Contents/Resources/runtime-manifest.json"


class RuntimeErrorCode(ValueError):
    def __init__(self, code, action):
        self.code, self.action = code, action
        super().__init__(code)


def digest_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def bundle_path(bundle, relative):
    if not isinstance(relative, str) or not relative or "\\" in relative:
        raise RuntimeErrorCode("RUNTIME_PATH_INVALID", "Reinstall the complete App candidate.")
    path = PurePosixPath(relative)
    if path.is_absolute() or any(p in ("", ".", "..") for p in relative.split("/")):
        raise RuntimeErrorCode("RUNTIME_PATH_INVALID", "Reinstall the complete App candidate.")
    root = Path(bundle).resolve()
    candidate = root.joinpath(*path.parts)
    if not candidate.resolve().is_relative_to(root):
        raise RuntimeErrorCode("RUNTIME_PATH_ESCAPE", "Reinstall the complete App candidate.")
    return candidate


def _unique_pairs(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise RuntimeErrorCode("RUNTIME_MANIFEST_INVALID", "Rebuild the runtime manifest.")
        value[key] = item
    return value


def load_manifest(bundle):
    try:
        manifest = json.loads(bundle_path(bundle, MANIFEST).read_text(), object_pairs_hook=_unique_pairs)
        if manifest['architecture'] != 'arm64' or manifest['minimum_macos'] != '14.0':
            raise ValueError()
        if not isinstance(manifest["runtime_version"], str) or not manifest["runtime_version"]:
            raise ValueError()
        if not isinstance(manifest["python"]["version"], str) or not manifest["python"]["version"]:
            raise ValueError()
        dependencies = manifest["dependencies"]
        if not isinstance(dependencies, list) or not dependencies:
            raise ValueError()
        names = set()
        for dependency in dependencies:
            if not isinstance(dependency["name"], str) or not isinstance(dependency["version"], str) or not dependency["name"] or not dependency["version"] or dependency["name"] in names:
                raise ValueError()
            names.add(dependency["name"])
        if not {"pypdf", "openpyxl", "pdfplumber", "pypdfium2"}.issubset(names):
            raise ValueError()
        files = manifest["files"]
        if not isinstance(files, list) or not files or len(files) > 50000:
            raise ValueError()
        required = {manifest[name]["path"] for name in ("python", "bootstrap", "doctor", "helper")}
        required.add(manifest["licenses"]["path"])
        required.add(manifest["defaults"]["path"] + "/default-config.json")
        scripts = manifest["scripts"]["path"]
        bundle_path(bundle, scripts)
        if not isinstance(manifest["entry_scripts"], list) or not manifest["entry_scripts"]:
            raise ValueError()
        required.update(scripts + "/" + entry for entry in manifest["entry_scripts"])
        for entry in manifest["entry_scripts"]:
            if not isinstance(entry, str) or "/" in entry or "\\" in entry or not entry.endswith(".py"):
                raise ValueError()
        present = set()
        for record in files:
            relative = record["path"]
            if relative in present:
                raise ValueError()
            present.add(relative)
            path = bundle_path(bundle, relative)
            if not path.is_file():
                raise RuntimeErrorCode("RUNTIME_FILE_MISSING", "Reinstall the complete App candidate.")
            if record["kind"] == "symlink":
                if not path.is_symlink() or os.readlink(path) != record["target"] or PurePosixPath(record["target"]).is_absolute():
                    raise ValueError()
                raw = os.readlink(path).encode()
                actual_hash, actual_size = hashlib.sha256(raw).hexdigest(), len(raw)
            else:
                if record["kind"] not in ("file", "macho") or path.is_symlink():
                    raise ValueError()
                actual_hash, actual_size = digest_file(path), path.stat().st_size
            if actual_hash != record["sha256"] or actual_size != record["size"]:
                raise RuntimeErrorCode("RUNTIME_HASH_MISMATCH", "Reinstall the candidate; do not modify the ledger.")
        if not required.issubset(present):
            raise ValueError()
        licenses = json.loads(bundle_path(bundle, manifest["licenses"]["path"]).read_text(), object_pairs_hook=_unique_pairs)
        if licenses['runtime_lock_sha256'] != manifest['lock_sha256'] or licenses['distribution_ready'] is not False or (not licenses['artifacts']):
            raise ValueError()
        indexed = {record["path"]: record for record in files}
        for artifact in licenses["artifacts"]:
            if artifact["status"] not in ("needs_review", "metadata_and_files_recorded"):
                raise ValueError()
            references = list(artifact["license_files"])
            if artifact.get("metadata_file"):
                references.append(artifact["metadata_file"])
            for record in references:
                verified = indexed[record["path"]]
                if verified["kind"] == "symlink" or record["sha256"] != verified["sha256"] or record["size"] != verified["size"]:
                    raise RuntimeErrorCode("RUNTIME_LICENSE_FILE_INVALID", "Rebuild the candidate with its actual license and notice files.")
        # Reject unmanifested modules/native payload, including injected .pth.
        for relative in (str(PurePosixPath(scripts).parent), str(PurePosixPath(manifest["python"]["path"]).parent.parent), manifest["defaults"]["path"], "Contents/Resources/release"):
            directory = bundle_path(bundle, relative)
            for path in directory.rglob("*"):
                if path.is_file() or path.is_symlink():
                    name = path.relative_to(Path(bundle).resolve()).as_posix()
                    if name not in present:
                        raise RuntimeErrorCode("RUNTIME_UNTRACKED_FILE", "Reinstall the complete App candidate.")
        return manifest
    except RuntimeErrorCode:
        raise
    except (ValueError, TypeError, KeyError, OSError, UnicodeError):
        raise RuntimeErrorCode("RUNTIME_MANIFEST_INVALID", "Rebuild or reinstall the runtime candidate.") from None


def validate_packaged_helper(helper, *, trusted_pin=None):
    """Authenticate the readonly effective-view helper in a complete signed App.

    No PATH lookup or development fallback. Ad-hoc QA candidates may qualify
    local runtime tests; this check does not grant distribution acceptance.
    """
    helper = Path(helper).absolute()
    if helper.name != "FinancialProjection" or helper.parent.name != "Helpers" or helper.parent.parent.name != "Contents":
        raise RuntimeErrorCode("RUNTIME_HELPER_INVALID", "Select the bundled FinancialProjection helper.")
    bundle = helper.parent.parent.parent
    if bundle.suffix != ".app":
        raise RuntimeErrorCode("RUNTIME_HELPER_INVALID", "Select a complete App candidate.")
    manifest = load_manifest(bundle)
    relative = "Contents/Helpers/FinancialProjection"
    path = bundle_path(bundle, relative)
    records = [item for item in manifest["files"] if item["path"] == relative]
    if len(records) != 1 or records[0]["kind"] != "macho" or relative not in manifest["native_code"] or path.is_symlink():
        raise RuntimeErrorCode("RUNTIME_HELPER_INVALID", "Rebuild the complete helper inventory.")
    manifest_hash = digest_file(bundle / MANIFEST)
    # The running controlled App is the default authority, not a separately
    # selected App's own claims. Development callers must supply a trusted pin
    # from their independently verified build/QA receipt.
    executing_bundle = Path(__file__).resolve().parents[4]
    if trusted_pin is None:
        if executing_bundle.suffix != ".app" or bundle.resolve() != executing_bundle:
            raise RuntimeErrorCode("RUNTIME_HELPER_UNTRUSTED", "Use this App's helper or an independently pinned QA artifact.")
    else:
        if not isinstance(trusted_pin, dict) or set(trusted_pin) != {"sha256", "runtime_manifest_sha256"} or any(
                not isinstance(value, str) or len(value) != 64 or any(character not in '0123456789abcdef' for character in value)
                for value in trusted_pin.values()) or trusted_pin != {
                    "sha256": records[0]["sha256"], "runtime_manifest_sha256": manifest_hash}:
            raise RuntimeErrorCode("RUNTIME_HELPER_UNTRUSTED", "The helper differs from its independently trusted artifact pin.")
    for signed in (path, bundle):
        subprocess.run([tool_path('codesign', system=True), "--verify", "--strict", str(signed)],
                       check=True, capture_output=True, timeout=20,
                       env={"PATH": system_search_path(), "LANG": "en_US.UTF-8",
                            "LC_ALL": "en_US.UTF-8", "TZ": "UTC"})
    return {"path": str(path), "sha256": records[0]["sha256"],
            "runtime_manifest_sha256": manifest_hash}


def isolation_check(bundle, manifest):
    runtime = bundle_path(bundle, str(PurePosixPath(manifest["python"]["path"]).parent.parent))
    scripts = bundle_path(bundle, manifest["scripts"]["path"])
    if not sys.flags.isolated or not sys.flags.no_user_site or not sys.flags.no_site or not sys.dont_write_bytecode:
        raise RuntimeErrorCode("RUNTIME_NOT_ISOLATED", "Launch with the bundled isolated bootstrap.")
    if Path(sys.executable).resolve() != bundle_path(bundle, manifest["python"]["path"]).resolve():
        raise RuntimeErrorCode("RUNTIME_WRONG_INTERPRETER", "Launch the bundled interpreter.")
    for item in sys.path:
        if not item or not (Path(item).resolve().is_relative_to(runtime) or Path(item).resolve() == scripts):
            raise RuntimeErrorCode("RUNTIME_IMPORT_PATH_EXTERNAL", "Launch with the bundled isolated bootstrap.")


def inspect_runtime(bundle):
    checks, manifest = [], None
    def check(name, action, function):
        try:
            detail = function()
            checks.append({"check": name, "ok": True, "code": "OK", "detail": detail})
        except RuntimeErrorCode as error:
            checks.append({"check": name, "ok": False, "code": error.code, "action": error.action})
        except Exception:
            checks.append({"check": name, "ok": False, "code": "RUNTIME_" + name.upper() + "_FAILED", "action": action})
    try:
        manifest = load_manifest(bundle)
        checks.append({"check": "manifest", "ok": True, "code": "OK"})
    except RuntimeErrorCode as error:
        return {"ok": False, "checks": [{"check": "manifest", "ok": False, "code": error.code, "action": error.action}]}
    check("isolation", "Launch through the bundled bootstrap.", lambda: isolation_check(bundle, manifest))
    if not checks[-1]["ok"]:
        return {"ok": False, "checks": checks}
    def bootstrap():
        if not os.get_inheritable(0):
            raise RuntimeErrorCode("RUNTIME_LEASE_FD_NOT_INHERITED", "Keep the workspace lease descriptor inherited across exec.")
        if any(key.startswith("DYLD_") or key in {"PYTHONPATH", "PYTHONHOME", "BANKING_PROCESSOR_PROJECT", "BANKING_PROCESSOR_CONFIG", "BANKING_PROCESSOR_PYTHON", "BANKING_MERCHANT_DB"} for key in os.environ):
            raise RuntimeErrorCode("RUNTIME_EXTERNAL_ENVIRONMENT", "Launch through the bundled bootstrap.")
        return {"bytecode_writes": False, "user_site": False, "automatic_site_import": False, "lease_fd_inherited": True}
    check("bootstrap_selfcheck", "Launch through the bundled bootstrap.", bootstrap)
    def version():
        if platform.machine() != "arm64" or platform.python_version() != manifest["python"]["version"]:
            raise RuntimeErrorCode("RUNTIME_VERSION_MISMATCH", "Use the locked arm64 interpreter.")
        macos = tuple(int(n) for n in platform.mac_ver()[0].split("."))
        if macos < (14, 0):
            raise RuntimeErrorCode("RUNTIME_OS_UNSUPPORTED", "Use macOS 14 or newer.")
        return {"python": platform.python_version(), "architecture": platform.machine()}
    check("version", "Use the locked runtime on supported macOS.", version)
    expected = {item["name"]: item["version"] for item in manifest["dependencies"]}
    for name in ("pypdf", "openpyxl", "pdfplumber", "pypdfium2"):
        def imported(name=name):
            module = importlib.import_module(name)
            origin = Path(module.__file__).resolve()
            if not origin.is_relative_to(bundle_path(bundle, "Contents/Resources/ProcessorRuntime")):
                raise RuntimeErrorCode("RUNTIME_EXTERNAL_MODULE", "Use only bundled packages.")
            for dependency, locked in expected.items():
                if importlib.metadata.version(dependency) != locked:
                    raise RuntimeErrorCode("RUNTIME_DEPENDENCY_VERSION", "Rebuild from the runtime lock.")
            return {"version": importlib.metadata.version(name)}
        check("import_" + name, "Reinstall the complete runtime candidate.", imported)
    def sql():
        with sqlite3.connect(":memory:") as connection:
            connection.execute("create table smoke (value integer)")
            connection.execute("insert into smoke values (42)")
            if connection.execute("select value from smoke").fetchone() != (42,):
                raise ValueError()
        return {"version": sqlite3.sqlite_version}
    check("sqlite", "Rebuild the bundled SQLite extension.", sql)
    def pdf():
        import pypdf
        import pdfplumber
        import pypdfium2
        raw = io.BytesIO()
        writer = pypdf.PdfWriter()
        writer.add_blank_page(width=72, height=72)
        writer.write(raw)
        if len(pypdf.PdfReader(io.BytesIO(raw.getvalue())).pages) != 1:
            raise ValueError()
        with pdfplumber.open(io.BytesIO(raw.getvalue())) as parsed:
            if len(parsed.pages) != 1:
                raise ValueError()
        document = pypdfium2.PdfDocument(raw.getvalue())
        try:
            page = document[0]
            try:
                bitmap = page.render(scale=1)
                try:
                    if bitmap.width != 72 or bitmap.height != 72:
                        raise ValueError()
                finally:
                    bitmap.close()
            finally:
                page.close()
        finally:
            document.close()
        return {"pages": 1, "render_width": 72, "render_height": 72}
    check("pdf_render", "Rebuild signed PDFium and its native dependencies.", pdf)
    def xlsx():
        import openpyxl
        workbook = openpyxl.Workbook()
        workbook.active["A1"] = "runtime"
        data = io.BytesIO()
        workbook.save(data)
        workbook.close()
        parsed = openpyxl.load_workbook(io.BytesIO(data.getvalue()), read_only=True)
        try:
            if parsed.active["A1"].value != "runtime":
                raise ValueError()
        finally:
            parsed.close()
        return {"roundtrip": True}
    check("xlsx", "Rebuild the locked Excel dependencies.", xlsx)
    def helper():
        process = subprocess.run([str(bundle_path(bundle, manifest["helper"]["path"])), "--self-test"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10, check=True, env={"PATH": system_search_path()})
        if len(process.stdout) > 65536:
            raise ValueError()
        report = json.loads(process.stdout)
        if not isinstance(report, dict) or report.get("ok") is not True:
            raise ValueError()
        return {"self_test": True}
    check("helper", "Rebuild and sign the Release VideoRecords helper.", helper)
    return {"ok": all(item["ok"] for item in checks), "runtime_version": manifest["runtime_version"], "license_inventory_status": manifest["licenses"]["status"], "distribution_ready": False, "checks": checks}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-root", type=Path)
    args = parser.parse_args(argv)
    bundle = args.bundle_root or Path(__file__).resolve().parents[4]
    report = inspect_runtime(bundle)
    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
