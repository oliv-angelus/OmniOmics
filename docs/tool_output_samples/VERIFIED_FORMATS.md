# Formatos verificados no código-fonte das ferramentas

Verificado clonando cada repositório e lendo o código que **escreve** a saída —
não a documentação, não memória. Data: 2026-08-12.

Para cada ferramenta abaixo está o caminho exato do arquivo-fonte e da linha,
para poder reconferir quando uma versão nova sair.

---

## MOB-suite (`phac-nml/mob-suite`)

**Arquivos escritos pelo `mob_recon`** (`mob_suite/mob_recon.py:1007,1397`):

- `contig_report.txt` — uma linha por contig
- `mobtyper_results.txt` — uma linha por plasmídeo reconstruído
- com `--prefix X`, viram `X.contig_report.txt` e `X.mobtyper_results.txt`

**`contig_report.txt`** — `MOB_RECON_INFO_HEADER`, `mob_suite/constants.py:48`:

```
sample_id  molecule_type  primary_cluster_id  secondary_cluster_id  contig_id
size  gc  md5  circularity_status  rep_type(s)  rep_type_accession(s)
relaxase_type(s)  relaxase_type_accession(s)  mpf_type  mpf_type_accession(s)
orit_type(s)  orit_accession(s)  predicted_mobility  mash_nearest_neighbor
mash_neighbor_distance  mash_neighbor_identification  repetitive_dna_id
repetitive_dna_type  filtering_reason
```

**`mobtyper_results.txt`** — `MOB_TYPER_REPORT_HEADER`, `mob_suite/constants.py:19`:

```
sample_id  num_contigs  size  gc  md5  rep_type(s)  rep_type_accession(s)
relaxase_type(s)  relaxase_type_accession(s)  mpf_type  mpf_type_accession(s)
orit_type(s)  orit_accession(s)  predicted_mobility  mash_nearest_neighbor
mash_neighbor_distance  mash_neighbor_identification  primary_cluster_id
secondary_cluster_id  predicted_host_range_overall_rank
predicted_host_range_overall_name  observed_host_range_ncbi_rank
observed_host_range_ncbi_name  reported_host_range_lit_rank
reported_host_range_lit_name  associated_pmid(s)
```

**Valores literais**:

- `molecule_type` ∈ {`chromosome`, `plasmid`} (`mob_recon.py:669,674,686,693,700`)
- `predicted_mobility` ∈ {`conjugative`, `mobilizable`, `non-mobilizable`}
  (`mob_typer.py:530-534`, `utils.py:1034-1040`)
- valores múltiplos em `rep_type(s)`/`relaxase_type(s)` são separados por
  **vírgula** — `','.join(...)` em `utils.py:1139`

### A armadilha que só o código revelou

`contig_id` **não é** necessariamente o mesmo identificador que o AMRFinder e o
ABRicate reportam.

O `mob_recon` reescreve os cabeçalhos do FASTA antes de trabalhar
(`fix_fasta_header`, `utils.py:822`) e depois mapeia de volta — mas o que ele
guarda no mapa é `str(record.description)` (`utils.py:837`), ou seja **a linha
de cabeçalho inteira**, incluindo qualquer descrição depois do primeiro espaço.
O AMRFinder (`Contig id`) e o ABRicate (`SEQUENCE`) usam o **primeiro token**.

Consequência prática: numa montagem cujos cabeçalhos tenham descrição (o Flye e
o SPAdes produzem headers com campos extras em algumas configurações), juntar
as duas tabelas pelo valor cru **não casa nenhuma linha**, e o gráfico sairia
vazio sem erro nenhum — o pior modo de falha possível.

**Regra para o leitor**: cortar o `contig_id` do MOB-suite no primeiro espaço
antes de cruzar, e registrar quantas linhas casaram.

---

## CheckV (`bitbucket.org/berkeleylab/checkv`)

**`quality_summary.tsv`** — `checkv/modules/quality_summary.py:146-161`:

```
contig_id  contig_length  provirus  proviral_length  gene_count  viral_genes
host_genes  checkv_quality  miuvig_quality  completeness  completeness_method
contamination  kmer_freq  warnings
```

`checkv_quality` ∈ {`Complete`, `High-quality`, `Medium-quality`,
`Low-quality`, `Not-determined`} (`quality_summary.py:129-142`).

Os cinco níveis são categorias ordenadas, não contínuas — a ordem acima é a
ordem correta para o eixo de um gráfico empilhado.

---

## geNomad (`apcamargo/genomad`)

Escreve dois resumos no diretório `summary` (`genomad/_paths.py:405,421`):
`{prefix}_virus_summary.tsv` e `{prefix}_plasmid_summary.tsv`.

**`_virus_summary.tsv`** (`modules/summary.py:670`):

```
seq_name  length  topology  coordinates  n_genes  genetic_code  virus_score
fdr  n_hallmarks  marker_enrichment  taxonomy
```

**`_plasmid_summary.tsv`** (`modules/summary.py:626`):

```
seq_name  length  topology  n_genes  genetic_code  plasmid_score  fdr
n_hallmarks  marker_enrichment  conjugation_genes  amr_genes
```

Nota: o geNomad reporta plasmídeo **e** vírus, e a coluna `amr_genes` do
resumo de plasmídeo é uma segunda fonte, independente do MOB-suite, para a
mesma pergunta "a resistência está em elemento móvel".

---

## ISEScan (`xiezhq/ISEScan`)

Escreve `.csv` (vírgula) e `.tsv` (tab) com **o mesmo conteúdo**
(`pred.py:1129,1131`) — usar o `.tsv` evita problema com vírgula dentro de
campo.

Colunas, na ordem (`pred.py:728-751`):

```
seqID  family  cluster  isBegin  isEnd  isLen  ncopy4is  start1  end1
start2  end2  score  irId  irLen  nGaps  orfBegin  orfEnd  strand  orfLen
E-value  ov  tir
```

`family` é a família da sequência de inserção (IS3, IS5, IS200/IS605, …), que
é a coluna que interessa para um gráfico de composição.

---

## antiSMASH (`antismash/antismash`)

**Não escreve saída tabular nenhuma.** O diretório `antismash/outputs/` contém
apenas `html`. As saídas são: os `.gbk` por região, o `regions.js` dentro da
saída HTML (`outputs/html/generator.py:96-101`), e o `.json` completo do
resultado (`main.py:761`).

Isso muda o desenho: qualquer leitura de BGC precisa parsear o JSON do
antiSMASH (o mais estável dos três) em vez de um TSV. Fica registrado como
custo real, não como detalhe.

---

## BiG-SCAPE

Ainda **não verificado**. Continua como já estava registrado nas notas.
