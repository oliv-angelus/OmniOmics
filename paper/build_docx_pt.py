#!/usr/bin/env python3
"""Gera Artigo_PT.docx -- versão em português (tradução) de Artigo.docx.
Mesma estrutura, mesmas tabelas e dados reais; apenas o texto narrativo é
traduzido. Nomes de ferramentas, bancos de dados, espécies, DOIs, números e
referências bibliográficas permanecem no idioma/formato original, como é
prática padrão em traduções de artigos científicos."""
import json
import os
import docx
from docx import Document
from docx.shared import Pt, Cm, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

BLACK = RGBColor(0, 0, 0)

doc = Document()

# --- estilo base: Times New Roman 12pt em todo o documento ---
style = doc.styles["Normal"]
style.font.name = "Times New Roman"
style.font.size = Pt(12)
style.font.color.rgb = BLACK
for section in doc.sections:
    section.left_margin = Cm(2.5)
    section.right_margin = Cm(2.5)
    section.top_margin = Cm(2.5)
    section.bottom_margin = Cm(2.5)

_counters = [0, 0, 0]  # nível 1, 2, 3

def set_cell_shading(cell, hex_color):
    shd = OxmlElement("w:shd")
    shd.set(qn("w:fill"), hex_color)
    cell._tc.get_or_add_tcPr().append(shd)

def add_pending(paragraph, text):
    run = paragraph.add_run(text)
    run.font.name = "Times New Roman"
    run.font.size = Pt(12)
    run.font.color.rgb = BLACK
    run.bold = True
    return run

def add_note(text):
    p = doc.add_paragraph()
    r = p.add_run(text)
    r.font.name = "Times New Roman"
    r.font.size = Pt(12)
    r.font.color.rgb = BLACK
    r.italic = True
    doc.add_paragraph()

def heading(text, level=1):
    _counters[level - 1] += 1
    for i in range(level, 3):
        _counters[i] = 0
    number = ".".join(str(_counters[i]) for i in range(level))
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(14 if level == 1 else 8)
    p.paragraph_format.space_after = Pt(4)
    r = p.add_run(f"{number}. {text}" if level == 1 else f"{number} {text}")
    r.bold = True
    r.font.name = "Times New Roman"
    r.font.size = Pt(12)
    r.font.color.rgb = BLACK
    return p

def unnumbered_heading(text):
    p = doc.add_paragraph()
    p.paragraph_format.space_before = Pt(14)
    p.paragraph_format.space_after = Pt(4)
    r = p.add_run(text)
    r.bold = True
    r.font.name = "Times New Roman"
    r.font.size = Pt(12)
    r.font.color.rgb = BLACK
    return p

def para(text="", size=12, italic=False, bold=False):
    p = doc.add_paragraph()
    if text:
        r = p.add_run(text)
        r.font.name = "Times New Roman"
        r.font.size = Pt(size)
        r.font.color.rgb = BLACK
        r.italic = italic
        r.bold = bold
    return p

def set_col_widths(table, widths_cm):
    table.autofit = False
    for row in table.rows:
        for cell, w in zip(row.cells, widths_cm):
            cell.width = Cm(w)
    tbl = table._tbl
    tblGrid = tbl.find(qn("w:tblGrid"))
    if tblGrid is not None:
        for gridCol, w in zip(tblGrid.findall(qn("w:gridCol")), widths_cm):
            gridCol.set(qn("w:w"), str(int(w * 567)))

def make_table(headers, rows, widths_cm, pending_cols=None):
    pending_cols = pending_cols or set()
    table = doc.add_table(rows=1, cols=len(headers))
    table.style = "Table Grid"
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    hdr_cells = table.rows[0].cells
    for i, h in enumerate(headers):
        hdr_cells[i].text = ""
        p = hdr_cells[i].paragraphs[0]
        r = p.add_run(h)
        r.bold = True
        r.font.name = "Times New Roman"
        r.font.size = Pt(10)
        r.font.color.rgb = BLACK
    for row in rows:
        cells = table.add_row().cells
        for i, val in enumerate(row):
            cells[i].text = ""
            p = cells[i].paragraphs[0]
            is_pending = isinstance(val, str) and val.startswith("[PENDENTE")
            r = p.add_run(val)
            r.font.name = "Times New Roman"
            r.font.size = Pt(10)
            r.font.color.rgb = BLACK
            if is_pending:
                r.bold = True
    set_col_widths(table, widths_cm)
    doc.add_paragraph()
    return table

# ============================================================
# PÁGINA DE TÍTULO
# ============================================================
title_p = doc.add_paragraph()
title_p.alignment = WD_ALIGN_PARAGRAPH.CENTER
r = title_p.add_run(
    "OmniOmics: um hub local de pipelines para análise multiômica "
    "reprodutível e de ponta a ponta com Snakemake e conda"
)
r.bold = True
r.font.size = Pt(16)

sub = doc.add_paragraph()
sub.alignment = WD_ALIGN_PARAGRAPH.CENTER
rs = sub.add_run("Rascunho de Resource Article, periódico-alvo: Molecular Ecology Resources")
rs.italic = True
rs.font.size = Pt(11)
rs.font.color.rgb = BLACK

doc.add_paragraph()
auth = doc.add_paragraph()
auth.alignment = WD_ALIGN_PARAGRAPH.CENTER
ra = auth.add_run("Angelo Felipe Barbosa de Oliveira")
ra.bold = True
ra.font.size = Pt(12)
sup = auth.add_run("1")
sup.font.superscript = True

affil = doc.add_paragraph()
affil.alignment = WD_ALIGN_PARAGRAPH.CENTER
raf = affil.add_run(
    "1Programa de Pós-Graduação em Genética e Biologia Molecular, "
    "Universidade Federal do Pará (UFPA), Belém, PA, Brasil. "
    "ORCID: 0000-0003-0831-447X"
)
raf.font.size = Pt(10)
raf.font.color.rgb = BLACK

