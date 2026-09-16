#!/usr/bin/env python3
"""SIGMA assembly-quality figure: short-read-only vs. hybrid-ONT vs.
hybrid-PacBio, real QUAST-vs-reference numbers from
OmniOmics-validation/sigma/results/quast_vs_reference_report*.tsv (the exact
figures already reported in the paper's Table 3 / Discussion) -- nothing
here is invented or estimated."""
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mticker

plt.rcParams["font.family"] = "DejaVu Sans"
plt.rcParams["font.size"] = 11

labels = ["Short-only", "Hybrid\n(ONT)", "Hybrid\n(PacBio)"]
colors = ["#9e9e9e", "#4c78a8", "#e08214"]

contigs = [87, 2, 33]
genome_fraction = [97.783, 100.000, 99.036]
n50 = [116054, 4765451, 742616]
misassemblies = [0, 0, 21]

fig, axes = plt.subplots(1, 4, figsize=(13, 3.4))

def bar_panel(ax, values, title, ylabel, fmt="{:.0f}", log=False, ylim=None):
    bars = ax.bar(labels, values, color=colors, width=0.62, edgecolor="black", linewidth=0.6)
    ax.set_title(title, fontsize=11, fontweight="bold")
    ax.set_ylabel(ylabel, fontsize=9.5)
    if log:
        ax.set_yscale("log")
    if ylim:
        ax.set_ylim(*ylim)
    ax.spines["top"].set_visible(False)
    ax.spines["right"].set_visible(False)
    for b, v in zip(bars, values):
        ax.annotate(
            fmt.format(v),
            xy=(b.get_x() + b.get_width() / 2, b.get_height()),
            xytext=(0, 4),
            textcoords="offset points",
            ha="center",
            fontsize=9,
        )
    ax.tick_params(axis="x", labelsize=9)
    ax.tick_params(axis="y", labelsize=8.5)

bar_panel(axes[0], contigs, "# Contigs", "count (log scale)", "{:.0f}", log=True)
bar_panel(axes[1], genome_fraction, "Genome fraction", "%", "{:.2f}%", ylim=(90, 101))
bar_panel(axes[2], n50, "N50", "bp (log scale)", "{:,.0f}", log=True)
bar_panel(axes[3], misassemblies, "Misassemblies", "count", "{:.0f}", ylim=(0, 24))

fig.suptitle(
    "SIGMA -- real assembly quality vs. reference, same E. coli isolate (QUAST)",
    fontsize=12.5, fontweight="bold", y=1.04,
)
fig.tight_layout()
out = "/home/angelo/Documentos/OmniOmics/paper/figures/SIGMA_assembly_quality.png"
fig.savefig(out, dpi=300, bbox_inches="tight", facecolor="white")
print("Wrote", out)
