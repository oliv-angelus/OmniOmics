# Citing the tools OmniOmics runs

OmniOmics orchestrates other people's software. The science is theirs, and work
published using OmniOmics should cite the tools it actually used.

This file lists every tool, **at the version OmniOmics pins**, grouped by what
it does. Versions are read from the conda environment files under
`pipelines/*/workflow/envs/`, which are the single source of truth — if a
version here disagrees with one of those files, the environment file is right
and this document is stale.

> **Before submitting a manuscript**, check each tool's current preferred
> citation on its own repository. Tools change their requested citation when a
> new major version is published, and a citation list compiled once goes out of
> date quietly.

Only cite what you enabled. Most pipeline steps are optional, and the run's
configuration records which ones actually ran.

---

## Orchestration and interface

| Component | Version | Citation |
|---|---|---|
| Snakemake | installed on first run | Mölder F, *et al.* (2021) Sustainable data analysis with Snakemake. *F1000Research* 10:33. doi:10.12688/f1000research.29032.2 |
| conda | installed on first run | — |

---

## Read quality control and preprocessing

| Tool | Version | Used by | Citation |
|---|---|---|---|
| fastp | 1.3.5 | all | Chen S, *et al.* (2018) fastp: an ultra-fast all-in-one FASTQ preprocessor. *Bioinformatics* 34:i884. doi:10.1093/bioinformatics/bty560 |
| FastQC | 0.12.1 | DEFINE | Andrews S. Babraham Bioinformatics. |
| MultiQC | 1.35 | DEFINE | Ewels P, *et al.* (2016) MultiQC. *Bioinformatics* 32:3047. doi:10.1093/bioinformatics/btw354 |
| NanoPlot | — | MAGMA, DOGMA, SIGMA, PRISM | De Coster W, *et al.* (2018) NanoPack. *Bioinformatics* 34:2666. doi:10.1093/bioinformatics/bty149 |
| Filtlong | 0.3.1 | MAGMA, DOGMA, SIGMA, PRISM | Wick RR. github.com/rrwick/Filtlong |
| cutadapt | 4.9 | PRISM | Martin M (2011) *EMBnet.journal* 17:10. doi:10.14806/ej.17.1.200 |
| SeqKit | 2.9.0 / 2.13.0 | MAGMA, PRISM | Shen W, *et al.* (2016) *PLoS ONE* 11:e0163962. doi:10.1371/journal.pone.0163962 |
| RiboDetector | 0.3.3 | DOGMA | Deng ZL, *et al.* (2022) *Nucleic Acids Res* 50:e60. doi:10.1093/nar/gkac112 |

## Assembly and polishing

| Tool | Version | Used by | Citation |
|---|---|---|---|
| MEGAHIT | 1.2.9 | MAGMA, DOGMA | Li D, *et al.* (2015) *Bioinformatics* 31:1674. doi:10.1093/bioinformatics/btv033 |
| SPAdes | 3.15.5 / 4.3.0 | MAGMA, DOGMA | Prjibelski A, *et al.* (2020) *Curr Protoc Bioinformatics* 70:e102. doi:10.1002/cpbi.102 |
| metaSPAdes | 3.15.5 | MAGMA | Nurk S, *et al.* (2017) *Genome Res* 27:824. doi:10.1101/gr.213959.116 — cite this for the hybrid metagenomic mode |
| rnaSPAdes | 3.15.5 | DOGMA | Bushmanova E, *et al.* (2019) *GigaScience* 8:giz100. doi:10.1093/gigascience/giz100 — cite this for the transcriptome mode |
| Flye | 2.9.5 | MAGMA, SIGMA | Kolmogorov M, *et al.* (2019) *Nat Biotechnol* 37:540. doi:10.1038/s41587-019-0072-8 |
| Unicycler | 0.5.0 | SIGMA | Wick RR, *et al.* (2017) *PLoS Comput Biol* 13:e1005595. doi:10.1371/journal.pcbi.1005595 |
| Racon | 1.5.0 | SIGMA | Vaser R, *et al.* (2017) *Genome Res* 27:737. doi:10.1101/gr.214270.116 |
| Medaka | 2.1.0 | SIGMA | Oxford Nanopore Technologies. github.com/nanoporetech/medaka |
| RagTag | 2.1.0 | SIGMA | Alonge M, *et al.* (2022) *Genome Biol* 23:258. doi:10.1186/s13059-022-02823-7 |
| Trinity | 2.15.1 | DOGMA | Grabherr MG, *et al.* (2011) *Nat Biotechnol* 29:644. doi:10.1038/nbt.1883 |
| QUAST / MetaQUAST | 5.3.0 | MAGMA, SIGMA | Gurevich A, *et al.* (2013) *Bioinformatics* 29:1072. doi:10.1093/bioinformatics/btt086 |

