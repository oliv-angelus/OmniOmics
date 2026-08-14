#!/usr/bin/env python3
"""Detects a title clipped by its own title bar, in a rendered preview.png.

    .venv/bin/python3 scripts/check_title_clipping.py FIGURE.png [FIGURE.png ...]

Exits non-zero if any figure is clipped. Used on its own for one figure, and
folded into run_plots_suite.py so a whole pipeline's analyses are checked as
they render.

It exists because `with_title_bar` (plots/scripts/lib/plot_theme.R) wraps the
title to a *guessed* fraction of the figure width -- `plot_width_in * 0.65`,
calibrated by eye on plots whose chrome is a y-axis plus a legend. The guess
does not hold once a plot has a facet strip column, and the title then runs past
the bar at both ends. That has now happened twice, in sigma_genome_quality_
overview (fixed at the time by passing the width through) and in
magma_mag_abundance. Nothing catches it: the script exits 0, the PNG is written,
and only a human looking at the figure notices.

See notes/Known Issues and Next Steps.md for the measurements behind the bug --
the gtable reports a 7.49in panel where the bar renders 6.68in wide. Fixing
with_title_bar needs a check that can prove non-regression across many figures,
which is what this is; the fix itself should come after, not before.

## How it detects the bar, and why not by colour

The obvious approach -- find pixels of `gray70` -- breaks as soon as a user
restyles the figure, because the panel background is theirs to choose and can be
gray70 too. This instead uses structure, which restyling cannot change:

* ggsave writes the figure on a white ground, so anything non-white at the very
  top of the image is the title bar.
* The bar is a solid rectangle, so within its rows the non-white pixels form one
  contiguous horizontal run.
* The title text sits inside that run and is much darker than the bar.

A title is clipped when its dark pixels reach the run's first or last column:
text that fits always leaves the bar's own padding on both sides.
"""
import os
import sys

import numpy as np
from PIL import Image

# Anything at least this bright counts as the page, not the figure. ggsave's
# white is exactly 1.0; the tolerance is for PNG quantisation only.
WHITE = 0.99
# How much darker than the bar itself a pixel has to be to count as a glyph.
# Measured against the bar's own shade rather than a fixed level, so the test
# survives a restyled figure: the title is near-black on a mid grey, and any
# bar dark enough to close a 0.25 gap would not be readable text anyway.
INK_DROP = 0.25
# Two rows belong to the same fill if their medians are this close. Comfortably
# below the gap between the default bar and panel (gray70 vs gray90) and well
# above PNG quantisation.
SHADE_TOLERANCE = 0.04
# How many consecutive rows of one shade establish the bar's fill, as opposed to
# an antialiased edge row. Edges are one or two rows; the thinnest bar rendered
# here is 26px.
SOLID_ROWS = 4
# The bar never occupies more than a small band at the top. Scanning further
# risks walking into the plot panel, which can also be a contiguous non-white
# run and would then be mistaken for the bar.
MAX_BAND_FRACTION = 0.30


