# MAGMA

Metagenome-assisted MAG (metagenome-assembled genome) analysis pipeline. First pipeline plugged into [[Project Overview|OmniOmics]]. Category: `metagenomics`.

Lives at `pipelines/magma/` — `Snakefile` + `workflow/rules/*.smk` (8 stage files: QC/taxonomy, assembly, mapping, binning, MAG refinement, dereplication/taxonomy, annotation/mobilome, coverage) + `pipeline.yaml` (see [[Pipeline Manifest Schema]]).

Source of truth for the actual pipeline logic is `MAGMA-main` (a separate, non-app repo the user publishes independently) — `pipelines/magma/`'s Snakefile/workflow were copied from there, not from the `MAGMA-ideia-de-app` Electron prototype, which had drifted (see [[Decisions Log]] for a concrete example: a stale non-hybrid `metaspades` rule that only existed in the prototype).

42 tools across 11 categories, 13 downloadable reference databases. Full dependency chain: [[MAGMA Dependency Graph]].

## Read-level taxonomy: two independent classifiers

Kraken2/Bracken/kreport2mpa (k-mer/nucleotide) and Kaiju (protein-level, translated search) are both optional and independent — either, both, or neither can be active, since they only need clean reads, not each other. Kaiju's own output shape doesn't fit Kraken2's report format, so it gets its own chain (`kaiju_classify` → `kaiju_table` → `consolidate_taxonomy_kaiju`) instead of feeding Bracken/kreport2mpa. See [[Decisions Log]].

