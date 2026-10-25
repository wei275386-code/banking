"""Stage Mac distribution artifacts; never install, launch, or import user data."""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import plistlib
import queue
import re
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path

if __package__:
    from .package_macos_release import package, source_identity
    from .release_contracts import digest_file
    from .ios_artifact import controlled_environment
    from .tool_locations import macos_directory, resolve_command, tool_path
else:
    from package_macos_release import package, source_identity
    from release_contracts import digest_file
    from ios_artifact import controlled_environment
    from tool_locations import macos_directory, resolve_command, tool_path


class DistributionError(ValueError):
    """Safe public error code; never echo command output or credentials."""


def run(command, **kwargs):
    kwargs.setdefault("text", True)
    kwargs['env'] = controlled_environment()
    return subprocess.run([str(x) for x in resolve_command(command)], check=True, capture_output=True,
                          timeout=20, **kwargs)


def committed_inputs(root: Path, source: dict):
    for name, expected in source["source_files"].items():
        path = Path(name)
        if path.is_absolute() or ".." in path.parts:
            raise DistributionError("UNSAFE_SOURCE_PROVENANCE")
        # A clean worktree alone does not exclude ignored, uncommitted inputs.
        content = run(["git", "cat-file", "blob", source["commit"] + ":" + name],
                      cwd=root, text=False).stdout
        if hashlib.sha256(content).hexdigest() != expected:
            raise DistributionError("COMMITTED_SOURCE_MISMATCH")