## Read mapping and quantification

| Tool | Version | Used by | Citation |
|---|---|---|---|
| Bowtie 2 | 2.5.5 | MAGMA, DEFINE, SIGMA | Langmead B, Salzberg SL (2012) *Nat Methods* 9:357. doi:10.1038/nmeth.1923 |
| minimap2 | 2.31 | MAGMA, SIGMA | Li H (2018) *Bioinformatics* 34:3094. doi:10.1093/bioinformatics/bty191 |
| SAMtools | 1.23.1 | MAGMA, DEFINE, SIGMA | Danecek P, *et al.* (2021) *GigaScience* 10:giab008. doi:10.1093/gigascience/giab008 |
| CoverM | 0.7.0 | MAGMA, SIGMA | Woodcroft BJ. github.com/wwood/CoverM |
| Salmon | 2.3.4 | DOGMA | Patro R, *et al.* (2017) *Nat Methods* 14:417. doi:10.1038/nmeth.4197 |
| featureCounts (Subread) | 2.1.1 | DEFINE | Liao Y, *et al.* (2014) *Bioinformatics* 30:923. doi:10.1093/bioinformatics/btt656 |
| RSeQC | 5.0.4 | DEFINE | Wang L, *et al.* (2012) *Bioinformatics* 28:2184. doi:10.1093/bioinformatics/bts356 |

## Taxonomic classification

| Tool | Version | Used by | Citation |
|---|---|---|---|
| Kraken 2 | 2.17.1 | MAGMA, DOGMA, SIGMA | Wood DE, *et al.* (2019) *Genome Biol* 20:257. doi:10.1186/s13059-019-1891-0 |
| Bracken | 3.1 | MAGMA | Lu J, *et al.* (2017) *PeerJ Comput Sci* 3:e104. doi:10.7717/peerj-cs.104 |
| KrakenTools | — | MAGMA, DOGMA | Lu J, *et al.* (2022) *Nat Protoc* 17:2815. doi:10.1038/s41596-022-00738-y |
| Kaiju | 1.10.1 | MAGMA, DOGMA, SIGMA | Menzel P, *et al.* (2016) *Nat Commun* 7:11257. doi:10.1038/ncomms11257 |
| GTDB-Tk | 2.7.2 | MAGMA, SIGMA | Chaumeil PA, *et al.* (2022) *Bioinformatics* 38:5315. doi:10.1093/bioinformatics/btac672 |
| CAT/BAT | 6.0.1 | DOGMA | von Meijenfeldt FAB, *et al.* (2019) *Genome Biol* 20:217. doi:10.1186/s13059-019-1817-x |
| EUKulele | 2.1.2 | DOGMA | Krinos AI, *et al.* (2021) *J Open Source Softw* 6:2817. doi:10.21105/joss.02817 |
| Tiara | 1.0.3 | MAGMA | Karlicki M, *et al.* (2022) *Bioinformatics* 38:344. doi:10.1093/bioinformatics/btab672 |

## Binning, MAG recovery and genome quality

