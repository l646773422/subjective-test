from pathlib import Path
from PIL import Image, ImageDraw
root = Path(__file__).resolve().parents[1]
im = Image.new("RGB", (256,256), "#edf1e9")
d = ImageDraw.Draw(im)
d.rounded_rectangle((62,35,201,188), radius=10, outline="#173e3a", width=14)
d.rounded_rectangle((34,67,174,222), radius=10, fill="#edf1e9", outline="#173e3a", width=14)
d.line((60,150,96,111,125,150,145,126), fill="#173e3a", width=12)
d.ellipse((119,92,140,113), fill="#b48943")
im.save(root/"windows/runner/resources/app_icon.ico", sizes=[(16,16),(32,32),(48,48),(64,64),(128,128),(256,256)])
for density, size in [("mdpi",48),("hdpi",72),("xhdpi",96),("xxhdpi",144),("xxxhdpi",192)]:
    target=root/"android/app/src/main/res"/("mipmap-"+density)/"ic_launcher.png"
    target.parent.mkdir(parents=True,exist_ok=True)
    im.resize((size,size), Image.Resampling.LANCZOS).save(target)
