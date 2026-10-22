"""Rebuild Android launcher icons from the Tolaria desktop icon.

The desktop icon is a 512x512 PNG: a white squircle (x/y 50..462, i.e. 80.5% of
the canvas) with a blue water drop centred inside it, plus a soft outer shadow.

Android needs two different shapes of the same artwork:

  * adaptive icon (API 26+): a full-bleed 108dp canvas split into a background
    layer and a foreground layer. The system mask shows roughly the middle 72dp,
    so the drop has to be sized against that visible circle, not the canvas.
  * legacy icon (API < 26): one flat bitmap, which we crop to the squircle so
    the drop is not shrunk by the transparent shadow margin.

Both keep the drop at the same relative size it has on the desktop icon
(drop height / squircle height = 272 / 412 = 66%), which is what makes the app
look like the same app on both platforms.
"""

from collections import deque

from PIL import Image, ImageDraw

SRC = '.tools/tolaria_icon_src.png'
RES = 'tolaria_android/android/app/src/main/res'

# Measured from the source PNG.
SQUIRCLE = (50, 50, 462, 462)          # opaque white plate
DROP = (156, 120, 354, 392)            # blue drop bounding box
DROP_RATIO = (DROP[3] - DROP[1]) / (SQUIRCLE[3] - SQUIRCLE[1])   # 0.660

# Legacy launcher bitmap sizes (px) per density bucket.
LEGACY = {
    'mdpi': 48, 'hdpi': 72, 'xhdpi': 96, 'xxhdpi': 144, 'xxxhdpi': 192,
}
# Adaptive layers are 108dp.
ADAPTIVE = {
    'mdpi': 108, 'hdpi': 162, 'xhdpi': 216, 'xxhdpi': 324, 'xxxhdpi': 432,
}

# Adaptive icons: the system only guarantees the middle 66dp of 108dp.
VISIBLE_DP = 72.0
CANVAS_DP = 108.0


def load():
    return Image.open(SRC).convert('RGBA')


def make_legacy(src, size):
    """Flat bitmap: crop away the shadow, then downscale with a good filter."""
    plate = src.crop(SQUIRCLE)
    # Round the corners so the launcher does not show hard white edges on the
    # densities where no system mask is applied.
    mask = Image.new('L', plate.size, 0)
    radius = int(plate.size[0] * 0.22)
    ImageDraw.Draw(mask).rounded_rectangle(
        (0, 0, plate.size[0] - 1, plate.size[1] - 1), radius=radius, fill=255,
    )
    plate.putalpha(mask)
    return plate.resize((size, size), Image.LANCZOS)


def extract_drop(src):
    """Cut the drop out of the white plate, keeping its white highlight.

    The source is a white plate with a blue drop painted on it, so cropping the
    drop's bounding box still carries opaque white pixels around it. Flood
    filling inwards from the border removes that background while the highlight
    inside the drop survives, because the blue body walls it off from the edge.
    """
    img = src.crop(SQUIRCLE).convert('RGBA')
    w, h = img.size
    px = img.load()

    def white(x, y):
        r, g, b, a = px[x, y]
        return a > 8 and r > 232 and g > 232 and b > 232

    seen = bytearray(w * h)
    queue = deque()
    for x in range(w):
        queue.append((x, 0))
        queue.append((x, h - 1))
    for y in range(h):
        queue.append((0, y))
        queue.append((w - 1, y))

    while queue:
        x, y = queue.popleft()
        index = y * w + x
        if seen[index]:
            continue
        seen[index] = 1

        r, g, b, a = px[x, y]
        if a <= 8:
            # Effectively transparent, but it may still carry stray RGB bytes;
            # zero it so measuring the alpha channel gives a tight crop.
            px[x, y] = (0, 0, 0, 0)
        elif b - r > 25 and a > 100:
            continue                                # the blue drop: barrier
        elif a < 250 or (r > 225 and g > 225 and b > 225):
            # Everything else belongs to the plate: solid white, the antialiased
            # rim, and the soft drop shadow that fades out past the corner.
            px[x, y] = (0, 0, 0, 0)
        else:
            continue                                # unexpected opaque ink: keep

        for nx, ny in ((x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)):
            if 0 <= nx < w and 0 <= ny < h and not seen[ny * w + nx]:
                queue.append((nx, ny))

    # Cut to what is actually visible. Measuring the alpha channel rather than
    # Image.getbbox() matters: the shadow rim keeps leftover RGB values with a
    # near-zero alpha, and getbbox() counts those as content.
    box = img.getchannel('A').getbbox()
    return img.crop(box)


def make_foreground(src, size, drop):
    """Drop only, transparent, scaled so it sits inside the 66dp safe circle."""
    # Target drop height on the 108dp canvas, expressed as a fraction of it.
    target_h_ratio = (VISIBLE_DP * DROP_RATIO) / CANVAS_DP
    target_h = max(1, round(size * target_h_ratio))
    scale = target_h / drop.size[1]
    target_w = max(1, round(drop.size[0] * scale))
    drop = drop.resize((target_w, target_h), Image.LANCZOS)

    canvas = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    canvas.alpha_composite(
        drop, ((size - target_w) // 2, (size - target_h) // 2),
    )
    return canvas


def main():
    src = load()
    for bucket, px in LEGACY.items():
        make_legacy(src, px).save(f'{RES}/mipmap-{bucket}/ic_launcher.png')
        print(f'legacy  mipmap-{bucket}/ic_launcher.png  {px}x{px}')

    drop = extract_drop(src)
    print(f'drop extracted: {drop.size[0]}x{drop.size[1]}')
    for bucket, px in ADAPTIVE.items():
        make_foreground(src, px, drop).save(
            f'{RES}/mipmap-{bucket}/ic_launcher_foreground.png',
        )
        print(f'fg      mipmap-{bucket}/ic_launcher_foreground.png  {px}x{px}')


if __name__ == '__main__':
    main()
