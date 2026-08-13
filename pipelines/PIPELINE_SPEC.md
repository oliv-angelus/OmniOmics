> **What this document is.** The original requirements specification that
> DEFINE was built to implement -- a transcriptomics reanalysis worked out step
> by step before any code existed. It is kept because two DEFINE scripts cite it
> by name for the reasoning behind their design decisions
> (`workflow/scripts/qc_summary.py`, `workflow/scripts/decide_strandedness.py`),
> and because it records why DEFINE's stages are arranged as they are.
>
> It is **not** a requirements document in the hardware sense -- for RAM, cores
> and CPU instruction sets see [`../docs/REQUIREMENTS.md`](../docs/REQUIREMENTS.md).
> It is also **not** a description of the other four pipelines; those are
> documented in [`../docs/pipelines/`](../docs/pipelines/).
>
> Kept in its original Portuguese: it is a historical source document, and
> translating it would make it a paraphrase of itself rather than the record it
> is.

---

# Especificação do pipeline — reanálise transcriptômica Pn16

> Documento de referência para automatizar este pipeline (ex.: Snakemake/Nextflow ou script próprio).
> Diferente do `LOG_PIPELINE.md` (registro cronológico com investigações e decisões pontuais), este documento
> descreve o fluxo como uma sequência de etapas reutilizáveis: entrada → ferramenta → parâmetros → saída.
> Marca explicitamente onde há julgamento humano/decisão de projeto vs. onde é uma etapa puramente mecânica.

---

## Visão geral do fluxo

```
FASTQ pareado (por amostra)
  → [1] QC bruto (FastQC/MultiQC)
  → [2] Trimagem (fastp)
  → [3] QC pós-trim (FastQC/MultiQC)
  → [4] Anotação do genoma de referência (Bakta)          ← uma vez por genoma, não por amostra
  → [5] Filtro de rRNA/tRNA/tmRNA no GFF                   ← depende da saída de [4]
  → [6] Confirmação de fita (RSeQC infer_experiment.py)    ← uma vez por lote, não por amostra
  → [7] Alinhamento (Bowtie2)                              ← por amostra, usa índice de [4]
  → [8] Contagem por gene (featureCounts)                  ← usa GFF filtrado de [5] e fita de [6]
  → [9] Expressão diferencial (DESeq2)                     ← usa matriz de [8] + design experimental
  → [10] Anotação funcional (eggNOG-mapper)                ← uma vez por genoma, usa proteínas de [4]
  → [11] Enriquecimento funcional (clusterProfiler)        ← usa DEGs de [9] + anotação de [10]
  → [12] Figuras e tabelas                                 ← usa [9], [10], [11]
```

Etapas [4] e [10] rodam uma vez por **genoma de referência**, não por amostra — reaproveitáveis entre projetos que usem o mesmo organismo. Etapa [6] roda uma vez por **lote de sequenciamento** (biblioteca/protocolo), não por amostra individual. Todas as outras rodam por amostra (ou usam a matriz agregada de todas as amostras).

---

## [1] QC bruto

**Ferramenta:** FastQC v0.12.1 + MultiQC v1.35
**Entrada:** FASTQ R1/R2 por amostra
**Comando:**
```
fastqc -t <threads> -o <dir_saida> <amostra>_R1.fastq.gz <amostra>_R2.fastq.gz
multiqc <dir_fastqc> -o <dir_multiqc>
```
**Saída:** relatórios HTML por amostra + relatório consolidado MultiQC (dados agregados em `multiqc_data/`, incluindo `multiqc_general_stats.txt` e `fastqc_overrepresented_sequences_plot.txt`).

**Automação:** 100% mecânico, sem decisão humana. Para um pipeline automatizado, vale extrair programaticamente do `multiqc_data` (não do HTML): % duplicação, % GC, sequências sobrerrepresentadas — usar como sinal de alerta automático para possível contaminação por rRNA (ver [5]).

---

## [2] Trimagem

**Ferramenta:** fastp v1.1.0
**Entrada:** FASTQ bruto + métricas de QC de [1]
**Comando:**
```
fastp -i <R1> -I <R2> -o <R1_trim> -O <R2_trim> -w <threads> --detect_adapter_for_pe \
  --cut_right --cut_right_window_size 4 --cut_right_mean_quality <Q> \
  --qualified_quality_phred <Q> --unqualified_percent_limit <P> --length_required <L>
```
**Parâmetros usados nesta reanálise** (calibrados nos dados reais, não são default do fastp): `Q=20`, `P=20`, `L=36`.