doc.add_paragraph()
add_note(
    "Tradução para português do rascunho em andamento, iniciado em "
    "2026-09-12. Seções marcadas como PENDENTE são espaços reservados ou "
    "estão incompletas; as execuções reais de validação em HPC por trás da "
    "seção de Resultados ainda estão em andamento (ver "
    "github.com/oliv-angelus/OmniOmics-validation para o status ao vivo). "
    "Este bloco de nota deve ser removido antes da submissão. O idioma de "
    "submissão para a Molecular Ecology Resources é o inglês "
    "(ver Artigo.docx); esta versão em português é para uso interno/"
    "divulgação."
)

# ============================================================
# RESUMO (ABSTRACT)
# ============================================================
unnumbered_heading("Resumo")
p = para()
add_pending(p, (
    "[PENDENTE: redigir após a conclusão dos Resultados; ≤250 palavras "
    "conforme a exigência da MER para Resource Article. Deve declarar: "
    "(1) a lacuna, isto é, que microbiologistas de bancada sem fluência em "
    "terminal/HPC ficam excluídos da análise multiômica reprodutível; "
    "(2) o que é o OmniOmics, isto é, uma aplicação nativa de desktop que "
    "empacota cinco pipelines Snakemake independentes (MAGMA/SIGMA/DOGMA/"
    "DEFINE/PRISM: metagenômica, genômica de isolados, metatranscriptômica, "
    "expressão diferencial, metabarcoding de amplicons) atrás de uma única "
    "interface gráfica, sem necessidade de servidor/terminal; (3) a prova "
    "de extensibilidade, isto é, que quatro dos cinco pipelines foram "
    "adicionados sem nenhuma mudança na camada de execução de pipelines; "
    "(4) a validação, isto é, conjuntos de dados públicos reais, não "
    "simulados, com verdade de campo conhecida, executados de ponta a "
    "ponta, com correção confirmada contra resultados esperados "
    "certificados/publicados; (5) disponibilidade: código aberto, licença "
    "MIT, pacote .deb, repositório complementar de reprodutibilidade.]"
))

# ============================================================
# INTRODUÇÃO
# ============================================================
heading("Introdução", level=1)
para(
    "A análise multiômica reprodutível depende cada vez mais de "
    "gerenciadores de fluxo de trabalho como o Snakemake (Mölder et al., "
    "2021) ou o Nextflow (Di Tommaso et al., 2017), que resolvem a "
    "reprodutibilidade e o gerenciamento de dependências, mas pressupõem "
    "familiaridade com linha de comando, uma sessão de terminal e, "
    "frequentemente, acesso direto a HPC. Essa é uma barreira real para "
    "boa parte dos pesquisadores que geram os dados em primeiro lugar, "
    "incluindo microbiologistas de bancada, ecólogos e clínicos sem apoio "
    "dedicado de bioinformática, que acabam ou aprendendo linha de "
    "comando o suficiente para ser perigoso, ou dependendo inteiramente "
    "de um colaborador para cada nova análise."
)
para(
    "As soluções existentes resolvem metade desse problema de cada vez. "
    "O Galaxy (Galaxy Community, 2022) e o KBase (Arkin et al., 2018) "
    "oferecem uma interface gráfica, mas exigem infraestrutura de "
    "servidor ou nuvem, seja autogerenciada ou uma instância pública "
    "compartilhada, em vez de uma instalação local que um único "
    "pesquisador possa simplesmente executar. O nf-core (Ewels et al., "
    "2020) e o Bactopia (Petit & Read, 2020) são locais e reprodutíveis "
    "em primeiro lugar, mas continuam ancorados em CLI; o próprio comando "
    "de lançamento do nf-core adiciona uma GUI nativa de entrada de "
    "parâmetros, mas ainda exige um terminal para ser invocado e não tem "
    "painel de monitoramento de execução ou de resultados sem a camada "
    "separada e comercial Seqera Platform. O Anvi'o (Eren et al., 2021) "
    "é local e genuinamente multiômico, mas sua interface interativa é "
    "uma camada de visualização a jusante sobre dados já processados, não "
    "um ambiente completo de configuração-execução-monitoramento de "
    "pipeline. O Bactopia é local e fácil de executar, mas restrito a um "
    "único domínio, a genômica bacteriana."
)
para(
    "O OmniOmics foi construído para fechar essa lacuna específica e "
    "composta: uma aplicação nativa de desktop, sem exigir terminal, "
    "servidor autogerenciado ou dependência de nuvem, que cobre todo o "
    "ciclo configurar → executar → monitorar → analisar em cinco domínios "
    "ômicos independentes em uma única interface, e é projetada para que "
    "novos pipelines possam ser adicionados sem tocar no código da "
    "própria aplicação."
)

# ============================================================
# MATERIAIS E MÉTODOS
# ============================================================
heading("Materiais e Métodos", level=1)

