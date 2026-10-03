"""Generate the native iOS icon from the Guarda Mídias visual mark."""

import json
from pathlib import Path

from PIL import Image, ImageDraw


ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "GuardaMidias" / "Assets.xcassets" / "AppIcon.appiconset"
DEST.mkdir(parents=True, exist_ok=True)

scale = 4
size = 1024 * scale
image = Image.new("RGB", (size, size), "#071923")
draw = ImageDraw.Draw(image)


def xy(values):
    return tuple(int(v * scale * 2) for v in values)


# The original mark is a photo flowing into a safe storage tray.
draw.rounded_rectangle(xy((93, 106, 419, 351)), radius=70 * scale, fill="#173b48", outline="#72e0bd", width=36 * scale)
draw.ellipse(xy((161, 150, 217, 206)), fill="#72e0bd")
draw.line([xy((111, 318)), xy((203, 224)), xy((269, 285)), xy((327, 240)), xy((402, 318))], fill="#72e0bd", width=48 * scale, joint="curve")
draw.line([xy((256, 349)), xy((256, 427))], fill="white", width=44 * scale)
draw.line([xy((211, 385)), xy((256, 430)), xy((301, 385))], fill="white", width=44 * scale, joint="curve")
image = image.resize((1024, 1024), Image.Resampling.LANCZOS)

images = []
for points, scales in [(20, [2, 3]), (29, [2, 3]), (40, [2, 3]), (60, [2, 3])]:
    for factor in scales:
        pixels = points * factor
        filename = f"Icon-{pixels}.png"
        image.resize((pixels, pixels), Image.Resampling.LANCZOS).save(DEST / filename)
        images.append({"filename": filename, "idiom": "iphone", "scale": f"{factor}x", "size": f"{points}x{points}"})

image.save(DEST / "Icon-1024.png")
images.append({"filename": "Icon-1024.png", "idiom": "ios-marketing", "scale": "1x", "size": "1024x1024"})
(DEST / "Contents.json").write_text(json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n", encoding="utf-8")
