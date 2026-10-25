"""Package the native household financial review App for this local Mac."""
import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from datetime import datetime, timezone

if __package__:
    from .mac_app_install import default_app_path, BUNDLE_ID, install_lock, install_staged
    from .app_icon import write_app_icon
else:
    from mac_app_install import default_app_path, BUNDLE_ID, install_lock, install_staged
    from app_icon import write_app_icon


def source_digest(root):
    package = root / 'native/PaymentImageCore'
    sources = sorted(path for path in (package / 'Sources').rglob('*') if path.is_file()) + [package / 'Package.swift']
    digest = hashlib.sha256()
    for path in sources:
        digest.update(str(path.relative_to(root)).encode() + b'\0' + path.read_bytes() + b'\0')
    return digest.hexdigest()


def bundle(root, output, configuration="release", app_path=None):
    root, output = Path(root).resolve(), Path(output).resolve()
    production_app = default_app_path()
    app = Path(app_path).absolute() if app_path else production_app
    if configuration not in ("debug", "release"):
        raise ValueError("Unknown build configuration")
    if app == production_app and configuration != 'release':
        raise ValueError('Production App requires Release; use --app-path for an isolated Debug App')
    if not output.is_dir():
        raise ValueError('The review data directory does not exist')
    binary = root / f"native/PaymentImageCore/.build/{configuration}/EvidenceBrowser"
    if not binary.exists():
        raise ValueError("Build the EvidenceBrowser Swift Package product first")
    sources = [path for path in (root / "native/PaymentImageCore/Sources").rglob('*') if path.is_file()]
    sources.append(root / "native/PaymentImageCore/Package.swift")
    if any(path.stat().st_mtime > binary.stat().st_mtime for path in sources):
        raise ValueError("Executable is stale. Build the whole Swift Package (without --target-name) so executable products are linked before bundling.")
    app.parent.mkdir(parents=True, exist_ok=True)
    with install_lock(app), tempfile.TemporaryDirectory(prefix='.family-review-install-', dir=app.parent) as temporary:
        candidate = Path(temporary) / '家庭财务复盘.app'
        contents = candidate / 'Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Resources').mkdir()
        provenance = {'configuration': configuration, 'source_sha256': source_digest(root),
                      'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest(),
                      'packaged_at': datetime.now(timezone.utc).isoformat()}
        shutil.copy2(binary, contents / 'MacOS/EvidenceBrowser')
        if hashlib.sha256((contents / 'MacOS/EvidenceBrowser').read_bytes()).hexdigest() != provenance['binary_sha256']:
            raise ValueError('Executable changed during packaging; rebuild and retry')
        write_app_icon(root, contents / 'Resources/AppIcon.icns')
        identity = BUNDLE_ID if app == production_app else BUNDLE_ID + '.qa-' + hashlib.sha256(str(app).encode()).hexdigest()[:12]
        (contents / 'Info.plist').write_bytes(plistlib.dumps({
            'CFBundleExecutable': 'EvidenceBrowser', 'CFBundleIdentifier': identity,
            'CFBundleName': '家庭财务复盘', 'CFBundleDisplayName': '家庭财务复盘', 'CFBundlePackageType': 'APPL',
            'CFBundleIconFile': 'AppIcon.icns',
            'CFBundleShortVersionString': '0.17', 'CFBundleVersion': '17', 'LSMinimumSystemVersion': '14.0',
            'NSHighResolutionCapable': True, 'NSPrincipalClass': 'NSApplication'}))
        (contents / 'Resources/evidence-location.json').write_text(json.dumps({'folder': str(output)}))
        (contents / 'Resources/processor-location.json').write_text(json.dumps({
            'project': str(root), 'python': sys.executable}))
        # Signing changes Mach-O bytes; record the unsigned build input, not a
        # self-referential hash of an executable signing this same manifest.
        (contents / 'Resources/build-provenance.json').write_text(json.dumps(provenance, indent=2))
        subprocess.run(['codesign', '--force', '--sign', '-', str(candidate)], check=True, capture_output=True, timeout=15)
        subprocess.run(['codesign', '--verify', '--strict', str(candidate)], check=True, capture_output=True, timeout=15)
        if source_digest(root) != provenance['source_sha256'] or hashlib.sha256(binary.read_bytes()).hexdigest() != provenance['binary_sha256']:
            raise ValueError('Sources or executable changed during packaging; rebuild and retry')
        install_staged(candidate, app, root, output)
    return str(app)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--configuration", choices=["debug", "release"], default="release")
    parser.add_argument("--app-path", type=Path, help="Explicit bundle destination for isolated QA; default is the OS applications directory")
    args = parser.parse_args()
    print(bundle(args.root, args.output, args.configuration, args.app_path))
