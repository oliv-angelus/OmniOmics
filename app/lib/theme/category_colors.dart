import 'package:flutter/material.dart';

/// The "omics" taxonomy for pipelines shown on the Hub. MAGMA is the only one
/// backed by a real pipeline today; the rest render as non-interactive
/// "coming soon" placeholder cards until their own pipelines/<id>/ folder exists.
enum PipelineCategory {
  metagenomics,
  genomics,
  transcriptomics,
  metatranscriptomics,
  proteomics,
  metaproteomics,
  metabolomics,
  singleCell,
  pangenomics,
  genotyping,
  metabarcoding,
}

class CategoryStyle {
  final Color accent;
  const CategoryStyle(this.accent);

  Color bg(Brightness b) => accent.withValues(alpha: b == Brightness.dark ? 0.20: 0.12);
  Color fg(Brightness b) => b == Brightness.dark ? Color.lerp(accent, Colors.white, 0.25)!: accent;
}

const _styles = <PipelineCategory, CategoryStyle>{
  PipelineCategory.metagenomics: CategoryStyle(Color(0xFF0D9488)),
  PipelineCategory.genomics: CategoryStyle(Color(0xFF4F46E5)),
  PipelineCategory.transcriptomics: CategoryStyle(Color(0xFF9333EA)),
  PipelineCategory.metatranscriptomics: CategoryStyle(Color(0xFFC026D3)),
  PipelineCategory.proteomics: CategoryStyle(Color(0xFFEA580C)),
  PipelineCategory.metaproteomics: CategoryStyle(Color(0xFFD97706)),
  PipelineCategory.metabolomics: CategoryStyle(Color(0xFFE11D48)),
  PipelineCategory.singleCell: CategoryStyle(Color(0xFF0891B2)),
  PipelineCategory.pangenomics: CategoryStyle(Color(0xFF16A34A)),
  PipelineCategory.genotyping: CategoryStyle(Color(0xFF2563EB)),
  PipelineCategory.metabarcoding: CategoryStyle(Color(0xFF65A30D)),
};

const _ids = <PipelineCategory, String>{
  PipelineCategory.metagenomics: 'metagenomics',
  PipelineCategory.genomics: 'genomics',
  PipelineCategory.transcriptomics: 'transcriptomics',
  PipelineCategory.metatranscriptomics: 'metatranscriptomics',
  PipelineCategory.proteomics: 'proteomics',
  PipelineCategory.metaproteomics: 'metaproteomics',
  PipelineCategory.metabolomics: 'metabolomics',
  PipelineCategory.singleCell: 'single_cell',
  PipelineCategory.pangenomics: 'pangenomics',
  PipelineCategory.genotyping: 'genotyping',
  PipelineCategory.metabarcoding: 'metabarcoding',
};

extension PipelineCategoryX on PipelineCategory {
  String get id => _ids[this]!;
  CategoryStyle get style => _styles[this]!;

  String label(bool english) => switch (this) {
        PipelineCategory.metagenomics => english ? 'Metagenomics': 'Metagenômica',
        PipelineCategory.genomics => english ? 'Genomics': 'Genômica',
        PipelineCategory.transcriptomics => english ? 'Transcriptomics': 'Transcriptômica',
        PipelineCategory.metatranscriptomics => english ? 'Metatranscriptomics': 'Metatranscriptômica',
        PipelineCategory.proteomics => english ? 'Proteomics': 'Proteômica',
        PipelineCategory.metaproteomics => english ? 'Metaproteomics': 'Metaproteômica',
        PipelineCategory.metabolomics => english ? 'Metabolomics': 'Metabolômica',
        PipelineCategory.singleCell => 'Single-cell',
        PipelineCategory.pangenomics => english ? 'Pangenomics': 'Pangenômica',
        PipelineCategory.genotyping => english ? 'Genotyping': 'Genotipagem',
        PipelineCategory.metabarcoding => 'Metabarcoding',
      };

  static PipelineCategory? fromId(String id) {
    for (final entry in _ids.entries) {
      if (entry.value == id) return entry.key;
    }
    return null;
  }
}

/// Placeholder "coming soon" pipelines shown on the Hub alongside real ones.
const placeholderCategories = [
  PipelineCategory.transcriptomics,
  PipelineCategory.metatranscriptomics,
  PipelineCategory.proteomics,
  PipelineCategory.metaproteomics,
  PipelineCategory.metabolomics,
  PipelineCategory.singleCell,
  PipelineCategory.pangenomics,
  PipelineCategory.genotyping,
];

