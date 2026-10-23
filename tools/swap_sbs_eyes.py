"""Swap the two halves of packed SBS PNGs without mirroring either eye.

Python 3.10+ and Pillow (python -m pip install Pillow).
SOURCE is one sequence directory; OUTPUT is a new material-root directory.
By default only frame000000 is processed. Use --all explicitly for all frames.
The original sequence/frame/test layout is preserved under OUTPUT.
Existing output directories are refused; source files are never written.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path

from PIL import Image, PngImagePlugin


def file_hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def swap_image(source: Path, target: Path) -> dict:
    before = file_hash(source)
    with Image.open(source) as image:
        if image.format != "PNG" or getattr(image, "n_frames", 1) != 1:
            raise ValueError(f"Expected a static PNG: {source}")
        width, height = image.size
        if width < 2 or width % 2:
            raise ValueError(f"SBS width must be positive and even: {source} ({width}x{height})")
        image.load()
        half = width // 2
        left = image.crop((0, 0, half, height))
        right = image.crop((half, 0, width, height))
        swapped = image.copy()
        swapped.paste(right, (0, 0))
        swapped.paste(left, (half, 0))
        metadata = PngImagePlugin.PngInfo()
        for key, value in getattr(image, "text", {}).items():
            metadata.add_itxt(key, value)
        options = {key: image.info[key] for key in ("icc_profile", "exif", "dpi", "transparency")
                   if key in image.info}
        target.parent.mkdir(parents=True, exist_ok=True)
        # The whole destination root is new; exclusive creation also refuses races.
        with target.open("xb") as output:
            swapped.save(output, format="PNG", pnginfo=metadata, **options)
        with Image.open(target) as verified:
            verified.load()
            if (verified.size != image.size or verified.mode != image.mode
                    or verified.crop((0, 0, half, height)).tobytes() != right.tobytes()
                    or verified.crop((half, 0, width, height)).tobytes() != left.tobytes()):
                raise ValueError(f"Output pixel verification failed: {target}")
    if file_hash(source) != before:
        raise ValueError(f"Source changed during conversion: {source}")
    return {"width": width, "height": height, "sourceSha256": before,
            "outputSha256": file_hash(target), "verified": True}


def convert(source: Path, output: Path, frame: str = "frame000000", all_frames: bool = False) -> dict:
    source = source.resolve(strict=True)
    output = output.resolve()
    if not source.is_dir():
        raise ValueError(f"Source is not a sequence directory: {source}")
    if output == source or source in output.parents or output in source.parents:
        raise ValueError("Source and output must be separate directory trees")
    if output.exists():
        raise ValueError(f"Output already exists; choose a new directory: {output}")
    if not output.parent.is_dir():
        raise ValueError(f"Output parent directory does not exist: {output.parent}")
    if not re.fullmatch(r"frame\d+", frame):
        raise ValueError("--frame must be a directory name such as frame000000")
    frames = sorted((p for p in source.iterdir() if re.fullmatch(r"frame\d+", p.name)),
                    key=lambda p: int(p.name[5:])) if all_frames else [source / frame]
    files = []
    for folder in frames:
        if folder.is_symlink() or not folder.is_dir():
            raise ValueError(f"Missing or linked frame directory: {folder}")
        selected = sorted(folder.rglob("*"))
        if any(p.is_symlink() for p in selected):
            raise ValueError(f"Linked files/directories are not supported: {folder}")
        frame_files = [p for p in selected if p.is_file()]
        if not any(p.suffix.lower() == ".png" for p in frame_files):
            raise ValueError(f"No PNG images in {folder}")
        if any(p.suffix.lower() in (".jpg", ".jpeg", ".webp") for p in frame_files):
            raise ValueError(f"Only lossless PNG SBS images are supported: {folder}")
        files.extend(frame_files)
    if not frames:
        raise ValueError(f"No frame directories found in {source}")
    report = {"complete": False, "operation": "swap-sbs-halves", "source": str(source),
              "output": str(output), "frames": [p.name for p in frames],
              "images": [], "copiedMetadata": []}
    output.mkdir()
    report_path = output / "eye-swap-report.json"

    def save_report():
        report_path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    save_report()
    try:
        for path in files:
            relative = path.relative_to(source)
            target = output / source.name / relative
            if path.suffix.lower() == ".png":
                info = swap_image(path, target)
                report["images"].append({"path": relative.as_posix(), **info})
                print(f"Swapped and verified: {relative.as_posix()}", flush=True)
            else:
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, target)
                report["copiedMetadata"].append(relative.as_posix())
        report["complete"] = True
    finally:
        save_report()
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("source", type=Path, help="Original sequence directory")
    parser.add_argument("--output", required=True, type=Path, help="New material-root directory; must not exist")
    selection = parser.add_mutually_exclusive_group()
    selection.add_argument("--frame", default="frame000000", help="Only this frame (default: frame000000)")
    selection.add_argument("--all", action="store_true", help="Process every frame (explicit opt-in)")
    args = parser.parse_args()
    try:
        report = convert(args.source, args.output, args.frame, args.all)
    except (OSError, ValueError) as error:
        parser.exit(2, f"Error: {error}\n")
    print(f"Done: {len(report['images'])} images, {len(report['frames'])} frame(s). Output: {args.output}")


if __name__ == "__main__":
    main()