heading("Arquitetura", level=2)
para(
    "O OmniOmics é uma aplicação de desktop em Flutter (o cliente "
    "gráfico, sem HTML/WebView) que inicia um backend FastAPI/Python "
    "como processo filho local, comunicando-se via HTTP e WebSocket em "
    "127.0.0.1. Toda a lógica de orquestração de pipelines, incluindo "
    "gerenciamento de ambientes conda/Snakemake, download de bancos de "
    "dados com relato de progresso, parsing dos logs do Snakemake e "
    "monitoramento de execuções, reside no backend; a camada Flutter é "
    "um cliente enxuto."
)
para(
    "Cada pipeline é um diretório autocontido (pipelines/<id>/) que "
    "guarda seu próprio fluxo de trabalho Snakemake e um manifesto "
    "pipeline.yaml descrevendo suas ferramentas, parâmetros, padrões de "
    "threads e requisitos de banco de dados em um esquema declarativo. O "
    "backend descobre os pipelines instalados varrendo esse manifesto na "
    "inicialização; adicionar um pipeline significa adicionar um novo "
    "diretório, não modificar o código da aplicação. Bancos de dados "
    "compartilhados (por exemplo, CheckM2, GTDB-Tk, usados por mais de "
    "um pipeline) são deduplicados e configurados uma única vez no nível "
    "da aplicação, em vez de por pipeline."
)
para(
    "Os cinco pipelines empacotados no momento da redação são: MAGMA, "
    "para metagenômica shotgun (montagem, binning, recuperação de MAGs e "
    "anotação); SIGMA, para montagem, polimento e anotação de genomas de "
    "isolados bacterianos únicos; DOGMA, para metatranscriptômica "
    "(montagem de novo e anotação funcional); DEFINE, para RNA-seq de "
    "isolados bacterianos e expressão diferencial; e PRISM, para "
    "metabarcoding de amplicons (16S/18S/23S/28S/ITS/operon rrn/COI/12S, "
    "tanto leituras curtas quanto longas)."
)
para(
    "Além de executar cada pipeline, a aplicação inclui uma aba de "
    "Gráficos que gera figuras de pré-visualização prontas para "
    "publicação diretamente a partir da própria saída de uma execução "
    "concluída (diversidade, ordenação, abundância diferencial e outras "
    "análises padrão por pipeline), cada uma parametrizada pela "
    "interface gráfica. Isso permite que um pesquisador sem experiência "
    "em programação R produza e inspecione figuras estatísticas reais a "
    "partir de seus próprios dados, sem escrever código de análise."
)

heading("Alegação de extensibilidade", level=2)
para(
    "O MAGMA foi o pipeline fundador; o SIGMA, o DOGMA, o DEFINE e o "
    "PRISM foram adicionados depois, cada um sem nenhuma mudança na "
    "camada de execução de pipelines: descoberta, configuração, "
    "submissão de execução e monitoramento funcionaram imediatamente "
    "apenas a partir do diretório e do manifesto do novo pipeline. Isso "
    "é apresentado como evidência direta e estrutural para a alegação de "
    "extensibilidade, não como uma afirmação sem lastro."
)
para(
    "A única camada com adições reais e incrementais por pipeline é a "
    "aba de Gráficos descrita acima. O formato de saída de cada pipeline "
    "exigiu uma pequena extensão pontual na primeira vez em que foi "
    "conectado, por exemplo um novo tipo de parâmetro para as análises "
    "por genoma do SIGMA (a montagem de isolados não tem uma tabela "
    "entre amostras como um perfil de comunidade tem) e uma busca de "
    "arquivo de saída sensível ao pipeline para o PRISM (um nome de "
    "arquivo de tabela final diferente do usado pelo MAGMA). Essas "
    "adições são reportadas honestamente como pequenas e delimitadas a "
    "uma camada de visualização compartilhada, não como exceções à "
    "alegação de extensibilidade da camada de execução acima."
)

heading("Comparação com plataformas existentes (Entregável A)", level=2)
para(
    "Seis plataformas adjacentes foram comparadas quanto a interface, "
    "modelo de implantação, amplitude de domínio e mecanismo de "
    "extensibilidade, escolhidas porque cada uma ocupa um nicho real e "
    "citável adjacente ao do OmniOmics, e não como concorrentes diretas "
    "ferramenta-a-ferramenta. A comparação usou a documentação pública "
    "atual de cada plataforma em 27/08/2026, não apenas o resumo de sua "
    "publicação fundadora. Ver Tabela 1. Uma segunda comparação, "
    "pareada por domínio, contra o pipeline de propósito único que um "
    "pesquisador usaria de outra forma para cada um dos cinco domínios "
    "do OmniOmics (Tabela 1b), faz o mesmo argumento em granularidade "
    "mais fina."
)

heading("Validação real de ponta a ponta (Entregável B)", level=2)
para(
    "O OmniOmics orquestra ferramentas de terceiros sem modificar ou "
    "reimplementar seus algoritmos; um benchmark de acurácia cabeça a "
    "cabeça contra outros pipelines mediria, portanto, essas ferramentas "
    "subjacentes, não a lógica própria desta contribuição. Em vez disso, "
    "cada um dos cinco pipelines foi executado de verdade, nem como "
    "simulação nem sobre dados sintéticos, contra um conjunto de dados "
    "público com resultado esperado conhecido e publicado de forma "
    "independente, usando a mesma invocação do Snakemake e o mesmo "
    "esquema de configuração que a própria aplicação gera internamente, "
    "executado em um nó de computação (128 núcleos de CPU, ~264 GB de "
    "RAM, openSUSE Leap 15.3) do cluster institucional da Universidade "
    "Federal do Oeste do Pará (UFOPA). A correção foi então verificada "
    "contra essa verdade de campo publicada, não contra a saída de outra "
    "ferramenta."
)
para(
    "Os conjuntos de dados, sua verdade de campo e o critério de "
    "aprovação usado para cada pipeline estão na Tabela 2. Os tamanhos "
    "amostrais foram escolhidos seguindo a prática padrão para este tipo "
    "de demonstração de infraestrutura/orquestração, em vez de um novo "
    "estudo de replicação biológica, seguindo a própria convenção de "
    "perfil de teste mínimo do nf-core e o desenho de validação com três "
    "réplicas por condição do SARTools (Varet et al., 2016), em vez de "
    "reproduzir o número completo de réplicas de cada estudo de origem."
)
para(
    "Os dados brutos de sequenciamento nunca são re-hospedados; todo "
    "conjunto de dados já é público (acessos SRA/ENA/GEO/dados abertos "
    "de fabricante, citados na Tabela 2). Os arquivos de configuração "
    "exatos, a verdade de campo curada e a comparação observado-vs-"
    "esperado para cada pipeline são publicados como um pacote "
    "complementar de reprodutibilidade (OmniOmics-validation, ver "
    "Acessibilidade dos Dados)."
)

# ============================================================
# RESULTADOS
# ============================================================
heading("Resultados", level=1)

