# PRISM

**P**rofiling **r**RNA **I**nference of **S**pecies via **M**etabarcoding

Amplicon sequencing: community profiling from 16S, 18S, 23S/28S or ITS marker
genes, on long-read platforms. 13 rules across 6 tool environments.

> **This page is not written yet.** The workflow diagram is still to be drawn,
> and this document will be filled in alongside it. Until then, the stage-level
> summary in [`README.md`](README.md#prism--amplicon-sequencing) is accurate and
> current.

<!-- Diagram goes here once drawn, same form as the other pipelines:

<p align="center">
  <img src="../../pipelines/prism/PRISM.drawio.svg" alt="PRISM workflow diagram" width="100%">
</p>

Worth covering when this is written, because it is what distinguishes PRISM:
it is the only pipeline that builds a phylogenetic tree, which is what makes
UniFrac and weighted UniFrac available in the Plots tab. Every other pipeline's
community table is lineage-collapsed with no placed sequences, so those
distances are refused there with an explanation rather than silently
substituted.
-->
