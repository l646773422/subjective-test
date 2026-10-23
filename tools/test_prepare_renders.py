"""Adapter checks use small valid images; real images remain outside Git."""

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from prepare_renders import file_hash, inspect, prepare, write_json
from study_data import StudyError, load_study


ROOT = Path(__file__).resolve().parents[1]


class PrepareRendersTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="renders-adapter-test-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.source = self.base / "original"
        self.scene = self.source / "arbitrary_renders"
        self.config = self.base / "adapter.json"
        self.entry = {"id": "arbitrary", "directory": self.scene.name,
                      "views": {"00000.png": 7, "00001.png": 42}}
        self.write_config()
        for frame in (0, 1):
            folder = self.scene / f"frame{frame:06d}" / "test" / "primitive"
            for side, example in (("gt", "a.png"), ("renders", "b.png")):
                (folder / side).mkdir(parents=True)
                for name in self.entry["views"]:
                    shutil.copyfile(ROOT / "examples/study-v2/images" / example, folder / side / name)
            write_json(folder / "per_view_count.json", {"00000.png": 10, "00001.png": 20})

    def write_config(self):
        write_json(self.config, {"schema": 1, "sequences": [self.entry]})

    def test_inventory_checks_every_frame_and_pair(self):
        result = inspect(self.source)
        self.assertEqual((result["pairs"], result["images"]), (4, 8))
        self.assertEqual(result["sequences"][0]["frames"], 2)
        self.assertEqual(result["sequences"][0]["perViewCountFiles"], 2)

    def test_reproducible_conversion_preserves_bytes_and_explicit_camera_ids(self):
        before = {str(p): file_hash(p) for p in self.source.rglob("*") if p.is_file()}
        first, second = self.base / "first", self.base / "second"
        result = prepare(self.source, first, self.config, seed=17)
        prepare(self.source, second, self.config, seed=17)
        self.assertEqual((first / "study.json").read_bytes(), (second / "study.json").read_bytes())
        self.assertEqual(result["scheduledResponses"], 4)
        study = load_study(first)
        self.assertTrue(study["isDemo"])
        self.assertNotIn("profile", study["analysis"])
        self.assertEqual({i["metadata"]["view"] for i in study["items"]}, {7, 42})
        manifest = json.loads((first / "source-manifest.json").read_text(encoding="utf-8"))
        for asset in manifest["assets"]:
            self.assertEqual(file_hash(first / asset["path"]), file_hash(self.source / asset["source"]))
        self.assertEqual(before, {str(p): file_hash(p) for p in self.source.rglob("*") if p.is_file()})

    def test_frame_override_and_overwrite_protection(self):
        self.entry["frame"] = 1
        self.write_config()
        destination = self.base / "study"
        result = prepare(self.source, destination, self.config)
        self.assertEqual(result["selectedFrames"], {"arbitrary": 1})
        with self.assertRaisesRegex(StudyError, "already exists"):
            prepare(self.source, destination, self.config)
        with self.assertRaisesRegex(StudyError, "read-only source"):
            prepare(self.source, self.source / "nested", self.config)

    def test_unpaired_later_frame_is_not_silently_skipped(self):
        (self.scene / "frame000001/test/primitive/renders/00001.png").unlink()
        with self.assertRaisesRegex(StudyError, "do not match"):
            prepare(self.source, self.base / "study", self.config)
        self.assertFalse((self.base / "study").exists())

    def test_camera_mapping_must_cover_source_exactly(self):
        self.entry["views"] = {"00000.png": 0, "00002.png": 20}
        self.write_config()
        with self.assertRaisesRegex(StudyError, "does not cover"):
            prepare(self.source, self.base / "study", self.config)

    def test_duplicate_frame_ids_and_corrupt_headers_fail(self):
        shutil.copytree(self.scene / "frame000001", self.scene / "frame1")
        with self.assertRaisesRegex(StudyError, "duplicate numeric"):
            inspect(self.source)
        shutil.rmtree(self.scene / "frame1")
        (self.scene / "frame000001/test/primitive/gt/00000.png").write_bytes(b"not a PNG")
        with self.assertRaisesRegex(StudyError, "invalid PNG header"):
            inspect(self.source)


if __name__ == "__main__":
    unittest.main()
