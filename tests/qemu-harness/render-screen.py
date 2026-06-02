#!/usr/bin/env python3
# render-screen.py — rasterize ANSI 256-color text onto an 800x480 canvas, matching
# the printer's real 4.3" framebuffer console (8x16 cell grid, 100x30 chars).
#
# Usage: render-screen.py <ansi-in> <png-out> [center|topleft]
#   center  — center the text block (boot splash)
#   topleft — anchor top-left like a console (boot log)   [default]
import sys, re
from PIL import Image, ImageDraw, ImageFont

WIDTH, HEIGHT = 800, 480           # the real panel
CELL_W, CELL_H = 8, 16             # fbcon 8x16 -> 100 cols x 30 rows
FONT_PX = 15                       # DejaVu mono that reads well inside an 8x16 cell
BG = (11, 11, 14)                  # near-black warm console
FG = (208, 208, 208)              # default (reset) text
FONT_DIR = "/usr/share/fonts/TTF"
REG  = ImageFont.truetype(f"{FONT_DIR}/DejaVuSansMono.ttf", FONT_PX)
BOLD = ImageFont.truetype(f"{FONT_DIR}/DejaVuSansMono-Bold.ttf", FONT_PX)


def xterm(n):
    if n < 16:
        b = [(0,0,0),(205,0,0),(0,205,0),(205,205,0),(0,0,238),(205,0,205),(0,205,205),
             (229,229,229),(127,127,127),(255,0,0),(0,255,0),(255,255,0),(92,92,255),
             (255,0,255),(0,255,255),(255,255,255)]
        return b[n]
    if n <= 231:
        n -= 16; r, g, b = n // 36, (n % 36) // 6, n % 6
        f = lambda x: 0 if x == 0 else 55 + 40 * x
        return (f(r), f(g), f(b))
    v = 8 + (n - 232) * 10
    return (v, v, v)


def parse(text):
    """ANSI text -> list of rows; each row is a list of (char, (r,g,b), bold)."""
    text = text.replace("\r", "")
    text = "\n".join(l for l in text.split("\n")
                     if not l.startswith("Script started") and not l.startswith("Script done"))
    tok = re.compile(r"\x1b\[([0-9;]*)m")
    color, bold = FG, False
    rows, row, pos = [], [], 0
    def emit(seg):
        nonlocal row, rows
        for ch in seg:
            if ch == "\n":
                rows.append(row); row = []
            else:
                row.append((ch, color, bold))
    for m in tok.finditer(text):
        emit(text[pos:m.start()]); pos = m.end()
        parts = [p for p in m.group(1).split(";") if p != ""]
        if not parts or parts == ["0"]:
            color, bold = FG, False; continue
        k = 0
        while k < len(parts):
            p = parts[k]
            if p == "0":
                color, bold = FG, False
            elif p == "1":
                bold = True
            elif p == "38" and k + 2 < len(parts) and parts[k + 1] == "5":
                color = xterm(int(parts[k + 2])); k += 2
            k += 1
    emit(text[pos:])
    rows.append(row)
    while rows and not rows[-1]:
        rows.pop()
    return rows


def main():
    src, out = sys.argv[1], sys.argv[2]
    align = sys.argv[3] if len(sys.argv) > 3 else "topleft"
    rows = parse(open(src, encoding="utf-8", errors="replace").read())
    img = Image.new("RGB", (WIDTH, HEIGHT), BG)
    d = ImageDraw.Draw(img)
    nrows = len(rows)
    maxcols = max((len(r) for r in rows), default=0)
    if align == "center":
        x0 = max(0, (WIDTH - maxcols * CELL_W) // 2)
        y0 = max(0, (HEIGHT - nrows * CELL_H) // 2)
    else:
        x0, y0 = CELL_W, CELL_H // 2
    for ri, row in enumerate(rows):
        y = y0 + ri * CELL_H
        if y + CELL_H > HEIGHT:
            break
        for ci, (ch, col, bold) in enumerate(row):
            x = x0 + ci * CELL_W
            if x + CELL_W > WIDTH:
                break
            if ch != " ":
                d.text((x, y - 1), ch, font=(BOLD if bold else REG), fill=col)
    img.save(out)
    print(f"  wrote {out} ({WIDTH}x{HEIGHT})")


if __name__ == "__main__":
    main()