heading("Tabela 1. Comparação com plataformas existentes", level=2)
t1_headers = ["Plataforma", "Citação", "Interface", "Implantação", "Amplitude de domínio", "Modelo de extensibilidade"]
t1_rows = [
    ["Galaxy", "Galaxy Community 2022, doi:10.1093/nar/gkac247", "Navegador (web)", "Servidor/nuvem, autogerenciado ou público", "Amplo, agnóstico à ferramenta", "Wrappers XML do ToolShed, ecossistema grande"],
    ["nf-core", "Ewels et al. 2020, doi:10.1038/s41587-020-0439-x", "CLI (Nextflow); GUI nativa de entrada de parâmetros (launch), sem painel de monitoramento sem a camada comercial Seqera", "Local/HPC/nuvem", "Amplo, catálogo curado pela comunidade", "Novo pipeline = novo repositório revisado pela comunidade"],
    ["KBase", "Arkin et al. 2018, doi:10.1038/nbt.4163", "Navegador (interface narrativa)", "Hospedado em nuvem (infraestrutura do DOE)", "Sistemas/microbiologia/biologia vegetal", "Baseado em apps, curadoria centralizada"],
    ["Anvi'o", "Eren et al. 2021, doi:10.1038/s41564-020-00834-3", "CLI + visualização interativa HTML/D3, não é uma GUI de orquestração de execução", "Local", "Multiômico, mais forte em metagenômica", "Estilo plugin, conduzido pela comunidade"],
    ["Bactopia", "Petit & Read 2020, doi:10.1128/mSystems.00190-20", "CLI (Nextflow)", "Local/HPC/nuvem", "Domínio único: apenas genômica bacteriana", "Módulos de pós-processamento “Bactopia Tools”"],
    ["Snakemake (motor sobre o qual o OmniOmics é construído)", "Mölder et al. 2021, doi:10.12688/f1000research.29032.3", "CLI, sem GUI nativa", "Local/HPC/nuvem", "Genérico, agnóstico a domínio", "Baseado em regras, por projeto"],
    ["OmniOmics (este trabalho)", "—", "GUI nativa de desktop, zero terminal", "Local, zero dependência de servidor/nuvem", "5 domínios em uma aplicação", "Novo pipeline = novo diretório + manifesto, sem mudança no código-núcleo"],
]
make_table(t1_headers, t1_rows, widths_cm=[2.5, 2.7, 2.7, 2.7, 2.7, 3.2])

heading("Tabela 1b. Comparação com pipelines pareados por domínio", level=2)
para(
    "A Tabela 1 compara o OmniOmics com plataformas gerais multi-"
    "ferramenta. Uma segunda comparação, mais específica, é possivelmente "
    "mais informativa: contra o pipeline de domínio único que um "
    "pesquisador usaria de outra forma para cada um dos cinco domínios "
    "do OmniOmics. Os seis pipelines pareados por domínio abaixo são "
    "todos exclusivamente CLI (os pipelines nf-core baseados em Nextflow "
    "herdam o próprio modelo de interface do nf-core: existe uma GUI "
    "nativa de entrada de parâmetros, launch, mas ainda exige um "
    "terminal para ser invocada e não tem painel de monitoramento/"
    "resultados sem a camada separada e comercial Seqera Platform). O "
    "QIIME2 é a única exceção que tentou uma GUI nativa de desktop "
    "(q2studio), que nunca passou de um protótipo em estágio alfa e está "
    "arquivada desde dezembro de 2023, sem manutenção e inutilizável com "
    "as versões atuais do QIIME2."
)
t1b_headers = ["Pipeline OmniOmics", "Ferramenta pareada por domínio", "Citação", "GUI nativa", "Bancos de dados de referência", "Escopo de domínio"]
t1b_rows = [
    ["MAGMA", "nf-core/mag + nf-core/taxprofiler (dois pipelines separados encadeados)",
     "Krakau et al. 2022, doi:10.1093/nargab/lqac007; Stamouli et al. 2023 (preprint), doi:10.1101/2023.10.20.563221",
     "Nenhuma", "Baixa automaticamente o GTDB-Tk (~110 GB) e o CAT/NCBI-nr (~200 GB) como dois downloads independentes", "mag: apenas montagem/binning/taxonomia de MAGs, sem perfilamento de comunidade em nível de leitura; taxprofiler: apenas perfilamento em nível de leitura, sem montagem"],
    ["SIGMA", "nf-core/bacass", "comunidade nf-core, github.com/nf-core/bacass",
     "Nenhuma", "Os caminhos dos bancos de dados Kraken2/KmerFinder devem ser informados manualmente", "Apenas montagem de isolados bacterianos"],
    ["DOGMA", "nf-core/metatdenovo", "Di Leo et al. 2025, doi:10.7717/peerj.20328",
     "Nenhuma", "Configuração manual por banco de dados", "Apenas montagem/anotação de metatranscriptomas"],
    ["DEFINE", "nf-core/rnaseq + nf-core/differentialabundance (dois pipelines separados encadeados)", "comunidade nf-core",
     "Nenhuma", "Genoma/anotação de referência fornecidos pelo usuário", "Apenas expressão diferencial"],
    ["PRISM", "nf-core/ampliseq", "comunidade nf-core, github.com/nf-core/ampliseq",
     "Nenhuma", "Baixa automaticamente SILVA/UNITE/PR2/GTDB sob demanda", "Apenas metabarcoding de amplicons"],
    ["PRISM (alt.)", "QIIME2", "Bolyen et al. 2019, doi:10.1038/s41587-019-0209-9",
     "q2studio: arquivada em dez. 2023, protótipo em estágio alfa, sem manutenção", "Configuração manual por plugin", "Apenas metabarcoding de amplicons"],
]
make_table(t1b_headers, t1b_rows, widths_cm=[2.3, 3.3, 3.0, 3.0, 3.2, 2.2])
para(
    "Reproduzir o que o OmniOmics cobre em uma única aplicação exigiria "
    "instalar, aprender e executar separadamente pelo menos sete "
    "pipelines Nextflow diferentes, nenhum dos quais compartilha entre "
    "si uma interface, um gerenciador de bancos de dados ou uma visão de "
    "monitoramento de execução comum. O tratamento de bancos de dados de "
    "referência no ecossistema nf-core é, em si, real e frequentemente "
    "bem projetado (tanto o nf-core/mag quanto o nf-core/ampliseq baixam "
    "automaticamente bancos de dados curados), razão pela qual isso não "
    "é apresentado como uma lacuna de automação de bancos de dados; a "
    "lacuna real é que o gerenciamento de bancos de dados permanece "
    "isolado por pipeline, sem uma visão compartilhada e conduzida por "
    "GUI entre domínios, a mesma lacuna que se aplica à configuração, "
    "execução e monitoramento ao longo desta comparação."
)