⚠️ **Decisão humana nesta etapa:** os valores de Q/P/L foram escolhidos olhando a distribuição real de qualidade por base do MultiQC (aqui, a qualidade já era excepcionalmente alta — Q38+ em toda a extensão da leitura — então usamos um corte mais rígido que o default do fastp, que é mais permissivo). **Para automação:** dá para tornar isso adaptativo — ex., ler a qualidade média por posição do `multiqc_data` e escolher Q automaticamente (ex.: usar o percentil 10 da qualidade por base como `qualified_quality_phred`), em vez de fixar um valor único para todo dataset.

**Saída:** FASTQ trimado por amostra + relatório JSON/HTML do fastp (`reads before/after`, taxa de retenção — usar como métrica de QC automática: alertar se retenção < ~85%).

---

## [3] QC pós-trim

Igual a [1], mas nos FASTQ trimados. Serve para confirmar que a trimagem funcionou (comparação antes/depois). Mecânico, sem decisão.

---

## [4] Anotação do genoma de referência

**Ferramenta:** Bakta v1.12.0 (banco local v6.0, "full")
**Entrada:** FASTA do genoma montado (não as leituras)
**Comando:**
```
bakta --db <caminho_banco_bakta> --output <dir_saida> --prefix <nome> \
  --locus-tag <PREFIXO> --genus <genero> --species <especie> --strain <linhagem> \
  --gram <+/-> --threads <n> --skip-crispr <genoma.fasta>
```
`--skip-crispr` foi necessário nesta máquina por incompatibilidade de CPU do PilerCR (ver nota de ambiente no fim do documento) — não é uma escolha de projeto, é um workaround de infraestrutura.

**Saída crítica para as próximas etapas:**
- `<prefix>.gff3` — anotação completa (CDS, rRNA, tRNA, tmRNA, ncRNA, etc.), usada em [5]/[8]
- `<prefix>.fna` — sequência do genoma (mesmos contigs, cabeçalhos renomeados), usada em [7] (índice do Bowtie2)
- `<prefix>.faa` — proteínas traduzidas de cada CDS, usada em [10]
- `<prefix>.tsv` — tabela plana locus_tag → gene → produto, usada para juntar nomes aos resultados finais

**Automação:** mecânico uma vez configurado; a única entrada variável entre projetos é o FASTA do genoma + metadados de organismo (genus/species/strain/gram). Rodar 1x por genoma e cachear a saída — não precisa rodar de novo a cada amostra ou a cada vez que o pipeline é executado.

---

## [5] Filtro de rRNA/tRNA/tmRNA

**Objetivo:** excluir da contagem de expressão os genes de RNA estrutural (rRNA, tRNA, tmRNA), que não são o alvo de uma análise de expressão de mRNA e cuja presença residual (mesmo após depleção em bancada, ex. Ribo-Zero) pode distorcer a normalização por ter contagens muito acima do restante do transcriptoma.

**Como foi feito (mecânico, direto do GFF do Bakta — não precisa do trabalho de investigação/confirmação que fizemos manualmente nesta reanálise):**
```python
# manter todas as linhas, exceto as de tipo rRNA/tRNA/tmRNA
awk -F'\t' '$1~/^#/ || ($3!="rRNA" && $3!="tRNA" && $3!="tmRNA")' <prefix>.gff3 > <prefix>_filtered.gff3
```
**Saída:** GFF filtrado, usado como anotação de entrada do featureCounts em [8].

⚠️ **Nota:** nesta reanálise, além desse filtro mecânico, foi feita uma investigação adicional (BLAST de sequências sobrerrepresentadas do FastQC contra o genoma + checagem de cobertura anômala na montagem) para **confirmar** que a contaminação era real antes de decidir excluir — isso foi um passo de verificação/auditoria, não uma etapa que uma ferramenta automatizada precisa reproduzir toda vez. Para automação, o filtro por tipo de feature (`rRNA`/`tRNA`/`tmRNA`) já é suficiente e é a prática padrão; a investigação extra só é necessária se o usuário quiser *diagnosticar* uma distorção de normalização inesperada depois dos resultados prontos.

**Ponto de atenção para o design de uma ferramenta automatizada:** este filtro assume que a anotação (Bakta ou similar) rotula corretamente os tipos de feature. Se o anotador não separar rRNA/tRNA como tipos distintos (ex., anotadores mais simples que só geram "gene"/"CDS"), a ferramenta precisa de uma etapa alternativa (ex., rodar Barrnap/tRNAscan-SE separadamente, ou usar um banco de referência de rRNA como o SILVA para filtrar por similaridade).

---

## [6] Confirmação de fita (strandedness)