def write_receipt(path: Path, value: dict):
    temporary = path.with_suffix(".tmp")
    with temporary.open("w", encoding="utf-8") as handle:
        json.dump(value, handle, indent=2, sort_keys=True, ensure_ascii=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(path)
    descriptor = os.open(path.parent, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


@contextlib.contextmanager
def locked_receipt(path: Path):
    if (path.is_symlink() or not path.is_file() or path.parent.is_symlink()
            or path.parent.resolve().is_relative_to(macos_directory('applications').resolve())):
        raise DistributionError("UNSAFE_RECEIPT")
    with path.with_suffix(".lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise DistributionError("RECEIPT_BUSY") from None
        value = json.loads(path.read_text())
        if value.get('mode') not in ('candidate', 'developer-id'):
            raise DistributionError("INVALID_RECEIPT")
        yield value


def stage_file(stage: Path, name: str) -> Path:
    # Receipt paths are basenames; editing a receipt cannot target installed Apps.
    if stage.is_symlink() or stage.resolve().is_relative_to(macos_directory('applications').resolve()):
        raise DistributionError("UNSAFE_STAGING_DIRECTORY")
    if not isinstance(name, str) or Path(name).name != name or name in (".", ".."):
        raise DistributionError("UNSAFE_ARTIFACT_PATH")
    path = stage / name
    if path.is_symlink():
        raise DistributionError("UNSAFE_ARTIFACT_PATH")
    return path


def tree_digest(app: Path) -> str:
    rows = []
    for path in sorted(app.rglob("*")):
        relative = path.relative_to(app).as_posix()
        if path.is_symlink():
            if not path.resolve().is_relative_to(app.resolve()):
                raise DistributionError("EXTERNAL_APP_SYMLINK")
            rows.append([relative, "symlink", os.readlink(path)])
        elif path.is_file():
            rows.append([relative, digest_file(path), path.stat().st_mode & 0o777])
        elif not path.is_dir():
            raise DistributionError("UNSUPPORTED_APP_ENTRY")
    return hashlib.sha256(json.dumps(rows, separators=(",", ":")).encode()).hexdigest()


def preflight(mode: str, identity: str | None, profile: str | None, runner=run) -> dict:
    if mode == "candidate":
        if identity or profile:
            raise DistributionError("CANDIDATE_USES_AD_HOC_ONLY")
        return {"identity": "-", "profile": None}
    if mode != "developer-id" or not identity or not re.fullmatch(
            r"Developer ID Application: .+ \([A-Z0-9]{10}\)", identity):
        raise DistributionError("EXPLICIT_DEVELOPER_ID_REQUIRED")
    if not profile or not re.fullmatch(r"[A-Za-z0-9_.-]{1,128}", profile):
        raise DistributionError("EXPLICIT_KEYCHAIN_PROFILE_REQUIRED")
    inventory = runner([tool_path('security', system=True), "find-identity", "-v", "-p", "codesigning"]).stdout
    if '"' + identity + '"' not in inventory:
        raise DistributionError("DEVELOPER_ID_UNAVAILABLE")
    developer = Path(runner([tool_path('xcode-select', system=True), "-p"]).stdout.strip())
    notary = developer / "usr/bin/notarytool"
    stapler = developer / "usr/bin/stapler"
    if not notary.is_file() or not stapler.is_file():
        raise DistributionError("NOTARY_TOOLS_UNAVAILABLE")
    # XcodeBuildMCP has no notarization/stapling workflow. Use Xcode's canonical
    # binaries directly; never raw xcrun, xcodebuild, or simctl.
    runner([notary, "history", "--keychain-profile", profile, "--output-format", "json"])
    return {"identity": identity, "profile": profile,
            "notarytool": str(notary), "stapler": str(stapler)}


def verify_app(app: Path, mode: str, identity: str, runner=run) -> dict:
    if app.suffix != ".app" or app.is_symlink() or not app.is_dir():
        raise DistributionError("INVALID_APP")
    tree_digest(app)
    resources = app / "Contents/Resources"
    provenance = json.loads((resources / "build-provenance.json").read_text())
    bootstrap = json.loads((resources / "bootstrap.json").read_text())
    manifest_path = resources / "runtime-manifest.json"
    manifest = json.loads(manifest_path.read_text())
    if bootstrap.get("kind") != "empty" or bootstrap.get("workspace_created") is not False:
        raise DistributionError("EMPTY_BOOTSTRAP_REQUIRED")
    if (provenance.get('configuration') != 'release' or provenance.get('architecture') != 'arm64' or provenance.get('runtime_manifest_sha256') != digest_file(manifest_path)):
        raise DistributionError("INVALID_BUILD_PROVENANCE")
    expected_signing = "ad-hoc" if mode == "candidate" else "developer-id"
    if provenance.get("signing") != expected_signing:
        raise DistributionError("SIGNING_MODE_MISMATCH")
    if mode == "developer-id" and (provenance.get("dirty") is not False
                                     or provenance.get("qa_identifier") is not False):
        raise DistributionError("CLEAN_PRODUCTION_COMMIT_REQUIRED")
    with (app / "Contents/Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    version = provenance["version"]
    if (info.get("CFBundleIdentifier") != "local.banking.family-review" +
            (".ReleaseQA" if provenance.get("qa_identifier") else "")
            or info.get("CFBundleShortVersionString") != version["app_version"]
            or info.get("CFBundleVersion") != str(version["build_number"])):
        raise DistributionError("APP_VERSION_OR_ID_MISMATCH")
    for record in manifest["files"]:
        target = app / record["path"]
        if not target.resolve().is_relative_to(app.resolve()) or not target.is_file():
            raise DistributionError("INVALID_RUNTIME_INVENTORY")
        actual = (hashlib.sha256(os.readlink(target).encode()).hexdigest()
                  if record["kind"] == "symlink" and target.is_symlink() else digest_file(target))
        if actual != record["sha256"]:
            raise DistributionError("RUNTIME_FILE_CHANGED")
    extra = provenance["additional_native_code"]
    native = set(manifest["native_code"]) | set(extra) | {"Contents/MacOS/EvidenceBrowser", "Contents/Helpers/SyncHost"}
    for relative in sorted(native):
        target = app / relative
        if not target.resolve().is_relative_to(app.resolve()) or not target.is_file():
            raise DistributionError("INVALID_NATIVE_INVENTORY")
        if relative in extra and digest_file(target) != extra[relative]:
            raise DistributionError("NATIVE_FILE_CHANGED")
        runner([tool_path('codesign', system=True), "--verify", "--strict", target])
        if mode == "developer-id":
            details = runner([tool_path('codesign', system=True), "--display", "--verbose=4", target])
            text = details.stdout + details.stderr
            if "Authority=" + identity not in text or not re.search(r"flags=.*\bruntime\b", text):
                raise DistributionError("DEVELOPER_ID_HARDENING_REQUIRED")
    runner([tool_path('codesign', system=True), "--verify", "--strict", app])
    if mode == "developer-id":
        details = runner([tool_path('codesign', system=True), "--display", "--verbose=4", app])
        if "Authority=" + identity not in details.stdout + details.stderr:
            raise DistributionError("APP_IDENTITY_MISMATCH")
    return provenance


def make_dmg(stage: Path, receipt: dict, runner=run):
    app = stage_file(stage, receipt["app"])
    dmg = stage_file(stage, receipt["dmg"])
    if not dmg.exists():
        with tempfile.TemporaryDirectory(prefix=".dmg-stage-", dir=stage) as temporary:
            payload = Path(temporary) / "payload"
            payload.mkdir()
            copied = payload / app.name
            runner([tool_path('ditto', system=True), app, copied])
            if tree_digest(app) != tree_digest(copied):
                raise DistributionError("APP_COPY_CHANGED")
            # This is a drag-install affordance, not an installation action.
            (payload / "Applications").symlink_to(macos_directory('applications'))
            pending = Path(temporary) / "image.dmg"
            runner([tool_path('hdiutil', system=True), "create", "-format", "UDZO", "-fs", "HFS+", "-volname",
                    "Family Review", "-srcfolder", payload, pending])
            if receipt["mode"] == "developer-id":
                runner([tool_path('codesign', system=True), "--sign", receipt["tools"]["identity"], "--timestamp", pending])
            runner([tool_path('hdiutil', system=True), "verify", pending])
            os.link(pending, dmg)  # exclusive publication; never overwrite a previous DMG
    runner([tool_path('hdiutil', system=True), "verify", dmg])
    if receipt["mode"] == "developer-id":
        runner([tool_path('codesign', system=True), "--verify", "--strict", dmg])
        details = runner([tool_path('codesign', system=True), "--display", "--verbose=4", dmg])
        if "Authority=" + receipt["tools"]["identity"] not in details.stdout + details.stderr:
            raise DistributionError("DMG_IDENTITY_MISMATCH")
    verify_dmg_contents(stage, receipt, dmg, runner, tickets=False)
    receipt["artifacts"]["dmg"] = {"name": dmg.name, "sha256": digest_file(dmg), "state": "prepared"}


def prepare(root: Path, stage: Path, *, app: Path | None = None, build: bool = False,
            mode="candidate", identity=None, profile=None, cache=None,
            qa=False, allow_dirty=False, runner=run) -> dict:
    root, stage = root.resolve(), stage.absolute()
    if build == (app is not None):
        raise DistributionError("CHOOSE_PREBUILT_APP_OR_BUILD")
    if stage.exists() or stage.is_symlink() or stage.resolve().is_relative_to(macos_directory('applications').resolve()):
        raise DistributionError("NEW_STAGING_DIRECTORY_REQUIRED")
    if mode == "developer-id" and (qa or allow_dirty):
        raise DistributionError("CLEAN_PRODUCTION_COMMIT_REQUIRED")
    tools = preflight(mode, identity, profile, runner)
    before = source_identity(root, allow_dirty=mode == "candidate")
    if mode == "developer-id" and before["dirty"]:
        raise DistributionError("CLEAN_PRODUCTION_COMMIT_REQUIRED")
    if mode == "developer-id":
        committed_inputs(root, before)
    if build:
        # Help-first discovery; explicit package/configuration prevent local iOS
        # session defaults from silently selecting a different build target.
        runner(["xcodebuildmcp", "--help"], cwd=root)
        runner(["xcodebuildmcp", "tools"], cwd=root)
        runner(["xcodebuildmcp", "swift-package", "build", "--help"], cwd=root)
        config = root / ".xcodebuildmcp/config.yaml"
        if config.exists():
            config.read_text()  # inspect defaults without copying or printing them
        runner(["xcodebuildmcp", "swift-package", "build", "--package-path",
                root / "native/PaymentImageCore", "--configuration", "release",
                "--architectures", "arm64"], cwd=root)
    stage.mkdir(parents=True)
    staged_app = stage / "FamilyReview.app"
    if build:
        package(root, staged_app, cache or root / ".scratch/release-runtime/artifacts",
                identity=tools["identity"], allow_dirty=allow_dirty, qa=qa)
    else:
        verify_app(app, mode, tools["identity"], runner)
        runner([tool_path('ditto', system=True), app, staged_app])
        if tree_digest(app) != tree_digest(staged_app):
            raise DistributionError("APP_COPY_CHANGED")
    provenance = verify_app(staged_app, mode, tools["identity"], runner)
    keys = ("commit", "dirty", "source_input_sha256", "source_files")
    if any(provenance.get(key) != before[key] for key in keys) or source_identity(root, mode == "candidate") != before:
        raise DistributionError("APP_SOURCE_PROVENANCE_MISMATCH")
    if provenance["runtime_lock_sha256"] != digest_file(root / "release/runtime-lock.json"):
        raise DistributionError("RUNTIME_LOCK_MISMATCH")
    version = provenance["version"]
    name = f"FamilyReview-{version['app_version']}-{version['build_number']}-{uuid.uuid4().hex[:12]}"
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
        raise DistributionError("UNSAFE_RELEASE_VERSION")
    receipt = {"release_status": "candidate", "mode": mode,
               "phase": "prepared", "app": staged_app.name, "dmg": name + ".dmg",
               "tools": tools, "source": {key: before[key] for key in keys},
               "provenance_sha256": digest_file(staged_app / "Contents/Resources/build-provenance.json"),
               "app_sha256": tree_digest(staged_app), "artifacts": {},
               "distribution_ready": False, "installed": False, "launched": False}
    if mode == "candidate":
        make_dmg(stage, receipt, runner)
        receipt["phase"] = "candidate_dmg"
    else:
        archive = stage / (name + ".zip")
        runner([tool_path('ditto', system=True), "-c", "-k", "--keepParent", staged_app, archive])
        receipt["artifacts"]["app"] = {"name": archive.name, "sha256": digest_file(archive), "state": "prepared"}
        receipt["phase"] = "app_prepared"
    write_receipt(stage / "distribution-receipt.json", receipt)
    return summary(stage / "distribution-receipt.json", receipt)


def upload(command, on_id, timeout=20):
    """Persist ID as soon as Apple emits it, including a subsequently timed-out upload."""
    process = subprocess.Popen([str(x) for x in command], stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True, start_new_session=True,
                               env=controlled_environment())
    lines = queue.Queue()

    def reader():
        for line in process.stdout:
            lines.put(line)
        lines.put(None)

    thread = threading.Thread(target=reader, daemon=True)
    thread.start()
    deadline, found = time.monotonic() + timeout, None
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise DistributionError("UPLOAD_TIMEOUT_RESUME_RECEIPT")
            try:
                line = lines.get(timeout=remaining)
            except queue.Empty:
                raise DistributionError("UPLOAD_TIMEOUT_RESUME_RECEIPT") from None
            if line is None:
                break
            match = re.search(r"\bid:\s*([0-9a-fA-F-]{36})\b", line)
            if match:
                identifier = str(uuid.UUID(match.group(1)))
                if found and found != identifier:
                    raise DistributionError("CONFLICTING_SUBMISSION_ID")
                found = identifier
                on_id(found)
        if process.wait(timeout=max(0.01, deadline - time.monotonic())) != 0:
            raise DistributionError("UPLOAD_FAILED_RESUME_RECEIPT")
        if not found:
            raise DistributionError("SUBMISSION_ID_UNKNOWN")
    finally:
        if process.poll() is None:
            import signal
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)
        process.stdout.close()


def active_kind(receipt):
    return "dmg" if "dmg" in receipt["artifacts"] else "app"


def check_artifact(stage, artifact):
    path = stage_file(stage, artifact["name"])
    if not path.is_file() or digest_file(path) != artifact["sha256"]:
        raise DistributionError("ARTIFACT_CHANGED")
    return path


def check_provenance(app, receipt):
    if digest_file(app / "Contents/Resources/build-provenance.json") != receipt["provenance_sha256"]:
        raise DistributionError("APP_PROVENANCE_CHANGED")


def submit(receipt_path: Path, runner=run, uploader=upload) -> dict:
    with locked_receipt(receipt_path) as receipt:
        if receipt["mode"] != "developer-id":
            raise DistributionError("CANDIDATE_CANNOT_NOTARIZE")
        kind = active_kind(receipt)
        artifact = receipt["artifacts"][kind]
        if artifact["state"] != "prepared":
            raise DistributionError("RESUME_EXISTING_SUBMISSION")
        artifact_path = check_artifact(receipt_path.parent, artifact)
        app = stage_file(receipt_path.parent, receipt["app"])
        check_provenance(app, receipt)
        verify_app(app, "developer-id", receipt["tools"]["identity"], runner)
        if tree_digest(app) != receipt["app_sha256"]:
            raise DistributionError("APP_CHANGED")
        artifact["state"] = "submission_started"
        receipt["phase"] = kind + "_pending"
        write_receipt(receipt_path, receipt)  # durable fence before any external upload

        def record(identifier):
            artifact["submission_id"] = identifier
            artifact["state"] = "submitted"
            write_receipt(receipt_path, receipt)

        uploader([receipt["tools"]["notarytool"], "submit", artifact_path,
                  "--keychain-profile", receipt["tools"]["profile"], "--no-wait", "--no-progress"], record)
        return summary(receipt_path, receipt)


def verify_dmg_contents(stage: Path, receipt: dict, dmg: Path, runner=run, *, tickets=True):
    mount = stage / "verify-mount"
    if mount.is_symlink():
        raise DistributionError("UNSAFE_MOUNT_DIRECTORY")
    mount.mkdir(exist_ok=True)
    runner([tool_path('hdiutil', system=True), "attach", "-readonly", "-nobrowse", "-noautoopen",
            "-mountpoint", mount, dmg])
    try:
        app = mount / receipt["app"]
        verify_app(app, receipt["mode"], receipt["tools"]["identity"], runner)
        if tree_digest(app) != receipt["app_sha256"]:
            raise DistributionError("DMG_APP_CHANGED")
        if tickets:
            runner([receipt["tools"]["stapler"], "validate", app])
            runner([tool_path('spctl', system=True), "--assess", "--type", "execute", app])
    finally:
        runner([tool_path('hdiutil', system=True), "detach", mount])


def validate_final(stage: Path, receipt: dict, dmg: Path, runner=run):
    runner([receipt["tools"]["stapler"], "validate", dmg])
    runner([tool_path('hdiutil', system=True), "verify", dmg])
    runner([tool_path('codesign', system=True), "--verify", "--strict", dmg])
    details = runner([tool_path('codesign', system=True), "--display", "--verbose=4", dmg])
    if "Authority=" + receipt["tools"]["identity"] not in details.stdout + details.stderr:
        raise DistributionError("DMG_IDENTITY_MISMATCH")
    runner([tool_path('spctl', system=True), "--assess", "--type", "open", "--context", "context:primary-signature", dmg])
    verify_dmg_contents(stage, receipt, dmg, runner)


def resume(receipt_path: Path, *, submission_id=None, runner=run) -> dict:
    with locked_receipt(receipt_path) as receipt:
        if receipt["mode"] != "developer-id":
            raise DistributionError("CANDIDATE_CANNOT_NOTARIZE")
        if receipt["phase"] == "distribution_verified":
            receipt["distribution_ready"] = False
            receipt["phase"] = "dmg_pending"
            write_receipt(receipt_path, receipt)
            final = check_artifact(receipt_path.parent / "final", receipt["final"])
            validate_final(receipt_path.parent, receipt, final, runner)
            receipt["distribution_ready"] = True
            receipt["phase"] = "distribution_verified"
            write_receipt(receipt_path, receipt)
            return summary(receipt_path, receipt)
        kind = active_kind(receipt)
        artifact = receipt["artifacts"][kind]
        uploaded = check_artifact(receipt_path.parent, artifact)
        identifier = artifact.get("submission_id")
        if submission_id:
            submission_id = str(uuid.UUID(submission_id))
            if identifier and identifier != submission_id:
                raise DistributionError("SUBMISSION_ID_MISMATCH")
            if artifact["state"] == "prepared":
                raise DistributionError("NO_SUBMISSION_STARTED")
            identifier = submission_id
        if not identifier:
            raise DistributionError("SUBMISSION_ID_UNKNOWN_RECOVER_FROM_HISTORY")
        tools = receipt["tools"]
        info = json.loads(runner([tools["notarytool"], "info", identifier,
                                  "--keychain-profile", tools["profile"], "--output-format", "json"]).stdout)
        if info.get("id") != identifier or info.get("name") != artifact["name"]:
            raise DistributionError("NOTARY_RECEIPT_MISMATCH")
        artifact["submission_id"] = identifier
        artifact["notary_status"] = info.get("status")
        artifact["state"] = "submitted"
        write_receipt(receipt_path, receipt)
        if info.get("status") == "In Progress":
            return summary(receipt_path, receipt)
        if info.get("status") != "Accepted":
            artifact["state"] = "rejected"
            receipt["phase"] = kind + "_rejected"
            write_receipt(receipt_path, receipt)
            raise DistributionError("NOTARIZATION_REJECTED")
        artifact["state"] = "accepted"
        write_receipt(receipt_path, receipt)
        app = stage_file(receipt_path.parent, receipt["app"])
        check_provenance(app, receipt)
        verify_app(app, "developer-id", tools["identity"], runner)
        if kind == "app":
            runner([tools["stapler"], "staple", app])
            runner([tools["stapler"], "validate", app])
            verify_app(app, "developer-id", tools["identity"], runner)
            receipt["app_sha256"] = tree_digest(app)
            write_receipt(receipt_path, receipt)
            make_dmg(receipt_path.parent, receipt, runner)
            receipt["phase"] = "dmg_prepared"
        else:
            final = receipt_path.parent / "final"
            if final.is_symlink():
                raise DistributionError("UNSAFE_STAGING_DIRECTORY")
            final.mkdir(exist_ok=True)
            destination = stage_file(final, artifact["name"])
            # Keep the uploaded DMG immutable; retries restage the final copy.
            runner([tool_path('ditto', system=True), uploaded, destination])
            runner([tools["stapler"], "staple", destination])
            validate_final(receipt_path.parent, receipt, destination, runner)
            receipt["final"] = {"name": destination.name, "sha256": digest_file(destination)}
            receipt["phase"] = "distribution_verified"
            receipt["distribution_ready"] = True
            receipt["checks"] = {"app_ticket": "verified", "dmg_ticket": "verified",
                                  "gatekeeper_app": "accepted", "gatekeeper_dmg": "accepted"}
        write_receipt(receipt_path, receipt)
        return summary(receipt_path, receipt)


def summary(path, receipt):
    return {"status": receipt["release_status"], "phase": receipt["phase"],
            "receipt": str(path), "distribution_ready": receipt["distribution_ready"],
            "installed": False, "launched": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("prepare")
    create.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    create.add_argument("--staging", type=Path, required=True)
    source = create.add_mutually_exclusive_group(required=True)
    source.add_argument("--app", type=Path)
    source.add_argument("--build", action="store_true")
    create.add_argument("--mode", choices=("candidate", "developer-id"), default="candidate")
    create.add_argument("--identity")
    create.add_argument("--keychain-profile", dest="profile")
    create.add_argument("--cache", type=Path)
    create.add_argument("--qa", action="store_true")
    create.add_argument("--allow-dirty", action="store_true")
    for command in ("submit", "resume"):
        child = commands.add_parser(command)
        child.add_argument("--receipt", type=Path, required=True)
        if command == "resume":
            child.add_argument("--submission-id", help="Recover an interrupted upload ID from Notary history; never reupload")
    args = vars(parser.parse_args())
    command = args.pop("command")
    try:
        if command == "prepare":
            result = prepare(args.pop("root"), args.pop("staging"), **args)
        elif command == "submit":
            result = submit(args["receipt"])
        else:
            result = resume(args["receipt"], submission_id=args["submission_id"])
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        code = str(error) if isinstance(error, DistributionError) else "DISTRIBUTION_FAILED"
        print(json.dumps({"status": "candidate", "code": code, "distribution_ready": False,
                          "installed": False, "launched": False}))
        return 1
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
