#!/usr/bin/env python3
"""
final_mag_catalog.py -- consolida, numa única tabela (uma linha por MAG
final, já dereplicada), os critérios do padrão MIMAG/MISAG (Bowers et al.
2017, Nature Biotechnology, "Minimum information about a single amplified
genome (MISAG) and a metagenome-assembled genome (MIMAG)...",
doi:10.1038/nbt.3893) mais taxonomia e quimerismo:

  - completude e contaminação -- CheckM2 (etapa 05, results/06_MAG_REFINEMENT/
    {sample}/checkm2/quality_report.tsv)
  - presença dos rRNAs 5S/16S/23S e contagem de tipos de tRNA -- barrnap e
    tRNAscan-SE (etapa 07, results/09_ANNOTATION/mags/{barrnap,trnascan})
  - quimerismo (GUNC) -- informativo, não entra na classificação MIMAG em si
    (results/06_MAG_REFINEMENT/{sample}/gunc)
  - taxonomia -- GTDB-Tk (results/08_MAG_TAXONOMY/gtdbtk), sobre o conjunto
    JÁ DEREPLICADO

O conjunto de MAGs coberto por esta tabela é exatamente
results/07_DEREP/drep_out/dereplicated_genomes/*.fa -- o catálogo final de
MAGs do run inteiro (todas as amostras, já sem redundância entre elas), não
os bins brutos do binette por amostra. Uma MAG que existe no binette mas não
sobreviveu à dereplicação simplesmente não aparece aqui.

Porta a mesma lógica que plots/scripts/lib/build_magma_mag_table.R já usa no
app (Plots tab), como um artefato real do pipeline em vez de só uma tabela
recalculada sob demanda -- para poder rodar sem R/dplyr num nó de HPC. Ver
esse arquivo para a versão completa (que também cobre MAGs não-dereplicadas,
com uma coluna `dereplicated` booleana, e as tabelas de abundância/genes).

Uso:
    python3 final_mag_catalog.py --results-dir results --out results/07_DEREP/final_mag_catalog.tsv

Só biblioteca padrão (csv, glob, os, re, argparse, sys) -- de propósito, para
não precisar de mais um ambiente conda só para isto (mesma escolha do
mimag_summary.py que o precedeu).
"""

import argparse
import csv
import glob
import os
import sys

MIMAG_HIGH_COMPLETENESS = 90
MIMAG_HIGH_CONTAMINATION = 5
MIMAG_MED_COMPLETENESS = 50
MIMAG_MED_CONTAMINATION = 10
MIMAG_MIN_TRNA_TYPES = 18

RANKS = ["domain", "phylum", "class", "order", "family", "genus", "species"]


def discover_final_mags(results_dir):
    """Lista de ids de MAG = nome do arquivo (sem extensão) em
    07_DEREP/drep_out/dereplicated_genomes/*.fa -- o catálogo final."""
    d = os.path.join(results_dir, "07_DEREP", "drep_out", "dereplicated_genomes")
    if not os.path.isdir(d):
        return []
    mags = []
    for f in sorted(os.listdir(d)):
        for ext in (".fa", ".fna", ".fasta"):
            if f.endswith(ext):
                mags.append(f[: -len(ext)])
                break
    return mags


def discover_samples(results_dir):
    """Nomes de amostra = subpastas de 06_MAG_REFINEMENT, usado só para
    quebrar "{sample}_{bin}" em (sample, bin) sem assumir que o nome da
    amostra não tem underscore."""
    d = os.path.join(results_dir, "06_MAG_REFINEMENT")
    if not os.path.isdir(d):
        return []
    return sorted(n for n in os.listdir(d) if os.path.isdir(os.path.join(d, n)))


def mag_sample(mag_id, samples):
    """Amostra de origem de uma MAG, pelo prefixo "{sample}_" que
    pool_hq_mags usa ao gerar o nome do arquivo -- casa contra os nomes de
    amostra reais do run (mais longo primeiro, para o caso de um nome de
    amostra ser prefixo de outro), não um split ingênuo no primeiro "_"."""
    candidatos = [s for s in samples if mag_id.startswith(s + "_")]
    if not candidatos:
        return None
    return max(candidatos, key=len)


