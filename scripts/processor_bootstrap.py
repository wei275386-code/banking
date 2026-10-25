"""Isolated controlled entry. Keeps the inherited FD 0 workspace lease alive.

The caller owns process-group isolation and readiness; exec preserves that PID,
group and FD. No package installation or business-data access occurs here.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import sys


def _digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def clean_environment(environment, bundle, helper):
    result = {key: value for key, value in environment.items() if not key.startswith(("PYTHON", "DYLD_")) and key not in {"BANKING_PROCESSOR_PROJECT", "BANKING_PROCESSOR_CONFIG", "BANKING_PROCESSOR_PYTHON", "BANKING_MERCHANT_DB", "BANKING_VIDEO_HELPER", "BANKING_VIDEO_RECORDS_HELPER"}}
    result.update({"PATH": os.confstr("CS_PATH") or os.defpath, "BANKING_RUNTIME_BUNDLE": str(bundle), "BANKING_VIDEO_HELPER": str(helper), "PYTHONDONTWRITEBYTECODE": "1", "PYTHONNOUSERSITE": "1"})
    return result


def prepare(bundle, entry):
    if not sys.flags.isolated or not sys.flags.no_user_site or not sys.flags.no_site or not sys.dont_write_bytecode:
        raise ValueError("RUNTIME_NOT_ISOLATED")
    bundle = Path(bundle).resolve()
    own_path = Path(__file__).resolve()
    manifest = json.loads((bundle / "Contents/Resources/runtime-manifest.json").read_text())
    scripts = bundle / "Contents/Resources/processor/scripts"
    if own_path != scripts / "processor_bootstrap.py" or manifest["scripts"]["path"] != "Contents/Resources/processor/scripts":
        raise ValueError("RUNTIME_BOOTSTRAP_INVALID")
    # Authenticate the validator before importing any controlled script module.
    doctor = scripts / "runtime_doctor.py"
    records = {item["path"]: item for item in manifest["files"]}
    doctor_relative = doctor.relative_to(bundle).as_posix()
    if doctor.is_symlink() or _digest(doctor) != records[doctor_relative]["sha256"]:
        raise ValueError("RUNTIME_HASH_MISMATCH")
    runtime = bundle / "Contents/Resources/ProcessorRuntime"
    sys.path[:] = [value for value in sys.path if value and Path(value).resolve().is_relative_to(runtime)]
    sys.path.insert(0, str(scripts))
    import runtime_doctor
    manifest = runtime_doctor.load_manifest(bundle)
    runtime_doctor.isolation_check(bundle, manifest)
    if entry not in manifest["entry_scripts"] or PurePosixPath(entry).name != entry:
        raise ValueError("RUNTIME_ENTRY_FORBIDDEN")
    return bundle, scripts / entry, runtime_doctor.bundle_path(bundle, manifest["helper"]["path"])


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle-root", required=True, type=Path)
    parser.add_argument("--entry", required=True)
    parser.add_argument("arguments", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    try:
        bundle, entry, helper = prepare(args.bundle_root, args.entry)
        forwarded = args.arguments[1:] if args.arguments[:1] == ["--"] else args.arguments
        os.set_inheritable(0, True)  # Never close/read stdin: it owns the lease.
        environment = clean_environment(os.environ, bundle, helper)
        wrapper = "import sys,runpy;from pathlib import Path;sys.dont_write_bytecode=True;root=Path(sys.executable).resolve().parent.parent;sys.path[:]=[p for p in sys.path if p and Path(p).resolve().is_relative_to(root)];sys.path.append(str(root/'lib'/('python'+str(sys.version_info.major)+'.'+str(sys.version_info.minor))/'site-packages'));entry=sys.argv.pop(1);sys.path.insert(0,str(Path(entry).parent));sys.argv[0]=entry;runpy.run_path(entry,run_name='__main__')"
        os.execve(sys.executable, [sys.executable, "-I", "-B", "-S", "-c", wrapper, str(entry), *forwarded], environment)
    except Exception as error:
        code = getattr(error, "code", None)
        if not code:
            code = str(error) if str(error).startswith("RUNTIME_") and "/" not in str(error) else "RUNTIME_BOOTSTRAP_FAILED"
        print(json.dumps({"ok": False, "code": code, "action": "Reinstall the complete App candidate before retrying."}), file=sys.stderr)
        return 78


if __name__ == "__main__":
    raise SystemExit(main())
