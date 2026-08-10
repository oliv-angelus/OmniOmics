import '../models/tool.dart';

/// Client-side mirror of the tool prerequisite graph, for instant UI feedback
/// (auto-disabling dependents, greying out blocked toggles). This is a
/// *preview* only -- actual run correctness comes from Snakemake's own DAG via
/// `--omit-from` (computed here too, but Snakemake will cascade correctly
/// regardless of any gap in this model).
///
/// Track-aware: a dual-track tool (Prodigal, antiSMASH,...) that requires
/// another dual-track tool depends on it *per track* -- e.g. eggnog_sample's
/// rule takes prodigal_sample's own output file as input, not prodigal_mags's
/// (confirmed against workflow/rules/07_annotation_mobilome.smk). So turning
/// off Prodigal's "sample" track must cascade to every dependent's "sample"
/// track specifically, leaving their "mags" track alone. When the *required*
/// tool has no tracks of its own (e.g. Tiara), the check isn't track-specific
/// -- it just needs to be active at all.
class DependencyGraph {
  final Map<String, ToolDef> toolsById;
  const DependencyGraph(this.toolsById);

  bool _groupSatisfiedForTrack(
    RequirementGroup group,
    String? evalTrack,
    Set<String> activeTools,
    Map<String, Set<String>> activeTracks,
  ) {
    var count = 0;
    for (final reqId in group.tools) {
      final reqTool = toolsById[reqId];
      if (reqTool == null || !activeTools.contains(reqId)) continue;
      if (evalTrack != null && reqTool.tracks.isNotEmpty) {
        final reqTracks = activeTracks[reqId] ?? reqTool.tracks.keys.toSet();
        if (!reqTracks.contains(evalTrack)) continue;
      }
      count++;
    }
    return count >= group.min;
  }

  /// Whether [toolId]'s requirements are met for [track] (null for tools
  /// without tracks). Excludes [toolId] itself from the active set first --
  /// a tool never counts as its own prerequisite.
  bool _satisfiedForTrack(
    String toolId,
    String? track,
    Set<String> activeTools,
    Map<String, Set<String>> activeTracks,
  ) {
    final tool = toolsById[toolId];
    if (tool == null) return true;
    final without = Set<String>.from(activeTools)..remove(toolId);
    return tool.requires.every((g) => _groupSatisfiedForTrack(g, track, without, activeTracks));
  }

  /// Iteratively drops any tool/track whose requirements aren't satisfied,
  /// mutating [activeTools]/[activeTracks] in place until a fixed point
  /// (dropping one tool's track can strand another's, e.g. disabling
  /// Prodigal/sample strands eggNOG/sample which... etc).
  void settle(Set<String> activeTools, Map<String, Set<String>> activeTracks) {
    var changed = true;
    while (changed) {
      changed = false;
      for (final id in activeTools.toList()) {
        final tool = toolsById[id];
        if (tool == null) continue;
        if (tool.tracks.isEmpty) {
          if (!_satisfiedForTrack(id, null, activeTools, activeTracks)) {
            activeTools.remove(id);
            activeTracks.remove(id);
            changed = true;
          }
          continue;
        }
        final tracks = activeTracks[id] ?? tool.tracks.keys.toSet();
        final keep = tracks.where((t) => _satisfiedForTrack(id, t, activeTools, activeTracks)).toSet();
        if (keep.length != tracks.length) {
          changed = true;
          if (keep.isEmpty) {
            activeTools.remove(id);
            activeTracks.remove(id);
          } else {
            activeTracks[id] = keep;
          }
        }
      }
    }
  }

  /// Whether [toolId] as a whole could be turned on right now -- for
  /// non-track tools, its (only) requirements; for a dual-track tool, whether
  /// *at least one* of its tracks would be enableable (the toggle handler
  /// then decides which track(s) to actually activate).
  bool canEnable(String toolId, Set<String> activeTools, Map<String, Set<String>> activeTracks) {
    final tool = toolsById[toolId];
    if (tool == null) return true;
    if (tool.tracks.isEmpty) return _satisfiedForTrack(toolId, null, activeTools, activeTracks);
    return tool.tracks.keys.any((t) => _satisfiedForTrack(toolId, t, activeTools, activeTracks));
  }

  /// Whether [toolId]'s specific [track] could be turned on right now.
  bool canEnableTrack(String toolId, String track, Set<String> activeTools, Map<String, Set<String>> activeTracks) {
    return _satisfiedForTrack(toolId, track, activeTools, activeTracks);
  }

  /// Human-readable names of whichever requirement group is currently
  /// unsatisfied for [toolId] (optionally for one specific [track]) -- e.g.
  /// "Fastp" or "Metabat2, Semibin2, Vamb, Maxbin2 (min. 2)" -- for the
  /// "Requer:..." caption on a blocked toggle.
  String missingRequirementLabel(
    String toolId,
    Set<String> activeTools,
    Map<String, Set<String>> activeTracks, {
    String? track,
    bool english = true,
  }) {
    final tool = toolsById[toolId];
    if (tool == null) return '';
    final without = Set<String>.from(activeTools)..remove(toolId);
    final parts = <String>[];
    final minAbbrev = english ? 'min.': 'mín.';
    for (final group in tool.requires) {
      if (!_groupSatisfiedForTrack(group, track, without, activeTracks)) {
        final names = group.tools.map((id) => toolsById[id]?.name ?? id).join(', ');
        parts.add(group.min > 1 ? '$names ($minAbbrev ${group.min})': names);
      }
    }
    return parts.join(' + ');
  }

  /// Snakemake rule names to pass as `--omit-from` for the given active set:
  /// any rule not produced by the currently-active tools/tracks. A rule shared
  /// by multiple tool_ids (e.g. map_reads, used by both bowtie2 and minimap2)
  /// is only omitted once *every* tool_id referencing it is inactive; for a
  /// dual-track tool (e.g. Prodigal), only the rule(s) of the tracks the user
  /// switched off get omitted -- the other track keeps running independently.
  List<String> omitFromRuleNames(Set<String> activeTools, [Map<String, Set<String>>? activeTracks]) {
    final allRules = <String>{for (final tool in toolsById.values)...tool.ruleNames};
    final active = <String>{};
    for (final tool in toolsById.values) {
      if (!activeTools.contains(tool.id)) continue;
      if (tool.tracks.isEmpty) {
        active.addAll(tool.ruleNames);
        continue;
      }
      final tracks = activeTracks?[tool.id] ?? tool.tracks.keys.toSet();
      for (final entry in tool.tracks.entries) {
        if (tracks.contains(entry.key)) active.addAll(entry.value);
      }
    }
    return allRules.difference(active).toList();
  }
}