def _rows_of_bar(gray: np.ndarray) -> tuple[int, int, float] | None:
    """First row, last row and grey level of the title bar, or None if no bar.

    Walks down from the top: skips any white margin, then takes rows while they
    keep looking like the bar -- one contiguous non-white run, roughly where the
    previous row had one, and of the same shade.

    That last condition is not decoration. The bar is laid directly on top of
    the plot panel with no white gap between them, and the panel has the same
    left and right edges as the bar, so width alone never says where the bar
    ends: the walk ran on into the panel, and the plot's own content -- points,
    legend text, axis labels -- was then read as title text spanning the full
    width, reporting every such figure as clipped. Shade separates them because
    the bar is a solid fill and the panel is a different solid fill; a row's
    median is unmoved by the title glyphs sitting on it, which cover little of
    its width. This stays a structural test rather than a hunt for gray70 --
    a restyled figure keeps a uniform bar, whatever colour the user chose.
    """
    height = gray.shape[0]
    limit = int(height * MAX_BAND_FRACTION)

    # Pass 1: the leading run of rows that could be a bar -- non-white, one
    # contiguous span, at a stable width. This alone overshoots into the panel.
    rows: list[int] = []
    extent = None
    for y in range(limit):
        row = gray[y]
        nonwhite = np.flatnonzero(row < WHITE)
        if nonwhite.size == 0:
            if not rows:
                continue  # still in the top margin
            break
        left, right = int(nonwhite[0]), int(nonwhite[-1])
        # Contiguous run? Text inside the bar is non-white too, so the run
        # stays solid; a plot panel with white gridlines would not.
        if nonwhite.size != right - left + 1:
            break
        if extent is None:
            extent = (left, right)
        elif abs(left - extent[0]) > 2 or abs(right - extent[1]) > 2:
            break
        rows.append(y)

    if not rows:
        return None

    # Pass 2: the bar is the solid fill inside that run. Its first row or two
    # are antialiased against the white above -- a shade of their own, belonging
    # to neither -- so anchoring on the topmost row measured the blend and ended
    # the bar immediately. Anchor instead on the first shade that persists,
    # which is the fill itself.
    medians = [float(np.median(gray[y][extent[0]:extent[1] + 1])) for y in rows]
    anchor = None
    for i in range(len(medians) - SOLID_ROWS + 1):
        window = medians[i:i + SOLID_ROWS]
        if max(window) - min(window) <= SHADE_TOLERANCE:
            anchor = i
            break
    if anchor is None:
        return None

    shade = float(np.median(medians[anchor:anchor + SOLID_ROWS]))
    end = anchor
    while end + 1 < len(medians) and abs(medians[end + 1] - shade) <= SHADE_TOLERANCE:
        end += 1

    # A run that never stops before the scan limit is not a title bar -- it is
    # the plot panel, which is exactly what this walk must not mistake for one.
    if rows[end] >= limit - 1:
        return None
    return (rows[anchor], rows[end], shade)


def check(path: str) -> tuple[bool, str]:
    """(ok, message) for one figure."""
    try:
        img = Image.open(path).convert("L")
    except Exception as exc:  # noqa: BLE001 -- a broken PNG is a real result
        return False, f"could not be read: {exc}"

    gray = np.asarray(img, dtype=float) / 255.0
    band = _rows_of_bar(gray)
    if band is None:
        # Not every analysis uses a title bar. Absence is not a failure.
        return True, "no title bar"

    top, bottom, shade = band
    strip = gray[top:bottom + 1]
    nonwhite = np.flatnonzero((strip < WHITE).any(axis=0))
    bar_left, bar_right = int(nonwhite[0]), int(nonwhite[-1])

    ink = np.flatnonzero((strip < shade - INK_DROP).any(axis=0))
    if ink.size == 0:
        return True, f"bar {bar_left}-{bar_right}px, no text"

    text_left, text_right = int(ink[0]), int(ink[-1])
    # Touching the edge means the glyph was cut by it: a title that fits keeps
    # the bar's padding clear on both sides.
    clipped_left = text_left <= bar_left
    clipped_right = text_right >= bar_right
    detail = (f"bar {bar_left}-{bar_right}px, text {text_left}-{text_right}px "
              f"({100 * (text_right - text_left) / max(1, bar_right - bar_left):.0f}% of the bar)")
    if clipped_left or clipped_right:
        sides = " and ".join(s for s, c in (("left", clipped_left), ("right", clipped_right)) if c)
        return False, f"title clipped on the {sides} -- {detail}"
    return True, detail


def main() -> int:
    paths = sys.argv[1:]
    if not paths:
        print(__doc__.strip().splitlines()[2].strip())
        return 2

    problems = 0
    for path in paths:
        ok, message = check(path)
        # The suite writes one preview.png per analysis directory, so there the
        # directory is the name worth showing. Anywhere else the file's own name
        # is -- naming them all after a shared parent makes a list of results
        # impossible to read back against the figures.
        stem, parent = os.path.basename(path), os.path.basename(os.path.dirname(path))
        label = parent if (stem == "preview.png" and parent) else stem
        print(f"  [{'ok  ' if ok else 'CLIP'}] {label:<52} {message}")
        problems += 0 if ok else 1

    print(f"\n{problems} clipped title(s) in {len(paths)} figure(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
