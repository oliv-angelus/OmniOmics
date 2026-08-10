# Scientific References

Papers used to justify real design decisions in [[Project Overview|OmniOmics]] (mostly the Plots tab / R statistics engine so far). Kept so the eventual OmniOmics publication has a ready-made citation list, and so future decisions can be checked against what was actually read rather than re-derived from memory. Add an entry whenever a real published source (not just a package vignette or blog post) shapes a decision — see [[Decisions Log]] for the decisions themselves.

## Venn diagrams don't scale past ~4 sets for microbiome data
- **Shade, A. & Handelsman, J. (2012).** "Beyond the Venn diagram: the hunt for a core microbiome." *Environmental Microbiology*, 14(1), 4–12. DOI: [10.1111/j.1462-2920.2011.02585.x](https://doi.org/10.1111/j.1462-2920.2011.02585.x)
- Used to confirm `plots/scripts/analyses/venn_diagram.R`'s hard 4-set cap is correct, published practice — not an arbitrary or overly conservative limit — and that UpSet plots (`UpSetR`) are the standard alternative once there are more groups to compare. Confirms the user's own suspicion that Venn diagrams "não funcione mesmo para muitas amostras" for metagenomics group comparisons.

## Differential abundance methods disagree substantially -- DESeq2 alone (the Plots tab's current only method) is not the safest default
- **Nearing, J.T. et al. (2022).** "Microbiome differential abundance methods produce different results across 38 datasets." *Nature Communications*, 13, 342. DOI: [10.1038/s41467-022-28034-z](https://doi.org/10.1038/s41467-022-28034-z)
- **Lin, H. & Peddada, S.D. (2020).** "Analysis of compositions of microbiomes with bias correction." *Nature Communications*, 11, 3514. DOI: [10.1038/s41467-020-17041-7](https://doi.org/10.1038/s41467-020-17041-7) (ANCOM-BC)
- **Lin, H. & Peddada, S.D. (2023).** "Multigroup analysis of compositions of microbiomes with covariate adjustments and repeated measures." *Nature Methods*. DOI: [10.1038/s41592-023-02092-7](https://doi.org/10.1038/s41592-023-02092-7) (ANCOM-BC2)
- Benchmarked 14 DA methods across 38 real 16S datasets: results (which taxa come out "significant") vary drastically by tool. ALDEx2 and ANCOM-II were the most conservative/most mutually concordant; edgeR and LEfSe called the most (and least reproducible) hits. `differential_abundance_deseq2.R` is currently DESeq2-only -- not wrong, but a single-method result should be read with this in mind; adding ALDEx2 and/or ANCOM-BC2 as alternative/companion methods is the literature-backed next step, not a novel proposal.

## Naive Spearman/Pearson correlation is statistically unsound for compositional network data -- affects `cooccurrence_network.R` as currently built
- **Friedman, J. & Alm, E.J. (2012).** "Inferring Correlation Networks from Genomic Survey Data." *PLoS Computational Biology*, 8(9), e1002687. DOI: [10.1371/journal.pcbi.1002687](https://doi.org/10.1371/journal.pcbi.1002687) (SparCC)
- **Kurtz, Z.D. et al. (2015).** "Sparse and Compositionally Robust Inference of Microbial Ecological Networks." *PLoS Computational Biology*, 11(5), e1004226. DOI: [10.1371/journal.pcbi.1004226](https://doi.org/10.1371/journal.pcbi.1004226) (SPIEC-EASI)
- Because relative abundances sum to 1, plain correlation on them (what `cooccurrence_network.R` does via `Hmisc::rcorr` on relative abundance) induces spurious correlations -- Friedman & Alm's own estimate: ~3 spurious edges per true edge, ~60% of true interactions missed, in real human microbiome data. SparCC (log-ratio-based correlation) and SPIEC-EASI (clr + sparse graphical-model/conditional-independence inference, a different statistical object than pairwise correlation) are the two standard fixes, both still the field's canonical answer as of 2024–2026.

## MIMAG standard: the real completeness/contamination thresholds for MAG quality tiers
- **Bowers, R.M. et al. (2017).** "Minimum information about a single amplified genome (MISAG) and a metagenome-assembled genome (MIMAG) of bacteria and archaea." *Nature Biotechnology*, 35(8), 725–731. DOI: [10.1038/nbt.3893](https://doi.org/10.1038/nbt.3893)
- High-quality draft: >90% completeness, <5% contamination, plus 5S/16S/23S rRNA + ≥18 tRNAs present. Medium-quality: ≥50% completeness, <10% contamination. Low-quality: <50% completeness, <10% contamination. The field-standard reference for any MAG QC plot (CheckM2's own `completeness`/`contamination` columns, already produced by MAGMA at `results/06_MAG_REFINEMENT/*/checkm2/quality_report.tsv`, map directly onto these tiers) -- not yet used anywhere in the Plots tab, which has no MAG-catalog analysis at all yet.

## Random Forest / ML biomarker discovery is now a standard microbiome-analysis component, but with an active reproducibility caveat
- **Topçuoğlu, B.D. et al. (2020).** "A Framework for Effective Application of Machine Learning to Microbiome-Based Classification Problems." *mBio*, 11(3), e00434-20. DOI: [10.1128/mBio.00434-20](https://doi.org/10.1128/mBio.00434-20)
- Compares 7 ML algorithms (including random forest) for microbiome classification with a reusable, careful cross-validation framework; explicitly warns that microbiome ML performance is often overoptimistic without it. Later 2024–2025 literature increasingly flags that RF-identified "biomarkers" often don't generalize across independent cohorts/studies -- worth building as a real feature-importance complement to `differential_abundance_deseq2.R`/`indicator_species.R`, but should present results with that caveat, not as definitive biomarkers.

## Functional/pathway differential abundance uses the same compositional methods as taxonomic DA -- not a separate framework
- **Mallick, S. et al. (2021).** "Multivariable association discovery in population-scale meta-omics studies." *PLOS Computational Biology*, 17(11), e1009442. DOI: [10.1371/journal.pcbi.1009442](https://doi.org/10.1371/journal.pcbi.1009442) (MaAsLin2)
- KO/COG/pathway abundance tables (e.g. from MAGMA's own eggNOG-mapper output) are just as compositional as taxon tables -- the same DA tools (MaAsLin2, ALDEx2, ANCOM-BC2) apply directly, no separate statistical framework needed. Relevant once a functional-abundance analysis is built alongside the existing taxonomic one.

## MAG-based vs. read-based (Kraken2/Bracken) community profiling -- a real tradeoff, no single head-to-head paper
- **Quince, C. et al. (2017).** "Shotgun metagenomics, from sampling to analysis." *Nature Biotechnology*, 35(9), 833–844. DOI: [10.1038/nbt.3935](https://doi.org/10.1038/nbt.3935)
- **Meyer, F. et al. (2022).** "Critical Assessment of Metagenome Interpretation: the second round of challenges." *Nature Methods*, 19, 429–440. DOI: [10.1038/s41592-022-01431-4](https://doi.org/10.1038/s41592-022-01431-4) (CAMI II)
- No single paper directly benchmarks CoverM-style MAG coverage against Bracken read-classification as inputs to diversity statistics specifically -- flagged honestly as a documented-but-not-singly-cited tradeoff, not a gap in the search. Quince et al.'s review and the CAMI II benchmark both establish that assembly/binning-based profiling systematically undercounts low-abundance taxa (whatever doesn't assemble/bin never becomes a MAG), while k-mer/read classification counts every read regardless -- the two approaches answer subtly different questions and neither is a strict upgrade of the other.

## PRISM: SILVA (SSU+LSU) and GROND (full rrn operon) as additional reference databases, more marker genes
- **Quast, C. et al. (2013).** "The SILVA ribosomal RNA gene database project: improved data processing and web-based tools." *Nucleic Acids Research*, 41(D1), D590–D596. DOI: [10.1093/nar/gks1219](https://doi.org/10.1093/nar/gks1219)
- SILVA is the one database that curates both SSU (16S+18S together, all three domains) and LSU (23S+28S together) rRNA -- confirmed via its own real documentation (arb-silva.de), not assumed. **Real caveat found, not glossed over**: the convenient DADA2-formatted SILVA SSU training set (`silva_nr99_v138.2_toGenus_trainset.fa.gz`) is explicitly documented (DADA2's own training-data page) as bacteria/archaea-only -- "not suitable for classifying Eukaryotes" -- so genuine 18S support needs the *raw* SILVA SSU release + PRISM's own header conversion (same pattern `build_emu_taxonomy.py` already established for GTDB), not the pre-packaged DADA2 file.
- **Matschiner, M. et al. / GROND database** — Zenodo record [10.5281/zenodo.10889037](https://doi.org/10.5281/zenodo.10889037), described in the accompanying paper on full-length 16S-ITS-23S rRNA operon sequencing (PMC11261877, *Scientific Reports* 2024, 10.1038/s41598-024-83410-7 family). GTDB-derived, ~104k deduplicated 16S-ITS-23S operon sequences (median ~4,895 bp) -- purpose-built as a reference for classifying the full-operon long-read amplicon PRISM's own PacBio HiFi/ONT platforms can uniquely capture in one read (unlike short-read platforms).
- **Karst, S.M. et al. (2021)** (already cited above for the UMI method) and **Martijn, J. et al. (2019)**, "Amplicon sequencing of the 16S-ITS-23S rRNA operon with long-read technology for improved phylogenetic classification of uncultured prokaryotes" (bioRxiv, precursor to the published record) both independently confirm full rrn-operon long-read sequencing (16S-ITS-23S, ~4.3kb) is real, established practice specifically enabled by long-read platforms -- directly relevant to PRISM's own long-read-only scope, not a shotgun-sequencing analog forced onto amplicon data.

## PRISM: phylogenetic tree construction for ASVs (DADA2/phyloseq's own real, documented method)
- **Callahan, B.J. et al.** DADA2 ITS/16S workflow tutorials (benjjneb.github.io/dada2) -- the real, standard "handoff to phyloseq" method: `DECIPHER::AlignSeqs()` builds a multiple alignment of the ASV sequences directly (DADA2 is reference-free, so the tree must be built de novo, not looked up), then `phangorn` builds a neighbor-joining tree from that alignment and refines it to a GTR+G+I maximum-likelihood tree (`phangorn::pml` + `optim.pml`) using the NJ tree as the starting topology. This is the literal method used to attach a real `phy_tree()` slot to a phyloseq object built from ASVs -- not an invented approach.
- **Wright, E.S. (2016).** "Using DECIPHER v2.0 to Analyze Big Biological Sequence Data in R." *The R Journal*, 8(1), 352–359. DOI: [10.32614/RJ-2016-025](https://doi.org/10.32614/RJ-2016-025)
- **Schliep, K.P. (2011).** "phangorn: phylogenetic analysis in R." *Bioinformatics*, 27(4), 592–593. DOI: [10.1093/bioinformatics/btq706](https://doi.org/10.1093/bioinformatics/btq706)
- Directly relevant to PRISM's own `beta_diversity.R`, which already had `unifrac`/`wunifrac` removed from its `distance_method` choices specifically because MAGMA/SIGMA/DOGMA's abundance tables carry no phylogenetic tree (see this file's earlier "2026-08-03" entry) -- a real tree changes that constraint for PRISM's PacBio/DADA2 path, where genuine per-ASV sequences exist to build one from.

## PRISM: PICRUSt2 for functional inference from marker-gene taxonomy alone (no shotgun data)
- **Douglas, G.M. et al. (2020).** "PICRUSt2 for prediction of metagenome functions." *Nature Biotechnology*, 38, 685–688. DOI: [10.1038/s41587-020-0548-6](https://doi.org/10.1038/s41587-020-0548-6)
- Real, confirmed mechanism (not assumed): ASV sequences are placed into PICRUSt2's own bundled reference tree via multiple-sequence alignment + EPA-ng phylogenetic placement, then hidden-state prediction (ancestral-state reconstruction along that tree) infers each ASV's likely gene content, weighted by predicted 16S copy number, to produce a predicted metagenome functional-abundance table (KEGG orthologs/pathways, EC numbers) -- genuinely no shotgun sequencing involved, matching exactly what the user asked for. **Real scope constraint, not glossed over**: PICRUSt2's reference is 16S/bacteria-archaea-specific; it needs real per-sample ASV sequences to place (available from PRISM's PacBio/DADA2 path, not from the ONT/Emu path's reference-only EM classification, which produces no per-sample consensus sequence).

## PRISM (long-read amplicon pipeline): platform-dependent denoising, not one method for both ONT and PacBio
- **Callahan, B.J. et al. (2019).** "High-throughput amplicon sequencing of the full-length 16S rRNA gene with single-nucleotide resolution." *Nucleic Acids Research*, 47(18), e103. DOI: [10.1093/nar/gkz569](https://doi.org/10.1093/nar/gkz569)
- **Curry, K.D. et al. (2022).** "Emu: species-level microbial community profiling of full-length 16S rRNA Oxford Nanopore sequencing data." *Nature Methods*, 19, 845–853. DOI: [10.1038/s41592-022-01520-4](https://doi.org/10.1038/s41592-022-01520-4)
- **Rodríguez-Pérez, H., Ciuffreda, L. & Flores, C. (2021).** "NanoCLUST: a species-level analysis of 16S rRNA nanopore sequencing data." *Bioinformatics*, 37(11), 1600–1601. DOI: [10.1093/bioinformatics/btaa900](https://doi.org/10.1093/bioinformatics/btaa900)
- **Karst, S.M. et al. (2021).** "High-accuracy long-read amplicon sequences using unique molecular identifiers with Nanopore or PacBio sequencing." *Nature Methods*, 18, 165–169. DOI: [10.1038/s41592-020-01041-y](https://doi.org/10.1038/s41592-020-01041-y)
- PacBio HiFi CCS reads have near-zero error (Q93), so DADA2's own ASV-inference algorithm (Callahan et al. 2019) resolves exact amplicon sequence variants directly, same core algorithm as short-read Illumina data just reparameterized for longer/higher-quality reads. **ONT reads do not** — even current R10.4.1/Kit 14 chemistry's ~99% single-read accuracy is far too error-prone for DADA2's exact-sequence-matching model, which is why ONT-specific tools exist: Emu uses expectation-maximization against a reference database instead of exact inference (species-level, reference-dependent); NanoCLUST uses UMAP clustering + Canu/Racon/Medaka consensus polishing + BLAST (species-level, reference-dependent for classification only); Karst et al.'s UMI-tagging approach gets near-Sanger accuracy by physically tagging molecules before PCR (near-zero error but requires a different, UMI-aware library prep the user may not already be using). **Conclusion for PRISM: the denoising/consensus step must branch by platform** — DADA2-based for PacBio CCS, Emu (or equivalent reference-based EM) for ONT — not a single shared algorithm.

## PRISM: long-read chimera detection has a real, recently-documented false-positive problem
- **Hakimzadeh, A., Mikryukov, V., Metsoja, M., Tedersoo, L. & Anslan, S. (2025).** "Are we throwing away good data? Evaluation of chimera detection algorithms on long-read amplicons reveals high false-positive rates across algorithms." *PeerJ*. DOI: [10.7717/peerj.20456](https://doi.org/10.7717/peerj.20456)
- Benchmarked `uchime_denovo`, `removeBimeraDenovo`, and VSEARCH's newer `chimeras_denovo` on real long-read (PacBio full-ITS) amplicon data: default settings on empirical data misclassified up to **55% of real reads as chimeric** (`chimeras_denovo`) and 52.2% (`removeBimeraDenovo`); only `uchime_denovo` stayed reasonably precise (9.8% FP) at default settings, but got *worse* (19.9% FP) when parameters were tuned against simulated data instead. Authors' recommendation, directly actionable for PRISM: don't trust one chimera-filter's default output blindly — cross-check flagged "chimeras" against a reference database (BLAST rescue) before discarding, and be extra cautious on complex/environmental samples where FP rates are worse. Directly informs PRISM's chimera-handling step, which needs the same caution `venn_diagram.R`'s 4-set cap got from real literature rather than picking whatever tool sounds standard.

## DEFINE Plots tab (bacterial RNA-seq): standard DESeq2 workflow visualizations
- **Love, M.I., Huber, W. & Anders, S. (2014).** "Moderated estimation of fold change and dispersion for RNA-seq data with DESeq2." *Genome Biology*, 15, 550. DOI: [10.1186/s13059-014-0550-8](https://doi.org/10.1186/s13059-014-0550-8)
- Confirmed directly against the current (2024–2026) Bioconductor DESeq2 vignette, not just the paper: PCA (`plotPCA`), sample-to-sample distance heatmap, dispersion plot (`plotDispEsts`), and MA plot (`plotMA`, ideally with shrunk fold changes) are the vignette's own standard recommended exploratory/QC + result plots. Used to justify `sample_pca.R`/`sample_distance_heatmap.R`/`ma_plot.R` directly -- these aren't novel choices, they're the tool's own documented workflow, reimplemented in this app's ggplot2 theme instead of DESeq2's built-in base-R plots.
- **Zhu, A., Ibrahim, J.G. & Love, M.I. (2019).** "Heavy-tailed prior distributions for sequence count data: removing the noise and preserving large differences." *Bioinformatics*, 35(12), 2084–2092. DOI: [10.1093/bioinformatics/bty895](https://doi.org/10.1093/bioinformatics/bty895) (apeglm)
- The modern shrinkage estimator the DESeq2 vignette itself now recommends over the older normal-prior shrinkage -- used in `ma_plot.R`'s `lfcShrink(..., type = "apeglm")`, with a defensive fallback to unshrunk results if apeglm fails for a given design (never used in the microbiome DESeq2 script since it's a different comparison shape).

## Volcano plots: real methodological origin
- **Cui, X. & Churchill, G.A. (2003).** "Statistical tests for differential expression in cDNA microarray experiments." *Genome Biology*, 4(4), 210. DOI: [10.1186/gb-2003-4-4-210](https://doi.org/10.1186/gb-2003-4-4-210)
- No single "inventor" paper exists for RNA-seq specifically (confirmed via real search, not assumed) -- this microarray-era paper is the most defensible citation for combining fold-change (x-axis) and significance (y-axis) into the scatter format that became the volcano plot, universally adopted since across DESeq2/edgeR/limma workflows. Used to justify `plots/scripts/analyses/volcano_plot.R` (DEFINE).

## Functional enrichment for a custom-annotated organism with no curated OrgDb
- **Yu, G., Wang, L.-G., Han, Y. & He, Q.-Y. (2012).** "clusterProfiler: an R package for comparing biological themes among gene clusters." *OMICS*, 16(5), 284–287. DOI: [10.1089/omi.2011.0118](https://doi.org/10.1089/omi.2011.0118)
- **Wu, T. et al. (2021).** "clusterProfiler 4.0: A universal enrichment tool for interpreting omics data." *The Innovation*, 2(3), 100141. DOI: [10.1016/j.xinn.2021.100141](https://doi.org/10.1016/j.xinn.2021.100141)
- Confirmed directly against clusterProfiler's own documentation: `enricher()`'s generic `TERM2GENE` interface is explicitly documented by the authors for "unsupported organisms... customized annotations" -- exactly DEFINE's situation (an arbitrary user-uploaded bacterial genome annotated via Bakta + eggNOG-mapper, never in a Bioconductor org.*.eg.db package). Used to justify `functional_enrichment.R` building its own TERM2GENE mapping directly from the eggNOG-derived COG_category/GOs/KEGG_Pathway columns DEFINE's own pipeline already produces, rather than requiring any external database/OrgDb lookup.

## Gene co-expression networks need real sample-size minimums -- why DEFINE's "Network Enrichment" isn't built yet
- **Langfelder, P. & Horvath, S. (2008).** "WGCNA: an R package for weighted correlation network analysis." *BMC Bioinformatics*, 9, 559. DOI: [10.1186/1471-2105-9-559](https://doi.org/10.1186/1471-2105-9-559)
- Still the standard reference, no serious competitor as of 2026. The real, load-bearing constraint isn't in the paper itself but the maintainers' own package FAQ (Horvath lab): *"We do not recommend attempting WGCNA on a data set consisting of fewer than 15 samples... If at all possible, one should have at least 20 samples."* A typical bacterial isolate RNA-seq experiment (DEFINE's own real demo: 2 conditions × 2 replicates = 4 samples) is far below this floor -- WGCNA-based co-expression network analysis is deferred, not silently dropped, pending the user's confirmation of scope/whether it's worth gating behind a sample-count guard (same pattern as `cooccurrence_network.R`'s own `nsamples <= 4` skip) or leaving out of DEFINE's analysis set entirely.
- **Szklarczyk, D. et al. (2023).** "The STRING database in 2023: protein–protein association networks and functional enrichment analyses for any sequenced genome of interest." *Nucleic Acids Research*, 51(D1), D638–D646. DOI: [10.1093/nar/gkac1000](https://doi.org/10.1093/nar/gkac1000)
- A sample-size-independent alternative for a DE gene *list* (not counts) -- covers arbitrary sequenced genomes including custom bacterial isolates -- but requires either a live STRING REST API call or a local STRING database, an external-dependency shape nothing else in this app's R engine has needed so far (every other analysis is fully offline/local-conda). Also deferred pending a real decision on whether an internet dependency is acceptable here.

## GTDB vs. NCBI/Kraken2 taxonomic rank depth
- NCBI Taxonomy added a formal, unranked-no-more **Kingdom** rank across the tree in **October 2024**, which is why Kraken2 databases built against NCBI taxonomy from that point on (e.g. the PlusPFP family) report **8** taxonomic ranks (Domain–Kingdom–Phylum–Class–Order–Family–Genus–Species), while **GTDB**-based classifications (what MAGMA's own pipeline uses) report **7** (no separate Kingdom rank; Domain doubles as the top rank).
- Not a single peer-reviewed paper — this was confirmed via NCBI's own taxonomy database changelog/announcement, cross-checked against the real 7-rank lineage strings actually produced by MAGMA's taxonomy step and the real 8-rank lineage strings in `microbiome.R`'s own (Kraken2-derived) original example data. Used to justify `build_phyloseq.R` auto-detecting rank count from the data (`n_ranks <- max(lengths(strsplit(raw$tax, ";", fixed = TRUE)))`) instead of hardcoding either 7 or 8.

## ONT Microbial Amplicon Barcoding Kit 24 V14 (SQK-MAB114.24) — primers reais
Sequências extraídas do PDF oficial da ONT (`sqk_mab114_24_primer_sequences_16s_its.pdf`,
linkado em nanoporetech.com/document/microbial-amplicon-barcoding-sequencing-for-16s-and-its-sqk-mab114-24),
lido 2026-08-09 e apagado em seguida a pedido do usuário. Registradas aqui porque
são caras de reobter (só existem no PDF, não no HTML da página) e o laboratório do
usuário usa este kit — viram presets de amplicon no `pipeline.yaml` do PRISM.

O kit é um **mix**, não um par único: combina o par universal com pares
taxon-específicos na mesma reação (por isso o preset passa vários -g/-G ao cutadapt).

16S:  16S_mix_F AGRGTTYGATYMTGGCTCAG   | 16S_mix_R SGGYTACCTTGTTACGACTT
      16S_Bor_F AGAGTTTGATCCTGGCTTAG   | 16S_Bor_R CGGCTACCTTGTTACGACTT   (Borrelia)
      16S_Chl_F AGAATTTGATCTTRGTTCAG   | 16S_Chl_R GGGCTACCTTGTTACGACTT   (Chlamydia)
      16S_Ent_F AGAGTTTGATCATGGCTCAG
ITS:  ITS1      TCCGTAGGTGAACCTGCGG    | ITS4      TCCTCCGCTTATTGATATGC
      ITS1_Fus  TCCGTTGGTGAACCAGCGG    (Fusarium)
      ITS1_Mal  TCTGTAGGTGAACCTGCAG    (Malassezia)
      ITS4_Pyt  TCCTCCGCTTATTAATATGC   (Pythium)
Bases degeneradas: R=A/G, Y=C/T, M=A/C, S=C/G

Nota real: `16S_mix_F` é idêntico ao default de 16S que o PRISM já usava. O reverse
que o PRISM usava (`AAGTCGTAACAAGGTARCY`) é o reverso-complemento do `16S_mix_R` da
ONT — mesmo primer 1492R, orientação oposta; ambos válidos, mas o preset do kit usa
a sequência literal da ONT.

## Operon rrn completo (16S-ITS-23S) — primers e banco
Par 16S-27F + 23S-2241R, amplicon ~4.300 bp (Cuscó et al. 2019, F1000Research 7:1755,
10.12688/f1000research.16817.2). Sequência do 2241R confirmada por busca 2026-08-09:
`ACCRCCCCAGTHRAACT`. (A sequência que eu tinha de memória estava ERRADA — confirmar
em vez de assumir evitou um primer silenciosamente incorreto.)

GROND (Genome-derived Ribosomal OperoN Database), Zenodo 10.5281/zenodo.10889037.
Formatos reais confirmados baixando fragmentos dos arquivos (2026-08-09):
- `gtdb207nr_nrRep.fna.gz` (128 MB): headers são só IDs opacos de cluster (`>C_00000001`),
  SEM taxonomia; sequências já em DNA (ao contrário do SILVA, que vem em RNA).
- `gtdb207nr_taxRep.tsv` (14,5 MB): 2 colunas, SEM linha de cabeçalho, ranks separados
  por PIPE (`d__Bacteria|p__Proteobacteria|...`), não por ponto-e-vírgula.
Por isso o GROND precisa de um JOIN real entre dois arquivos + conversão de `|` para `;`
(`convert_grond_headers.py`), diferente do SILVA/GTDB que só precisam reescrever header.