Icon: orange/black volcano, `build/icon.png` (kept from the original Electron prototype's branding).

## Pipeline flowchart — `pipelines/magma/MAGMA.drawio.svg`

User-maintained metro-map-style diagram (nf-core icon set, hand-edited in app.diagrams.net/draw.io) of the real MAGMA DAG. **Reviewed against [[MAGMA Dependency Graph]] 2026-07-28** (the ground-truth doc derived from reading the actual `.smk` rules) and found + the user fixed 6 real discrepancies: missing `drep` node (GTDB-Tk/CoverM were shown depending on Binette's raw output directly, not on `drep` — exactly the misconception that doc's "Key corrections" section already once flagged); Bowtie2/Minimap2 shown mapping against unfiltered `contigs` instead of Tiara's prokaryotic-filtered output; VirSorter2/Genomad/VIBRANT/MOBsuite shown gated behind Prodigal/Tiara when they actually run on the unfiltered assembly; "MOBsite" typo for MOBsuite; CheckV missing entirely (depends on VirSorter2); VFDB missing from both the sample and MAGs annotation tracks. All confirmed fixed after the user's edits (re-rendered and diffed against the dependency graph a second time). Remaining simplifications (CheckV/BIGscape drawn as siblings of their tool group rather than strictly downstream of VirSorter2/Antismash specifically) are deliberate legibility choices, not errors — flagged and accepted.

**How this file works, if it needs touching again**: it's a real draw.io SVG export with the full editable `mxfile` XML embedded in a `content="..."` attribute on the root `<svg>` (decode with `html.unescape` after regex-extracting the attribute) — so it opens natively in draw.io/diagrams.net despite being a `.svg` file. To render it headlessly for review (no draw.io CLI available in this environment): `firefox --headless --screenshot out.png --window-size=4300,2500 -profile <fresh-tmp-dir> "file://$(pwd)/MAGMA.drawio.svg"` — cairosvg fails on this file (chokes on a `requiredFeatures` URI it misparses as a color), Firefox handles it fine. The companion icon library (station dots, file-type icons, connector/bridge conventions, palette) lives at `pipelines/ICONES BASE.drawio.svg`, same embedding trick.

## Inventário completo das saídas vs. o que a aba Plots usa (2026-08-10)

Levantamento feito antes de construir qualquer análise nova, lendo o `output:` real das
**62 regras** nos 8 arquivos `.smk` e conferindo os formatos contra a run demo.

**O achado central**: o MAGMA tem 62 regras e a aba Plots lê **um único arquivo** —
`results/03_TAXONOMY/abundance_table_final_RAW.tsv` (consolidação Kraken2/Bracken, via
`load_phyloseq.R`). As 12 análises do MAGMA são todas ecologia de comunidade sobre essa
tabela. Todo o resto é produzido e nunca vira gráfico.

### Pronto para usar, formato já conferido

| Origem | Arquivo | Colunas reais | Destino proposto |
|---|---|---|---|
| Kaiju | `03_TAXONOMY/abundance_table_final_kaiju_RAW.tsv` | `tax \| <amostra>… \| total` | Mesma forma da tabela do Kraken → entra nas 12 análises existentes quase de graça, mais uma análise nova de concordância entre classificadores |
| CheckM2 | `06_MAG_REFINEMENT/<amostra>/checkm2/quality_report.tsv` | `Name \| Completeness \| Contamination \| Genome_Size` | Completude × contaminação com limiares MIMAG |
| GTDB-Tk | `08_MAG_TAXONOMY/gtdbtk/gtdbtk.bac120.summary.tsv` | `user_genome \| classification \| fastani_ani \| red_value` | Taxonomia dos MAGs; coluna de agrupamento |
| CoverM | `10_MAG_COVERAGE/coverm_coverage.tsv` | `Genome \| <amostra> Relative Abundance (%)…` | **Já é MAG × amostra** — abundância dos MAGs entre amostras, direto |
| MetaQuast | `02_ASSEMBLY/<amostra>/metaquast/report.tsv` | (formato QUAST padrão) | Qualidade da montagem por amostra |

As quatro tabelas de MAG têm exatamente a forma que `lib/build_sigma_table.R` já resolve
(juntar qualidade + taxonomia + cobertura por genoma numa tabela densa). É molde direto, e
o tipo de parâmetro `sample` do manifest — o seletor de genoma feito para o SIGMA — serve
sem alteração para "qual MAG".

### Produzido, não usado, formato ainda NÃO conferido contra saída real

- Refino/dereplicação: `binette` (`final_bins_quality_reports.tsv`), `gunc`
  (`GUNC.progenomes_2.1.maxCSS_level.tsv`), `drep` (`Wdb.csv`/`Cdb.csv` dentro de `drep_out`).
- Montagem: `tiara` (`classifications.txt`), `filter_prokaryotes` (`prokaryotic_ids.txt`).
- QC: `fastp` (`<s>_fastp.json`), NanoPlot (`NanoStats.txt`).
- **Anotação e mobiloma — 25 regras**, metade por amostra e metade por MAG:
  prodigal, eggNOG, abricate, AMRFinder, MINCED, VFDB, barrnap, tRNAscan, ISEScan,
  antiSMASH, BiG-SCAPE (por amostra **e** por MAG); e só por amostra: VirSorter2, CheckV,
  geNomad, MOB-suite, VIBRANT.
  A maioria declara **diretório** como output, então o nome real de cada arquivo interno
  precisa ser confirmado antes de escrever qualquer parser — mesma disciplina do DOGMA e do
  SIGMA. A run demo já tem `mags/vfdb/<mag>_vfdb_results.tab`,
  `mags/eggnog/<mag>_annotations.emapper.annotations`, `mags/amrfinder/<mag>_amrfinder_results.tsv`
  e `mags/barrnap/<mag>.gff`, mas **essa run é sintética, feita por mim** — os nomes vieram
  de ler as regras, não de execução real das ferramentas.

### Ressalva honesta sobre os formatos

Tudo marcado como "conferido" foi conferido contra a run demo sintética. As colunas vieram
de ler as regras reais e a documentação das ferramentas, não de saída real. O CheckM2 real,
por exemplo, emite mais colunas que as quatro acima. Os leitores devem ser tolerantes a
colunas extras (foi o que se fez no SIGMA), e uma execução real continua pendente.
