"""Validate standard study sources and convert frozen schema-1 packages.

Python 3.10+, standard library only. Published packages are verified by Flutter.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import stat
import tempfile
import zipfile
from pathlib import Path, PurePosixPath


class StudyError(ValueError):
    pass


DEFAULTS = {
    "presentation": {"mode": "sequential", "promptMs": 2000, "imageMs": 3000},
    "schedule": {
        "repetitions": 1,
        "pairOrder": "random",
        "itemOrder": "random",
        "blockByGroup": False,
        "avoidAdjacentRepeats": False,
        "controlPlacement": "spread",
        "practicePairOrder": "random",
        "controlPairOrder": "random",
    },
    "quality": {"minControlAccuracy": 1.0, "requiredTrue": []},
    "analysis": {"metric": "selection_rate"},
}


def require(condition, message):
    if not condition:
        raise StudyError(message)


def object_keys(value, allowed, location):
    require(isinstance(value, dict), f"{location}: expected an object")
    unknown = value.keys() - set(allowed)
    require(not unknown, f"{location}: unknown fields {sorted(unknown)}; use metadata")


def text(value):
    return isinstance(value, str) and bool(value.strip())


def identifier(value):
    return isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,79}", value)


def asset_path(value):
    require(text(value), "asset path: expected a non-empty relative path")
    path = PurePosixPath(value)
    require(
        not path.is_absolute() and "\\" not in value and ":" not in value
        and all(part not in ("", ".", "..") for part in value.split("/")),
        f"unsafe asset path: {value}",
    )
    require(path.suffix.lower() in (".png", ".jpg", ".jpeg"), f"unsupported image: {value}")
    return path


def checked_file(root, relative):
    path = root.joinpath(*asset_path(relative).parts)
    require(path.resolve().is_relative_to(root.resolve()), f"asset escapes study folder: {relative}")
    cursor = path
    while cursor != root:
        require(not cursor.is_symlink(), f"asset symlink is unsupported: {relative}")
        cursor = cursor.parent
    require(path.is_file(), f"missing image: {relative}")
    require(path.stat().st_size > 0, f"empty image: {relative}")
    return path


def normalize(study, root=None):
    """Return effective settings without changing the author's input object."""
    object_keys(study, {
        "schema", "studyId", "name", "method", "question", "instructions", "isDemo",
        "presentation", "schedule", "quality", "analysis", "items", "metadata", "participantFields", "sampling",
    }, "study")
    value = copy.deepcopy(study)
    require(type(value.get("schema")) is int and value["schema"] == 2, "schema must be 2")
    require(identifier(value.get("studyId")), "studyId must be 1-80 ASCII letters, digits, dots, hyphens or underscores")
    for field in ("name", "question"):
        require(text(value.get(field)), f"{field} is required")
    require(value.get("method") == "2afc", "only method 2afc is supported")
    value.setdefault("isDemo", False)
    value.setdefault("instructions", "")
    value.setdefault("metadata", {})
    value.setdefault("participantFields", [])
    require(type(value["isDemo"]) is bool, "isDemo must be boolean")
    require(isinstance(value["instructions"], str), "instructions must be text")
    require(isinstance(value["metadata"], dict), "metadata must be an object")
    for section, defaults in DEFAULTS.items():
        supplied = value.get(section, {})
        extras = ["profile"] if section == "analysis" else ["stereo", "patch"] if section == "presentation" else []
        object_keys(supplied, [*defaults, *extras], section)
        value[section] = {**copy.deepcopy(defaults), **supplied}
    presentation, schedule = value["presentation"], value["schedule"]
    require(presentation["mode"] == "sequential", "only sequential image presentation is supported")
    if "stereo" in presentation:
        stereo = presentation["stereo"]
        object_keys(stereo, ("layout", "uiDisparity", "pointerMapping"), "presentation.stereo")
        stereo.setdefault("layout", "full_sbs")
        stereo.setdefault("uiDisparity", 0)
        stereo.setdefault("pointerMapping", "screen")
        require(stereo["pointerMapping"] in ("screen", "per_eye"), "invalid pointer mapping")
        require(stereo["layout"] in ("half_sbs", "full_sbs"), "invalid SBS layout")
        require(type(stereo["uiDisparity"]) in (int, float) and -64 <= stereo["uiDisparity"] <= 64,
                "UI disparity must be -64..64 logical pixels")
    if "patch" in presentation:
        patch = presentation["patch"]
        object_keys(patch, ("area", "width", "height", "distribution"), "presentation.patch")
        patch.setdefault("distribution", "center_triangular")
        require(("area" in patch) != ("width" in patch or "height" in patch),
                "patch requires pixel width/height, without legacy area")
        if "area" in patch:
            require(type(patch.get("area")) in (int, float) and 0.001 <= patch["area"] <= 1,
                    "patch area must be 0.001..1")
        else:
            require(type(patch.get("width")) is int and type(patch.get("height")) is int
                    and patch["width"] > 0 and patch["height"] > 0
                    and patch["width"] * patch["height"] <= 40000000,
                    "patch width/height must be positive integer pixels, at most 40 MP")
        require(patch["distribution"] == "center_triangular", "unsupported patch distribution")
    for key, low, high in (("promptMs", 0, 60000), ("imageMs", 1, 600000)):
        require(type(presentation[key]) is int and low <= presentation[key] <= high,
                f"presentation.{key} must be an integer in {low}..{high}")
    require(type(schedule["repetitions"]) is int and 1 <= schedule["repetitions"] <= 1000,
            "schedule.repetitions must be an integer in 1..1000")
    require(schedule["pairOrder"] in ("random", "balanced"), "pairOrder must be random or balanced")
    require(schedule["itemOrder"] in ("random", "listed"), "itemOrder must be random or listed")
    require(schedule["practicePairOrder"] in ("random", "alternating"), "practicePairOrder is invalid")
    require(schedule["controlPairOrder"] in ("random", "balanced"), "controlPairOrder is invalid")
    for field in ("blockByGroup", "avoidAdjacentRepeats"):
        require(type(schedule[field]) is bool, f"schedule.{field} must be boolean")
    require(schedule["controlPlacement"] == "spread", "controlPlacement must be spread")
    require(schedule["pairOrder"] != "balanced" or schedule["repetitions"] % 2 == 0,
            "balanced pair order requires an even number of main repetitions")
    threshold = value["quality"]["minControlAccuracy"]
    require(type(threshold) in (int, float) and 0 <= threshold <= 1,
            "quality.minControlAccuracy must be a number in 0..1")
    require(value["analysis"]["metric"] in ("selection_rate", "accuracy"),
            "analysis.metric must be selection_rate or accuracy")
    fields = value["participantFields"]
    require(isinstance(fields, list), "participantFields must be a list")
    field_ids, bool_ids = set(), set()
    for field in fields:
        object_keys(field, ("id", "label", "type", "required", "min", "max"), "participantFields")
        require(identifier(field.get("id")) and field["id"] not in field_ids and text(field.get("label")), "invalid participant field identity")
        field_ids.add(field["id"])
        require(field.get("type") in ("text", "integer", "number", "boolean"), "invalid participant field type")
        require("required" not in field or type(field["required"]) is bool, "field.required must be boolean")
        for key in ("min", "max"):
            require(key not in field or type(field[key]) in (int, float) and float("-inf") < field[key] < float("inf"), "invalid field range")
        require(not ("min" in field or "max" in field) or field["type"] in ("integer", "number"), "only numeric fields support min/max")
        require("min" not in field or "max" not in field or field["min"] <= field["max"], "inverted field range")
        if field["type"] == "boolean":
            bool_ids.add(field["id"])
    required_true = value["quality"]["requiredTrue"]
    require(isinstance(required_true, list) and all(isinstance(key, str) and key in bool_ids for key in required_true),
            "requiredTrue must reference defined boolean participant fields")
    profile = value["analysis"].get("profile")
    if "profile" in value["analysis"]:
        object_keys(profile, ("type", "version", "minObserversPerItem", "minObserversPerSequence", "expertNumerator", "expertDenominator",
                    "maxSequenceAccuracy", "equalCoverage", "sequenceViews", "resolutions", "practiceMin", "practiceMax", "controlCount"), "analysis.profile")
        require(profile.get("type") == "photorealism" and profile.get("version") in (1, 2) and value["analysis"]["metric"] == "accuracy", "unsupported analysis profile")
        for key in (("minObserversPerSequence" if profile["version"] == 2 else "minObserversPerItem"), "expertNumerator", "expertDenominator", "practiceMin", "practiceMax", "controlCount"):
            require(type(profile.get(key)) is int and profile[key] > 0, f"invalid profile.{key}")
        require(type(profile.get("equalCoverage")) is bool and type(profile.get("maxSequenceAccuracy")) in (int, float)
                and 0 <= profile["maxSequenceAccuracy"] <= 1, "invalid profile threshold")
        views, resolutions = profile.get("sequenceViews"), profile.get("resolutions")
        require(isinstance(views, dict) and bool(views) and isinstance(resolutions, dict) and views.keys() == resolutions.keys(), "profile groups do not match")
        for key, ids_for_group in views.items():
            require(isinstance(ids_for_group, list) and bool(ids_for_group) and all(type(v) is int for v in ids_for_group)
                    and len(set(ids_for_group)) == len(ids_for_group), "invalid profile views")
            require(isinstance(resolutions[key], list) and len(resolutions[key]) == 2 and
                    all(type(n) is int and n > 0 for n in resolutions[key]), "invalid profile resolution")
    require(isinstance(value.get("items"), list) and value["items"], "items must be a non-empty list")
    ids, files, main = set(), set(), []
    for index, item in enumerate(value["items"]):
        location = f"items[{index}]"
        object_keys(item, {"id", "a", "b", "aRight", "bRight", "answer", "role", "group", "metadata"}, location)
        require(identifier(item.get("id")), f"{location}.id is invalid")
        require(item["id"] not in ids, f"duplicate item id: {item['id']}")
        ids.add(item["id"])
        item.setdefault("role", "main")
        item.setdefault("metadata", {})
        require(item["role"] in ("main", "practice", "control"), f"{location}.role is invalid")
        require(isinstance(item["metadata"], dict), f"{location}.metadata must be an object")
        if "group" in item:
            require(text(item["group"]), f"{location}.group must be non-empty text")
        if "answer" in item:
            require(item["answer"] in ("a", "b"), f"{location}.answer must be a or b")
        require(item["role"] != "control" or "answer" in item, f"{location}: control needs an answer")
        for alternative in ("a", "b", *(["aRight", "bRight"] if "stereo" in presentation else
                [k for k in ("aRight", "bRight") if k in item])):
            asset_path(item.get(alternative))
            files.add(item[alternative])
        if item["role"] == "main":
            main.append(item)
    require(len({path.lower() for path in files}) == len(files), "image paths cannot differ only in letter case")
    require(main, "at least one main item is required")
    selected_counts = None
    if "sampling" in value:
        sampling = value["sampling"]
        object_keys(sampling, ("mode", "perGroup"), "sampling")
        selected_counts = sampling.get("perGroup")
        require(sampling.get("mode") == "per_participant" and isinstance(selected_counts, dict)
                and bool(selected_counts) and all(text(k) and type(n) is int and n > 0 for k, n in selected_counts.items()),
                "sampling requires per_participant mode and positive perGroup counts")
        require(all(i.get("group") in selected_counts for i in main)
                and all(sum(i.get("group") == k for i in main) >= n for k, n in selected_counts.items()),
                "sampling groups or counts do not match the pool")
    require(value["analysis"]["metric"] != "accuracy" or all("answer" in item for item in main),
            "accuracy requires an answer for every main item")
    if schedule["blockByGroup"]:
        require(all("group" in item for item in main), "blockByGroup requires a group on every main item")
    if schedule["avoidAdjacentRepeats"] and schedule["repetitions"] > 1:
        blocks = {}
        for item in main:
            blocks.setdefault(item.get("group") if schedule["blockByGroup"] else None, []).append(item)
        block_counts = (selected_counts.values() if schedule["blockByGroup"] else [sum(selected_counts.values())]) if selected_counts else [len(b) for b in blocks.values()]
        require(all(n >= 2 for n in block_counts),
                "cannot avoid adjacent repeats in a block with only one main item")
    require(schedule["controlPairOrder"] != "balanced" or sum(item["role"] == "control" for item in value["items"]) % 2 == 0,
            "balanced control order requires an even number of controls")
    if root is not None:
        for relative in sorted(files):
            checked_file(Path(root).resolve(), relative)
    return value


