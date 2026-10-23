"""Inspect primitive render exports and prepare a reproducible v2 workflow study.

This adapter reads frame*/test/primitive/{gt,renders}; Flutter only sees study.json.
Prepared studies always have isDemo=true and cannot produce a formal conclusion.
Python 3.10+, standard library only; source files are never changed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import struct
import tempfile
from collections import Counter
from pathlib import Path

from study_data import StudyError, identifier, load_study, require, summary


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8-sig"))


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def regular(path):
    require(path.is_file() and not path.is_symlink(), f"not a regular source file: {path}")
    return path


def file_hash(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def png_size(path):
    with regular(path).open("rb") as source:
        header = source.read(24)
    require(len(header) == 24 and header[:16] == b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR",
            f"invalid PNG header: {path}")
    width, height = struct.unpack(">II", header[16:24])
    require(0 < width * height <= 40000000, f"invalid PNG dimensions: {path}")
    return width, height


def frame_pairs(frame):
    require(not frame.is_symlink(), f"symlink frame is unsupported: {frame}")
    base = frame / "test" / "primitive"
    for folder in (frame / "test", base, base / "gt", base / "renders"):
        require(folder.is_dir() and not folder.is_symlink(), f"missing or linked directory: {folder}")
    sides = []
    for role in ("gt", "renders"):
        entries = list((base / role).iterdir())
        require(entries and all(p.suffix.lower() == ".png" and p.is_file() and not p.is_symlink()
                                for p in entries), f"expected only regular PNG images: {base / role}")
        sides.append({p.name: p for p in entries})
    require(sides[0].keys() == sides[1].keys(), f"GT/render filenames do not match: {frame}")
    require(len({name.casefold() for name in sides[0]}) == len(sides[0]), f"case-only filenames: {frame}")
    return {name: (sides[0][name], sides[1][name]) for name in sorted(sides[0])}


def frames_in(scene):
    require(scene.is_dir() and not scene.is_symlink(), f"missing or linked scene: {scene}")
    frames = sorted(p for p in scene.iterdir() if re.fullmatch(r"frame\d+", p.name))
    require(frames, f"no frame directories: {scene}")
    numbers = [int(p.name[5:]) for p in frames]
    require(len(set(numbers)) == len(numbers), f"duplicate numeric frame IDs: {scene}")
    return sorted(frames, key=lambda p: int(p.name[5:]))


def inspect_scene(scene):
    dimensions, filenames = Counter(), None
    size, pairs, metadata_files = 0, 0, 0
    frames = frames_in(scene)
    for frame in frames:
        paired = frame_pairs(frame)
        require(filenames is None or filenames == list(paired), f"view coverage changes: {frame}")
        filenames = list(paired)
        for a, b in paired.values():
            a_size, b_size = png_size(a), png_size(b)
            require(a_size == b_size, f"GT/render dimensions differ: {a}, {b}")
            dimensions[f"{a_size[0]}x{a_size[1]}"] += 2
            size += a.stat().st_size + b.stat().st_size
        pairs += len(paired)
        count_file = frame / "test" / "primitive" / "per_view_count.json"
        if count_file.exists():
            counts = read_json(regular(count_file))
            require(isinstance(counts, dict) and counts.keys() == paired.keys()
                    and all(type(v) is int and v >= 0 for v in counts.values()),
                    f"invalid per_view_count.json: {count_file}")
            metadata_files += 1
    return {"directory": scene.name, "frames": len(frames),
            "frameRange": [int(frames[0].name[5:]), int(frames[-1].name[5:])],
            "pairs": pairs, "images": pairs * 2, "imageBytes": size,
            "dimensions": dict(dimensions), "filenames": filenames,
            "perViewCountFiles": metadata_files,
            "validation": "all filenames paired; all PNG headers checked; Flutter decodes selected images"}


def inspect(root):
    scenes = sorted(p for p in root.glob("*_renders") if p.is_dir())
    require(scenes, f"no *_renders directories: {root}")
    reports = [inspect_scene(scene) for scene in scenes]
    return {"adapter": "primitive-renders@1", "sequences": reports,
            "pairs": sum(s["pairs"] for s in reports),
            "images": sum(s["images"] for s in reports),
            "imageBytes": sum(s["imageBytes"] for s in reports)}


def read_config(path):
    config = read_json(path)
    require(isinstance(config, dict) and set(config) == {"schema", "sequences"}
            and type(config["schema"]) is int and config["schema"] == 1,
            "config requires schema 1 and sequences")
    entries = config["sequences"]
    require(isinstance(entries, list) and entries, "config.sequences must not be empty")
    ids, directories = set(), set()
    for entry in entries:
        require(isinstance(entry, dict) and set(entry) <= {"id", "directory", "views", "frame"},
                "invalid sequence configuration")
        require(identifier(entry.get("id")) and len(entry["id"]) <= 50, "sequence id must be 1-50 ASCII identifier characters")
        directory = entry.get("directory")
        require(isinstance(directory, str) and directory not in ("", ".", "..")
                and not any(c in directory for c in "/\\:"), "directory must be one folder name")
        require(entry["id"] not in ids and directory.casefold() not in directories, "duplicate sequence configuration")
        ids.add(entry["id"])
        directories.add(directory.casefold())
        views = entry.get("views")
        require(isinstance(views, dict) and len(views) >= 2
                and all(re.fullmatch(r"[0-9]+\.png", name) and type(view) is int and view >= 0
                        for name, view in views.items())
                and len(set(views.values())) == len(views), "views must explicitly map PNG filenames to unique camera IDs")
        require("frame" not in entry or type(entry["frame"]) is int and entry["frame"] >= 0,
                "frame override must be a nonnegative integer")
    return entries


def prepare(root, destination, config_path, seed=20261023, study_id="photorealism-workflow"):
    root, destination = root.resolve(), destination.resolve()
    require(not destination.exists(), f"destination already exists: {destination}")
    require(not destination.is_relative_to(root), "destination must be outside the read-only source tree")
    require(identifier(study_id), "invalid studyId")
    entries = read_config(config_path)
    reports, selected = [], []
    for entry in entries:
        scene = root / entry["directory"]
        report = inspect_scene(scene)
        require(set(report["filenames"]) == set(entry["views"]), f"configured camera mapping does not cover {scene.name}")
        reports.append(report)
        frames = frames_in(scene)
        if "frame" in entry:
            matches = [p for p in frames if int(p.name[5:]) == entry["frame"]]
            require(len(matches) == 1, f"requested frame not found: {scene.name}, {entry['frame']}")
            frame = matches[0]
        else:
            # Independent per sequence, stable across Python versions and config ordering.
            digest = hashlib.sha256(f"{seed}:{entry['id']}".encode()).digest()
            frame = frames[int.from_bytes(digest[:8], "big") % len(frames)]
        selected.append((entry, frame))
    study = {"schema": 2, "studyId": study_id, "name": "真实素材 · 真实感流程演练",
             "method": "2afc", "question": "哪一幅是真实拍摄图像？", "isDemo": True,
             "instructions": "本次使用真实素材检查操作流程。演练答案不用于正式主观评价结论。",
             "presentation": {"promptMs": 2000, "imageMs": 3000},
             "schedule": {"repetitions": 2, "pairOrder": "balanced", "blockByGroup": True,
                          "avoidAdjacentRepeats": True},
             "analysis": {"metric": "accuracy"},
             "metadata": {"purpose": "workflow-simulation", "adapter": "primitive-renders@1", "seed": seed,
                          "missingFormalMaterials": ["independent practice pairs", "two obvious controls"],
                          "cameraMapping": "explicit adapter config; verify against export camera order"}, "items": []}
    manifest = {"adapter": "primitive-renders@1", "seed": seed, "sequences": [], "assets": []}
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".renders-v2-", dir=destination.parent) as temp:
        staging = Path(temp) / "study"
        staging.mkdir()
        total = 0
        for entry, frame in selected:
            number = int(frame.name[5:])
            manifest["sequences"].append({**entry, "selectedFrame": number})
            counts_file = frame / "test" / "primitive" / "per_view_count.json"
            counts = read_json(counts_file) if counts_file.exists() else {}
            for name, pair in frame_pairs(frame).items():
                view = entry["views"][name]
                item = {"id": f"{entry['id']}-f{number}-v{view}", "role": "main", "group": entry["id"],
                        "answer": "a", "metadata": {"frame": number, "view": view,
                        "sourceVariant": "primitive", "exportFilename": name, "mapping": "explicit-config"}}
                if name in counts:
                    item["metadata"]["primitiveCount"] = counts[name]
                for alternative, source in zip(("a", "b"), pair):
                    target_name = f"images/{entry['id']}/{frame.name}/v{view}_{alternative}.png"
                    target = staging / target_name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(source, target)
                    size = target.stat().st_size
                    total += size
                    require(total <= 1024**3, "selected images exceed the platform's 1 GB source limit")
                    sha = file_hash(target)
                    width, height = png_size(target)
                    item[alternative] = target_name
                    manifest["assets"].append({"path": target_name, "source": source.relative_to(root).as_posix(),
                                               "sha256": sha, "bytes": size, "width": width, "height": height})
                study["items"].append(item)
        write_json(staging / "study.json", study)
        write_json(staging / "source-manifest.json", manifest)
        write_json(staging / "inventory.json", {"sequences": reports, "selectedImageBytes": total})
        effective = load_study(staging)
        staging.rename(destination)
    return {**summary(effective), "selectedImageBytes": total,
            "selectedFrames": {e["id"]: int(f.name[5:]) for e, f in selected}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    scan = commands.add_parser("inspect", help="read-only pairing and PNG-header inventory")
    scan.add_argument("root", type=Path)
    scan.add_argument("--report", type=Path)
    convert = commands.add_parser("prepare", help="copy one frame/sequence into a v2 workflow study")
    convert.add_argument("root", type=Path)
    convert.add_argument("destination", type=Path)
    convert.add_argument("--config", type=Path, required=True)
    convert.add_argument("--seed", type=int, default=20261023)
    convert.add_argument("--study-id", default="photorealism-workflow")
    args = parser.parse_args()
    try:
        if args.command == "inspect":
            if args.report:
                require(not args.report.resolve().is_relative_to(args.root.resolve()),
                        "report must be outside the read-only source tree")
            result = inspect(args.root)
            if args.report:
                args.report.parent.mkdir(parents=True, exist_ok=True)
                write_json(args.report, result)
        else:
            result = prepare(args.root, args.destination, args.config, args.seed, args.study_id)
        print(json.dumps(result, ensure_ascii=False))
    except (StudyError, OSError, ValueError, TypeError, KeyError) as error:
        parser.exit(2, f"Error: {error}\n")


if __name__ == "__main__":
    main()
