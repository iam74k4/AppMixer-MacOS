#!/usr/bin/env python3
"""AppMixer のポップオーバー UI モックアップ（SVG）を生成する。

実装のレイアウトに合わせてある:
  ContentView  … 幅 420 / header・master・search・list・footer の縦積み
  AppRowView   … 1 行 2 段組（1段目: アイコン/名前/出力先/音量値、2段目: ミュート+スライダー+メーター）

スクリーンショットではなく、UI の構成を伝えるための図。
実装のレイアウトを変えたらこのスクリプトも合わせて更新すること。
"""

W = 420
PAD = 14

LIGHT = dict(
    name="light",
    bg="#F6F6F8", panel="#FFFFFF", text="#1D1D1F", dim="#6E6E73",
    divider="#E3E3E8", track="#D6D6DC", accent="#0A84FF",
    tile="#C9C9D1", tileText="#FFFFFF", warn="#D97706", shadow="0.10",
)
DARK = dict(
    name="dark",
    bg="#1C1C1E", panel="#242426", text="#F2F2F7", dim="#98989D",
    divider="#39393C", track="#48484A", accent="#0A84FF",
    tile="#5A5A60", tileText="#1C1C1E", warn="#F59E0B", shadow="0.35",
)

METER_GREEN = "#34C759"
METER_YELLOW = "#FFD60A"


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def text(x, y, s, size=12, fill="#000", weight="400", anchor="start", mono=False):
    family = (
        "ui-monospace, SFMono-Regular, Menlo, monospace" if mono
        else "-apple-system, BlinkMacSystemFont, 'Helvetica Neue', 'Hiragino Sans', sans-serif"
    )
    return (f'<text x="{x}" y="{y}" font-family="{family}" font-size="{size}" '
            f'font-weight="{weight}" fill="{fill}" text-anchor="{anchor}">{esc(s)}</text>')


def slider(x1, x2, cy, value, c, filled=True):
    """横スライダー。value は 0..1。"""
    out = [f'<rect x="{x1}" y="{cy - 2.5}" width="{x2 - x1}" height="5" rx="2.5" fill="{c["track"]}"/>']
    knob = x1 + (x2 - x1) * value
    if filled:
        out.append(f'<rect x="{x1}" y="{cy - 2.5}" width="{knob - x1}" height="5" rx="2.5" '
                   f'fill="{c["accent"]}" opacity="0.55"/>')
    out.append(f'<circle cx="{knob}" cy="{cy}" r="6.5" fill="#FFFFFF" '
               f'stroke="#000000" stroke-opacity="0.18" stroke-width="0.5"/>')
    return "".join(out)


def meter(x1, x2, y, level, color, c):
    """スライダー直下のレベルメーター。"""
    w = (x2 - x1) * level
    return (f'<rect x="{x1}" y="{y}" width="{x2 - x1}" height="4" rx="2" fill="{c["track"]}" opacity="0.7"/>'
            f'<rect x="{x1}" y="{y}" width="{w}" height="4" rx="2" fill="{color}"/>')


def speaker(x, y, c, muted=False, size=13):
    """簡易スピーカーアイコン。"""
    s = size / 13.0
    body = (f'<path d="M{x} {y + 4 * s} h{3 * s} l{4 * s} {-4 * s} v{13 * s} l{-4 * s} {-4 * s} '
            f'h{-3 * s} z" fill="{c["dim"]}"/>')
    if muted:
        body += (f'<line x1="{x + 9 * s}" y1="{y + 3 * s}" x2="{x + 15 * s}" y2="{y + 11 * s}" '
                 f'stroke="{c["dim"]}" stroke-width="{1.4 * s}" stroke-linecap="round"/>')
    else:
        for i, r in enumerate((3.5, 6.0)):
            body += (f'<path d="M{x + 9 * s} {y + 3.5 * s} a{r * s} {r * s} 0 0 1 0 {7 * s}" '
                     f'fill="none" stroke="{c["dim"]}" stroke-width="{1.3 * s}" stroke-linecap="round" '
                     f'opacity="{1 - i * 0.35}"/>')
    return body


def headphones(x, y, c, color=None):
    col = color or c["dim"]
    return (f'<path d="M{x} {y + 8} a6 6 0 0 1 12 0" fill="none" stroke="{col}" stroke-width="1.4"/>'
            f'<rect x="{x - 1}" y="{y + 7}" width="3.5" height="6" rx="1.6" fill="{col}"/>'
            f'<rect x="{x + 9.5}" y="{y + 7}" width="3.5" height="6" rx="1.6" fill="{col}"/>')


def tile(x, y, letter, c, size=30):
    """アプリアイコンの代わりのニュートラルなタイル。実在のロゴは使わない。"""
    return (f'<rect x="{x}" y="{y}" width="{size}" height="{size}" rx="7" fill="{c["tile"]}"/>'
            + text(x + size / 2, y + size / 2 + 4.5, letter, size=13,
                   fill=c["tileText"], weight="600", anchor="middle"))


