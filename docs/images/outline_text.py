#!/usr/bin/env python3
"""SVG 内の <text> をパスへ変換する。

閲覧側に日本語フォントが無くても崩れないようにするため。
生成物（mixer-*.svg）はこれを通したものをコミットする。
"""

import re
import sys
from fontTools.ttLib import TTCollection, TTFont
from fontTools.pens.svgPathPen import SVGPathPen

FONTS = {
    "400": ("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", 0),
    "500": ("/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc", 0),
    "600": ("/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc", 0),
}

_cache = {}


def load(weight):
    if weight not in _cache:
        path, index = FONTS.get(weight, FONTS["400"])
        try:
            font = TTCollection(path).fonts[index]
        except Exception:
            font = TTFont(path, fontNumber=index)
        _cache[weight] = font
    return _cache[weight]


def advance(font, glyph):
    hmtx = font["hmtx"]
    return hmtx[glyph][0] if glyph in hmtx.metrics else 0


def text_to_path(content, x, y, size, weight, anchor, fill):
    font = load(weight)
    upem = font["head"].unitsPerEm
    scale = size / upem
    cmap = font.getBestCmap()
    glyphset = font.getGlyphSet()

    glyphs, total = [], 0
    for ch in content:
        name = cmap.get(ord(ch))
        if name is None:
            total += upem * 0.5
            continue
        glyphs.append((name, total))
        total += advance(font, name)

    width = total * scale
    offset = {"start": 0.0, "middle": -width / 2, "end": -width}[anchor]

    parts = []
    for name, pos in glyphs:
        pen = SVGPathPen(glyphset)
        glyphset[name].draw(pen)
        d = pen.getCommands()
        if not d:
            continue
        tx = x + offset + pos * scale
        parts.append(
            f'<path d="{d}" fill="{fill}" '
            f'transform="translate({tx:.2f} {y:.2f}) scale({scale:.5f} {-scale:.5f})"/>'
        )
    return "".join(parts)


TEXT_RE = re.compile(
    r'<text x="([-\d.]+)" y="([-\d.]+)"[^>]*?font-size="([\d.]+)"'
    r'[^>]*?font-weight="(\d+)"[^>]*?fill="([^"]+)"[^>]*?text-anchor="(\w+)">([^<]*)</text>'
)


def convert(svg):
    def repl(m):
        x, y, size, weight, fill, anchor, content = m.groups()
        return text_to_path(content, float(x), float(y), float(size), weight, anchor, fill)

    out, count = TEXT_RE.subn(repl, svg)
    if "<text" in out:
        raise SystemExit("error: some <text> elements were not converted")
    return out, count


if __name__ == "__main__":
    for path in sys.argv[1:]:
        with open(path, encoding="utf-8") as f:
            svg = f.read()
        converted, n = convert(svg)
        with open(path, "w", encoding="utf-8") as f:
            f.write(converted)
        print(f"{path}: outlined {n} text elements")
