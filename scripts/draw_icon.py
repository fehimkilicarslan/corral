#!/usr/bin/env python3
"""Draws Assets/icon.svg and Assets/icon-square.svg.

The icon is a world on Corral's terracotta, printed the way the Insights plates
are: every mark a cell on one grid, its shade worked out from a lit sphere and
turned into ink by the same Bayer 8x8 matrix and the same three levels as
Sources/Corral/DitherArt.swift. A picture made of a few hundred squares is not
something to edit by hand, so this script is its source and the SVGs are its
output. scripts/make_icon.sh runs it before rendering the .icns.

No strokes and no circles. Earlier drafts drew a corral (a fence, a pen, a
lasso) and every one read as something else at icon size; one drew a ringed
planet with moons, and the vector ring and flat discs looked cheap next to the
dithered planet. Cells alone stay crisp, and the shape survives at 16 px as a
light disc on orange.
"""
import math
from pathlib import Path

ASSETS = Path(__file__).resolve().parent.parent / "Assets"

BAYER = [
    [0, 32, 8, 40, 2, 34, 10, 42],
    [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44, 4, 36, 14, 46, 6, 38],
    [60, 28, 52, 20, 62, 30, 54, 22],
    [3, 35, 11, 43, 1, 33, 9, 41],
    [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47, 7, 39, 13, 45, 5, 37],
    [63, 31, 55, 23, 61, 29, 53, 21],
]

# Whole pixels, so cells land on whole pixels at 1024, 512 and 256 and no
# rendering of the icon smears a cell edge.
CELL = 24
# Cells across the planet. Odd, so one cell sits dead centre; 23 of them is two
# thirds of the tile, with room around it.
CELLS = 23
RADIUS = CELLS * CELL / 2
CENTRE = 512
ORIGIN = int(CENTRE - RADIUS)

# The tile is the app's terracotta, Theme.accent(.claudeCode), #D97857, a
# little lighter at the top left and darker at the bottom right.
TILE = ("#ec9a72", "#d97757", "#a8442d")
# Three inks, darkest first: the night side, the half-tone, the lit side. The
# half-tone is kept clearly lighter than the tile's lightest corner, or the lit
# edge of the planet melts into the background.
INKS = ("#5c2216", "#f9c7a8", "#fff3e7")
# From the top left and in front: three quarters of the world in daylight.
LIGHT = (-0.5, -0.6, 0.62)


def level(density, col, row):
    """Paper, half ink or full ink: DitherArt.level, three levels."""
    d = min(1.0, max(0.0, density))
    threshold = (BAYER[row & 7][col & 7] + 0.5) / 64
    scaled = d * 2
    floor = math.floor(scaled)
    return min(2, int(floor) + (1 if scaled - floor > threshold else 0))


def planet():
    """The ink level of every cell inside the disc."""
    length = math.sqrt(sum(c * c for c in LIGHT))
    lx, ly, lz = (c / length for c in LIGHT)
    cells = {}
    for row in range(CELLS):
        for col in range(CELLS):
            u = (ORIGIN + (col + 0.5) * CELL - CENTRE) / RADIUS
            v = (ORIGIN + (row + 0.5) * CELL - CENTRE) / RADIUS
            if u * u + v * v > 1:
                continue
            z = math.sqrt(1 - u * u - v * v)
            cells[(col, row)] = level(max(0.0, u * lx + v * ly + z * lz), col, row)
    return cells


def path(cells):
    return "".join(
        f"M{ORIGIN + col * CELL} {ORIGIN + row * CELL}h{CELL}v{CELL}h-{CELL}z"
        for col, row in sorted(cells, key=lambda c: (c[1], c[0]))
    )


def svg(cells, tile):
    # One path per ink, each laid over the one below it. Cells that touch
    # share an edge inside one path, so the tile never shows through a seam.
    inks = "".join(
        f'  <path fill="{ink}" d="{path([c for c, q in cells.items() if q >= n])}"/>\n'
        for n, ink in enumerate(INKS)
    )
    if tile:
        note = ("macOS app icon: Big Sur-style rounded rect inset in a 1024 canvas with\n"
                "       transparent margins.")
        back = ('  <rect x="100" y="100" width="824" height="824" rx="180" fill="url(#bg)" filter="url(#sh)"/>\n'
                '  <rect x="100" y="100" width="824" height="824" rx="180" fill="url(#sheen)"/>\n')
    else:
        note = ("Full-bleed square of the app icon, for the marketing PNG: icon.svg\n"
                "       without the margin, the rounding or the shadow.")
        back = ('  <rect x="0" y="0" width="1024" height="1024" fill="url(#bg)"/>\n'
                '  <rect x="0" y="0" width="1024" height="1024" fill="url(#sheen)"/>\n')
    return f'''<svg width="1024" height="1024" viewBox="0 0 1024 1024" fill="none" xmlns="http://www.w3.org/2000/svg">
  <!-- {note} Drawn by scripts/draw_icon.py, which
       explains the picture; edit that, not this, and run scripts/make_icon.sh. -->
  <defs>
    <linearGradient id="bg" x1="100" y1="100" x2="924" y2="924" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="{TILE[0]}"/>
      <stop offset="55%" stop-color="{TILE[1]}"/>
      <stop offset="100%" stop-color="{TILE[2]}"/>
    </linearGradient>
    <linearGradient id="sheen" x1="512" y1="100" x2="512" y2="560" gradientUnits="userSpaceOnUse">
      <stop offset="0%" stop-color="#fff" stop-opacity="0.14"/>
      <stop offset="100%" stop-color="#fff" stop-opacity="0"/>
    </linearGradient>
    <filter id="sh" x="-20%" y="-20%" width="140%" height="140%">
      <feDropShadow dx="0" dy="14" stdDeviation="22" flood-color="#000000" flood-opacity="0.3"/>
    </filter>
  </defs>
{back}{inks}</svg>
'''


if __name__ == "__main__":
    cells = planet()
    (ASSETS / "icon.svg").write_text(svg(cells, tile=True))
    (ASSETS / "icon-square.svg").write_text(svg(cells, tile=False))
    print(f"Drew {ASSETS / 'icon.svg'} and {ASSETS / 'icon-square.svg'}")
