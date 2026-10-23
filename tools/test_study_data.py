"""Contract checks for the proposed format; run with unittest discovery."""

import copy
import json
import tempfile
import unittest
import zipfile
from pathlib import Path

from study_data import StudyError, load_study, migrate, normalize, summary


ROOT = Path(__file__).resolve().parents[1]


def minimal():
    return {
        "schema": 2, "studyId": "unrelated-dataset", "name": "任意素材",
        "method": "2afc", "question": "哪一幅符合要求？",
        "items": [{"id": "one", "a": "任意目录/first.png", "b": "other/second.jpg"}],
    }


class StudyDataTests(unittest.TestCase):
    def test_minimal_defaults_without_mutating_source(self):
        source = minimal()
        before = copy.deepcopy(source)
        effective = normalize(source)
        self.assertEqual(source, before)
        self.assertEqual(summary(effective)["scheduledResponses"], 1)
        self.assertEqual(effective["analysis"]["metric"], "selection_rate")
        self.assertEqual(effective["presentation"]["imageMs"], 3000)

    def test_answers_and_quality_have_explicit_semantics(self):
        source = minimal()
        source["items"].append({"id": "check", "role": "control", "a": "a.png", "b": "b.png"})
        with self.assertRaisesRegex(StudyError, "control needs"):
            normalize(source)
        source["items"][1]["answer"] = "b"
        self.assertEqual(summary(normalize(source))["scheduledResponses"], 2)
        source["analysis"] = {"metric": "accuracy"}
        with self.assertRaisesRegex(StudyError, "every main"):
            normalize(source)
        source["items"][0]["answer"] = "b"
        normalize(source)

    def test_per_participant_pool_counts_only_the_sampled_items(self):
        source = minimal()
        source['items'] = [dict(source['items'][0], id=f'item-{i}', group='sequence') for i in range(3)]
        source['sampling'] = {'mode': 'per_participant', 'perGroup': {'sequence': 2}}
        source['schedule'] = {'repetitions': 2, 'pairOrder': 'balanced', 'blockByGroup': True, 'avoidAdjacentRepeats': True}
        self.assertEqual(summary(normalize(source))['scheduledResponses'], 4)
        source['sampling']['perGroup']['sequence'] = 4
        with self.assertRaisesRegex(StudyError, 'counts'):
            normalize(source)

    def test_conflicting_schedule_is_rejected(self):
        source = minimal()
        source["schedule"] = {"pairOrder": "balanced"}
        with self.assertRaisesRegex(StudyError, "even"):
            normalize(source)
        source["schedule"] = {"repetitions": 2, "avoidAdjacentRepeats": True}
        with self.assertRaisesRegex(StudyError, "only one"):
            normalize(source)

    def test_unknown_fields_types_and_duplicate_ids_are_rejected(self):
        for update in ({"scheudle": {}}, {"schema": True}, {"method": "mos"},
                       {"presentation": {"imageMs": True}}, {"quality": {"minControlAccuracy": float("nan")}}):
            with self.subTest(update=update), self.assertRaises(StudyError):
                normalize({**minimal(), **update})
        source = minimal()
        source["items"].append(copy.deepcopy(source["items"][0]))
        with self.assertRaisesRegex(StudyError, "duplicate"):
            normalize(source)

    def test_unsafe_paths_are_rejected(self):
        for path in ("../outside.png", "/absolute.png", "C:/image.png", "folder\\image.png",
                     "folder/./image.png", "https://example.com/image.png"):
            with self.subTest(path=path), self.assertRaises(StudyError):
                source = minimal()
                source["items"][0]["a"] = path
                normalize(source)

    def test_example_is_self_contained(self):
        example = load_study(ROOT / "examples/study-v2")
        self.assertEqual(summary(example)["scheduledResponses"], 1)
        self.assertTrue(example["isDemo"])

    def test_normalization_agrees_with_the_shared_dart_contract_fixture(self):
        example = json.loads((ROOT / "examples/study-v2/study.json").read_text(encoding="utf-8"))
        expected = json.loads((ROOT / "test/fixtures/v2-expanded.json").read_text(encoding="utf-8"))
        self.assertEqual(normalize(example), expected)

    def test_missing_referenced_file_is_reported(self):
        with tempfile.TemporaryDirectory(prefix="study-data-test-") as temp:
            with self.assertRaisesRegex(StudyError, "missing image"):
                normalize(minimal(), Path(temp))

    def test_case_only_image_aliases_are_not_portable(self):
        source = minimal()
        source["items"][0].update(a="images/a.png", b="images/A.png")
        with self.assertRaisesRegex(StudyError, "letter case"):
            normalize(source)

    def test_source_validator_does_not_downgrade_a_published_package(self):
        with tempfile.TemporaryDirectory(prefix="study-data-test-") as temp:
            root = Path(temp)
            (root / "study.json").write_text(json.dumps(minimal()), encoding="utf-8")
            (root / "release.json").write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(StudyError, "published package"):
                load_study(root)

    def test_legacy_conversion_preserves_every_image_and_its_provenance(self):
        with tempfile.TemporaryDirectory(prefix="study-data-test-") as temp:
            destination = Path(temp) / "converted"
            value = migrate(ROOT / "assets/demo.study.zip", destination, "my-study")
            loaded = load_study(destination)
            self.assertEqual(value, loaded)
            self.assertEqual(summary(loaded)["items"], {"main": 20, "practice": 4, "control": 2})
            self.assertEqual(summary(loaded)["scheduledResponses"], 46)
            self.assertEqual(loaded["studyId"], "my-study")
            self.assertTrue(loaded["isDemo"])
            with zipfile.ZipFile(ROOT / "assets/demo.study.zip") as archive:
                legacy = json.loads(archive.read("experiment.json"))
                self.assertEqual(loaded["metadata"]["sourceExperimentId"], legacy["id"])
                for before, after in zip(legacy["cases"], loaded["items"]):
                    self.assertEqual(before["view"], after["metadata"]["view"])
                    for previous, current in (("gt", "a"), ("render", "b")):
                        self.assertEqual(archive.read(before[previous]), (destination / after[current]).read_bytes())
            with self.assertRaisesRegex(StudyError, "already exists"):
                migrate(ROOT / "assets/demo.study.zip", destination)

    def test_tampered_legacy_manifest_is_rejected_without_output(self):
        with tempfile.TemporaryDirectory(prefix="study-data-test-") as temp:
            altered = Path(temp) / "bad.zip"
            with zipfile.ZipFile(ROOT / "assets/demo.study.zip") as archive, zipfile.ZipFile(altered, "w") as output:
                value = json.loads(archive.read("experiment.json"))
                value["name"] = "changed"
                output.writestr("experiment.json", json.dumps(value))
            destination = Path(temp) / "converted"
            with self.assertRaisesRegex(StudyError, "manifest hash"):
                migrate(altered, destination)
            self.assertFalse(destination.exists())

    def test_tampered_legacy_picture_is_rejected_without_output(self):
        with tempfile.TemporaryDirectory(prefix="study-data-test-") as temp:
            altered = Path(temp) / "bad.zip"
            with zipfile.ZipFile(ROOT / "assets/demo.study.zip") as archive, zipfile.ZipFile(altered, "w") as output:
                value = json.loads(archive.read("experiment.json"))
                target = value["cases"][0]["gt"]
                for member in archive.infolist():
                    output.writestr(member.filename, b"changed" if member.filename == target else archive.read(member))
            destination = Path(temp) / "converted"
            with self.assertRaisesRegex(StudyError, "image hash"):
                migrate(altered, destination)
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