def read_checkm2_all(results_dir, samples):
    out = {}
    for sample in samples:
        f = os.path.join(results_dir, "06_MAG_REFINEMENT", sample, "checkm2", "quality_report.tsv")
        if not os.path.isfile(f):
            continue
        with open(f, newline="") as fh:
            for row in csv.DictReader(fh, delimiter="\t"):
                name = row.get("Name")
                if not name:
                    continue
                out[f"{sample}_{name}"] = {
                    "checkm2_completeness": row.get("Completeness", ""),
                    "checkm2_contamination": row.get("Contamination", ""),
                    "checkm2_genome_size": row.get("Genome_Size", ""),
                }
    return out


def read_gunc_all(results_dir, samples):
    out = {}
    for sample in samples:
        d = os.path.join(results_dir, "06_MAG_REFINEMENT", sample, "gunc")
        candidatos = glob.glob(os.path.join(d, "GUNC.*.maxCSS_level.tsv"))
        if not candidatos:
            continue
        with open(candidatos[0], newline="") as fh:
            for row in csv.DictReader(fh, delimiter="\t"):
                genome = row.get("genome")
                if not genome:
                    continue
                out[f"{sample}_{genome}"] = {
                    "gunc_pass": row.get("pass.GUNC", ""),
                    "gunc_css": row.get("clade_separation_score", ""),
                    "gunc_contamination_portion": row.get("contamination_portion", ""),
                }
    return out


def read_gtdbtk(results_dir):
    out = {}
    d = os.path.join(results_dir, "08_MAG_TAXONOMY", "gtdbtk")
    for fname in ("gtdbtk.bac120.summary.tsv", "gtdbtk.ar53.summary.tsv"):
        f = os.path.join(d, fname)
        if not os.path.isfile(f):
            continue
        with open(f, newline="") as fh:
            for row in csv.DictReader(fh, delimiter="\t"):
                genome = row.get("user_genome")
                if not genome:
                    continue
                classification = row.get("classification", "")
                entry = {
                    "gtdbtk_classification": classification,
                    "gtdbtk_fastani_ani": row.get("fastani_ani", ""),
                    "gtdbtk_red_value": row.get("red_value", ""),
                }
                parts = classification.split(";") if classification else []
                for i, rank in enumerate(RANKS):
                    val = parts[i].split("__", 1)[-1].strip() if i < len(parts) else ""
                    entry[f"gtdbtk_{rank}"] = val
                out[genome] = entry
    return out


def read_barrnap(results_dir, mag_ids):
    """GFF3 do barrnap; o nome do gene de rRNA está no atributo
    "Name=16S_rRNA" (ou 5S_rRNA/23S_rRNA)."""
    d = os.path.join(results_dir, "09_ANNOTATION", "mags", "barrnap")
    out = {}
    for mag in mag_ids:
        f = os.path.join(d, f"{mag}_rrna.gff")
        counts = {"5S": 0, "16S": 0, "23S": 0}
        if os.path.isfile(f):
            with open(f) as fh:
                for line in fh:
                    if line.startswith("#"):
                        continue
                    for tag in counts:
                        if f"Name={tag}_rRNA" in line:
                            counts[tag] += 1
        out[mag] = counts
    return out


def read_trnascan(results_dir, mag_ids):
    """Saída tabular padrão do tRNAscan-SE: 3 linhas de cabeçalho, depois
    uma linha por tRNA, com o aminoácido na 5a coluna ("Type")."""
    d = os.path.join(results_dir, "09_ANNOTATION", "mags", "trnascan")
    out = {}
    for mag in mag_ids:
        f = os.path.join(d, f"{mag}_trna.out")
        types = set()
        if os.path.isfile(f):
            with open(f) as fh:
                lines = fh.readlines()[3:]
            for line in lines:
                fields = line.rstrip("\n").split("\t")
                if len(fields) < 5:
                    continue
                t = fields[4].strip()
                if t and t not in ("Undet", "Pseudo"):
                    types.add(t)
        out[mag] = types
    return out