heading("Tabela 2. Conjuntos de dados de validação, verdade de campo e critério de aprovação", level=2)
t2_headers = ["Pipeline", "Conjunto de dados", "Verdade de campo", "Critério de aprovação"]
t2_rows = [
    ["MAGMA", "Comunidade mock ZymoBIOMICS, even+log, híbrido Illumina+ONT (Nicholls et al. 2019, doi:10.1093/gigascience/giz043)", "Composição teórica certificada (%) por espécie", "Abundância observada dentro de 10% do valor certificado; taxonomia correta em nível de espécie para as 10"],
    ["SIGMA", "Isolado individual de E. coli, mesma série Zymo, Illumina + ONT/PacBio independentes (McIntyre et al. 2019, doi:10.1038/s41467-019-08289-9)", "Genoma de referência do próprio isolado, fornecido pela Zymo", "QUAST vs. referência: fração do genoma, N50, desmontagens; comparação híbrido vs. apenas leituras curtas"],
    ["DOGMA", "Metatranscriptoma de solo, série temporal de adição de glicose (Chuckran et al. 2021, doi:10.1128/mSystems.00161-21)", "Direção da mudança (para cima/para baixo) para categorias gênicas nomeadas em t8 vs t0, fold-changes reais do artigo", "Sinal do log2FoldChange do DESeq2 corresponde à direção reportada"],
    ["DEFINE", "E. coli exposta a 239Pu vs. controle, dia 1 (GEO GSE208658, doi:10.1128/msystems.00718-22)", "590 DEGs (13,8% dos CDSs) reportados para este contraste; categorias funcionais enriquecidas", "Contagem de DEGs na mesma ordem de grandeza; sobreposição de categorias enriquecidas"],
    ["PRISM", "Comunidade ZymoBIOMICS 16S “MSPlus”, ONT (dados abertos do fabricante, zymo_16s_2025.09)", "Classificação Emu oficial da própria ONT para o mesmo arquivo de leituras", "Abundância em nível de espécie correlaciona com o próprio resultado da ONT; todas as 4 espécies adicionadas detectadas"],
]
make_table(t2_headers, t2_rows, widths_cm=[2.2, 4.8, 4.3, 4.7])

heading("Resultados reais de validação", level=2)
t3_headers = ["Pipeline", "Status", "Resultado principal"]
t3_rows = [
    ["SIGMA (via ONT)", "Concluído, APROVADO",
     "A montagem híbrida Illumina+ONT de um isolado de referência de E. "
     "coli da Zymo recuperou 100,000% da fração do genoma em relação ao "
     "genoma de referência certificado, zero desmontagens, comprimento "
     "total a 11 pb da referência (4.875.452 vs. 4.875.441 pb). A "
     "montagem apenas com leituras curtas do mesmo isolado, corretamente "
     "mais fragmentada (87 contigs alinhados vs. 2) mas ainda assim com "
     "zero desmontagens, demonstrando melhoria mensurável a partir do "
     "polimento com leituras longas, sem introduzir erro estrutural."],
    ["SIGMA (via PacBio)", "Concluído, resultado misto (ver Discussão)",
     "A montagem híbrida Illumina+PacBio do mesmo isolado (subreads "
     "PacBio RS II CLR, McIntyre et al. 2019) identificou corretamente a "
     "espécie (GTDB-Tk) com 100,0% de completude pelo CheckM2 e 99,04% "
     "de fração do genoma em relação à referência, mas introduziu 21 "
     "desmontagens reais (6 contigs mal montados, 8 locais); a montagem "
     "apenas com leituras curtas do mesmo isolado teve zero. Atribuído à "
     "taxa de erro bruto por leitura substancialmente mais alta da "
     "química CLR em relação à execução ONT acima (sem correção por "
     "consenso circular neste conjunto de dados de 2018), e não a um "
     "defeito do pipeline; reportado como um resultado honesto e misto, "
     "e não como uma aprovação uniforme."],
    ["DEFINE", "Concluído, APROVADO",
     "A análise real com DESeq2 (E. coli exposta a 239Pu vs. controle "
     "não irradiado, dia 1, 3 réplicas por condição) contra o genoma de "
     "referência real do GEO GSE208658, usando os próprios critérios de "
     "DEG declarados pelo artigo (log2FC>2 e padj<0,05, Wintenberg et "
     "al. 2023) em vez de apenas o padj, encontrou 433 DEGs "
     "significativos (9,9% dos genes testados), a mesma ordem de "
     "grandeza dos 590 (13,8%) reportados pelo artigo. A sobreposição de "
     "categorias funcionais também se confirmou: os genes significativos "
     "foram hits reais em todas as categorias reportadas como "
     "enriquecidas para este contraste (transportadores ABC, "
     "biossíntese de sideróforos, resposta a estresse, biossíntese de "
     "aminoácidos)."],
    ["PRISM (execução com verdade de campo, ONT 16S “MSPlus”)", "Concluído, resultado misto (ver Discussão)",
     "A classificação Emu real (referência GTDB SSU r220) de 3 réplicas "
     "ONT MSPlus, comparada com a própria classificação Emu oficial da "
     "ONT para os mesmos arquivos de leituras, em nível de gênero (a "
     "nomenclatura em nível de espécie difere entre versões do GTDB). A "
     "dissimilaridade de Bray-Curtis, a métrica padrão de similaridade "
     "composicional para este tipo de dado, foi de 0,08-0,11 entre "
     "réplicas (média 0,10), indicando forte concordância em nível de "
     "comunidade; o r de Pearson (0,96-0,98) e o rho de Spearman "
     "(0,66-0,79) são reportados junto, e não isoladamente, já que o "
     "Pearson sozinho é dominado por poucos gêneros de alta abundância. "
     "Das quatro espécies adicionadas especificamente rastreadas, três "
     "foram detectadas com abundâncias próximas (Bifidobacterium "
     "adolescentis, B. vaginale, Borreliella/Borrelia burgdorferi); a "
     "Chlamydia trachomatis não foi detectada de forma alguma, muito "
     "provavelmente devido ao descompasso documentado entre os primers "
     "universais de 16S e as sequências de Chlamydiae, e não a um "
     "defeito do banco de dados ou da classificação (o genoma de "
     "referência está presente no banco de dados usado)."],
    ["MAGMA", "Concluído, resultado misto (ver Discussão)",
     "Montagem híbrida real Illumina+Nanopore e binning das comunidades "
     "mock even e log-distribuídas da ZymoBIOMICS. Duas linhas de "
     "evidência independentes: (1) o perfilamento taxonômico baseado em "
     "leituras (Kraken2+Bracken) detectou as 10 espécies de referência "
     "em ambas as distribuições, abrangendo cerca de cinco ordens de "
     "grandeza na amostra log-distribuída, mas correspondeu à composição "
     "certificada dentro de uma tolerância relativa pré-registrada de "
     "±10% para apenas 2 das 10 espécies na amostra de abundância igual; "
     "os desvios reais para as 8 restantes (0,5-3,6 pontos percentuais) "
     "são consistentes com vieses conhecidos de eficiência de extração e "
     "de número de cópias do genoma na estimativa de abundância baseada "
     "em leituras, e não um defeito do pipeline. (2) A montagem e o "
     "binning reais do metagenoma recuperaram 7 MAGs dereplicados, todos "
     "os 7 corretamente classificados na espécie certa pelo GTDB-Tk sem "
     "nenhuma chamada falsa e com qualidade alta a média (completude "
     "CheckM2 de 81,7-100%, contaminação de 0,0-5,6%), o real "
     "diferencial do pipeline frente a simples ferramentas de "
     "classificação de leituras."],
    ["DOGMA", "Em execução", "[PENDENTE]"],
]
make_table(t3_headers, t3_rows, widths_cm=[3.5, 2.5, 10.0])

