#!/usr/bin/env python3
"""AppMixer のアプリアイコンを生成する。

SVG を描いてから、.icns に必要なサイズの PNG を AppIcon.iconset/ へ書き出す。
.icns への変換は macOS の iconutil が要るので Makefile 側で行う。

    python3 make_icon.py     # icon.svg と AppIcon.iconset/*.png を生成
"""

import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).parent

# macOS のアイコンは 1024pt 角で描き、周囲に余白を取る作法に合わせる。
S = 1024
MARGIN = 100                      # 角丸矩形の外側に空ける余白
R = 228                           # 角丸半径（Big Sur 以降の比率に近づける）
BODY = S - MARGIN * 2

# ミキサーらしさを 3 本のフェーダーで表す。値は上から見た位置（0=下, 1=上）。
FADERS = [0.72, 0.38, 0.58]

BG_TOP = "#3B82F6"
BG_BOTTOM = "#1D4ED8"
TRACK = "#0B265E"
KNOB = "#FFFFFF"
LEVEL = "#7DD3FC"


def svg() -> str:
    x0 = MARGIN
    y0 = MARGIN
    track_w = 52
    knob_h = 108
    knob_w = 150
    gap = BODY / 3
    inner_top = y0 + 165
    inner_bot = y0 + BODY - 165
    span = inner_bot - inner_top

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" viewBox="0 0 {S} {S}">',
        '<defs>',
        '  <linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">',
        f'    <stop offset="0" stop-color="{BG_TOP}"/>',
        f'    <stop offset="1" stop-color="{BG_BOTTOM}"/>',
        '  </linearGradient>',
        '</defs>',
        f'<rect x="{x0}" y="{y0}" width="{BODY}" height="{BODY}" rx="{R}" fill="url(#bg)"/>',
    ]

    for i, value in enumerate(FADERS):
        cx = x0 + gap * (i + 0.5)
        # トラック
        parts.append(
            f'<rect x="{cx - track_w / 2}" y="{inner_top}" width="{track_w}" height="{span}" '
            f'rx="{track_w / 2}" fill="{TRACK}" opacity="0.55"/>'
        )
        knob_cy = inner_bot - span * value
        # つまみより下＝出ている音量ぶんを明るく塗る
        parts.append(
            f'<rect x="{cx - track_w / 2}" y="{knob_cy}" width="{track_w}" '
            f'height="{inner_bot - knob_cy}" rx="{track_w / 2}" fill="{LEVEL}" opacity="0.9"/>'
        )
        # つまみ
        parts.append(
            f'<rect x="{cx - knob_w / 2}" y="{knob_cy - knob_h / 2}" width="{knob_w}" '
            f'height="{knob_h}" rx="{knob_h / 2}" fill="{KNOB}"/>'
        )

    parts.append('</svg>')
    return "\n".join(parts)


# .icns に必要な (ファイル名, 実ピクセル数)
SIZES = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]


def main() -> int:
    source = HERE / "icon.svg"
    source.write_text(svg(), encoding="utf-8")
    print(f"wrote {source.name}")

    try:
        import cairosvg
    except ImportError:
        print("error: cairosvg が要ります (pip install cairosvg)", file=sys.stderr)
        return 1

    out = HERE / "AppIcon.iconset"
    out.mkdir(exist_ok=True)
    for name, px in SIZES:
        cairosvg.svg2png(url=str(source), write_to=str(out / name),
                         output_width=px, output_height=px)
    print(f"wrote {len(SIZES)} png into {out.name}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
