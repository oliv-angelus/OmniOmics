/// The static DAG shape streamed once per run by the dart logger plugin's
/// `rulegraph` event (see backend/main.py's pipeline_dart_bridge_ws and
/// notes/Snakemake Dart Integration Plan.md). One node per *rule*, not per
/// job instance -- a rule that fans out per-sample still gets exactly one
/// node here, so live status has to be aggregated across that rule's job
/// instances separately (see RuleGraphView's _statusByRule).
class RuleGraphEdge {
  final int source;
  final int target;
  const RuleGraphEdge({required this.source, required this.target});
}

class RuleGraph {
  /// Index-aligned with the plugin's own `nodes` array -- edges reference
  /// nodes by that same index, not by name.
  final List<String> ruleNames;
  final List<RuleGraphEdge> edges;

  const RuleGraph({required this.ruleNames, required this.edges});

  factory RuleGraph.fromJson(Map<String, dynamic> json) {
    final nodes = (json['nodes'] as List? ?? const []).cast<Map<String, dynamic>>();
    final ruleNames = nodes.map((n) => (n['rule'] as String?) ?? '?').toList();
    final links = (json['links'] as List? ?? const []).cast<Map<String, dynamic>>();
    final edges = links
        .map((l) => RuleGraphEdge(source: l['source'] as int, target: l['target'] as int))
        .toList();
    return RuleGraph(ruleNames: ruleNames, edges: edges);
  }

  /// Longest-path-from-a-root layer number per node index -- a plain
  /// topological level, not a full Sugiyama layout: good enough for the
  /// phase-by-phase shape every OmniOmics pipeline actually has (QC ->
  /// assembly -> ... -> fan-out -> report), and cheap to recompute on every
  /// paint rather than needing to be cached/invalidated.
  Map<int, int> computeLayers() {
    final layer = <int, int>{for (var i = 0; i < ruleNames.length; i++) i: 0};
    final incoming = <int, List<int>>{for (var i = 0; i < ruleNames.length; i++) i: []};
    for (final e in edges) {
      incoming[e.target]?.add(e.source);
    }
    // Nodes have no guaranteed topological order in the raw list, so relax
    // repeatedly until stable rather than assuming index order is a valid
    // sort -- cheap for DAG sizes any real pipeline actually produces.
    var changed = true;
    var guard = 0;
    while (changed && guard < ruleNames.length + 1) {
      changed = false;
      guard++;
      for (var i = 0; i < ruleNames.length; i++) {
        final sources = incoming[i] ?? const [];
        if (sources.isEmpty) continue;
        final maxParent = sources.map((s) => layer[s] ?? 0).reduce((a, b) => a > b ? a : b);
        if ((layer[i] ?? 0) < maxParent + 1) {
          layer[i] = maxParent + 1;
          changed = true;
        }
      }
    }
    return layer;
  }
}