**Ferramenta:** RSeQC v5.0.4 (`infer_experiment.py`)
**Entrada:** BAM alinhado de uma amostra representativa (não precisa ser todas) + BED12 de referência
**Gerar o BED12 a partir do GFF** (genes bacterianos são single-exon, conversão direta):
```python
# para cada linha de tipo CDS no GFF: chrom, start-1, end, id, 0, strand, start-1, end, 0, 1, tamanho, 0
```
**Comando:**
```
infer_experiment.py -r <genoma.bed12> -i <amostra.bam> -s 500000
```
**Saída:** frações de leituras em cada um dos 2 padrões de fita possíveis (`"1++,1--,2+-,2-+"` vs. `"1+-,1-+,2++,2--"`) + fração indeterminada.

**Decisão automatizável:** se uma fração > ~90% domina, a biblioteca é stranded (forward ou reverse, conforme qual fração domina); se as duas frações ficam próximas de 50/50, a biblioteca é unstranded. Isso mapeia diretamente para o parâmetro `-s` do featureCounts (`0`=unstranded, `1`=forward, `2`=reverse). **Totalmente automatizável** — não precisa de decisão humana, só rodar em 1-3 amostras e aplicar a regra acima. Evita depender só da ficha técnica do kit (que pode estar errada ou não ser informada).

---

## [7] Alinhamento

**Ferramenta:** Bowtie2 v2.5.5 + samtools v1.23.1
**Entrada:** FASTQ trimado (por amostra) + índice do genoma (de [4])
**Comando:**
```
bowtie2-build --threads <n> <genoma.fna> <prefixo_indice>   # uma vez só, reaproveitar
bowtie2 -p <n> -x <prefixo_indice> -1 <R1_trim> -2 <R2_trim> --no-unal \
  | samtools sort -@ <n> -o <amostra.sorted.bam> -
samtools index <amostra.sorted.bam>
```
**Saída:** BAM ordenado e indexado por amostra + log do Bowtie2 com % de alinhamento (métrica de QC automática — alertar se < ~85-90%, dependendo do organismo).

**Automação:** mecânico. Único cuidado é rodar `bowtie2-build` uma vez e reaproveitar o índice entre amostras (não reconstruir a cada amostra).

---

## [8] Contagem por gene

**Ferramenta:** Subread/featureCounts v2.1.1
**Entrada:** BAMs de [7] + GFF filtrado de [5] + parâmetro de fita de [6]
**Comando:**
```
featureCounts -T <n> -p --countReadPairs -t CDS -g locus_tag -s <0|1|2> \
  -a <genoma_filtered.gff3> -o <contagem.tsv> <amostra1.bam> <amostra2.bam> ...
```
Passar todos os BAMs de uma vez gera uma matriz de contagem única e já alinhada (mesmas linhas de gene, uma coluna por amostra) — mais conveniente que rodar por amostra e juntar depois.

**Saída:** `contagem.tsv` (matriz gene × amostra) + `.summary` (métricas de atribuição — % assigned, % no features, etc., outra métrica automática de QC).

**Automação:** mecânico, dado que [5] e [6] já resolveram o GFF de entrada e o parâmetro de fita.

---

## [9] Expressão diferencial

**Ferramenta:** R + DESeq2 v1.50.2 + apeglm v1.32.0
**Entrada:** matriz de contagem de [8] + tabela de design (amostra → condição/grupo experimental)
**Passos:**
```r
dds <- DESeqDataSetFromMatrix(countData, colData, design = ~condition)  # condicao de referencia = controle
keep <- rowSums(counts(dds) >= 10) >= <replicas_minimas_por_grupo>       # pre-filtro
dds <- dds[keep,]
dds <- DESeq(dds)
res <- lfcShrink(dds, coef = "condition_<X>_vs_<referencia>", type = "apeglm")
```
**Saída:** tabela por contraste com `baseMean, log2FoldChange, lfcSE, pvalue, padj` por gene; `sizeFactors(dds)` (métrica de QC — size factor muito fora do range das réplicas do mesmo grupo pode indicar amostra problemática, ex. contaminação residual); `vst(dds)` para PCA/heatmaps.

⚠️ **Duas decisões humanas nesta etapa, que uma ferramenta automatizada deveria expor como parâmetros configuráveis, não hardcode:**
1. **Design experimental** (`design = ~condition`, quem é a condição de referência) — depende do delineamento de cada projeto, não é genérico.
2. **Limiar de significância para chamar um gene de DEG** (`|log2FC| ≥ 1` e `padj < 0,05` nesta reanálise) — escolha de projeto, não estatística objetiva. **Recomendação para a ferramenta:** deixar configurável, com um valor default razoável (ex. os mesmos usados aqui), e sempre reportar explicitamente qual limiar foi usado nos metadados de saída (a causa raiz do problema nesta dissertação original foi justamente um limiar aplicado sem ser declarado de forma consistente — uma ferramenta automatizada deveria tornar isso impossível de acontecer por design, gravando o limiar usado junto com cada tabela de resultado).