| Tool | Version | Used by | Citation |
|---|---|---|---|
| MetaBAT 2 | 2.18 | MAGMA | Kang DD, *et al.* (2019) *PeerJ* 7:e7359. doi:10.7717/peerj.7359 |
| MaxBin 2 | 2.2.7 | MAGMA | Wu YW, *et al.* (2016) *Bioinformatics* 32:605. doi:10.1093/bioinformatics/btv638 |
| SemiBin2 | 2.3.0 | MAGMA | Pan S, *et al.* (2023) *Bioinformatics* 39:i21. doi:10.1093/bioinformatics/btad209 |
| VAMB | 5.0.2 | MAGMA | Nissen JN, *et al.* (2021) *Nat Biotechnol* 39:555. doi:10.1038/s41587-020-00777-4 |
| Binette | 1.2.1 | MAGMA | Mainguy J, Hoede C. github.com/genotoul-bioinfo/Binette |
| dRep | 3.4.0 | MAGMA | Olm MR, *et al.* (2017) *ISME J* 11:2864. doi:10.1038/ismej.2017.126 |
| CheckM2 | 1.1.0 | MAGMA, SIGMA | Chklovski A, *et al.* (2023) *Nat Methods* 20:1203. doi:10.1038/s41592-023-01940-w |
| GUNC | — | MAGMA, SIGMA | Orakov A, *et al.* (2021) *Genome Biol* 22:178. doi:10.1186/s13059-021-02393-0 |

The MIMAG quality tiers the Plots tab reports follow **Bowers RM, *et al.*
(2017) *Nat Biotechnol* 35:725. doi:10.1038/nbt.3893**.

## Gene calling and functional annotation

| Tool | Version | Used by | Citation |
|---|---|---|---|
| Bakta | 1.11.3 | SIGMA, DEFINE | Schwengers O, *et al.* (2021) *Microb Genom* 7:000685. doi:10.1099/mgen.0.000685 |
| Pyrodigal | 3.7.1 | MAGMA | Larralde M (2022) *J Open Source Softw* 7:4296. doi:10.21105/joss.04296 |
| TransDecoder | 5.7.1 | DOGMA | Haas BJ. github.com/TransDecoder/TransDecoder |
| eggNOG-mapper | 2.1.13 | all | Cantalapiedra CP, *et al.* (2021) *Mol Biol Evol* 38:5825. doi:10.1093/molbev/msab293 |
| DIAMOND | 2.2.4 | DOGMA | Buchfink B, *et al.* (2021) *Nat Methods* 18:366. doi:10.1038/s41592-021-01101-x |
| MMseqs2 | 15 | DOGMA | Steinegger M, Söding J (2017) *Nat Biotechnol* 35:1026. doi:10.1038/nbt.3988 |
| HMMER | 3.4 | DOGMA | Eddy SR (2011) *PLoS Comput Biol* 7:e1002195. doi:10.1371/journal.pcbi.1002195 |
| dbCAN (run_dbcan) | 5.2.9 | DOGMA | Zheng J, *et al.* (2023) *Nucleic Acids Res* 51:W115. doi:10.1093/nar/gkad328 |
| FeGenie | 1.2 | DOGMA | Garber AI, *et al.* (2020) *Front Microbiol* 11:37. doi:10.3389/fmicb.2020.00037 |
| barrnap | 1.10.6 | MAGMA | Seemann T. github.com/tseemann/barrnap |
| tRNAscan-SE | 2.0.12 | MAGMA | Chan PP, *et al.* (2021) *Nucleic Acids Res* 49:9077. doi:10.1093/nar/gkab688 |
| MinCED | 0.4.2 | MAGMA | Bland C, *et al.* (2007) *BMC Bioinformatics* 8:209. doi:10.1186/1471-2105-8-209 |

## Resistance, virulence and typing