# ============================================================
# DISCUSSÃO
# ============================================================
heading("Discussão", level=1)
para(
    "Os dois caminhos de leitura longa do SIGMA no mesmo isolado "
    "ilustram um ponto que vale a pena declarar explicitamente, em vez "
    "de apenas reportar uma contagem de APROVADO/REPROVADO: a qualidade "
    "da montagem é função da qualidade dos dados de entrada, e uma "
    "validação real deve mostrar isso com honestidade. O caminho ONT "
    "(química moderna) melhorou em todos os eixos em relação à linha de "
    "base apenas com leituras curtas, com menos contigs, N50 mais alto e "
    "fração do genoma chegando a 100,000% sem introduzir uma única "
    "desmontagem. O caminho PacBio, construído a partir de subreads RS "
    "II CLR da era 2018, sem correção por consenso circular, recuperou "
    "mais do genoma e maior completude do que apenas leituras curtas, "
    "mas a um custo real: 21 desmontagens que a montagem apenas com "
    "leituras curtas não teve. Nenhum dos resultados foi ajustado ou "
    "reportado seletivamente após o fato; ambos são a saída direta do "
    "QUAST contra a referência. Apresentar o resultado do PacBio como um "
    "resultado misto, em vez de reformulá-lo como uma aprovação, é em si "
    "parte da honestidade da validação: demonstra que o OmniOmics "
    "reproduz fielmente o que quer que as ferramentas subjacentes e os "
    "dados de entrada realmente produzam, em vez de a demonstração ser "
    "ajustada para resultados uniformemente limpos."
)
para(
    "A validação real do DEFINE comparou sua saída do DESeq2 contra os "
    "próprios critérios declarados pelo artigo de origem para classificar "
    "um gene como diferencialmente expresso (log2 fold-change maior que "
    "2 e padj<0,05; Wintenberg et al. 2023), em vez de apenas um corte de "
    "p-valor ajustado, já que a contagem principal de DEGs do artigo foi "
    "reportada sob essa definição em duas partes. Sob esses critérios "
    "equivalentes, a saída real do DEFINE deu 433 genes significativos "
    "(9,9% dos genes testados) contra os 590 (13,8%) reportados pelo "
    "artigo, a mesma ordem de grandeza. A checagem de categoria funcional "
    "também passou: os genes significativos foram hits reais em todas as "
    "categorias que o artigo reporta como enriquecidas para este "
    "contraste (transportadores ABC, biossíntese de sideróforos, "
    "resposta a estresse, biossíntese de aminoácidos)."
)
para(
    "A validação real do MAGMA é melhor interpretada como duas "
    "alegações separadas com desfechos diferentes, deliberadamente "
    "reportadas assim em vez de condensadas em uma única nota. O "
    "perfilamento taxonômico baseado apenas em leituras, o mesmo tipo de "
    "resultado que o nf-core/taxprofiler ou uma execução simples do "
    "Kraken2 daria, detectou corretamente as 10 espécies de referência "
    "tanto na comunidade de abundância igual quanto na log-distribuída, "
    "mas correspondeu quantitativamente à composição certificada dentro "
    "da tolerância para apenas 2 das 10 espécies. Essa lacuna é uma "
    "propriedade bem caracterizada da estimativa de abundância baseada "
    "em leituras em dados reais de sequenciamento de comunidade mock "
    "(efeitos de eficiência de extração de DNA e de número de cópias do "
    "genoma), não evidência contra a camada de orquestração. A alegação "
    "que o MAGMA de fato faz além de um classificador taxonômico, a "
    "recuperação real resolvida em nível de genoma via montagem e "
    "binning, se sustentou de forma limpa: 7 MAGs dereplicados, cada um "
    "corretamente classificado em espécie pelo GTDB-Tk, zero chamadas "
    "falsas, completude consistentemente alta e contaminação baixa. "
    "Reportar o mais fraco dos dois resultados (acurácia quantitativa "
    "baseada em leituras) junto com o mais forte (recuperação de MAGs), "
    "em vez de liderar apenas com o que parece melhor, mantém esta "
    "validação no mesmo padrão aplicado ao SIGMA, ao DEFINE e ao PRISM "
    "acima."
)
p = para()
add_pending(p, (
    "[PENDENTE: redigir após a conclusão dos Resultados. Deve cobrir: "
    "(1) o argumento de posicionamento, isto é, por que o nicho nativo "
    "de desktop, sem infraestrutura, de amplitude multiômica importa "
    "para o usuário-alvo (o pesquisador de bancada sem apoio dedicado de "
    "bioinformática), reafirmado com a evidência real de validação agora "
    "em mãos; (2) reafirmação explícita do enquadramento de ausência de "
    "benchmark, com o precedente de política do JOSS/F1000 como apoio; "
    "(3) limitações, declaradas com clareza: escopo por pipeline mais "
    "estreito do que os 100+ pipelines comunitários do nf-core, cinco "
    "pipelines contra ecossistemas estabelecidos, o caminho de "
    "marcadores gênicos via PacBio do PRISM ainda não validado no "
    "momento da redação, e ausência de montagem de metatranscriptoma "
    "apenas com leituras longas (DOGMA) porque não existe ferramenta "
    "validada na literatura para esse caso (uma lacuna de método real e "
    "citada, não uma lacuna de implementação); (4) trabalhos futuros: "
    "pipelines adicionais, modo GROND/operon rrn completo para o PRISM, "
    "expansão da aba de Gráficos para o SIGMA.]"
))