---

## [10] Anotação funcional

**Ferramenta:** eggNOG-mapper v2.1.13 (banco local v5.0.2, modo `diamond`)
**Entrada:** FASTA de proteínas de [4] (`<prefix>.faa`)
**Comando:**
```
emapper.py -i <genoma.faa> --data_dir <banco_eggnog> -m diamond \
  --sensmode fast --dmnd_iterate no --cpu <n> -o <prefix> --output_dir <dir_saida>
```
`--sensmode fast` foi escolhido depois de testar que o modo default do emapper ("sensitive" + `--dmnd_iterate yes`) seria ~14x mais lento sem ganho relevante de sensibilidade para este caso (ver LOG_PIPELINE.md seção 13) — bom default para automação também, com opção de usar `sensitive` se o usuário tiver tempo/recursos de sobra e quiser sensibilidade máxima.

**Saída:** `<prefix>.emapper.annotations` — por gene: OGs do eggNOG, categoria COG, descrição, GO, EC, KEGG (ko/pathway/module), PFAM, etc. Roda uma vez por genoma, reaproveitável entre análises do mesmo organismo.

**Automação:** mecânico, mas depende de banco de dados local (~62 GB) já baixado — para uma ferramenta redistribuível, considerar oferecer também o modo remoto/menor banco (eggNOG "web"/API) como alternativa para quem não tem o banco local.

---

## [11] Enriquecimento funcional

**Ferramenta:** R + clusterProfiler v4.18.4 (+ GO.db v3.22.0, KEGGREST v1.50.0)
**Entrada:** lista de genes DEG (de [9], já com o limiar aplicado) + anotação funcional (de [10]) + universo de fundo (todos os genes testados em [9])
**Passos:**
```r
enricher(genes, universe, TERM2GENE, TERM2NAME, pAdjustMethod = "BH")   # COG e GO (TERM2GENE construido do eggNOG)
enrichKEGG(gene, organism = "ko", universe, pAdjustMethod = "BH")        # KEGG via API publica (nao precisa de organismo especifico)
```
**Saída:** tabela de termos testados com p.adjust por conjunto de genes (tipicamente rodado separadamente para UP e DOWN de cada contraste).

**Automação:** mecânico, dado o formato de entrada padronizado do eggNOG-mapper. Único cuidado: `enrichKEGG(organism="ko")` precisa de acesso à internet (consulta a API do KEGG) — para um ambiente sem internet, seria necessário cachear as definições de pathway localmente com antecedência.

---

## [12] Figuras e tabelas

Gerado a partir de [9]/[10]/[11]: PCA (vst + prcomp/plotPCA), vulcões (EnhancedVolcano), heatmaps (pheatmap, top-N por padj, z-score por linha), UpSet (UpSetR, interseção de listas de DEG por gene_id entre contrastes). Tudo determinístico a partir dos dados — sem decisão humana, exceto escolhas estéticas (paleta de cores, quantos genes rotular/mostrar).

---

## Resumo: onde a automação precisa de input humano vs. onde é 100% mecânico

| Etapa | Decisão humana? |
|---|---|
| [1] QC bruto | Não |
| [2] Trimagem | **Sim** — thresholds de qualidade (pode virar heurística automática) |
| [3] QC pós-trim | Não |
| [4] Anotação do genoma | Não (mas precisa dos metadados do organismo) |
| [5] Filtro rRNA/tRNA | Não, se o anotador tipa as features corretamente |
| [6] Fita | Não — totalmente inferível dos dados |
| [7] Alinhamento | Não |
| [8] Contagem | Não |
| [9] Expressão diferencial | **Sim** — design experimental e limiar de DEG |
| [10] Anotação funcional | Não |
| [11] Enriquecimento | Não |
| [12] Figuras/tabelas | Não (exceto estética) |

Ou seja: as duas únicas decisões de projeto que uma ferramenta automatizada realmente precisa expor ao usuário (não pode inferir sozinha com segurança) são **os thresholds de trimagem** (ou aceitar um bom default adaptativo) e **o design experimental + limiar de significância do DESeq2**. Todo o resto é mecanizável de ponta a ponta.

## Nota de ambiente (específica desta máquina, não do pipeline)

Nesta máquina em particular, alguns binários bioconda (PilerCR, MMseqs2) falham com "Illegal instruction" por causa de uma CPU sem AVX2 (Xeon X5650). Contornado usando `--skip-crispr` no Bakta e o modo `diamond` (em vez de `mmseqs`) no eggNOG-mapper. Isso não é uma característica do pipeline em si — é só um detalhe de infraestrutura que uma ferramenta redistribuível deveria detectar automaticamente (testar o binário antes de usar, com fallback) em vez de assumir hardware moderno.
