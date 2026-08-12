# Amostras de saída real das ferramentas

Esta pasta existe para uma coisa só: escrever os leitores da aba Plots contra o
**formato real** de cada ferramenta, não contra o que a documentação diz ou o
que alguém lembra.

Isso não é preciosismo. Todos os bugs mais caros deste projeto foram dessa
classe — o `Element symbol` do AMRFinder que em versões antigas era
`Gene symbol`, o cabeçalho do eggNOG que começa com um `#` só enquanto o
banner usa `##`, o `{mag}.fa.fa` do MAGMA, o `-` do eggNOG virando uma família
gênica literalmente chamada `-`. Nenhum deles apareceria lendo documentação.

## Como fornecer

Coloque os arquivos nesta pasta mantendo o nome original. Não precisa ser a
saída inteira: **cabeçalho + umas 5 linhas de dados basta**, e é o suficiente
para ver os separadores e o formato dos valores.

```bash
head -6 contig_report.txt > docs/tool_output_samples/contig_report.txt
```

Se for de dado sensível, pode trocar nomes de amostra/contig por rótulos
genéricos — o que importa é a **estrutura**, não os valores.

Onde só peço `ls`, salve como arquivo de texto:

```bash
ls -R <pasta_de_saida> > docs/tool_output_samples/antismash_ls.txt
```

---

## Bloco 2 — Resistoma × mobiloma (MOB-suite)

Prioridade mais alta: é o bloco de maior valor científico dos três que faltam.

| Arquivo | O que preciso ver |
|---|---|
| `contig_report.txt` | cabeçalho + 5 linhas. **Crítico**: como o arquivo diz que um contig é cromossomo ou plasmídeo, e o nome exato dessa coluna e dos valores dela |
| `mobtyper_results.txt` | cabeçalho + 5 linhas. Preciso do nome exato das colunas de tipo de replicon, tipo de relaxase e mobilidade prevista, e de como valores múltiplos são separados (vírgula? ponto-e-vírgula?) |
| `mobsuite_ls.txt` | `ls` da pasta de saída do `mob_recon` — quais arquivos ele realmente escreve |

O que este bloco vai desenhar: se o gene de AMR está em plasmídeo ou no
cromossomo. Para isso preciso **casar o contig** entre o MOB-suite e os hits de
AMR. O AMRFinder já reporta `Contig id` e o ABRicate reporta `SEQUENCE` — o que
falta confirmar é se o identificador de contig do MOB-suite é o mesmo string,
ou se ele renomeia. Se renomear, o cruzamento precisa de outra chave e é melhor
eu saber agora.

## Bloco 3 — Mobiloma viral e sequências de inserção

| Arquivo | O que preciso ver |
|---|---|
| `quality_summary.tsv` (CheckV) | cabeçalho + 5 linhas |
| `isescan_ls.txt` | `ls` da pasta de saída do ISEScan |
| o `.csv` principal do ISEScan | cabeçalho + 5 linhas |
| saída do geNomad | `ls -R` da pasta, e cabeçalho + 5 linhas do resumo de vírus/plasmídeo |
| `final-viral-score.tsv` (VirSorter2) | cabeçalho + 3 linhas — opcional, o CheckV já cobre a parte de qualidade |

## Bloco 4 — BGC / metabólitos secundários

Este é o mais incerto dos quatro, porque o antiSMASH não escreve uma tabela
simples por padrão, e o formato do BiG-SCAPE já estava registrado nas notas
como não verificado.

| Arquivo | O que preciso ver |
|---|---|
| `antismash_ls.txt` | `ls -R` da pasta de saída (2 níveis bastam) — é isso que decide se dá para ler sem abrir GenBank |
| qualquer `.tsv`/`.txt` de resumo que aparecer ali | cabeçalho + 5 linhas |
| `bigscape_ls.txt` | `ls -R` da pasta de saída do BiG-SCAPE |
| o arquivo de anotação/rede do BiG-SCAPE | cabeçalho + 5 linhas |

Se o antiSMASH só deixar os `.gbk` por região, me diga — nesse caso a leitura
passa a ser extrair o qualificador `/product=` de cada região, que é mais
frágil e eu prefiro registrar isso explicitamente antes de escrever.

---

## Se você não achar alguma

Diga qual. Eu escrevo o leitor a partir do esquema documentado e **marco no
código e nas notas** que aquele não foi conferido contra saída real, do mesmo
jeito que o BiG-SCAPE já está registrado. Funciona, e fica honesto sobre onde
está o risco — o que não dá é apresentar como verificado o que não foi.
