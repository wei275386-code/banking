"""Assemble a self-contained Mac App candidate without installing or launching it.

Build the complete Swift package first. This tool does not open a workspace or
copy family data. Signing and provenance never imply distribution acceptance.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path

if __package__:
    from .generate_release_inputs import load_version
    from .app_icon import write_app_icon
    from .release_contracts import digest_file
    from .stage_processor_runtime import stage, refresh_manifest, inspect_macho
    from .ios_artifact import controlled_environment
    from .tool_locations import macos_directory, tool_path
else:
    from generate_release_inputs import load_version
    from app_icon import write_app_icon
    from release_contracts import digest_file
    from stage_processor_runtime import stage, refresh_manifest, inspect_macho
    from ios_artifact import controlled_environment
    from tool_locations import macos_directory, tool_path


BUNDLE_ID = "local.banking.family-review"


def build_only_rpaths(root: Path) -> tuple[str, ...]:
    """Bind a removable build search path to the locked Swift toolchain."""
    inventory = json.loads((root / "release/native-toolchain.json").read_text())
    developer = Path(run(["xcode-select", "-p"], text=True).stdout.strip()).resolve()
    swift = developer / "Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
    if digest_file(swift) != inventory["tools"]["swift"]["sha256"]:
        raise ValueError("Selected Swift toolchain does not match the release inventory")
    relative = inventory.get("build_only_swift_rpaths", [])
    if not relative or any(not value.startswith("Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-")
                           or not value.endswith("/macosx") or ".." in Path(value).parts for value in relative):
        raise ValueError("Missing or unsafe build-only Swift rpath inventory")
    return tuple(str(developer / value) for value in relative)


def stage_native_executables(binaries: dict, directory: Path, allowed: tuple[str, ...]) -> tuple[dict, list]:
    """Remove only unused, inventory-bound rpaths from private staging copies."""
    directory.mkdir()
    copies, relocations = {}, []
    for name, source in binaries.items():
        source_hash = digest_file(source)
        before = inspect_macho(source, allowed_external_rpaths=allowed)
        if before is None:
            raise ValueError("Release executable is not Mach-O")
        target = directory / name
        shutil.copyfile(source, target)
        target.chmod(0o755)
        removable = [value for value in before["rpaths"] if value in allowed]
        if removable and any(value.startswith("@rpath/") for value in before["dependencies"]):
            raise ValueError("Cannot remove a Swift rpath used by a native dependency")
        for value in removable:
            run([tool_path('install_name_tool', system=True), "-delete_rpath", value, str(target)])
            relocations.append({"binary": name, "operation": "delete_rpath", "old_rpath_sha256": hashlib.sha256(value.encode()).hexdigest(),
                                "source_sha256": source_hash})
        after = inspect_macho(target)
        if after is None or after["dependencies"] != before["dependencies"] or after["minimum_macos"] != before["minimum_macos"]:
            raise ValueError("Native relocation changed executable dependencies or deployment target")
        if digest_file(source) != source_hash:
            raise ValueError("Native build input changed during staging")
        copies[name] = target
    return copies, relocations


def run(command, **kwargs):
    kwargs['env'] = controlled_environment()
    return subprocess.run(command, check=True, capture_output=True, timeout=20, **kwargs)


def source_identity(root: Path, allow_dirty: bool) -> dict:
    commit = run(["git", "rev-parse", "HEAD"], cwd=root, text=True).stdout.strip()
    dirty = bool(run(["git", "status", "--porcelain"], cwd=root, text=True).stdout)
    if dirty and not allow_dirty:
        raise ValueError("Commit the release inputs before packaging")
    names = json.loads((root / "release/source-allowlist.json").read_text())["profiles"]["production"]
    files = {}
    for name in names:
        path = root / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("A production source input is missing or unsafe")
        files[name] = digest_file(path)
    manifest = json.dumps(files, sort_keys=True, separators=(",", ":")).encode()
    return {"commit": commit, "dirty": dirty, "source_input_sha256": hashlib.sha256(manifest).hexdigest(),
            "source_files": files}


def package(root: Path, destination: Path, cache: Path, *, identity: str = "-",
            allow_dirty: bool = False, qa: bool = False) -> dict:
    root = root.resolve()
    destination = destination.absolute()
    # The build action must never become the previous installation action.
    if destination.suffix != ".app" or destination.exists() or destination.is_symlink():
        raise ValueError("Use a new, explicit .app staging destination")
    if destination.resolve().is_relative_to(macos_directory('applications')):
        raise ValueError("Package into a staging directory before installation")
    if not identity or identity != "-" and not identity.startswith("Developer ID Application:"):
        raise ValueError("Use ad-hoc candidate signing or an explicit Developer ID Application identity")
    version = load_version(root)
    before = source_identity(root, allow_dirty)
    if before["dirty"] and not qa:
        raise ValueError("Dirty candidates require the independent QA identifier")
    build = root / "native/PaymentImageCore/.build/release"
    binaries = {name: build / name for name in ("EvidenceBrowser", "VideoRecords", "SyncHost", "FinancialProjection")}
    allowed_rpaths = build_only_rpaths(root)
    for name, path in binaries.items():
        if path.is_symlink():
            # SwiftPM's release directory can be a symlink; the artifact itself
            # must resolve to the build tree, not an unrelated installed App.
            if not path.resolve().is_relative_to((root / "native/PaymentImageCore/.build").resolve()):
                raise ValueError("Executable points outside the build directory")
        if not path.is_file() or not os.access(path, os.X_OK) or inspect_macho(path, allowed_external_rpaths=allowed_rpaths) is None:
            raise ValueError(f"Build the whole Release package before packaging {name}")
    newest_source = max((root / name).stat().st_mtime_ns for name in before["source_files"]
                        if name.endswith(".swift"))
    if any(path.stat().st_mtime_ns < newest_source for path in binaries.values()):
        raise ValueError("Release executables predate native sources; rebuild the whole package")
    input_hashes = {name: digest_file(path) for name, path in binaries.items()}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".release-package-", dir=destination.parent) as temporary:
        app = Path(temporary) / destination.name
        lock = root / "release/runtime-lock.json"
        copies, native_relocations = stage_native_executables(binaries, Path(temporary) / "native", allowed_rpaths)
        stage(app, lock, cache, root, copies["VideoRecords"])
        contents = app / "Contents"
        (contents / "MacOS").mkdir()
        shutil.copyfile(copies["EvidenceBrowser"], contents / "MacOS/EvidenceBrowser")
        (contents / "MacOS/EvidenceBrowser").chmod(0o755)
        shutil.copyfile(copies["SyncHost"], contents / "Helpers/SyncHost")
        (contents / "Helpers/SyncHost").chmod(0o755)
        shutil.copyfile(copies["FinancialProjection"], contents / "Helpers/FinancialProjection")
        (contents / "Helpers/FinancialProjection").chmod(0o755)
        resources = contents / "Resources"
        write_app_icon(root, resources / "AppIcon.icns")
        (resources / "release-version.json").write_text(json.dumps(version, sort_keys=True) + "\n")
        (resources / "bootstrap.json").write_text(json.dumps({
            "kind": "empty", "workspace_created": False}, sort_keys=True) + "\n")
        (contents / "Info.plist").write_bytes(plistlib.dumps({
            "CFBundleExecutable": "EvidenceBrowser", "CFBundleIdentifier": BUNDLE_ID + (".ReleaseQA" if qa else ""),
            "CFBundleName": "家庭财务复盘", "CFBundleDisplayName": "家庭财务复盘", "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "AppIcon.icns", "CFBundleShortVersionString": version["app_version"],
            "CFBundleVersion": str(version["build_number"]), "LSMinimumSystemVersion": version["macos_minimum"],
            "NSHighResolutionCapable": True, "NSPrincipalClass": "NSApplication"}))
        unsigned = json.loads((resources / "runtime-manifest.json").read_text())
        native = [app / name for name in unsigned["native_code"]]
        native.extend([contents / "MacOS/EvidenceBrowser", contents / "Helpers/SyncHost", contents / "Helpers/FinancialProjection"])
        options = ["--options", "runtime", "--timestamp"] if identity != "-" else []
        for path in sorted(set(native), key=lambda p: (-len(p.parts), str(p))):
            run(["codesign", "--force", "--sign", identity, *options, str(path)])
        manifest = refresh_manifest(app, lock)
        provenance = {"status": "candidate", **before,
                      "configuration": "release", "architecture": "arm64", "version": version,
                      "unsigned_binary_sha256": input_hashes, "runtime_lock_sha256": digest_file(lock),
                      "native_relocations": native_relocations,
                      "runtime_manifest_sha256": digest_file(resources / "runtime-manifest.json"),
                      "qa_identifier": qa, "signing": "ad-hoc" if identity == "-" else "developer-id",
                      "notarization": "not_performed", "distribution_ready": False}
        provenance["additional_native_code"] = {"Contents/Helpers/" + name: digest_file(contents / "Helpers" / name)
                                               for name in ("SyncHost", "FinancialProjection")}
        (resources / "build-provenance.json").write_text(json.dumps(provenance, sort_keys=True, indent=2) + "\n")
        run(["codesign", "--force", "--sign", identity, *options, str(app)])
        for path in native:
            run(["codesign", "--verify", "--strict", str(path)])
        run(["codesign", "--verify", "--strict", str(app)])
        if source_identity(root, allow_dirty) != before or any(digest_file(path) != input_hashes[name] for name, path in binaries.items()):
            raise ValueError("Build inputs changed during packaging")
        # Atomic publication follows all checks. Never replace an earlier artifact.
        rename = ctypes.CDLL(None, use_errno=True).renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        if rename(os.fsencode(app), os.fsencode(destination), 0x00000004) != 0:  # RENAME_EXCL
            error = ctypes.get_errno()
            raise OSError(error, "Candidate publication failed")
    return {"status": "candidate", "app": str(destination), "version": version["app_version"],
            "build": version["build_number"], "runtime_files": len(manifest["files"]),
            "provenance_sha256": digest_file(destination / "Contents/Resources/build-provenance.json"),
            "distribution_ready": False, "installed": False, "launched": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--destination", type=Path, required=True)
    parser.add_argument("--cache", type=Path, default=Path(".scratch/release-runtime/artifacts"))
    parser.add_argument("--identity", default="-")
    parser.add_argument("--qa", action="store_true")
    parser.add_argument("--allow-dirty", action="store_true")
    args = parser.parse_args()
    try:
        result = package(args.root, args.destination, args.cache, identity=args.identity,
                         qa=args.qa, allow_dirty=args.allow_dirty)
    except (OSError, ValueError, subprocess.SubprocessError):
        print(json.dumps({"status": "failed", "code": "PACKAGE_FAILED",
                          "action": "Check committed inputs, complete Release executables, runtime lock and signing identity."}))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