# ============================================================
# AGRADECIMENTOS
# ============================================================
unnumbered_heading("Agradecimentos")
p = para()
add_pending(p, "[PENDENTE]")

# ============================================================
# REFERÊNCIAS
# ============================================================
unnumbered_heading("Referências")
para(
    "As referências bibliográficas abaixo são mantidas no formato "
    "original (título, periódico e demais metadados tal como publicados, "
    "predominantemente em inglês), conforme a prática padrão em traduções "
    "de artigos científicos.",
    size=10,
    italic=True,
)
heading("Plataformas e conjuntos de dados de validação", level=2)
refs = [
    "Arkin AP, Cottingham RW, Henry CS, et al. (2018). KBase: The United States Department of Energy Systems Biology Knowledgebase. Nature Biotechnology, 36(7), 566–569. https://doi.org/10.1038/nbt.4163",
    "Bolyen E, Rideout JR, Dillon MR, Bokulich NA, et al. (2019). Reproducible, interactive, scalable and extensible microbiome data science using QIIME 2. Nature Biotechnology, 37(8), 852–857. https://doi.org/10.1038/s41587-019-0209-9",
    "Di Leo D, Nilsson E, Krinos A, Pinhassi J, Lundin D (2025). The Nextflow nf-core/metatdenovo pipeline for reproducible annotation of metatranscriptomes, and more. PeerJ, 13, e20328. https://doi.org/10.7717/peerj.20328",
    "Eren AM, Kiefl E, Shaiber A, et al. (2021). Community-led, integrated, reproducible multi-omics with anvi'o. Nature Microbiology, 6(1), 3–6. https://doi.org/10.1038/s41564-020-00834-3",
    "Ewels PA, Peltzer A, Fillinger S, et al. (2020). The nf-core framework for community-curated bioinformatics pipelines. Nature Biotechnology, 38(3), 276–278. https://doi.org/10.1038/s41587-020-0439-x",
    "Galaxy Community (2022). The Galaxy platform for accessible, reproducible and collaborative biomedical analyses: 2022 update. Nucleic Acids Research, 50(W1), W345–W351. https://doi.org/10.1093/nar/gkac247",
    "Krakau S, Straub D, Gourlé H, Gabernet G, Nahnsen S (2022). nf-core/mag: a best-practice pipeline for metagenome hybrid assembly and binning. NAR Genomics and Bioinformatics, 4(1), lqac007. https://doi.org/10.1093/nargab/lqac007",
    "McIntyre ABR, Alexander N, Grigorev K, Bezdan D, Sichtig H, Chiu CY, Mason CE (2019). Single-molecule sequencing detection of N6-methyladenine in microbial reference materials. Nature Communications, 10, 579. https://doi.org/10.1038/s41467-019-08289-9",
    "Di Tommaso P, Chatzou M, Floden EW, Barja PP, Palumbo E, Notredame C (2017). Nextflow enables reproducible computational workflows. Nature Biotechnology, 35(4), 316–319. https://doi.org/10.1038/nbt.3820",
    "Nicholls SM, Quick JC, Tang S, Loman NJ (2019). Ultra-deep, long-read nanopore sequencing of mock microbial community standards. GigaScience, 8(5), giz043. https://doi.org/10.1093/gigascience/giz043",
    "Mölder F, Jablonski KP, Letcher B, et al. (2021). Sustainable data analysis with Snakemake. F1000Research, 10, 33. https://doi.org/10.12688/f1000research.29032.3",
    "Petit RA III, Read TD (2020). Bactopia: a flexible pipeline for complete analysis of bacterial genomes. mSystems, 5(4), e00190-20. https://doi.org/10.1128/mSystems.00190-20",
    "Stamouli S, Beber ME, Normark T, Christensen II TA, Andersson-Li L, Borry M, Jamy M, nf-core community, Fellows Yates JA (2023). nf-core/taxprofiler: Highly parallelised and flexible pipeline for metagenomic taxonomic classification and profiling. bioRxiv preprint. https://doi.org/10.1101/2023.10.20.563221",
    "Varet H, Brillet-Guéguen L, Coppée JY, Dillies MA (2016). SARTools: A DESeq2- and edgeR-Based R Pipeline for Comprehensive Differential Analysis of RNA-Seq Data. PLoS ONE, 11(6), e0157022. https://doi.org/10.1371/journal.pone.0157022",
    "Wintenberg M, Manglass L, Martinez NE, Blenner M (2023). Global Transcriptional Response of Escherichia coli Exposed In Situ to Different Low-Dose Ionizing Radiation Sources. mSystems, 8(2), e00718-22. https://doi.org/10.1128/msystems.00718-22",
]
for ref in refs:
    p = doc.add_paragraph(style="List Bullet")
    r = p.add_run(ref)
    r.font.size = Pt(10.5)