def build(c):
    o = []
    rows = [
        dict(letter="M", name="Music", vol=0.20, level=0.16, pct="20%",
             badge="自動で音量を下げ中", routed=False, meter_color=METER_GREEN),
        dict(letter="C", name="Google Chrome", vol=0.80, level=0.62, pct="80%",
             badge=None, routed=True, meter_color=METER_GREEN),
        dict(letter="Z", name="Zoom", vol=1.00, level=0.88, pct="100%",
             badge=None, routed=False, meter_color=METER_YELLOW),
    ]
    H = 44 + 58 + 36 + 62 * len(rows) + 30 + 36

    o.append(f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
             f'viewBox="0 0 {W} {H}" role="img" aria-label="AppMixer のミキサー画面">')
    o.append(f'<rect width="{W}" height="{H}" rx="12" fill="{c["bg"]}"/>')

    def divider(y, indent=0):
        o.append(f'<rect x="{indent}" y="{y}" width="{W - indent}" height="1" fill="{c["divider"]}"/>')

    # --- header
    o.append(f'<rect x="{PAD}" y="14" width="4" height="16" rx="2" fill="{c["accent"]}"/>')
    o.append(f'<rect x="{PAD + 6}" y="14" width="4" height="16" rx="2" fill="{c["accent"]}" opacity="0.55"/>')
    o.append(f'<rect x="{PAD + 12}" y="14" width="4" height="16" rx="2" fill="{c["accent"]}" opacity="0.3"/>')
    o.append(text(PAD + 26, 27, "AppMixer", size=13.5, fill=c["text"], weight="600"))
    o.append(text(W - PAD, 27, "MacBook Pro のスピーカー", size=10.5, fill=c["dim"], anchor="end"))
    divider(44)

    # --- master
    o.append(speaker(PAD, 62, c, size=15))
    o.append(text(PAD + 28, 66, "マスター", size=10.5, fill=c["dim"]))
    o.append(slider(PAD + 28, W - 58, 84, 0.75, c))
    o.append(text(W - PAD, 88, "75%", size=11, fill=c["dim"], anchor="end", mono=True))
    divider(102)

    # --- search
    o.append(f'<circle cx="{PAD + 5}" cy="119" r="4.2" fill="none" stroke="{c["dim"]}" stroke-width="1.3"/>')
    o.append(f'<line x1="{PAD + 8}" y1="122" x2="{PAD + 11}" y2="125" stroke="{c["dim"]}" '
             f'stroke-width="1.3" stroke-linecap="round"/>')
    o.append(text(PAD + 20, 123, "アプリを検索", size=11.5, fill=c["dim"]))
    o.append(f'<rect x="{W - 86}" y="114" width="11" height="11" rx="2.5" fill="none" '
             f'stroke="{c["dim"]}" stroke-width="1.2"/>')
    o.append(text(W - 70, 123, "全アプリ", size=10.5, fill=c["dim"]))
    divider(138)

    # --- rows
    y = 138
    for i, r in enumerate(rows):
        o.append(tile(PAD, y + 9, r["letter"], c))
        o.append(text(PAD + 40, y + 24, r["name"], size=12.5, fill=c["text"], weight="500"))

        if r["badge"]:
            bx = PAD + 40 + len(r["name"]) * 7.2 + 8
            o.append(f'<circle cx="{bx + 4}" cy="{y + 20}" r="4.5" fill="{c["warn"]}" opacity="0.85"/>')
            o.append(text(bx + 13, y + 24, r["badge"], size=9.5, fill=c["warn"]))

        if r["routed"]:
            o.append(headphones(W - 74, y + 12, c, color=c["accent"]))
        else:
            o.append(speaker(W - 72, y + 13, c, size=12))

        o.append(text(W - PAD, y + 24, r["pct"], size=11, fill=c["text"], anchor="end", mono=True))
        o.append(speaker(PAD + 40, y + 36, c, size=12))
        o.append(slider(PAD + 62, W - PAD, y + 43, r["vol"], c))
        o.append(meter(PAD + 62, W - PAD, y + 52, r["level"], r["meter_color"], c))

        y += 62
        if i < len(rows) - 1:
            divider(y, indent=44)

    divider(y)

    # --- ducking banner
    o.append(f'<circle cx="{PAD + 5}" cy="{y + 15}" r="5" fill="{c["warn"]}" opacity="0.85"/>')
    o.append(text(PAD + 18, y + 19, "Zoom のため音量を下げています", size=10.5, fill=c["warn"]))
    y += 30
    divider(y)

    # --- footer
    o.append(text(PAD, y + 22, "更新", size=10.5, fill=c["dim"]))
    o.append(text(W - 74, y + 22, "設定", size=10.5, fill=c["dim"]))
    o.append(text(W - PAD, y + 22, "終了", size=10.5, fill=c["dim"], anchor="end"))

    o.append("</svg>")
    return "\n".join(o)


if __name__ == "__main__":
    import pathlib
    here = pathlib.Path(__file__).parent
    for theme in (LIGHT, DARK):
        (here / f"mixer-{theme['name']}.svg").write_text(build(theme), encoding="utf-8")
        print(f"wrote mixer-{theme['name']}.svg")