| Tool | Version | Used by | Citation |
|---|---|---|---|
| AMRFinderPlus | 4.2.7 | MAGMA, SIGMA | Feldgarden M, *et al.* (2021) *Sci Rep* 11:12728. doi:10.1038/s41598-021-91456-0 |
| ABRicate | 1.4.0 | MAGMA, SIGMA | Seemann T. github.com/tseemann/abricate |
| mlst | 2.23.0 | SIGMA | Seemann T. github.com/tseemann/mlst; PubMLST: Jolley KA, *et al.* (2018) *Wellcome Open Res* 3:124. doi:10.12688/wellcomeopenres.14826.1 |

## Mobile elements, viruses and secondary metabolites

| Tool | Version | Used by | Citation |
|---|---|---|---|
| MOB-suite | 3.1.9 | MAGMA, SIGMA | Robertson J, Nash JHE (2018) *Microb Genom* 4:000206. doi:10.1099/mgen.0.000206 |
| ISEScan | 1.7.3 | MAGMA, SIGMA | Xie Z, Tang H (2017) *Bioinformatics* 33:3340. doi:10.1093/bioinformatics/btx433 |
| geNomad | 1.12.0 | MAGMA, SIGMA | Camargo AP, *et al.* (2024) *Nat Biotechnol* 42:1303. doi:10.1038/s41587-023-01953-y |
| VirSorter2 | 2.2.4 | MAGMA, SIGMA | Guo J, *et al.* (2021) *Microbiome* 9:37. doi:10.1186/s40168-020-00990-y |
| CheckV | 1.1.1 | MAGMA, SIGMA | Nayfach S, *et al.* (2021) *Nat Biotechnol* 39:578. doi:10.1038/s41587-020-00774-7 |
| VIBRANT | 1.2.1 | MAGMA, SIGMA | Kieft K, *et al.* (2020) *Microbiome* 8:90. doi:10.1186/s40168-020-00867-0 |
| antiSMASH | 8.0.4 | MAGMA, SIGMA | Blin K, *et al.* (2023) *Nucleic Acids Res* 51:W46. doi:10.1093/nar/gkad344 |
| BiG-SCAPE | 2.0.3 | MAGMA, SIGMA | Navarro-Muñoz JC, *et al.* (2020) *Nat Chem Biol* 16:60. doi:10.1038/s41589-019-0400-9 |

## Amplicon analysis (PRISM)

| Tool | Version | Citation |
|---|---|---|
| DADA2 | 1.34.0 | Callahan BJ, *et al.* (2016) *Nat Methods* 13:581. doi:10.1038/nmeth.3869 |
| VSEARCH | 2.29.1 | Rognes T, *et al.* (2016) *PeerJ* 4:e2584. doi:10.7717/peerj.2584 |
| Emu | ≥3.6.2 | Curry KD, *et al.* (2022) *Nat Methods* 19:845. doi:10.1038/s41592-022-01520-4 |
| DECIPHER | — | Wright ES (2016) *R Journal* 8:352. doi:10.32614/RJ-2016-025 |
| phangorn | — | Schliep KP (2011) *Bioinformatics* 27:592. doi:10.1093/bioinformatics/btq706 |
| PICRUSt2 | 2.6.3 | Douglas GM, *et al.* (2020) *Nat Biotechnol* 38:685. doi:10.1038/s41587-020-0548-6 |

---

## Statistics and figures (the Plots tab)

These run inside OmniOmics' own R environment (`plots/r_env/plots.yaml`) rather
than a pipeline, but they perform the statistics a manuscript reports and must
be cited when their results are.

