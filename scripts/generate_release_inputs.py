"""Generate native build inputs from the committed product version.

This command does not build, sign, install, launch, or read a user workspace.
The XcodeGen template stays in version control; generated files stay local.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import tempfile
from pathlib import Path

try:
    from .release_contracts import parse_json, validate_contract
except ImportError:  # Direct invocation from the exported source package.
    from release_contracts import parse_json, validate_contract


ROOT = Path(__file__).resolve().parents[1]


def load_version(root: Path) -> dict:
    return validate_contract("release-version", parse_json(
        (root / "config/release-version.json").read_bytes()))


def _replace_one(text: str, pattern: str, replacement: str) -> str:
    result, count = re.subn(pattern, lambda _: replacement, text, flags=re.MULTILINE)
    if count != 1:
        raise ValueError(f"XcodeGen template no longer has one expected entry: {pattern}")
    return result


def atomic_write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".generated-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def generate(root: Path = ROOT, *, team: str | None = None, qa: bool = False) -> dict:
    root = root.resolve()
    version = load_version(root)
    if team is not None and not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise ValueError("Signing team must be an explicit ten-character identifier")
    folder = root / "native/FamilyReviewIOS"
    source = folder / "project.yml"
    text = source.read_text()
    text = _replace_one(text, r"^    iOS:.*$", f"    iOS: '{version['ios_minimum']}'")
    text = _replace_one(text, r"^    DEVELOPMENT_TEAM:.*$", f"    DEVELOPMENT_TEAM: '{team or ''}'")
    text = _replace_one(text, r"^    MARKETING_VERSION:.*$", f"    MARKETING_VERSION: '{version['app_version']}'")
    text = _replace_one(text, r"^    CURRENT_PROJECT_VERSION:.*$", f"    CURRENT_PROJECT_VERSION: '{version['build_number']}'")
    text = _replace_one(text, r"^        CFBundleShortVersionString:.*$", f"        CFBundleShortVersionString: '{version['app_version']}'")
    text = _replace_one(text, r"^        CFBundleVersion:.*$", f"        CFBundleVersion: '{version['build_number']}'")
    # XcodeGen writes this file. Never let a generated spec rewrite the tracked plist.
    text = _replace_one(text, r"^      path: FamilyReviewApp/Info\.plist$", "      path: Generated/Info.plist")
    text = _replace_one(text, r"^      - path: Bootstrap$", "      - path: Generated/Bootstrap")
    if qa:
        text = _replace_one(text, r"^    SWIFT_VERSION:.*$", "    SWIFT_VERSION: '6.0'\n    SWIFT_ACTIVE_COMPILATION_CONDITIONS: '$(inherited) FAMILY_REVIEW_QA'")
        text = _replace_one(text, r"^        PRODUCT_BUNDLE_IDENTIFIER: local\.familyreview\.FamilyReview$",
                            "        PRODUCT_BUNDLE_IDENTIFIER: local.familyreview.FamilyReview.ReleaseQA")
    else:
        # Production source exports intentionally omit UI test code. The generated
        # project must not require those excluded directories during XcodeGen.
        text, count = re.subn(r"^  FamilyReviewUITests:\n.*?(?=^schemes:)", "", text,
                             flags=re.MULTILINE | re.DOTALL)
        if count != 1:
            raise ValueError("XcodeGen template no longer has one UI test target")
        text, count = re.subn(r"^    test:\n      config: Debug\n      targets: \[FamilyReviewUITests\]\n?", "", text,
                             flags=re.MULTILINE)
        if count != 1:
            raise ValueError("XcodeGen template no longer has one UI test scheme")
    spec = folder / "project.generated.yml"
    atomic_write(spec, text.encode())
    settings = {
        "CFBundleShortVersionString": version["app_version"],
        "CFBundleVersion": str(version["build_number"]),
        "LSMinimumSystemVersion": version["macos_minimum"],
    }
    metadata = folder / "Generated/release-version.json"
    version_bytes = (json.dumps(version, sort_keys=True, indent=2) + "\n").encode()
    atomic_write(metadata, version_bytes)
    atomic_write(folder / "Generated/Bootstrap/release-version.json", version_bytes)
    bootstrap = folder / "Generated/Bootstrap/bootstrap.json"
    atomic_write(bootstrap, (json.dumps({"kind": "empty",
                                       "workspace_created": False}, sort_keys=True) + "\n").encode())
    return {"status": "generated", "version": version, "project_spec": str(spec),
            "bootstrap": str(bootstrap),
            "mac_info_properties": settings, "qa": qa, "signing_team_configured": team is not None,
            "side_effects": ["generated_build_inputs_only"]}


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--team", help="Explicit build signing team; no developer-specific default")
    parser.add_argument("--qa", action="store_true", help="Use an independent QA bundle identifier")
    args = parser.parse_args()
    print(json.dumps(generate(args.root, team=args.team, qa=args.qa), ensure_ascii=False))


if __name__ == "__main__":
    main()
