import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from scripts.tool_locations import tool_path
from scripts.import_review_materials import file_sha256, retain, video_helper


class ImportRuntimeHelperTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def executable(self, path):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("#!" + tool_path('sh', system=True) + "\nexit 0\n")
        path.chmod(0o755)
        return path

    def test_controlled_helper_wins_over_standalone_release_binary(self):
        bundled = self.executable(self.root / "Synthetic.app/Contents/Helpers/VideoRecords")
        self.executable(self.root / "native/PaymentImageCore/.build/release/VideoRecords")
        with patch.dict(os.environ, {"BANKING_VIDEO_HELPER": str(bundled)}, clear=True):
            self.assertEqual(video_helper(self.root), bundled)

    def test_invalid_controlled_helper_never_falls_back(self):
        self.executable(self.root / "native/PaymentImageCore/.build/release/VideoRecords")
        for value in ("relative-helper", str(self.root / "missing-helper")):
            with self.subTest(value=value), patch.dict(os.environ, {"BANKING_VIDEO_HELPER": value}, clear=True):
                with self.assertRaises(ValueError):
                    video_helper(self.root)

    def test_standalone_root_uses_release_and_never_debug(self):
        self.executable(self.root / "native/PaymentImageCore/.build/debug/VideoRecords")
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaises(ValueError):
                video_helper(self.root)
            release = self.executable(self.root / "native/PaymentImageCore/.build/release/VideoRecords")
            self.assertEqual(video_helper(self.root), release)
            release.chmod(0o644)
            with self.assertRaises(ValueError):
                video_helper(self.root)

    def test_streaming_hash_and_retention_do_not_read_entire_material(self):
        source = self.root / "inputs/synthetic.mp4"
        source.parent.mkdir()
        block = b"synthetic-video-data" * 8192
        expected = hashlib.sha256()
        with source.open("wb") as stream:
            for _ in range(20):
                stream.write(block)
                expected.update(block)
        with patch.object(Path, "read_bytes", side_effect=AssertionError("whole-file read prohibited")):
            self.assertEqual(file_sha256(source), expected.hexdigest())
            saved = retain(source, self.root / "saved")
            self.assertEqual(file_sha256(saved), expected.hexdigest())
            self.assertEqual(retain(source, self.root / "saved"), saved)
            source.write_bytes(b"changed synthetic video")
            changed = retain(source, self.root / "saved")
            self.assertNotEqual(changed, saved)
            self.assertEqual(file_sha256(saved), expected.hexdigest())
            self.assertEqual(file_sha256(changed), hashlib.sha256(b"changed synthetic video").hexdigest())


if __name__ == "__main__":
    unittest.main()
