"""Shared Mac icon generation from the committed branding asset."""
import subprocess
import tempfile
from pathlib import Path


def write_app_icon(root, destination):
    source = Path(root) / "native/FamilyReviewIOS/FamilyReviewApp/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
    if not source.is_file():
        raise ValueError("The shared AppIcon is missing")
    with tempfile.TemporaryDirectory(prefix="family-review-icon-") as temporary:
        iconset = Path(temporary) / "AppIcon.iconset"
        iconset.mkdir()
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                pixels = size * scale
                name = f"icon_{size}x{size}" + ("@2x" if scale == 2 else "") + ".png"
                subprocess.run(["sips", "-z", str(pixels), str(pixels), str(source),
                                "--out", str(iconset / name)], check=True, capture_output=True, timeout=20)
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(destination)],
                       check=True, capture_output=True, timeout=20)
