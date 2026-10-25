"""Retained update from a verified current release artifact; never uninstall.

Build/package with distribute_macos_release first; install by atomic App replacement.
"""
from __future__ import annotations
import argparse
import plistlib
import uuid
from pathlib import Path
if __package__ in (None, ''):
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from scripts.distribute_macos_release import verify_app, tree_digest, run
from scripts.app_install_primitives import default_app_path, install_lock, swap_bundles, stop_app
from scripts.tool_locations import tool_path
from scripts.release_contracts import digest_file
from scripts.installation_inventory import POLICY, InstallationError, safe_tree
from scripts.workspace_state import WorkspacePaths, MaintenanceGate, _read, _safe, _regular, _write, _sync_dir
from scripts.installation_health import health_check, runtime_health, artifact_reference


def update(app, workspace, evidence, *, preferences, artifact_receipt, installed=None, mode='candidate', identity='-',
           effective_projection_helper=None, effective_projection_pin=None, runner=run,
           qualifier=health_check, runtime_validator=runtime_health, swapper=swap_bundles, stopper=stop_app):
    """Explicit retained update. Keep the former App until first-run acceptance."""
    installed = default_app_path() if installed is None else installed
    app, installed = _safe(Path(app)), _safe(Path(installed))
    evidence, preferences = _safe(Path(evidence)), _regular(Path(preferences))
    paths = workspace if isinstance(workspace, WorkspacePaths) else WorkspacePaths(workspace)
    if evidence.exists() or not installed.is_dir() or app == installed:
        raise InstallationError('use an existing installed App, separate candidate and new evidence directory')
    for protected in (paths.workspace, installed, app):
        if evidence == protected or protected in evidence.parents or evidence in protected.parents:
            raise InstallationError('upgrade evidence must be outside App and workspace trees')
    provenance = verify_app(app, mode, identity, runner)
    authority = artifact_reference(app, artifact_receipt)
    with (installed / 'Contents/Info.plist').open('rb') as handle:
        before_app = plistlib.load(handle)
    with (app / 'Contents/Info.plist').open('rb') as handle:
        candidate_app = plistlib.load(handle)
    policy = _read(POLICY)
    if (before_app.get('CFBundleIdentifier') != candidate_app.get('CFBundleIdentifier')
            or candidate_app.get('CFBundleShortVersionString') != policy['app_version']
            or candidate_app.get('CFBundleVersion') != str(policy['build_number'])
            or provenance.get('version', {}).get('app_version') != policy['app_version']):
        raise InstallationError('retained bundle identity or candidate release version mismatch')
    candidate_hash, old_app_hash = tree_digest(app), tree_digest(installed)
    preference_hash = digest_file(preferences)
    evidence.mkdir(parents=True)
    receipt = {'operation_id': str(uuid.uuid4()), 'bundle_id': candidate_app['CFBundleIdentifier'],
        'candidate_sha256': candidate_hash, 'old_app_sha256': old_app_hash,
        'preferences_path': str(preferences), 'preferences_sha256': preference_hash,
        'workspace_path': str(paths.workspace), 'phase': 'candidate-validated',
        'installed': False, 'first_run_qualified': False, 'business_replayed': False}
    receipt_path = evidence / 'update-receipt.json'
    _write(receipt_path, receipt)
    with install_lock(installed):
        before_health = qualifier(paths, runtime_bundle=app,
            effective_projection_helper=effective_projection_helper, effective_projection_pin=effective_projection_pin,
            artifact_reference=authority)
        if not before_health.get('writable') or not before_health.get('runtime_verified'):
            raise InstallationError('candidate/workspace health does not permit an update writer')
        stopper(installed)
        expected = before_health['source_pointer']
        staging = installed.parent / ('.family-review-upgrade-' + receipt['operation_id'])
        staging.mkdir(mode=0o700)
        staged_app = staging / installed.name
        receipt['retained_old_app_path'] = str(staged_app)
        with MaintenanceGate(paths).acquire('app-upgrade') as token:
            if paths.read_pointer() != expected:
                raise InstallationError('workspace changed before update gate')
            _, before_files, before_dirs = safe_tree(paths.workspace)
            closure = {'files': before_files, 'directories': before_dirs}
            if digest_file(preferences) != preference_hash:
                raise InstallationError('preferences changed before retained update')
            receipt.update(phase='data-inventoried', rollback_pointer=expected, closure=closure, before_health=before_health)
            _write(receipt_path, receipt)
            runner([tool_path('ditto', system=True), str(app), str(staged_app)])
            verify_app(staged_app, mode, identity, runner)
            if tree_digest(staged_app) != candidate_hash or tree_digest(app) != candidate_hash:
                raise InstallationError('candidate changed during staging')
            if tree_digest(installed) != old_app_hash or paths.read_pointer() != expected:
                raise InstallationError('installed App or workspace changed before atomic replacement')
            swapped = False
            try:
                swapper(staged_app, installed)
                swapped = True
                _sync_dir(installed.parent)
                receipt.update(phase='app-replaced', installed=True)
                _write(receipt_path, receipt)
                runtime = runtime_validator(installed, artifact_reference=authority)
                if runtime.get('verified') is not True:
                    raise InstallationError('installed candidate runtime qualification failed')
                _, after_files, after_dirs = safe_tree(paths.workspace)
                if (paths.read_pointer() != expected or after_files != closure['files']
                        or after_dirs != closure['directories'] or digest_file(preferences) != preference_hash):
                    raise InstallationError('data changed during retained update')
                receipt.update(phase='installed-awaiting-first-run', after_runtime=runtime,
                    exact_bytes_preserved=True, pending_gates=['native-first-run-health-and-task-recovery'])
                _write(receipt_path, receipt)
                return receipt
            except BaseException:
                # Restore only the App, only while the complete data closure is
                # unchanged. New work/data schemas are never overwritten.
                _, current_files, current_dirs = safe_tree(paths.workspace)
                unchanged = (paths.read_pointer() == expected and current_files == closure['files']
                    and current_dirs == closure['directories'] and digest_file(preferences) == preference_hash)
                if swapped and unchanged:
                    swapper(staged_app, installed)
                    _sync_dir(installed.parent)
                    receipt.update(phase='old-app-restored-data-unchanged', installed=False)
                else:
                    receipt['phase'] = 'failed-new-work-retained-no-auto-rollback'
                _write(receipt_path, receipt)
                raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True, help='current prebuilt distribution candidate')
    parser.add_argument('--workspace', type=Path, required=True)
    parser.add_argument('--preferences', type=Path, required=True, help='explicit retained app preferences plist')
    parser.add_argument('--evidence', type=Path, required=True)
    parser.add_argument('--artifact-receipt', type=Path, required=True, help='external committed distribution receipt')
    parser.add_argument('--installed', type=Path)
    parser.add_argument('--mode', choices=['candidate', 'developer-id'], default='candidate')
    parser.add_argument('--identity', default='-')
    parser.add_argument('--effective-projection-helper', type=Path)
    parser.add_argument('--effective-projection-sha256')
    parser.add_argument('--runtime-manifest-sha256')
    args = parser.parse_args(argv)
    pin = None
    if args.effective_projection_sha256 or args.runtime_manifest_sha256:
        pin = {'sha256': args.effective_projection_sha256, 'runtime_manifest_sha256': args.runtime_manifest_sha256}
    import json
    print(json.dumps(update(args.app, args.workspace, args.evidence, preferences=args.preferences, artifact_receipt=args.artifact_receipt,
        installed=args.installed, mode=args.mode, identity=args.identity,
        effective_projection_helper=args.effective_projection_helper, effective_projection_pin=pin), ensure_ascii=False, indent=2))

if __name__ == '__main__':
    main()