def load_study(path):
    path = Path(path)
    if path.is_dir():
        path = path / "study.json"
    require(not (path.parent / "release.json").exists(),
            "published package: this source validator cannot verify release.json")

    def reject_constant(value):
        raise StudyError(f"invalid JSON number: {value}")

    with path.open(encoding="utf-8-sig") as stream:
        value = json.load(stream, parse_constant=reject_constant)
    library = path.parent / "materials.json"
    asset_root = Path(json.loads(library.read_text(encoding="utf-8"))["root"]) if library.exists() else path.parent
    return normalize(value, asset_root)


def migrate(legacy, destination, study_id=None):
    """Convert data only; preserve original identities in provenance, not new results."""
    destination = Path(destination).absolute()
    require(not destination.exists(), f"output already exists: {destination}")
    require(destination.parent.is_dir(), f"output parent does not exist: {destination.parent}")
    require(Path(legacy).stat().st_size <= 512 * 1024**2, "legacy ZIP exceeds 512 MiB")
    with zipfile.ZipFile(legacy) as archive:
        members = archive.infolist()
        require(len({member.filename for member in members}) == len(members), "duplicate ZIP paths")
        require(sum(member.file_size for member in members) <= 1024**3, "legacy ZIP exceeds 1 GiB expanded")
        old = json.loads(archive.read("experiment.json").decode("utf-8-sig"))
        require(old.get("schema") == 1, "expected a frozen schema-1 package")
        body = {key: item for key, item in old.items() if key != "id"}
        digest = hashlib.sha256(json.dumps(body, ensure_ascii=False, sort_keys=True,
                                          separators=(",", ":")).encode("utf-8")).hexdigest()
        require(old.get("id") == digest, "legacy manifest hash mismatch")
        require(isinstance(old.get("cases"), list) and old["cases"], "legacy cases are missing")
        study = {
            "schema": 2,
            "studyId": study_id if study_id is not None else "migrated-" + old["id"][:20],
            "name": old["name"], "method": "2afc", "isDemo": old["isDemo"],
            "question": "哪一幅是真实拍摄图像？",
            "presentation": {"mode": "sequential", "promptMs": old["promptMs"], "imageMs": old["imageMs"]},
            "schedule": {"repetitions": 2, "pairOrder": "balanced", "blockByGroup": True,
                         "avoidAdjacentRepeats": True},
            "analysis": {"metric": "accuracy"},
            "metadata": {
                "sourceFormat": "subjective-study-schema-1", "sourceExperimentId": old["id"],
                "sourceCreatedAt": old["createdAt"], "sourceSamplingSeed": old["seed"],
                "legacyProtocol": {
                    "template": "photorealism-v1", "minObserversPerItem": 15,
                    "maxExpertFraction": "1/3", "maxSequenceAccuracy": 0.75,
                    "requiresEqualViewCoverage": True,
                    "eligibility": ["normalVision", "normalColorVision", "independent"],
                    "practicePairOrder": "alternating", "controlPairOrder": "balanced",
                    "schedulerVersion": "schema-1",
                },
            },
            "items": [],
        }
        assets = {}
        for case in old["cases"]:
            item = {"id": case["id"], "role": case["kind"], "group": case["sequence"],
                    "answer": "a", "metadata": {key: case[key] for key in
                    ("frame", "view", "iteration", "width", "height", "mapping") if key in case}}
            for alternative, key, hash_key in (("a", "gt", "gtHash"), ("b", "render", "renderHash")):
                source = case[key]
                asset_path(source)
                member = archive.getinfo(source)
                require(not member.is_dir() and not stat.S_ISLNK(member.external_attr >> 16), f"invalid ZIP asset: {source}")
                data = archive.read(member)
                digest = hashlib.sha256(data).hexdigest()
                require(digest == case[hash_key], f"legacy image hash mismatch: {source}")
                relative = f"assets/{digest}{PurePosixPath(source).suffix.lower()}"
                assets[relative] = data
                item[alternative] = relative
            study["items"].append(item)
        effective = normalize(study)
        with tempfile.TemporaryDirectory(prefix=".study-migration-", dir=destination.parent) as temp:
            staging = Path(temp) / "study"
            staging.mkdir()
            for relative, data in assets.items():
                target = staging / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            (staging / "study.json").write_text(json.dumps(study, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            load_study(staging)
            staging.rename(destination)
    return effective


def summary(study):
    counts = {role: sum(item["role"] == role for item in study["items"])
              for role in ("main", "practice", "control")}
    return {"studyId": study["studyId"], "items": counts,
            "scheduledResponses": (sum(study["sampling"]["perGroup"].values()) if "sampling" in study else counts["main"]) * study["schedule"]["repetitions"] + counts["practice"] + counts["control"],
            "isDemo": study["isDemo"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    validate = commands.add_parser("validate", help="validate study.json and referenced files")
    validate.add_argument("source", type=Path)
    convert = commands.add_parser("migrate", help="convert an old frozen ZIP to a new source directory")
    convert.add_argument("legacy", type=Path)
    convert.add_argument("destination", type=Path)
    convert.add_argument("--study-id", help="stable identity for the new study")
    args = parser.parse_args()
    try:
        study = load_study(args.source) if args.command == "validate" else migrate(args.legacy, args.destination, args.study_id)
        print(json.dumps(summary(study), ensure_ascii=False))
    except (StudyError, OSError, KeyError, TypeError, json.JSONDecodeError, zipfile.BadZipFile) as error:
        parser.exit(2, f"Error: {error}\n")


if __name__ == "__main__":
    main()