p = para()
add_pending(p, (
    "[PENDENTE: adicionar as citações de Chuckran et al. 2020/2021 "
    "(verdade de campo do DOGMA) e do lançamento de dados abertos "
    "zymo_16s_2025.09 da ONT assim que a execução do DOGMA for "
    "concluída; ver os próprios READMEs por pipeline do "
    "OmniOmics-validation para as citações já reunidas. Nicholls, "
    "McIntyre e Wintenberg já foram adicionadas acima.]"
))

heading("Ferramentas e bancos de dados de referência usados pelos cinco pipelines", level=2)
para(
    "O OmniOmics empacota, mas não modifica, as seguintes ferramentas e "
    "bancos de dados de terceiros ao longo de seus cinco pipelines. "
    "Listados para completude e atribuição correta; extraídos "
    "diretamente do próprio manifesto de cada pipeline (pipeline.yaml), "
    "não curados de forma independente para esta lista, de modo que "
    "reflete exatamente o que uma execução real de um usuário de fato "
    "invoca.",
    size=10.5,
)
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "tool_refs.json")) as f:
    tool_refs = json.load(f)

heading("Ferramentas", level=3)
for doi, text in sorted(tool_refs["tools"].items(), key=lambda kv: kv[1]):
    p = doc.add_paragraph(style="List Bullet")
    r = p.add_run(f"{text} https://doi.org/{doi}")
    r.font.size = Pt(9.5)

heading("Bancos de dados de referência", level=3)
for doi, text in sorted(tool_refs["databases"].items(), key=lambda kv: kv[1]):
    p = doc.add_paragraph(style="List Bullet")
    r = p.add_run(f"{text} https://doi.org/{doi}")
    r.font.size = Pt(9.5)

# ============================================================
# ACESSIBILIDADE DOS DADOS
# ============================================================
unnumbered_heading("Acessibilidade dos Dados e Compartilhamento de Benefícios")
para(
    "O código-fonte do OmniOmics está disponível em github.com/"
    "oliv-angelus/OmniOmics (licença MIT), incluindo um pacote Debian "
    "compilado (.deb). A configuração exata, a verdade de campo curada e "
    "os resultados reais de validação observado-vs-esperado descritos "
    "neste manuscrito estão disponíveis em github.com/oliv-angelus/"
    "OmniOmics-validation (MIT para scripts/configurações, CC-BY-4.0 "
    "para os dados). Um DOI Zenodo permanente e versionado para ambos "
    "os repositórios "
)
p = doc.paragraphs[-1]
add_pending(p, "[PENDENTE: a ser gerado antes da submissão].")
para(
    "Todos os conjuntos de dados reanalisados para a validação já são "
    "públicos, depositados pelos autores originais ou pelo fabricante da "
    "plataforma de sequenciamento (acessos SRA/ENA/GEO/dados abertos da "
    "ONT, citados por pipeline na Tabela 2 e no repositório "
    "complementar). Nenhuma nova amostra biológica foi coletada para "
    "este trabalho; as disposições de Compartilhamento de Benefícios do "
    "Protocolo de Nagoya / Convenção sobre Diversidade Biológica "
    "não se aplicam, portanto."
)

# ============================================================
# CONTRIBUIÇÕES DOS AUTORES
# ============================================================
unnumbered_heading("Contribuições dos Autores")
p = para()
add_pending(p, "[PENDENTE]")

# ============================================================
# TABELAS E FIGURAS
# ============================================================
unnumbered_heading("Tabelas e Figuras")
p = para()
add_pending(p, (
    "[PENDENTE: a Tabela 3 (resultados reais observado-vs-esperado) "
    "deve ser expandida para a versão completa por métrica assim que "
    "toda execução de pipeline estiver concluída. Figuras: diagrama de "
    "arquitetura (cliente/backend/registro de pipelines), uma figura de "
    "qualidade de montagem (por exemplo, a comparação de contagem de "
    "contigs/fração do genoma apenas leituras curtas vs. híbrido do "
    "SIGMA) como âncora visual para o argumento de validação.]"
))
p = para()
add_pending(p, (
    "[PENDENTE: Figura: diagramas de fluxo de trabalho por pipeline "
    "(um painel por pipeline, DAG rotulado por ferramenta). SVGs reais "
    "do draw.io já existem para MAGMA, SIGMA e DOGMA "
    "(pipelines/<id>/<ID>.drawio.svg no repositório OmniOmics); os "
    "diagramas de DEFINE e PRISM estão sendo desenhados pelo autor no "
    "mesmo estilo; inserir os 5 como uma única figura multipainel assim "
    "que ambos estiverem prontos, não antes (mantém os 5 painéis "
    "visualmente consistentes).]"
))

doc.save("/home/angelo/Documentos/OmniOmics/paper/Artigo_PT.docx")
print("OK: Artigo_PT.docx escrito")