def mimag_tier(completeness, contamination, rrna_ok, trna_ok):
    if completeness == "" or contamination == "":
        return "sem_dados"
    comp = float(completeness)
    cont = float(contamination)
    if comp > MIMAG_HIGH_COMPLETENESS and cont < MIMAG_HIGH_CONTAMINATION:
        if rrna_ok is None or trna_ok is None:
            return "alta_qualidade (C/C apenas -- rRNA/tRNA não encontrados)"
        return "alta_qualidade" if (rrna_ok and trna_ok) else "qualidade_media"
    if comp >= MIMAG_MED_COMPLETENESS and cont < MIMAG_MED_CONTAMINATION:
        return "qualidade_media"
    return "baixa_qualidade"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--results-dir", required=True, help="pasta results/ do run")
    ap.add_argument("--out", required=True, help="TSV de saída")
    args = ap.parse_args()

    mags = discover_final_mags(args.results_dir)
    if not mags:
        print(f"AVISO: nenhuma MAG encontrada em {args.results_dir}/07_DEREP/drep_out/"
              "dereplicated_genomes -- rodou a etapa de dereplicação (rule drep)?", file=sys.stderr)

    samples = discover_samples(args.results_dir)
    checkm2 = read_checkm2_all(args.results_dir, samples)
    gunc = read_gunc_all(args.results_dir, samples)
    gtdbtk = read_gtdbtk(args.results_dir)
    rrna = read_barrnap(args.results_dir, mags)
    trna = read_trnascan(args.results_dir, mags)

    campos = [
        "mag", "sample",
        "checkm2_completeness", "checkm2_contamination", "checkm2_genome_size",
        "rrna_5S", "rrna_16S", "rrna_23S", "trna_types",
        "mimag_quality",
        "gunc_pass", "gunc_css", "gunc_contamination_portion",
        "gtdbtk_classification", "gtdbtk_domain", "gtdbtk_phylum", "gtdbtk_class",
        "gtdbtk_order", "gtdbtk_family", "gtdbtk_genus", "gtdbtk_species",
        "gtdbtk_fastani_ani", "gtdbtk_red_value",
    ]
    linhas = []
    for mag in mags:
        cm = checkm2.get(mag, {})
        gu = gunc.get(mag, {})
        tk = gtdbtk.get(mag, {})
        rr = rrna.get(mag, {"5S": 0, "16S": 0, "23S": 0})
        tr = trna.get(mag, set())

        completeness = cm.get("checkm2_completeness", "")
        contamination = cm.get("checkm2_contamination", "")
        rrna_ok = rr["5S"] > 0 and rr["16S"] > 0 and rr["23S"] > 0 if mag in rrna else None
        trna_ok = len(tr) >= MIMAG_MIN_TRNA_TYPES if mag in trna else None

        linha = {
            "mag": mag,
            "sample": mag_sample(mag, samples) or "",
            "checkm2_completeness": completeness,
            "checkm2_contamination": contamination,
            "checkm2_genome_size": cm.get("checkm2_genome_size", ""),
            "rrna_5S": rr["5S"], "rrna_16S": rr["16S"], "rrna_23S": rr["23S"],
            "trna_types": len(tr),
            "mimag_quality": mimag_tier(completeness, contamination, rrna_ok, trna_ok),
            "gunc_pass": gu.get("gunc_pass", "NA"),
            "gunc_css": gu.get("gunc_css", "NA"),
            "gunc_contamination_portion": gu.get("gunc_contamination_portion", "NA"),
            "gtdbtk_classification": tk.get("gtdbtk_classification", "NA"),
            "gtdbtk_fastani_ani": tk.get("gtdbtk_fastani_ani", "NA"),
            "gtdbtk_red_value": tk.get("gtdbtk_red_value", "NA"),
        }
        for rank in RANKS:
            linha[f"gtdbtk_{rank}"] = tk.get(f"gtdbtk_{rank}", "NA")
        linhas.append(linha)

    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=campos, delimiter="\t")
        w.writeheader()
        w.writerows(linhas)

    print(f"Catálogo final de MAGs escrito em {args.out} ({len(linhas)} MAGs, "
          f"{len(samples)} amostras).")


if __name__ == "__main__":
    main()
