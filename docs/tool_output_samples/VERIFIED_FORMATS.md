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

## BiG-SCAPE (`medema-group/BiG-SCAPE`, commit 6bf7ca7, 2026-04-01)

Verificado. **A saída mudou em relação ao que as notas assumiam** — este é o
BiG-SCAPE 2.x, uma reescrita, e os nomes de arquivo do 1.x (`Network_Annotations_Full.tsv`,
`*_clustering_c*.tsv` na raiz) não existem mais no mesmo lugar.

Layout real (`big_scape/output/legacy_output.py:183,352,457`):

```
<output_dir>/output_files/<label>_c<cutoff>/record_annotations.tsv
<output_dir>/output_files/<label>_c<cutoff>/<bin>/<bin>_clustering_c<cutoff>.tsv
```

**`record_annotations.tsv`** (`legacy_output.py:382-394`) — o antigo
`Network_Annotations_Full.tsv`:

```
Record  GBK  Record_Type  Record_Number  Class  Category  Organism  Taxonomy  Description
```

**`<bin>_clustering_c<cutoff>.tsv`** (`legacy_output.py:490-495`):

```
Record  GBK  Record_Type  Record_Number  CC  Family
```

`Family` vem formatado como `FAM_00001` (`legacy_output.py:511`), e `Record`
como `{nome_do_gbk}_{Record_Type}_{Record_Number}` — a chave para juntar as
duas tabelas.

Observações que importam para desenhar o gráfico:

- **`Class` e `Category` estão no `record_annotations.tsv`**, não no
  clustering. Um gráfico de "BGCs por classe por genoma" sai só desse arquivo,
  sem precisar do antiSMASH nem do clustering.
- O genoma de origem **não** é uma coluna, mas isso não importa aqui: o SIGMA
  roda o BiG-SCAPE **uma vez por amostra**, em
  `results/11_BGC/{sample}/bigscape` (ver `11_secondary_metabolites.smk:19-38`,
  que junta os `.gbk` daquela amostra num `gbk_pool` próprio). O genoma é o
  diretório, não algo a extrair do nome do arquivo.
- Consequência boa: **o gráfico de BGC por classe sai só deste arquivo**, sem
  precisar parsear o JSON do antiSMASH nem o clustering. Era o custo que eu
  tinha registrado como real na seção do antiSMASH; ele desaparece.
- Há também um `--db_only_output` que **suprime esses TSVs inteiros**
  (`legacy_output.py:344-346`), deixando só o SQLite. Se o SIGMA passar essa
  flag, nenhum dos arquivos acima existe.

---

# Auditoria dos leitores do DOGMA (2026-08-12)

Motivo: as notas registravam que **10 das 15 colunas de anotação do DOGMA nunca
tinham rodado contra arquivo nenhum**, porque a fixture só escreve eggnog,
ncycdb e catbat. Auditados um a um contra a fonte.

Resultado: **nenhum bug**. Os leitores estavam certos. O que faltava era prova.

| Coluna | Formato definido por | Situação |
|---|---|---|
| `cazy_*` | dbCAN **v5** (`bcb-unl/run_dbcan`) | **verificado agora** |
| `ncycdb_gene`, `scycdb_gene`, `mcycdb_gene` | a nossa própria regra | **verificado agora** |
| `canthyd_*` | HMMER `--tblout` | já conferido antes contra run real |
| `fegenie_*` | `Arkadiy-Garber/FeGenie` | **verificado agora** |
| `eukulele_*` | `AlexanderLabWHOI/EUKulele` | **verificado agora** |
| `magma_xref_*` | a nossa própria regra | **verificado agora** |
| `eggnog_*` | eggNOG-mapper v2 | já conferido antes |
| `catbat_*` | CAT/BAT | já conferido antes |

## O detalhe que quase virou um falso positivo

O repositório `linnabrown/run_dbcan` (o que aparece em qualquer busca) escreve
**`overview.txt`** e não tem o subcomando `CAZyme_annotation` que a nossa regra
chama. Parecia bug grave: regra declarando saída que a ferramenta não produz
faria o Snakemake falhar com `MissingOutputException`.

Não é. Aquele repositório parou na **v4** (último tag `4.2.0-rc.1`, master de
2025-04-22). Nós fixamos `dbcan=5.2.9`, e a v5 vive em **`bcb-unl/run_dbcan`**
— outra origem. Lá o subcomando existe (`dbcan/main.py:73`) e a saída é
`overview.tsv` (`tests/test_dbcan.py:81`).

Lição para a próxima auditoria: **conferir o tag/versão do repositório contra o
pin da env antes de concluir qualquer coisa**. Ler a fonte errada é tão ruim
quanto ler documentação.

### Cabeçalho real do `overview.tsv` (v5)

`dbcan/constants/OverviewGenerator_constants.py:17`:

```
Gene ID    EC#    dbCAN_hmm    dbCAN_sub    DIAMOND    #ofTools    Recommend Results
```

Confirma duas coisas do nosso leitor: a coluna 1 é `Gene ID`, e o nome
`dbCAN_hmm` é **da v5** — na v4 essa mesma coluna se chamava `HMMER`. O nosso
manifesto usa `cazy_dbCAN_hmm`, coerente com o pin.

`cazy_Substrate` só existe quando a predição de substrato roda
(`utils.py:205`, "compatible with the added Substrate column") — é opcional,
não uma coluna que sempre deveria estar lá.

### Formatos definidos pela nossa própria regra

Esses não têm ferramenta externa a consultar: o formato é o que o nosso shell
escreve, então a regra **é** a fonte.

- **NCyc/SCyc/MCycDB** (`dogma/rules/05_annotation.smk:109-112`):
  `diamond blastp --outfmt 6 qseqid sseqid pident length evalue bitscore`, e um
  `awk` anexa uma 7ª coluna com o gene, ou o literal `"NA"`. Bate com o leitor,
  inclusive o tratamento do `"NA"` como texto e não como ausência.
- **magma_xref** (`dogma/rules/08_magma_xref.smk:84-96`): as mesmas 6 colunas do
  DIAMOND, mais `mag` e `taxonomy` anexadas por Python. Bate com as 8 do leitor.

## NanoPlot

`NanoStats.txt` verificado contra o arquivo real que o próprio repositório traz
em `scripts/agm_tests/` (copiado para esta pasta). O leitor parseia certo,
inclusive os separadores de milhar (`45,338.0` → 45338).
