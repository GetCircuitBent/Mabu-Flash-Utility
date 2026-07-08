"""Build the bundled wallpaper drawable from the style-guide boot-logo.

Scales GitHub-Style-Guide/assets/boot-logo.png to fit the 1024x600 panel and
pads it on Bluewood #1A242D (brand bg-primary), matching the boot animation's
first frame. Output: res/drawable-nodpi/gcb_wallpaper.png (nodpi so Android
does not density-scale it). Run with the Pillow-enabled interpreter: `python`.
"""
import os
from PIL import Image

W, H = 1024, 600
BG = (26, 36, 45)  # Bluewood #1A242D
SRC = r"D:\Claude Projects\GitHub-Style-Guide\assets\boot-logo.png"
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "res", "drawable-nodpi", "gcb_wallpaper.png")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
logo = Image.open(SRC).convert("RGBA")
scale = min(W / logo.width, H / logo.height)
nw, nh = int(round(logo.width * scale)), int(round(logo.height * scale))
logo = logo.resize((nw, nh), Image.LANCZOS)

canvas = Image.new("RGB", (W, H), BG)
canvas.paste(logo, ((W - nw) // 2, (H - nh) // 2), logo)
canvas.save(OUT, optimize=True)
print(f"wrote {OUT} ({W}x{H}, logo {nw}x{nh} centered on #1A242D)")