| Package | Used for | Citation |
|---|---|---|
| phyloseq | community data structure | McMurdie PJ, Holmes S (2013) *PLoS ONE* 8:e61217. doi:10.1371/journal.pone.0061217 |
| DESeq2 | differential abundance/expression, LRT | Love MI, *et al.* (2014) *Genome Biol* 15:550. doi:10.1186/s13059-014-0550-8 |
| vegan | ordination, PERMANOVA, diversity | Oksanen J, *et al.* The vegan package. cran.r-project.org/package=vegan |
| ape | phylogenetics | Paradis E, Schliep K (2019) *Bioinformatics* 35:526. doi:10.1093/bioinformatics/bty633 |
| indicspecies | indicator species | De Cáceres M, Legendre P (2009) *Ecology* 90:3566. doi:10.1890/08-1823.1 |
| circlize | circular genome map | Gu Z, *et al.* (2014) *Bioinformatics* 30:2811. doi:10.1093/bioinformatics/btu393 |
| ggplot2 | figures | Wickham H (2016) *ggplot2: Elegant Graphics for Data Analysis*. Springer. |
| ComplexUpset / UpSet | set intersections | Lex A, *et al.* (2014) *IEEE Trans Vis Comput Graph* 20:1983. doi:10.1109/TVCG.2014.2346248 |

### Methodological choices worth citing alongside

- **UniFrac** — Lozupone C, Knight R (2005) *Appl Environ Microbiol* 71:8228.
  doi:10.1128/AEM.71.12.8228-8235.2005; weighted variant: Lozupone CA, *et al.*
  (2007) *Appl Environ Microbiol* 73:1576. doi:10.1128/AEM.01996-06
- **PERMANOVA** — Anderson MJ (2001) *Austral Ecol* 26:32.
  doi:10.1111/j.1442-9993.2001.01070.pp.x
- **CAP (constrained ordination)** — Anderson MJ, Willis TJ (2003) *Ecology*
  84:511. doi:10.1890/0012-9658(2003)084[0511:CAOPCA]2.0.CO;2
- **Benjamini-Hochberg FDR** — Benjamini Y, Hochberg Y (1995) *J R Stat Soc B*
  57:289. Validity under positive dependency: Benjamini Y, Yekutieli D (2001)
  *Ann Stat* 29:1165. doi:10.1214/aos/1013699998
- **poscounts normalisation** for sparse count matrices — implemented in DESeq2,
  originating in the phyloseq workflow for 16S data (McMurdie & Holmes 2013,
  above). See `plots/scripts/lib/deseq_helpers.R` for why it is a fallback and
  not the default.
- **Circular genome layout conventions** — CGView/Proksee: Grant JR, *et al.*
  (2023) *Nucleic Acids Res* 51:W484. doi:10.1093/nar/gkad326; GenoVi: Cumsille
  A, *et al.* (2023) *PLoS Comput Biol* 19:e1010998.
  doi:10.1371/journal.pcbi.1010998

---

## Reference databases

Databases carry their own terms of use, independent of both OmniOmics' licence
and their tools'. Check each one before redistributing derived data.

| Database | Used by | Reference |
|---|---|---|
| GTDB | GTDB-Tk | Parks DH, *et al.* (2022) *Nucleic Acids Res* 50:D785. doi:10.1093/nar/gkab776 |
| SILVA | PRISM | Quast C, *et al.* (2013) *Nucleic Acids Res* 41:D590. doi:10.1093/nar/gks1219 |
| CARD | ABRicate | Alcock BP, *et al.* (2023) *Nucleic Acids Res* 51:D690. doi:10.1093/nar/gkac920 |
| VFDB | ABRicate | Chen L, *et al.* (2016) *Nucleic Acids Res* 44:D694. doi:10.1093/nar/gkv1239 |
| Pfam | dbCAN, BiG-SCAPE | Mistry J, *et al.* (2021) *Nucleic Acids Res* 49:D412. doi:10.1093/nar/gkaa913 |
| KEGG | eggNOG-mapper | Kanehisa M, Goto S (2000) *Nucleic Acids Res* 28:27. doi:10.1093/nar/28.1.27 |
| eggNOG | eggNOG-mapper | Hernández-Plaza A, *et al.* (2023) *Nucleic Acids Res* 51:D389. doi:10.1093/nar/gkac1022 |
