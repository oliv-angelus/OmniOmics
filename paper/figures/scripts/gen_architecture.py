#!/usr/bin/env python3
"""OmniOmics architecture figure: client / backend / pipeline registry, a
plain software-architecture diagram (not a bioinformatics workflow), drawn
directly from the Methods 2.1 Architecture description -- no invented
components."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.patches import FancyBboxPatch, FancyArrowPatch
from matplotlib.lines import Line2D

plt.rcParams["font.family"] = "DejaVu Sans"

fig, ax = plt.subplots(figsize=(9.5, 8.2))
ax.set_xlim(0, 10)
ax.set_ylim(0, 11.6)
ax.axis("off")

BLUE = "#4c78a8"
BLUE_L = "#dae8fc"
GREEN = "#59a14f"
GREEN_L = "#d5e8d4"
ORANGE = "#e08214"
ORANGE_L = "#ffe6cc"
GREY = "#666666"


def box(x, y, w, h, text, fc, ec, fontsize=10.5, bold=True, textcolor="black"):
    p = FancyBboxPatch(
        (x, y), w, h,
        boxstyle="round,pad=0.02,rounding_size=0.08",
        linewidth=1.4, edgecolor=ec, facecolor=fc, zorder=2,
    )
    ax.add_patch(p)
    ax.text(
        x + w / 2, y + h / 2, text,
        ha="center", va="center", fontsize=fontsize,
        fontweight="bold" if bold else "normal", color=textcolor,
        zorder=3, wrap=True,
    )
    return p


def arrow(x1, y1, x2, y2, text="", style="<->", color=GREY, fontsize=8.7, dx_text=0.28):
    a = FancyArrowPatch(
        (x1, y1), (x2, y2),
        arrowstyle=style, mutation_scale=14,
        linewidth=1.3, color=color, zorder=1,
    )
    ax.add_patch(a)
    if text:
        ax.text(
            (x1 + x2) / 2 + dx_text, (y1 + y2) / 2, text,
            ha="left", va="center", fontsize=fontsize, color=color, style="italic",
        )


# --- Client layer ---
box(2.4, 10.0, 5.2, 1.2, "Flutter Desktop Client\n(GUI only -- no HTML/WebView)", BLUE_L, BLUE, fontsize=11.5)

arrow(5.0, 10.0, 5.0, 9.15, style="<->", color=GREY)
ax.text(5.35, 9.58, "HTTP + WebSocket\n127.0.0.1 (local only)", ha="left", va="center",
        fontsize=8.8, style="italic", color=GREY)

# --- Backend layer ---
box(1.6, 7.35, 6.8, 1.55, "", "white", BLUE, fontsize=1)
ax.text(5.0, 8.68, "FastAPI / Python Backend", ha="center", va="center",
        fontsize=12, fontweight="bold")
ax.text(5.0, 8.36, "(spawned as a local child process of the client)", ha="center", va="center",
        fontsize=9, style="italic", color=GREY)

sub_labels = [
    "conda / Snakemake\nenv management",
    "Database download\n+ checksum",
    "Run monitoring +\nlog parsing",
    "Plots API\n(R scripts)",
]
sub_w = 1.43
gap = 0.15
start_x = 1.9
for i, lab in enumerate(sub_labels):
    x = start_x + i * (sub_w + gap)
    box(x, 7.5, sub_w, 0.68, lab, "#f5f5f5", "#999999", fontsize=7.8, bold=False)

# --- discovery arrow ---
arrow(5.0, 7.35, 5.0, 6.55, style="<->", color=GREY)
ax.text(5.35, 6.95, "discovers pipelines at startup by\nscanning for pipeline.yaml",
        ha="left", va="center", fontsize=8.8, style="italic", color=GREY)

# --- Pipeline registry layer ---
box(0.6, 5.3, 8.8, 1.15, "", "white", GREEN, fontsize=1)
ax.text(5.0, 6.1, "Pipeline Registry -- pipelines/<id>/", ha="center", va="center",
        fontsize=11.5, fontweight="bold")
ax.text(5.0, 5.72, "each a self-contained directory: Snakefile + pipeline.yaml manifest + per-tool conda envs",
        ha="center", va="center", fontsize=8.6, style="italic", color=GREY)

pipe_labels = ["MAGMA", "SIGMA", "DOGMA", "DEFINE", "PRISM"]
pw = 1.5
pgap = 0.15
pstart = 0.85
for i, lab in enumerate(pipe_labels):
    x = pstart + i * (pw + pgap)
    box(x, 3.9, pw, 0.85, lab, GREEN_L, GREEN, fontsize=10.5)
    arrow(5.0, 5.3, x + pw / 2, 4.75, style="->", color=GREY)

# --- execution layer ---
arrow(5.0, 3.9, 5.0, 3.05, style="->", color=GREY)
ax.text(5.35, 3.48, "backend spawns snakemake, one\nisolated conda env per tool",
        ha="left", va="center", fontsize=8.8, style="italic", color=GREY)

box(1.6, 1.9, 6.8, 1.05, "Snakemake execution\n(one isolated, version-pinned conda environment per tool)",
    ORANGE_L, ORANGE, fontsize=10)

# --- extensibility note ---
ax.annotate(
    "Adding a pipeline = adding a new directory here.\nNo application code changes.",
    xy=(1.3, 5.55), xycoords="data",
    xytext=(1.55, 0.55), textcoords="data",
    ha="center", va="center", fontsize=9.3, fontstyle="italic", color=BLUE,
    arrowprops=dict(arrowstyle="-", color=BLUE, lw=1, linestyle=(0, (3, 2)),
                     connectionstyle="arc3,rad=-0.15"),
)

fig.suptitle("OmniOmics -- client / backend / pipeline-registry architecture",
              fontsize=13, fontweight="bold", y=0.995)
fig.tight_layout(rect=[0, 0, 1, 0.98])
out = "/home/angelo/Documentos/OmniOmics/paper/figures/architecture.png"
fig.savefig(out, dpi=300, bbox_inches="tight", facecolor="white")
print("Wrote", out)
