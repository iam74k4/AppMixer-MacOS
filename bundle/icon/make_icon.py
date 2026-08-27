#!/usr/bin/env python3
"""AppMixer のアプリアイコンを生成する。

SVG を描いてから、.icns に必要なサイズの PNG を AppIcon.iconset/ へ書き出す。
.icns への変換は macOS の iconutil が要るので Makefile 側で行う。

    python3 make_icon.py                  # 既定（暗背景）で生成
    python3 make_icon.py --variant light  # 明背景で生成

明背景／暗背景の 2 種を icon-dark.svg / icon-light.svg として常に書き出し、
実際に .icns へ焼くほう（--variant）を icon.svg と AppIcon.iconset/ に出す。
macOS 14 の .icns は外観（ライト／ダーク）で絵を切り替えられないため、
同梱できるのはどちらか一方だけ。
"""

import argparse
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).parent

# macOS のアイコンは 1024pt 角で描き、周囲に余白を取る作法に合わせる。
S = 1024
MARGIN = 100                      # 角丸矩形の外側に空ける余白
R = 185                           # 角丸半径。macOS は本体幅の 0.225 倍（824 × 0.225）
BODY = S - MARGIN * 2

# ミキサーらしさを 3 本のフェーダーで表す。値は上から見た位置（0=下, 1=上）。
FADERS = [0.72, 0.38, 0.58]

# 背景とトラックは無彩色に保ち、操作点（つまみ）と出ている音量（レベル）だけを
# システムのアクセントカラーで塗る。色数を増やさずに「触るところ」を際立たせる。
#
# hairline は明背景版だけで使う。白い Finder の上に置くと輪郭が消えるため、
# ごく薄い縁を足して形が分かるようにする。暗背景版は落ち影だけで足りる。
PALETTES = {
    "dark": dict(
        bg_top="#3A3A3C", bg_bottom="#0B0B0D",
        track="#FFFFFF", track_opacity=0.16,
        accent="#0A84FF",              # ダーク外観のシステムブルー
        level_opacity=0.55,
        hairline=None,
    ),
    "light": dict(
        bg_top="#FFFFFF", bg_bottom="#E6E6EB",
        track="#000000", track_opacity=0.14,
        accent="#007AFF",              # ライト外観のシステムブルー
        level_opacity=0.55,
        hairline="#000000",
    ),
}


def svg(bg_top, bg_bottom, track, track_opacity, accent, level_opacity, hairline) -> str:
    x0 = MARGIN
    y0 = MARGIN
    # 16px まで縮めるとトラックが 1px を割るため、実寸より太めに取る。
    track_w = 72
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
        f'    <stop offset="0" stop-color="{bg_top}"/>',
        f'    <stop offset="1" stop-color="{bg_bottom}"/>',
        '  </linearGradient>',
        '  <filter id="shadow" x="-20%" y="-20%" width="140%" height="140%">',
        '    <feDropShadow dx="0" dy="18" stdDeviation="22" flood-color="#000000" flood-opacity="0.38"/>',
        '  </filter>',
        '</defs>',
        f'<rect x="{x0}" y="{y0}" width="{BODY}" height="{BODY}" rx="{R}" '
        f'fill="url(#bg)" filter="url(#shadow)"/>',
    ]

    if hairline:
        parts.append(
            f'<rect x="{x0 + 2}" y="{y0 + 2}" width="{BODY - 4}" height="{BODY - 4}" rx="{R - 2}" '
            f'fill="none" stroke="{hairline}" stroke-width="4" stroke-opacity="0.10"/>'
        )

    for i, value in enumerate(FADERS):
        cx = x0 + gap * (i + 0.5)
        # トラック
        parts.append(
            f'<rect x="{cx - track_w / 2}" y="{inner_top}" width="{track_w}" height="{span}" '
            f'rx="{track_w / 2}" fill="{track}" opacity="{track_opacity}"/>'
        )
        knob_cy = inner_bot - span * value
        # つまみより下＝出ている音量ぶん
        parts.append(
            f'<rect x="{cx - track_w / 2}" y="{knob_cy}" width="{track_w}" '
            f'height="{inner_bot - knob_cy}" rx="{track_w / 2}" fill="{accent}" '
            f'opacity="{level_opacity}"/>'
        )
        # つまみ
        parts.append(
            f'<rect x="{cx - knob_w / 2}" y="{knob_cy - knob_h / 2}" width="{knob_w}" '
            f'height="{knob_h}" rx="{knob_h / 2}" fill="{accent}"/>'
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
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--variant", choices=sorted(PALETTES), default="dark",
                    help=".icns に焼くほうの配色（既定: dark）")
    args = ap.parse_args()

    for name, palette in PALETTES.items():
        (HERE / f"icon-{name}.svg").write_text(svg(**palette), encoding="utf-8")
        print(f"wrote icon-{name}.svg")

    source = HERE / "icon.svg"
    source.write_text(svg(**PALETTES[args.variant]), encoding="utf-8")
    print(f"wrote {source.name} ({args.variant})")

    out = HERE / "AppIcon.iconset"
    out.mkdir(exist_ok=True)

    try:
        import cairosvg
    except ImportError:
        cairosvg = None

    if cairosvg is not None:
        for name, px in SIZES:
            cairosvg.svg2png(url=str(source), write_to=str(out / name),
                             output_width=px, output_height=px)
    else:
        # cairosvg が無い環境では macOS 標準の sips で SVG を読ませる。
        # SVG を単一の正としたまま、追加の依存を増やさずに済む。
        for name, px in SIZES:
            r = subprocess.run(
                ["sips", "-s", "format", "png", "-z", str(px), str(px),
                 str(source), "--out", str(out / name)],
                capture_output=True)
            if r.returncode != 0:
                print("error: sips で SVG を変換できませんでした。"
                      "cairosvg を入れてください (pip install cairosvg)", file=sys.stderr)
                return 1
    print(f"wrote {len(SIZES)} png into {out.name}/")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
