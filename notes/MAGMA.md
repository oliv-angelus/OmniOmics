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

## Plano do próximo bloco: QC/montagem/GUNC/eggNOG/Kaiju + anel genômico (2026-08-10)

Pedido do usuário (resumo): gráfico de abundância do Kaiju; gráficos simples de QC
antes/depois da limpeza; gráficos simples de métricas de montagem; GUNC junto do resultado
final de MIMAG das MAGs; perfil funcional do eggNOG das amostras (item que o usuário tem
certeza que quer); e — para as demais saídas de anotação por amostra/MAG sem uso (CRISPR,
vírus, elementos móveis, BGCs) — um anel genômico estilo Proksee, com decisão pendente
entre gráfico ou tabela/relatório grande.

Pesquisa feita antes de planejar (disciplina do projeto: fundamentar antes de codar):

- **Layout de anel genômico confirmado**: Cumsille et al. 2023, GenoVi, *PLOS Comput Biol*
  ([DOI](https://doi.org/10.1371/journal.pcbi.1010998), via PubMed PMC10104344), que compara
  GenoVi contra CGView, Proksee, DNAPlotter, Circleator e Circos. Layout padrão de fora para
  dentro: contigs → CDS fita direta (+ anotação funcional) → tRNA/rRNA → CDS fita reversa →
  conteúdo GC → GC skew, com anéis extras de anotação sobrepostos (o artigo usa isso para
  destacar clusters biossintéticos — mesma lógica que serve para CRISPR/vírus/elementos
  móveis). Ferramenta em R: **`circlize`** (CRAN, motor por trás da maioria desses
  visualizadores, sem depender de Python novo).
- **eggNOG-mapper v2 real** (25 colunas confirmadas via `USAGE.md` do repositório oficial):
  `COG_category` é a coluna 7, `KEGG_Pathway` a 13. **O DOGMA já usa exatamente essas colunas**
  (`build_dogma_table.R`, `eggnog_COG_category`/`eggnog_KEGG_Pathway`) — reaproveitar a mesma
  lógica para o eggNOG por amostra do MAGMA é baixo risco, não é formato novo.
- **fastp JSON confirmado**: `summary.before_filtering`/`summary.after_filtering`, cada um com
  `total_reads`, `total_bases`, `q30_rate`, `gc_content`.
- **GUNC confirmado** (documentação oficial, `grp-bork.embl-community.io/gunc/output.html`):
  13 colunas exatas em `GUNC.progenomes_2.1.maxCSS_level.tsv` — `genome`, `n_genes_called`,
  `n_genes_mapped`, `n_contigs`, `taxonomic_level`, `proportion_genes_retained_in_major_clades`,
  `genes_retained_index`, `clade_separation_score`, `contamination_portion`,
  `n_effective_surplus_clades`, `mean_hit_identity`, `reference_representation_score`,
  `pass.GUNC`. Corte oficial: `clade_separation_score <= 0.45` passa.
- **MINCED**: roda sem `-gffFull` na pipeline (confirmado lendo a regra) → GFF resumido, uma
  feature por array CRISPR — mesmo padrão de contagem já usado para o barrnap.
- **VirSorter2** (`final-viral-score.tsv`): `seqname`, score por grupo, `max_score`,
  `max_score_group`, `length`, `hallmark`, `viral genes %`, `nonviral genes %`.
- **geNomad** (`*_plasmid_summary.tsv`): `seq_name`, `length`, `topology`, `n_genes`,
  `plasmid_score`, `fdr`, `n_hallmarks`, `conjugation_genes`, `amr_genes`. `*_virus_summary.tsv`
  tem `marker_enrichment` e `taxonomy` (ICTV VMR).
- **ISEScan**: `seqID`, `family`, `cluster`, `isBegin`/`isEnd`, `isLen`, `ncopy4is`, `strand`.
- **MOB-suite** (`mob_recon`, não `mob_typer` — confirmado lendo a regra):
  `mobtyper_results.txt` com `rep_type(s)`, `relaxase_type(s)`, `mpf_type`,
  `PredictedMobility`, `mash_nearest_neighbor`.
- **BiG-SCAPE**: não aprofundado ainda — mais complexo (baseado em rede de similaridade),
  fica para quando chegar a vez dele.
- **Mesmo bug de nome de arquivo do achado anterior** (`magname=$(basename "$f".fa)` →
  `{mag}.fa.fa` em disco) confirmado também em `isescan_mags` e `minced_mags` — os parsers
  desse bloco todo precisam usar `.mag_shell_name()` (já existe em `build_magma_mag_table.R`).

### Fase A — bloco fácil, formato confirmado, baixo risco (próxima sessão de código)

1. **Kaiju**: `abundance_table_final_kaiju_RAW.tsv` já tem a mesma forma da tabela do Kraken
   → oferecer como fonte alternativa nas 12 análises de comunidade existentes (escolha
   Kraken/Kaiju/os dois), mais uma análise nova de concordância entre classificadores.
2. **QC antes/depois**: novo `build_magma_qc_table.R` lendo `{sample}_fastp.json` (curto-prazo)
   e `NanoStats.txt` do NanoPlot (longo-prazo) — gráfico simples de barras pareadas
   antes/depois por amostra (total de reads, % Q30, GC).
3. **Métricas de montagem**: `metaquast/report.tsv` e `metaquast_prokaryotic/report.tsv` por
   amostra — mesmo padrão `transposed_report.tsv` já usado no SIGMA (`.read_quast`).
   N50, total length, # contigs, GC%.
4. **GUNC + MIMAG**: juntar `pass.GUNC`/`clade_separation_score` na MESMA tabela/ficha de MAG
   já existente (`build_magma_mag_table.R`/`magma_mag_summary.R`), não como análise separada —
   é exatamente o que o usuário pediu ("devem ir junto com os resultados das MAGs finais
   MIMAG"). GUNC roda por AMOSTRA contra todos os bins dela (`--input_dir`), então o join é
   por MAG igual ao CheckM2.
5. **eggNOG por amostra**: novo `build_magma_sample_functional_table.R`, reaproveitando a
   lógica já testada de `build_dogma_table.R` para `COG_category`/`KEGG_Pathway`. Gráfico de
   composição funcional por amostra (barras empilhadas por categoria COG), mesmo padrão do
   `dogma_functional_composition.R`.

### Fase B — anel genômico + resto da anotação (sessão dedicada, depois da Fase A)

1. Verificar BiG-SCAPE de verdade antes de decidir seu lugar no anel (rede de similaridade
   não é uma feature posicional simples como as outras).
2. Construir `build_magma_mag_ring_data.R`: um MAG por vez, produz as trilhas do anel
   (CDS por fita, GC/GC-skew via janela deslizante no FASTA do genoma, tRNA/rRNA do
   barrnap/trnascan já lidos, CRISPR do MINCED, regiões virais do VirSorter2/geNomad,
   elementos móveis do ISEScan/MOB-suite) usando `circlize`.
3. Decisão gráfico-vs-tabela pendente até ver o anel de verdade: provável que o anel sirva
   para MAGs individuais (poucas features, visual vale a pena) e uma tabela grande sirva
   melhor para visão agregada entre muitos MAGs (mesmo padrão já adotado na ficha por MAG:
   sequência expansível em vez de gráfico).
4. Aplicar o mesmo tratamento (composição funcional) ao eggNOG por MAG, já que os dados são
   os mesmos formato, só o nível muda.

Ordem acordada com o usuário: **Fase A primeiro, Fase B depois**, "aos poucos" — não tentar
tudo de uma vez.

## Fase A concluída (2026-08-10)

Os 5 itens do plano acima foram implementados, testados e commitados nesta sessão. MAGMA saiu
de 13 para **18 análises**, em 4 formas de entrada (`phyloseq`, `phyloseq_kaiju`, `magma_mags`,
`magma_qc`, `magma_functional` — 5 no total contando a de comunidade original) e 4 seções na
aba Plots: **Comunidade, Funcional, MAGs, Qualidade**.

1. **Kaiju** — `phyloseq_kaiju` reaproveita `load_phyloseq.R` (novo `--classifier`) e
   `taxonomic_composition.R` **sem alteração nenhuma** (só um segundo registro no manifesto).
   `magma_classifier_concordance.R` novo, lê os dois `.rds` lado a lado pelo nome fixo no
   mesmo diretório.
2. **QC + Montagem** — `magma_read_qc.R` (fastp/NanoPlot, antes/depois) e
   `magma_assembly_quality.R` (MetaQuast, completo vs. filtrado pelo Tiara). Forma combinada
   `magma_qc`.
3. **GUNC + MIMAG** — `gunc_pass`/`gunc_css` entraram na mesma tabela/ficha de MAG, ao lado do
   `mimag_quality`, não misturados nele (GUNC não é parte do padrão MIMAG oficial). Fixture
   com dois casos reais de MAG "High" pelo MIMAG isolado mas reprovado pelo GUNC.
4. **Perfil funcional (eggNOG por amostra)** — `magma_functional_composition.R`, métrica de
   contagem de genes por categoria COG (não abundância de leitura, que o MAGMA não tem
   atrelada ao eggNOG por amostra).

**Bugs reais achados no caminho** (nenhum deles em código escrito nesta sessão — todos
pré-existentes, achados lendo as regras/documentação das ferramentas antes de escrever os
parsers, mesma causa raiz do incidente da limpeza por regex): `{output.json()}` em 4 pipelines
(quebraria todo run do DEFINE), `--file_suffix.fa` do GUNC e `--p_ext.pep` do EUKulele (espaço
engolido pela mesma regra de limpeza). Todos corrigidos e commitados separadamente.

**Bug de arquitetura achado pela suíte de teste**: `samples` era uma chave global só; com duas
formas (`magma_mags`, `magma_qc`) escrevendo significados diferentes nela, a última carregada
vencia silenciosamente. Corrigido com `samples_by_shape`, mesmo tratamento já dado a `columns`.

**Pendências que ficaram para trás, registradas para não esquecer**:
- NanoStats.txt do NanoPlot: formato ainda não conferido contra saída real (só documentação).
- MetaQuast na fixture: as duas variantes (completa/procariótica) saem com os mesmos números —
  não simula a diferença real que o Tiara produziria.
- `render_final.R`/exportação não testado com as novas 5 análises desta fase (deveria
  funcionar sem mudança, já que todas gravam `plot_final.rds`, mas não foi conferido).

## Fase B — ainda não iniciada

Anel genômico estilo Proksee (circlize) + resto da anotação (CRISPR, vírus, elementos móveis,
BiG-SCAPE). Ver plano completo na seção anterior. BiG-SCAPE segue sem verificar.

## Consolidação dos cards e nível de MAG no funcional (2026-08-11)

Feedback do usuário sobre a aba Plots depois de usá-la: as seções empilhadas
(Comunidade/Funcional/MAGs/Qualidade) foram trocadas por **um grid único com tags por forma de
entrada**, igual à página de pipelines; e os cards quase-duplicados viraram **um card com
toggle**, em vez de vários cards que só diferem na fonte dos dados.

**Comunidade — 3 cards viraram 1.** `magma_community_taxonomy.R` com `--classifier`:

| valor | o que faz |
|---|---|
| `kraken2` | barras empilhadas da tabela Kraken2/Bracken |
| `kaiju` | a mesma figura, da tabela do Kaiju |
| `compare` | concordância: abundância total por táxon lado a lado + quantos táxons cada classificador acha que o outro não acha |

Isso apagou `magma_kaiju_taxonomic_composition` (registro duplicado do
`taxonomic_composition`) e `magma_classifier_concordance.R`. O construtor de painel do
`taxonomic_composition.R` foi extraído para `lib/composition_panels.R` para os dois usarem o
mesmo código em vez de uma segunda cópia — refactor verificado por `data.json` byte a byte
idêntico ao pré-refactor. `taxonomic_composition` agora é `applies_to: [prism]` só.
`also_loads` (novo, em `plots_engine.get_input_shapes_for_pipeline`) é o que garante que
`phyloseq_kaiju.rds` seja construído no mesmo diretório, já que o script o abre pelo nome.

**Funcional — ganhou o nível de MAG.** O eggNOG por MAG (`09_ANNOTATION/mags/eggnog/`) existia
em disco e não era lido por nada; a ficha de MAG mostra só AMR/virulência, não categorias
funcionais. `build_magma_functional_table.R` passou de `sample` para `unit`+`level`, e
`magma_functional_composition.R` ganhou `--level sample|mag` — mesma simetria do toggle de
classificador da Comunidade, um card só. O cap de 300 termos e as porcentagens agora são
calculados **dentro de cada nível**, não misturando amostra com MAG.

Uma amostra é a comunidade inteira montada; um MAG é um genoma. São perguntas diferentes com o
mesmo vocabulário, por isso o mesmo script serve aos dois — mas o denominador nunca é
compartilhado entre eles.

**Fixture**: o eggNOG por MAG era um stub de 1 linha, então o nível `mag` nunca teria dado
nenhum. Agora as amostras e os MAGs usam o mesmo gerador (`eggnog_annotations()`), com contagem
de genes na escala de um genoma real (~2–3 mil) para os MAGs. As vias KEGG passaram a ser
sorteadas de um **pool ponderado de IDs reais** (ABC transporters, ribossomo, glicólise, TCA,
fosforilação oxidativa…) em vez de uniformemente sobre todo o espaço de IDs — com o sorteio
uniforme nenhuma via se destacava e o gráfico de top-N saía ~100% "Others", artefato da fixture
e não algo que um run real mostraria.

## Runner de suíte offline (2026-08-11)

`scripts/run_plots_suite.py` roda **todas** as análises de um pipeline contra uma pasta de
resultados, reproduzindo as mesmas chamadas do backend (`INPUT_SHAPE_INFO` para as formas,
`plots_engine.build_params_args` para os parâmetros). Existe porque script de R não é checado
por nada até rodar: uma coluna renomeada ou uma flag velha não aparece em lugar nenhum antes da
execução. Exercita **todos** os valores de cada parâmetro `choice`, não só o default — é
exatamente no ramo não-default que a quebra se esconde.

    python3 scripts/run_plots_suite.py magma <results> <metadata> \
        --conda ~/miniforge3/bin/conda "--set=--group_var=group"

`--set` preenche o que a UI resolveria a partir do run carregado (`--group_var`, `--mags`,
`--reference_group`), que de outro modo para na checagem "is required" da própria análise.

**Bug real que ele achou de primeira**: `--ordination_method CAP` quebrava em **qualquer**
distância, com um erro de dispatch ilegível (`unable to find an inherited method for
capscale.phyloseq`). CAP é ordenação **restrita** (dbRDA, Anderson & Willis 2003) — ao
contrário de PCoA/NMDS ela não resume a variação total, resume a parte explicada por variáveis
explicativas declaradas, então o `ordinate()` do phyloseq exige uma fórmula. Sem ela, `NULL`
chegava no `capscale`. Corrigido passando `~ group_var`, o mesmo fator que o PERMANOVA logo
acima testa. A descrição do parâmetro no manifesto agora avisa que a CAP **sempre** vai parecer
separada, por construção, e que quem carrega a evidência é o p do PERMANOVA — armadilha de
interpretação real, não detalhe de implementação.

MAGMA: 16 análises, todas passando. As 6 falhas de UniFrac/wUniFrac são a recusa intencional
(MAGMA não tem árvore filogenética — a mensagem explica e sugere bray/jaccard).

## Retorno do teste do usuário (2026-08-11)

**QC e Montagem tinham a caixa de parâmetros vazia** — as duas análises não tinham parâmetro
nenhum no manifesto. Olhando o código, as duas tabelas já *parseavam* métricas que nunca eram
desenhadas: o QC lia bases, GC, comprimento médio e N50 de leitura e plotava só reads e Q30; a
montagem lia contigs, maior contig, L50 e GC e plotava só N50 e comprimento total. Ganharam
`--metric` (`all` ou uma específica) e `--samples`. Não é métrica inventada: é exposição do que
já vinha do disco e era descartado.

Métrica sem dado na execução é recusada com mensagem explicando por quê (`length`/`n50` de
leitura só existem se o NanoPlot rodou, ou seja, amostras long-read), mesma convenção do
`--annotation_column` do DOGMA.

**Seletor de MAG no funcional** — exigiu um mecanismo novo no manifesto, `visible_when`. É
diferente do `depends_on` que já existia: o `depends_on` mantém o campo visível e só troca as
opções (o `--reference_group` seguindo o `--group_var`); o `visible_when` **esconde a linha
inteira**, não envia o parâmetro e não bloqueia o botão de rodar. O `--mags` do funcional só
aparece com `--level mag`, porque no nível de amostra não há MAG nenhum para escolher.

Junto vieram `options_shape` (o campo lê as opções de OUTRA forma de entrada carregada — o
`--mags` do funcional lista os MAGs que a forma `magma_mags` descobriu) e `optional` (campo que
pode legitimamente ficar vazio apesar do tipo; `--mags` vazio significa todos).

**UpSet: dois bugs, um deles nosso.**

1. `element_rect(fill = bg)` sem `colour` **não** preserva o painel sem borda. Os sub-gráficos
   do ComplexUpset têm `panel.background = element_blank`, e um `element_rect` mesclado sobre um
   blank não herda do painel existente — cai no elemento `rect` de topo, cuja cor é preta. Daí
   uma caixa preta em volta de cada sub-painel, que era o que fazia as barras de set size
   parecerem transbordar. (Os scripts que usam `base_theme` não têm o problema: lá a mescla é
   sobre o `panel.background` do `theme_grey`, que tem `colour = NA`.)
2. Pintávamos `plot.background` no corpo — que cobre também a margem — enquanto o `title_bar()`
   pinta só o painel dele. A faixa do título saía mais estreita que a figura por exatamente uma
   margem de cada lado.

Corrigido nos três scripts de UpSet (`upset_plot`, `de_upset`, `dogma_de_upset`).

**Pergunta do usuário sobre o DESeq2, respondida e não implementada**: o modelo já é ajustado
com todos os grupos de uma vez (`~ group`), usando as 18 amostras para estimar dispersão; o
`--reference_group`/`--test_group` só escolhe qual contraste extrair. O que falta é o **LRT**
(`~ group` vs `~ 1`), que responde outra pergunta — "esse gene responde ao gradiente de alguma
forma?" em vez de "polluted difere de control?". Para o desenho de 3 grupos ao longo de um
gradiente, o LRT seria a primeira passada natural. Fica registrado como possível
`--test_type wald|lrt`; o usuário só perguntou, não pediu.
