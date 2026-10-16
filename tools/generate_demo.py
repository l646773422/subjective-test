"""Deterministic synthetic fixtures. Never evidence for photorealism quality."""
from pathlib import Path
from PIL import Image, ImageDraw
import hashlib
import io
import json
import math
import random
import zipfile

ROOT = Path(__file__).resolve().parents[1]
VIEWS = {
    "VRU_gz": [0, 10, 20, 30],
    "VRU_dg4": [0, 10, 20, 30],
    "Dance_Dunhuang_Pair_1080": [0, 10, 20, 30, 40, 50],
    "Show_Groups_4K": [0, 10, 20, 30, 40, 50],
}


def picture(seed, rendered, control=False):
    rng = random.Random(seed)
    w, h = 960, 540
    image = Image.new("RGB", (w, h), "#c8d6d7")
    draw = ImageDraw.Draw(image)
    for y in range(h):
        shade = int(225 - 65 * y / h)
        draw.line((0, y, w, y), fill=(shade-15, shade+5, shade))
    horizon = 270 + seed % 40
    draw.polygon([(0, horizon), (w, horizon), (w, h), (0, h)], fill="#b9b4a2")
    for i in range(11):
        x = i * 96
        draw.line((w // 2, horizon, x, h), fill="#dfdac9", width=2)
    for y in [310, 350, 400, 470]:
        draw.line((0, y, w, y), fill="#dfdac9", width=2)
    for i in range(6):
        x = 40 + i * 160 + rng.randint(-12, 12)
        top = rng.randint(50, 125)
        color = tuple(rng.randint(50, 155) for _ in range(3))
        draw.rounded_rectangle((x, top, x+100, horizon+30), radius=4, fill=color)
        for row in range(4):
            for col in range(3):
                draw.rectangle((x+12+col*28, top+15+row*32,
                                x+25+col*28, top+35+row*32), fill="#e7cf97")
    for i in range(4):
        x = 165 + i * 190 + rng.randint(-24, 24)
        y = 340 + rng.randint(-18, 18)
        shift = (3 if rendered else 0) * (-1 if i % 2 else 1)
        draw.ellipse((x-45, y+78, x+55, y+96), fill="#8e9689")
        draw.ellipse((x-15+shift, y-92, x+15+shift, y-62), fill="#d6a37b")
        cloth = tuple(rng.randint(30, 185) for _ in range(3))
        draw.polygon([(x-24, y-55), (x+23, y-55), (x+33+shift, y+22),
                      (x-33+shift, y+22)], fill=cloth)
        draw.line((x-14, y+20, x-20+shift, y+77), fill="#344a50", width=14)
        draw.line((x+14, y+20, x+29+shift, y+78), fill="#344a50", width=14)
        draw.line((x-25, y-40, x-58, y-10+shift), fill="#d6a37b", width=10)
        draw.line((x+25, y-40, x+52, y-17-shift), fill="#d6a37b", width=10)
    if rendered:
        draw.ellipse((750, 52, 798, 100), fill="#e6d8a0")
    else:
        draw.ellipse((748, 52, 796, 100), fill="#e9dba5")
    if control and rendered:
        for x in range(0, w, 80):
            for y in range(0, h, 80):
                if (x//80+y//80) % 3 == 0:
                    draw.rectangle((x, y, x+75, y+75), fill="#aa4993")
        draw.line((40, 40, w-40, h-40), fill="#ffda44", width=18)
    data = io.BytesIO()
    image.save(data, format="PNG", optimize=True)
    return data.getvalue()


def main():
    assets = {}
    cases = []

    def pair(case_id, sequence, kind, seed, view=-1):
        a = picture(seed, False, kind == "control")
        b = picture(seed, True, kind == "control")
        gt, render = "images/"+case_id+"_gt.png", "images/"+case_id+"_render.png"
        assets[gt], assets[render] = a, b
        value = dict(id=case_id, sequence=sequence, kind=kind, gt=gt, render=render,
                     gtHash=hashlib.sha256(a).hexdigest(),
                     renderHash=hashlib.sha256(b).hexdigest(),
                     frame=0 if kind == "main" else 249, view=view,
                     iteration=30000, width=960, height=540, mapping="explicit")
        cases.append(value)
        return value

    counter = 0
    for seq, views in VIEWS.items():
        raw = ROOT/"demo-data"/"raw-sequences"/seq/"demo"
        raw.mkdir(parents=True, exist_ok=True)
        (raw/"DEMO_ONLY.txt").write_text("Synthetic fixtures. Not formal evidence.\n")
        for i, view in enumerate(views):
            counter += 1
            case = pair(seq+"_v"+str(view), seq, "main", counter, view)
            target = raw/"frame000000"/"test"/"ours_30000"
            for label, key in [("gt", "gt"), ("renders", "render")]:
                path = target/label/(str(i).zfill(5)+".png")
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(assets[case[key]])
        # The intentionally incomplete older iteration must never be chosen.
        (raw/"frame000000"/"test"/"ours_900"/"gt").mkdir(parents=True, exist_ok=True)
    for i in range(4):
        case = pair("practice_"+str(i), "aux", "practice", 100+i)
        for label in ["gt", "render"]:
            path = ROOT/"demo-data"/"auxiliary"/case["id"]/(label+".png")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(assets[case[label]])
    for i in range(2):
        case = pair("control_"+str(i), "aux", "control", 200+i)
        for label in ["gt", "render"]:
            path = ROOT/"demo-data"/"auxiliary"/case["id"]/(label+".png")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(assets[case[label]])
    payload = dict(schema=1, name="流程演示题库", createdAt="2026-10-16T00:00:00.000Z",
                   isDemo=True, seed=3917, promptMs=2000, imageMs=3000, cases=cases)
    encoded = json.dumps(payload, sort_keys=True, ensure_ascii=False,
                         separators=(",", ":")).encode("utf-8")
    payload["id"] = hashlib.sha256(encoded).hexdigest()
    (ROOT/"assets").mkdir(exist_ok=True)
    target = ROOT/"assets"/"demo.study.zip"
    with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("experiment.json", json.dumps(payload, ensure_ascii=False))
        for name, data in assets.items():
            archive.writestr(name, data)
    (ROOT/"demo-data"/"demo.study.zip").write_bytes(target.read_bytes())
    print("Demo:", len(cases), "pairs;", len(assets), "images;", target.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
