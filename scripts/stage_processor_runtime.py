"""Build-only, hash-locked runtime staging. Never invoked on an installed Mac.

Stages into a NEW .app directory. Nested code must be signed before running
--refresh-manifest, and the outer App must be signed afterwards. No signing or
notarization success is inferred from staging.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import stat
import struct
import subprocess
import tarfile
import tempfile
import zipfile

if __package__:
    from .ios_artifact import controlled_environment
    from .tool_locations import is_system_library, tool_path
else:
    from ios_artifact import controlled_environment
    from tool_locations import is_system_library, tool_path

RUNTIME = "Contents/Resources/ProcessorRuntime"
PROCESSOR = "Contents/Resources/processor"
SCRIPTS = "Contents/Resources/processor/scripts"
MANIFEST = "Contents/Resources/runtime-manifest.json"
LICENSES = "Contents/Resources/runtime-licenses.json"
HELPER = "Contents/Helpers/VideoRecords"
DEFAULTS = "Contents/Resources/defaults"
ENTRIES = ["workspace_cli.py", "app_review.py", "import_review_materials.py", "probe_payment_evidence.py", "runtime_doctor.py"]
MAX_EXPANDED = 1024 * 1024 * 1024
MAX_MEMBERS = 50000
CHUNK = 1024 * 1024


class StagingError(ValueError):
    pass


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(CHUNK), b""):
            digest.update(block)
    return digest.hexdigest()


def safe_relative(name):
    path = PurePosixPath(name)
    if not name or "\\" in name or path.is_absolute() or any(p in ("", ".", "..") for p in name.split("/")):
        raise StagingError("unsafe archive/bundle path")
    return path


def _copy_limited(source, destination, size):
    destination.parent.mkdir(parents=True, exist_ok=True)
    count = 0
    with destination.open("xb") as target:
        for block in iter(lambda: source.read(CHUNK), b""):
            count += len(block)
            if count > size:
                raise StagingError("archive member exceeds declared size")
            target.write(block)
    if count != size:
        raise StagingError("truncated archive member")


def extract_runtime(archive, destination):
    """No extractall: reject devices, hardlinks, aliases and escaping symlinks.

    Symlinks are created only after regular files, so no member can redirect a
    later write. The upstream install_only archive has relative bin aliases.
    """
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=False)
    links, seen, total = [], set(), 0
    with tarfile.open(archive, "r:gz") as tar:
        for index, member in enumerate(tar):
            if index >= MAX_MEMBERS:
                raise StagingError("archive member limit exceeded")
            raw = member.name.rstrip("/")
            relative = safe_relative(raw)
            if relative.parts[0] != "python":
                raise StagingError("unexpected runtime archive root")
            if len(relative.parts) == 1:
                if not member.isdir():
                    raise StagingError("invalid runtime archive root")
                continue
            relative = PurePosixPath(*relative.parts[1:])
            if relative in seen:
                raise StagingError("duplicate archive member")
            seen.add(relative)
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                total += member.size
                if member.size < 0 or total > MAX_EXPANDED:
                    raise StagingError("archive size limit exceeded")
                with tar.extractfile(member) as stream:
                    _copy_limited(stream, target, member.size)
                target.chmod(0o755 if member.mode & 0o111 else 0o644)
            elif member.issym():
                link = member.linkname
                if not link or "\\" in link or PurePosixPath(link).is_absolute():
                    raise StagingError("unsafe runtime symlink")
                resolved = (target.parent / link).resolve()
                if not resolved.is_relative_to(destination.resolve()):
                    raise StagingError("escaping runtime symlink")
                links.append((target, link))
            else:
                raise StagingError("unsupported runtime archive member")
    for target, link in links:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.symlink_to(link)
    for target, _ in links:
        if not target.resolve().is_relative_to(destination.resolve()) or not target.is_file():
            raise StagingError("invalid runtime symlink target")


def install_wheel(archive, site_packages, omitted_scripts=()):
    """Install locked wheel payload directly; no pip, sdist, .pth or scripts."""
    total, seen = 0, set()
    omitted = {item['path']: item for item in omitted_scripts}
    if len(omitted) != len(omitted_scripts):
        raise StagingError("duplicate wheel script omission")
    omitted_seen = set()
    with zipfile.ZipFile(archive) as wheel:
        for index, member in enumerate(wheel.infolist()):
            if index >= MAX_MEMBERS:
                raise StagingError("wheel member limit exceeded")
            path = safe_relative(member.filename.rstrip("/"))
            mode = member.external_attr >> 16
            if stat.S_ISLNK(mode) or (stat.S_IFMT(mode) not in (0, stat.S_IFREG, stat.S_IFDIR)):
                raise StagingError("wheel special file")
            if path.parts[0].endswith(".data"):
                if len(path.parts) >= 2 and path.parts[1] == 'scripts':
                    if member.is_dir() and any(name.startswith(str(path) + '/') for name in omitted):
                        continue
                    record = omitted.get(str(path))
                    if record is None or member.is_dir() or member.file_size != record['size']:
                        raise StagingError("wheel requires unsupported install scheme")
                    total += member.file_size
                    if total > MAX_EXPANDED or str(path) in omitted_seen:
                        raise StagingError("invalid wheel script omission")
                    checksum = hashlib.sha256()
                    with wheel.open(member) as stream:
                        for chunk in iter(lambda: stream.read(CHUNK), b''):
                            checksum.update(chunk)
                    if checksum.hexdigest() != record['sha256']:
                        raise StagingError("wheel script omission digest mismatch")
                    omitted_seen.add(str(path))
                    continue
                if len(path.parts) < 3 or path.parts[1] not in ("purelib", "platlib"):
                    raise StagingError("wheel requires unsupported install scheme")
                path = PurePosixPath(*path.parts[2:])
            if path.suffix in (".pth", ".pyc", ".pyo"):
                raise StagingError("wheel contains import hooks or bytecode")
            if path in seen:
                raise StagingError("duplicate wheel path")
            seen.add(path)
            target = Path(site_packages).joinpath(*path.parts)
            if member.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            total += member.file_size
            if total > MAX_EXPANDED:
                raise StagingError("wheel size limit exceeded")
            with wheel.open(member) as stream:
                _copy_limited(stream, target, member.file_size)
            target.chmod(0o755 if mode & 0o111 else 0o644)
    if omitted_seen != set(omitted):
        raise StagingError("locked wheel script omission is missing")


def _version(value):
    return ((value >> 16) & 0xffff, (value >> 8) & 255, value & 255)


def inspect_macho(path, minimum=(14, 0, 0), allowed_external_rpaths=(), allowed_external_rpath_hashes=()):
    """Inspect load commands without loading code; validate the arm64 slice."""
    with Path(path).open("rb") as stream:
        magic = stream.read(4)
        if magic not in (b"\xcf\xfa\xed\xfe", b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
            if magic in (b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xce", b"\xfe\xed\xfa\xcf"):
                raise StagingError("unsupported Mach-O architecture")
            return None
        offset = 0
        if magic.startswith(b"\xca\xfe\xba"):
            count = struct.unpack(">I", stream.read(4))[0]
            if not 1 <= count <= 16:
                raise StagingError("invalid fat Mach-O")
            offsets = []
            for _ in range(count):
                data = stream.read(32 if magic[-1] == 0xbf else 20)
                fields = struct.unpack(">IIQQII" if magic[-1] == 0xbf else ">IIIII", data)
                if fields[0] == 0x100000c:
                    offsets.append(fields[2])
            if len(offsets) != 1:
                raise StagingError("Mach-O lacks unique arm64 slice")
            offset = offsets[0]
        stream.seek(offset)
        header = stream.read(32)
        if len(header) != 32 or header[:4] != b"\xcf\xfa\xed\xfe":
            raise StagingError("invalid Mach-O header")
        _, cpu, _, _, count, command_bytes, _, _ = struct.unpack("<8I", header)
        if cpu != 0x100000c or count > 10000 or command_bytes > 16 * CHUNK:
            raise StagingError("Mach-O architecture/load command limit")
        commands = stream.read(command_bytes)
    links, rpaths, deployment, position = [], [], None, 0
    for _ in range(count):
        if position + 8 > len(commands):
            raise StagingError("truncated Mach-O load command")
        command, size = struct.unpack_from("<II", commands, position)
        if size < 8 or position + size > len(commands):
            raise StagingError("invalid Mach-O command size")
        data = commands[position:position + size]
        if command in (0xc, 0x80000018, 0x8000001f, 0x80000023, 0x8000001c):
            string_offset = struct.unpack_from("<I", data, 8)[0]
            if string_offset < 12 or string_offset >= len(data):
                raise StagingError("invalid Mach-O string offset")
            value = data[string_offset:].split(b"\0", 1)[0].decode("utf-8", "strict")
            (rpaths if command == 0x8000001c else links).append(value)
        elif command == 0x32:
            platform, version = struct.unpack_from("<II", data, 8)
            if platform != 1:
                raise StagingError("native code is not macOS")
            deployment = _version(version)
            if deployment > minimum:
                raise StagingError("incompatible native deployment target")
        elif command == 0x24:
            deployment = _version(struct.unpack_from("<I", data, 8)[0])
            if deployment > minimum:
                raise StagingError("incompatible native deployment target")
        position += size
    if position != len(commands) or deployment is None or deployment > minimum:
        raise StagingError("missing/incompatible native deployment target")
    for value in links + rpaths:
        if value in rpaths and value not in links and (
                value in allowed_external_rpaths or hashlib.sha256(value.encode()).hexdigest() in allowed_external_rpath_hashes):
            continue
        if value.startswith("/") and ".." in PurePosixPath(value).parts:
            raise StagingError("unsafe absolute native path")
        if not (is_system_library(value) or value.startswith(("@loader_path/", "@executable_path/", "@rpath/"))) and value not in ("@loader_path", "@executable_path"):
            raise StagingError("external native library/rpath")
    return {"architecture": "arm64", "minimum_macos": ".".join(map(str, deployment)), "dependencies": links, "rpaths": rpaths}


def apply_locked_relocations(bundle, lock):
    """Only a hash-proven, unused LC_RPATH may be removed before signing."""
    for relocation in lock.get("native_relocations", []):
        if relocation["operation"] != "delete_rpath":
            raise StagingError("unsupported native relocation")
        relative = safe_relative(relocation["path"])
        path = Path(bundle).joinpath(*relative.parts)
        if not path.resolve().is_relative_to(Path(bundle).resolve()) or path.is_symlink():
            raise StagingError("unsafe native relocation path")
        if sha256(path) != relocation["source_sha256"]:
            raise StagingError("native relocation source hash mismatch")
        expected = relocation["old_rpath_sha256"]
        if not isinstance(expected, str) or len(expected) != 64 or any(c not in '0123456789abcdef' for c in expected):
            raise StagingError("invalid locked rpath digest")
        info = inspect_macho(path, allowed_external_rpath_hashes=(expected,))
        matches = [value for value in info["rpaths"] if hashlib.sha256(value.encode()).hexdigest() == expected]
        if len(matches) != 1 or any(link.startswith("@rpath/") for link in info["dependencies"]):
            raise StagingError("relocation is not an unused exact rpath")
        old = matches[0]
        subprocess.run([tool_path('install_name_tool', system=True), "-delete_rpath", old, str(path)],
                       check=True, timeout=20, env=controlled_environment())
        after = inspect_macho(path)
        if old in after["rpaths"] or after["dependencies"] != info["dependencies"] or after["minimum_macos"] != info["minimum_macos"]:
            raise StagingError("native relocation verification failed")


def validate_native_tree(bundle, python_relative):
    bundle = Path(bundle).resolve()
    executable = bundle / python_relative
    native = {}
    for base in (bundle / RUNTIME, bundle / "Contents/Helpers"):
        paths = [base] if base.is_file() else sorted(base.rglob("*"))
        for path in paths:
            if path.is_file() and not path.is_symlink():
                info = inspect_macho(path)
                if info is None and path.suffix in (".so", ".dylib", ".pyd", ".dll"):
                    raise StagingError("native extension is not arm64 Mach-O")
                if info:
                    native[path.relative_to(bundle).as_posix()] = info
    if python_relative not in native or HELPER not in native:
        raise StagingError("interpreter/helper is not arm64 Mach-O")
    def expand(value, owner):
        value = value.replace("@loader_path", str(owner.parent)).replace("@executable_path", str(executable.parent))
        candidate = Path(value).resolve()
        if not candidate.is_relative_to(bundle):
            raise StagingError("native path escapes bundle")
        return candidate
    executable_rpaths = native[python_relative]["rpaths"]
    def bundled_rpaths(values, owner):
        # inspect_macho already checks system paths and traversal. They are
        # legitimate search locations, but cannot satisfy a bundled @rpath
        # dependency; that dependency must have a complete in-bundle payload.
        return [expand(value, owner) for value in values
                if not is_system_library(value)]
    for relative, info in native.items():
        owner = bundle / relative
        rpaths = bundled_rpaths(info["rpaths"], owner)
        rpaths += bundled_rpaths(executable_rpaths, executable)
        for dependency in info["dependencies"]:
            if is_system_library(dependency):
                continue
            if dependency.startswith("@rpath/"):
                candidates = [p / dependency[7:] for p in rpaths]
                if not candidates or not any(p.is_file() and p.resolve().is_relative_to(bundle) for p in candidates):
                    raise StagingError("unresolved bundled @rpath dependency")
            elif not expand(dependency, owner).is_file():
                raise StagingError("missing bundled native dependency")
    return native


def download_locked(item, cache):
    url = item["url"]
    if not url.startswith(("https://github.com/astral-sh/python-build-standalone/releases/download/", "https://files.pythonhosted.org/")):
        raise StagingError("unapproved artifact URL")
    digest = item["sha256"]
    if len(digest) != 64 or any(c not in "0123456789abcdef" for c in digest):
        raise StagingError("invalid artifact hash")
    cache = Path(cache)
    cache.mkdir(parents=True, exist_ok=True)
    target = cache / item["filename"]
    safe_relative(item["filename"])
    if len(PurePosixPath(item["filename"]).parts) != 1:
        raise StagingError("invalid artifact filename")
    if target.exists():
        if sha256(target) != digest or target.stat().st_size != item["size"]:
            raise StagingError("cached artifact integrity failure")
        return target
    temporary = target.with_suffix(target.suffix + ".partial")
    try:
        subprocess.run([tool_path('curl', system=True), "--fail", "--silent", "--show-error", "--location", "--proto", "=https", "--proto-redir", "=https", "--connect-timeout", "10", "--max-time", "18", "--max-filesize", str(item["size"]), "--output", str(temporary), url],
                       check=True, timeout=20, env=controlled_environment())
        if temporary.stat().st_size != item["size"] or sha256(temporary) != digest:
            raise StagingError("download integrity failure")
        temporary.replace(target)
    finally:
        temporary.unlink(missing_ok=True)
    return target


def inventory(bundle, native):
    bundle = Path(bundle).resolve()
    result = []
    for root in (bundle / RUNTIME, bundle / PROCESSOR, bundle / "Contents/Helpers", bundle / DEFAULTS, bundle / LICENSES, bundle / "Contents/Resources/release"):
        paths = [root] if root.is_file() else sorted(root.rglob("*"))
        for path in paths:
            if path.is_symlink():
                target = os.readlink(path)
                if not path.resolve().is_relative_to(bundle) or not path.is_file():
                    raise StagingError("invalid bundle symlink")
                result.append({"path": path.relative_to(bundle).as_posix(), "kind": "symlink", "target": target, "size": len(target.encode()), "sha256": hashlib.sha256(target.encode()).hexdigest()})
            elif path.is_file():
                relative = path.relative_to(bundle).as_posix()
                result.append({"path": relative, "kind": "macho" if relative in native else "file", "size": path.stat().st_size, "sha256": sha256(path)})
    return sorted(result, key=lambda item: item["path"])


def validate_license_inventory(bundle, lock, lock_hash):
    """Validate real local notice bytes; URLs and license labels grant no trust."""
    bundle = Path(bundle).resolve()
    value = json.loads((bundle / LICENSES).read_text())
    if value['runtime_lock_sha256'] != lock_hash or value['distribution_ready'] is not False:
        raise StagingError("stale/invalid runtime license inventory")
    expected = {item["filename"]: item["sha256"] for item in [lock["python"], *lock["wheels"]]}
    found = {}
    for artifact in value["artifacts"]:
        if artifact["artifact"] in found or artifact["status"] not in ("metadata_and_files_recorded", "needs_review"):
            raise StagingError("invalid runtime license artifact")
        found[artifact["artifact"]] = artifact["artifact_sha256"]
        records = list(artifact["license_files"])
        if artifact.get("metadata_file"):
            records.append(artifact["metadata_file"])
        for record in records:
            relative = safe_relative(record["path"])
            path = bundle.joinpath(*relative.parts)
            if not path.resolve().is_relative_to(bundle) or path.is_symlink() or not path.is_file():
                raise StagingError("missing/unsafe bundled license file")
            if path.stat().st_size != record["size"] or sha256(path) != record["sha256"]:
                raise StagingError("bundled license file hash mismatch")
    if found != expected:
        raise StagingError("runtime license artifact closure mismatch")
    return value


def write_manifest(bundle, lock, lock_hash, signing_status="unsigned_candidate"):
    python = RUNTIME + "/bin/python3.13"
    native = validate_native_tree(bundle, python)
    licenses = validate_license_inventory(bundle, lock, lock_hash)
    manifest = {"runtime_version": lock["runtime_version"], "architecture": "arm64", "minimum_macos": "14.0", "lock_sha256": lock_hash,
                "python": {"path": python, "version": lock["python"]["version"]}, "scripts": {"path": SCRIPTS}, "bootstrap": {"path": SCRIPTS + "/processor_bootstrap.py"}, "doctor": {"path": SCRIPTS + "/runtime_doctor.py"}, "helper": {"path": HELPER, "self_test_arguments": ["--self-test"]}, "defaults": {"path": DEFAULTS},
                "entry_scripts": ENTRIES, "dependencies": [{"name": x["name"], "version": x["version"]} for x in lock["wheels"]], "files": inventory(bundle, native), "native_code": native,
                "native_relocations": [{"path": item["path"], "operation": item["operation"], "source_sha256": item["source_sha256"]} for item in lock.get("native_relocations", [])],
                "wheel_script_omissions": lock.get("wheel_script_omissions", {}),
                "licenses": {"path": LICENSES, "status": "needs_review" if any(item["status"] == "needs_review" for item in licenses["artifacts"]) else "metadata_and_files_recorded"},
                "signing": {"status": signing_status, "notarization": "not_performed", "distribution_ready": False}}
    target = Path(bundle) / MANIFEST
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(manifest, indent=2, ensure_ascii=False) + "\n")
    return manifest


def refresh_manifest(bundle, lockfile, signing_status="locally_signed_candidate"):
    """Refresh resource hashes after nested signing, before outer App signing."""
    if signing_status not in ("unsigned_candidate", "locally_signed_candidate"):
        raise StagingError("unsupported signing status")
    return write_manifest(bundle, json.loads(Path(lockfile).read_text()), sha256(lockfile), signing_status)


def validate_processor_imports(source, scripts):
    """Check local dependencies, including imports reached by processing requests."""
    source = Path(source)
    selected = set(scripts)
    for name in scripts:
        safe_relative(name)
        if len(PurePosixPath(name).parts) != 2 or not name.startswith('scripts/') or not name.endswith('.py'):
            raise StagingError('invalid locked processor source')
        path = source / name
        if path.is_symlink() or not path.is_file():
            raise StagingError('missing/unsafe processor source')
        for node in ast.walk(ast.parse(path.read_text(), filename=name)):
            modules = []
            if isinstance(node, ast.Import):
                modules = [alias.name for alias in node.names]
            elif isinstance(node, ast.ImportFrom):
                if node.module == 'scripts' or (node.level and not node.module):
                    modules = ['scripts.' + alias.name for alias in node.names]
                elif node.module:
                    modules = [node.module]
            for module in modules:
                parts = module.split('.')
                dependency = 'scripts/' + (parts[1] if parts[0] == 'scripts' and len(parts) > 1 else parts[0]) + '.py'
                if (module.startswith('scripts.') or (source / dependency).is_file()) and dependency not in selected:
                    raise StagingError('locked processor import missing: ' + name + ' -> ' + dependency)


def stage(bundle, lockfile, cache, source, helper):
    bundle, source = Path(bundle), Path(source)
    if bundle.exists():
        raise StagingError("staging destination must not exist")
    lock = json.loads(Path(lockfile).read_text())
    if lock['architecture'] != 'arm64' or lock['minimum_macos'] != '14.0':
        raise StagingError("unsupported runtime lock")
    validate_processor_imports(source, lock['processor_scripts'])
    artifacts = [download_locked(item, cache) for item in [lock["python"], *lock["wheels"]]]
    bundle.parent.mkdir(parents=True, exist_ok=True)
    temporary = Path(tempfile.mkdtemp(prefix=".runtime-stage-", dir=bundle.parent))
    try:
        extract_runtime(artifacts[0], temporary / RUNTIME)
        runtime = temporary / RUNTIME
        site = runtime / "lib/python3.13/site-packages"
        site.mkdir(parents=True, exist_ok=True)
        # The installed runtime has no package installer or build-time bytecode.
        for path in sorted(runtime.rglob("*"), reverse=True):
            if path.is_dir() and (path.name == "__pycache__" or path.name == "ensurepip" or (path.parent == site and (path.name.startswith(("pip", "setuptools", "wheel")) or path.name == "_distutils_hack"))):
                shutil.rmtree(path)
            elif path.is_file() and path.suffix in (".pyc", ".pyo", ".pth"):
                path.unlink()
        omissions = lock.get("wheel_script_omissions", {})
        if not isinstance(omissions, dict) or not set(omissions).issubset({item['filename'] for item in lock['wheels']}):
            raise StagingError("wheel script omission references unlocked artifact")
        for wheel in artifacts[1:]:
            install_wheel(wheel, site, omissions.get(wheel.name, ()))
        apply_locked_relocations(temporary, lock)
        script_dir = temporary / SCRIPTS
        script_dir.mkdir(parents=True)
        allowlist = json.loads((source / "release/source-allowlist.json").read_text())["profiles"]["production"]
        scripts = lock["processor_scripts"]
        if not isinstance(scripts, list) or len(scripts) != len(set(scripts)):
            raise StagingError("invalid locked processor closure")
        for name in scripts:
            safe_relative(name)
            if len(PurePosixPath(name).parts) != 2 or not name.startswith("scripts/") or not name.endswith(".py") or name not in allowlist:
                raise StagingError("locked processor source is not allowed")
            source_path = source / name
            if source_path.is_symlink() or not source_path.is_file():
                raise StagingError("missing/unsafe processor source")
            shutil.copyfile(source_path, script_dir / source_path.name)
        for name in sorted(name for name in allowlist if name.startswith("schemas/release/") and name.endswith(".schema.json")):
            safe_relative(name)
            source_path = source / name
            if source_path.is_symlink() or not source_path.is_file():
                raise StagingError("missing/unsafe contract schema")
            target = temporary / PROCESSOR / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source_path, target)
        if not all((script_dir / entry).is_file() for entry in ENTRIES):
            raise StagingError("processor entry closure missing")
        helper_target = temporary / HELPER
        helper_target.parent.mkdir(parents=True)
        shutil.copyfile(helper, helper_target)
        helper_target.chmod(0o755)
        defaults = temporary / DEFAULTS
        defaults.mkdir(parents=True)
        shutil.copyfile(source / "release/default-config.json", defaults / "default-config.json")
        shutil.copyfile(source / "release/runtime-licenses.json", temporary / LICENSES)
        manifest = write_manifest(temporary, lock, sha256(lockfile))
        temporary.rename(bundle)
        return manifest
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bundle", type=Path, required=True)
    parser.add_argument("--lock", type=Path, default=Path(__file__).resolve().parents[1] / "release/runtime-lock.json")
    parser.add_argument("--cache", type=Path, default=Path(".scratch/release-runtime/artifacts"))
    parser.add_argument("--source", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--helper", type=Path)
    parser.add_argument("--refresh-manifest", action="store_true")
    parser.add_argument("--signing-status", choices=("unsigned_candidate", "locally_signed_candidate"), default="unsigned_candidate")
    args = parser.parse_args(argv)
    try:
        if args.refresh_manifest:
            refresh_manifest(args.bundle, args.lock, args.signing_status)
        elif args.helper is None:
            parser.error("--helper must name the Release VideoRecords artifact")
        else:
            stage(args.bundle, args.lock, args.cache, args.source, args.helper)
    except (OSError, ValueError, subprocess.SubprocessError, tarfile.TarError, zipfile.BadZipFile) as error:
        report = {"ok": False, "code": "RUNTIME_STAGE_FAILED", "action": "Check locked artifacts, safe archive payload, arm64 native links and macOS deployment target."}
        if isinstance(error, StagingError):
            report["detail"] = str(error)
        print(json.dumps(report))
        return 1
    print(json.dumps({"ok": True, "code": "RUNTIME_STAGED_CANDIDATE", "manifest": MANIFEST, "distribution_ready": False}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
