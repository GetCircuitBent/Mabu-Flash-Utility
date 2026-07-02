import math
import os
import random
import zipfile

from PIL import Image, ImageDraw

W, H = 1024, 600
FPS = 15
BG = (26, 36, 45)  # Bluewood 900 #1A242D — dark-theme bg-primary token (exception to the white/light-surface guidance)
LOGO_PATH = r"D:\Claude Projects\GitHub-Style-Guide\assets\logos\gcb-text-logo.png"
OUT_DIR = os.path.dirname(os.path.abspath(__file__))

# Brand sparkle colors (from Brand Colors.md core palette), each paired with a
# complementary outline color (orange sparkles outlined green, green sparkles outlined orange)
GREEN = (23, 158, 25)        # La Palma
ORANGE = (255, 79, 0)        # Signal Orange
HEADING_GREEN = (94, 135, 74)

SPARK_COLORS = [
    (GREEN, ORANGE),
    (ORANGE, GREEN),
    (HEADING_GREEN, ORANGE),
]

random.seed(7)

logo = Image.open(LOGO_PATH).convert("RGBA")
logo_w = 720
logo_h = int(logo.size[1] * (logo_w / logo.size[0]))
logo = logo.resize((logo_w, logo_h), Image.LANCZOS)
logo_x = (W - logo_w) // 2
logo_y = (H - logo_h) // 2

logo_bbox = (logo_x - 20, logo_y - 20, logo_x + logo_w + 20, logo_y + logo_h + 20)


def rand_point_outside_bbox(bbox, margin=24):
    while True:
        x = random.randint(margin, W - margin)
        y = random.randint(margin, H - margin)
        if not (bbox[0] <= x <= bbox[2] and bbox[1] <= y <= bbox[3]):
            return x, y


NUM_SPARKLES = 22
sparkles = []
for _ in range(NUM_SPARKLES):
    x, y = rand_point_outside_bbox(logo_bbox)
    color, outline = random.choice(SPARK_COLORS)
    sparkles.append({
        "x": x,
        "y": y,
        "size": random.uniform(6, 15),
        "color": color,
        "outline": outline,
        "phase": random.uniform(0, 2 * math.pi),
        "speed": random.uniform(0.5, 0.85),  # slowed down from 0.8-1.4
    })


def _draw_star(draw, x, y, r, color, a, width):
    draw.line([(x - r, y), (x + r, y)], fill=color + (a,), width=width)
    draw.line([(x, y - r), (x, y + r)], fill=color + (a,), width=width)
    r2 = r * 0.5
    draw.line([(x - r2, y - r2), (x + r2, y + r2)], fill=color + (a,), width=width)
    draw.line([(x - r2, y + r2), (x + r2, y - r2)], fill=color + (a,), width=width)


def draw_sparkle(draw, x, y, size, color, outline, brightness):
    if brightness <= 0.02:
        return
    a = int(255 * brightness)
    r = size * (0.4 + 0.6 * brightness)
    # outline star drawn slightly larger + thicker first, main color on top — reads as a colored core with a contrasting rim
    _draw_star(draw, x, y, r * 1.35, outline, a, width=3)
    _draw_star(draw, x, y, r, color, a, width=1)
    # bright core
    core = max(1, int(size * 0.2 * brightness))
    draw.ellipse([x - core, y - core, x + core, y + core], fill=color + (a,))


def render_frame(logo_alpha, sparkle_t, sparkles_on):
    frame = Image.new("RGB", (W, H), BG)
    overlay = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    odraw = ImageDraw.Draw(overlay)

    if sparkles_on:
        for s in sparkles:
            b = 0.5 + 0.5 * math.sin(sparkle_t * s["speed"] + s["phase"])
            b = max(0.0, b) ** 1.6  # sharpen twinkle peaks
            draw_sparkle(odraw, s["x"], s["y"], s["size"], s["color"], s["outline"], b)

    frame.paste(overlay, (0, 0), overlay)

    if logo_alpha < 255:
        lcopy = logo.copy()
        r, g, b, a = lcopy.split()
        a = a.point(lambda v: int(v * (logo_alpha / 255)))
        lcopy.putalpha(a)
        frame.paste(lcopy, (logo_x, logo_y), lcopy)
    else:
        frame.paste(logo, (logo_x, logo_y), logo)

    return frame


def save_indexed(frame, path):
    # Palette-reduce: mostly-solid-white frames compress far smaller as indexed PNG
    q = frame.convert("P", palette=Image.ADAPTIVE, colors=128)
    q.save(path, optimize=True)


# ---- part0: fade-in (no sparkles yet), ~1s ----
part0_dir = os.path.join(OUT_DIR, "part0")
os.makedirs(part0_dir, exist_ok=True)
N0 = 14
for i in range(N0):
    t = i / (N0 - 1)
    alpha = int(255 * (t ** 0.7))
    frame = render_frame(alpha, 0, sparkles_on=False)
    save_indexed(frame, os.path.join(part0_dir, f"{i:04d}.png"))

# ---- part1: looping sparkle twinkle, logo static, ~2.4s loop @15fps ----
part1_dir = os.path.join(OUT_DIR, "part1")
os.makedirs(part1_dir, exist_ok=True)
N1 = 36
for i in range(N1):
    t = (i / N1) * 2 * math.pi  # exact period -> seamless loop
    frame = render_frame(255, t, sparkles_on=True)
    save_indexed(frame, os.path.join(part1_dir, f"{i:04d}.png"))

# ---- desc.txt ----
desc_path = os.path.join(OUT_DIR, "desc.txt")
with open(desc_path, "w", newline="\n") as f:
    f.write(f"{W} {H} {FPS}\n")
    f.write("p 1 0 part0\n")
    f.write("p 0 0 part1\n")

# ---- zip (STORED, no compression on top of PNG's own compression) ----
zip_path = os.path.join(OUT_DIR, "bootanimation.zip")
if os.path.exists(zip_path):
    os.remove(zip_path)
with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_STORED) as zf:
    zf.write(desc_path, "desc.txt")
    for i in range(N0):
        p = os.path.join(part0_dir, f"{i:04d}.png")
        zf.write(p, f"part0/{i:04d}.png")
    for i in range(N1):
        p = os.path.join(part1_dir, f"{i:04d}.png")
        zf.write(p, f"part1/{i:04d}.png")

size = os.path.getsize(zip_path)
print(f"bootanimation.zip: {size} bytes ({size/1024/1024:.2f} MB)")
print(f"original stock file: 1870133 bytes (1.78 MB)")
print(f"fits Path A (same-size overwrite): {size <= 1870133}")