/// Extra descriptive tags shown on placeholder cards, keyed by category --
/// same tag vocabulary as real pipelines' `tags: [...]` (see
/// PipelineExtraTagX), since these placeholders aren't scoped by omics
/// layer alone either.
const placeholderExtraTags = <PipelineCategory, List<String>>{
  PipelineCategory.pangenomics: ['pangenome', 'prokaryote', 'eukaryote'],
  PipelineCategory.genotyping: ['genotyping', 'eukaryote'],
  // Mirrors DEFINE's own tags (isolate + prokaryote) -- proteomics here is
  // conceived the same way, protein expression of a single bacterial
  // isolate, just a different -omics layer (mass spec, not RNA-seq).
  PipelineCategory.proteomics: ['isolate', 'prokaryote'],
  // Mirrors MAGMA's own tags (community + prokaryote) -- the "meta" version
  // of proteomics above, community-level protein profiling instead of one
  // isolate.
  PipelineCategory.metaproteomics: ['community', 'prokaryote'],
  // Metabolomics doesn't fix an organism-scope axis the way sequencing-based
  // pipelines do (a metabolite profile isn't classified by organism) -- user
  // confirmed both isolate (e.g. bacterial culture supernatant) and
  // community (e.g. soil/gut) samples are real intended use cases, not a
  // single fixed scope.
  PipelineCategory.metabolomics: ['isolate', 'community'],
  // User confirmed eukaryote -- "single-cell" without further qualifier
  // overwhelmingly means scRNA-seq of eukaryotic tissue in the literature,
  // even though every other OmniOmics pipeline so far is prokaryote-focused;
  // flagged explicitly here since it's a real scope choice, not a default
  // inherited from the rest of the app.
  PipelineCategory.singleCell: ['eukaryote'],
};

/// Secondary descriptive tags a pipeline can carry alongside its one omics
/// category -- e.g. SIGMA is "genomics" (the omics layer) *and* "prokaryote"
/// (the organism scope), which don't belong on the same axis. Keyed by the
/// manifest's `tags: [...]` id strings (see pipeline.yaml).
const _extraTagStyle = CategoryStyle(Color(0xFF64748B));

const _extraTagLabels = <String, (String pt, String en)>{
  'prokaryote': ('Procarioto', 'Prokaryote'),
  'eukaryote': ('Eucarioto', 'Eukaryote'),
  'pangenome': ('Pangenoma', 'Pangenome'),
  'genotyping': ('Genotipagem', 'Genotyping'),
  // DEFINE only supports short-read RNA-seq (Bowtie2 + featureCounts) --
  // unlike SIGMA/MAGMA/DOGMA's short/long/hybrid read_type, there is no long-
  // read path, so this flags that scope up front on the Hub card.
  'short_only': ('Só reads curtas', 'Short reads only'),
  // MAGMA/SIGMA both have a real hybrid assembler (short+long reads combined
  // into one assembly, not just "both accepted separately") -- this flags
  // that full short/long/hybrid capability up front.
  'hybrid': ('Híbrido', 'Hybrid'),
  // Isolate (single organism/strain, e.g. a pure culture) vs. community
  // (mixed-organism environmental sample, e.g. soil/gut/water) -- the
  // biggest "which pipeline do I actually need" fork for a new user, and not
  // captured by the omics-layer category alone.
  'isolate': ('Isolado', 'Isolate'),
  'community': ('Comunidade', 'Community'),
  // Pipeline-id tags -- same vocabulary reused on the Databases screen to
  // show which pipeline(s) a shared database is used by (see
  // DatabaseDef.usedBy), so a database's "MAGMA"/"SIGMA"/"DOGMA" tag looks
  // and behaves exactly like a pipeline's own tags on the Hub.
  'magma': ('MAGMA', 'MAGMA'),
  'sigma': ('SIGMA', 'SIGMA'),
  'dogma': ('DOGMA', 'DOGMA'),
};

extension PipelineExtraTagX on String {
  CategoryStyle get extraTagStyle => _extraTagStyle;
  String extraTagLabel(bool english) {
    final pair = _extraTagLabels[this];
    if (pair == null) return this;
    return english ? pair.$2: pair.$1;
  }
}
