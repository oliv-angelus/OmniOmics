import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../models/job_entry.dart';
import '../models/rule_graph.dart';
import '../theme/app_theme.dart';

// Layout constants shared by the layout math (_GraphCanvasState) and the
// painter (_RuleGraphPainter) -- file-level rather than duplicated or
// coupled to one class's name.
const double _layerGap = 168;
const double _rowGap = 64;
const double _hPad = 90;
const double _vPad = 50;

/// The live DAG (Monitor screen, Fase 2 of the snakemake-dart integration --
/// see notes/Snakemake Dart Integration Plan.md). Hand-rolled layered layout
/// (Option A from the rendering comparison) rather than a graph-layout
/// package: one node per rule at a fixed grid position derived from
/// [RuleGraph.computeLayers], drawn in the app's own [AppPalette]/[RunStatus]
/// tokens so it reads as part of the same UI, not an embedded foreign widget.
class RuleGraphView extends ConsumerWidget {
  final RuleGraph? ruleGraph;
  final List<JobEntry> jobs;

  const RuleGraphView({super.key, required this.ruleGraph, required this.jobs});

  /// One rule can run many times (once per sample) with only a single node
  /// to represent it here -- highest-severity instance wins, same "don't
  /// downgrade a real problem" logic the rest of the Monitor screen already
  /// uses for run-level status.
  static int _severity(RunStatus s) => switch (s) {
        RunStatus.error => 3,
        RunStatus.running => 2,
        RunStatus.done => 1,
        RunStatus.queued => 0,
      };

  Map<String, RunStatus> _statusByRule() {
    final result = <String, RunStatus>{};
    for (final job in jobs) {
      final existing = result[job.rule];
      if (existing == null || _severity(job.status) > _severity(existing)) {
        result[job.rule] = job.status;
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final graph = ruleGraph;
    if (graph == null || graph.ruleNames.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            ref.t('monitor_graph_waiting'),
            textAlign: TextAlign.center,
            style: TextStyle(color: colors.textMuted, fontSize: 13),
          ),
        ),
      );
    }
    final statusByRule = _statusByRule();
    return _GraphCanvas(graph: graph, statusByRule: statusByRule, colors: colors);
  }
}

/// Owns the pan/zoom controller separately from [RuleGraphView] (which stays
/// a plain ConsumerWidget) because fitting a graph the size of MAGMA's real
/// DAG (confirmed via a real dry-run: 70 nodes, 18 layers deep, up to 9 wide
/// in one layer -- a canvas around 3000x600) into whatever panel width the
/// Monitor screen gives it needs the viewport's own size, known only once
/// this subtree is laid out.
class _GraphCanvas extends StatefulWidget {
  final RuleGraph graph;
  final Map<String, RunStatus> statusByRule;
  final AppPalette colors;

  const _GraphCanvas({required this.graph, required this.statusByRule, required this.colors});

  @override
  State<_GraphCanvas> createState() => _GraphCanvasState();
}

class _GraphCanvasState extends State<_GraphCanvas> {
  final _controller = TransformationController();
  bool _fitted = false;

  Size _contentSize(RuleGraph graph) {
    final layers = graph.computeLayers();
    if (layers.isEmpty) return const Size(_hPad * 2, _vPad * 2 + 40);
    final maxLayer = layers.values.reduce(math.max);
    final counts = <int, int>{};
    for (final l in layers.values) {
      counts[l] = (counts[l] ?? 0) + 1;
    }
    final maxCount = counts.values.reduce(math.max);
    return Size(
      _hPad * 2 + maxLayer * _layerGap,
      math.max(_vPad * 2 + (maxCount - 1) * _rowGap + 40, 220),
    );
  }

  void _fitToViewport(Size viewport, Size content) {
    if (_fitted || viewport.isEmpty) return;
    _fitted = true;
    // Never zoom *in* past 1:1 for a graph that's already smaller than the
    // panel -- fitting should shrink an oversized DAG to fit, not blow up a
    // small one to fill empty space.
    final scale = math.min(1.0, math.min(viewport.width / content.width, viewport.height / content.height));
    final dx = (viewport.width - content.width * scale) / 2;
    final dy = (viewport.height - content.height * scale) / 2;
    _controller.value = Matrix4.identity()
      ..translateByDouble(dx, dy, 0, 1)
      ..scaleByDouble(scale, scale, scale, 1);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final content = _contentSize(widget.graph);
    return LayoutBuilder(
      builder: (context, constraints) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _fitToViewport(Size(constraints.maxWidth, constraints.maxHeight), content);
        });
        return InteractiveViewer(
          transformationController: _controller,
          minScale: 0.15,
          maxScale: 2.5,
          boundaryMargin: const EdgeInsets.all(80),
          constrained: false,
          child: CustomPaint(
            size: content,
            painter: _RuleGraphPainter(graph: widget.graph, statusByRule: widget.statusByRule, colors: widget.colors),
          ),
        );
      },
    );
  }
}

class _RuleGraphPainter extends CustomPainter {
  final RuleGraph graph;
  final Map<String, RunStatus> statusByRule;
  final AppPalette colors;

  _RuleGraphPainter({required this.graph, required this.statusByRule, required this.colors});

  static const double _nodeWidth = 132;
  static const double _nodeHeight = 40;

  @override
  void paint(Canvas canvas, Size size) {
    final layers = graph.computeLayers();
    final byLayer = <int, List<int>>{};
    for (var i = 0; i < graph.ruleNames.length; i++) {
      byLayer.putIfAbsent(layers[i] ?? 0, () => []).add(i);
    }

    final positions = <int, Offset>{};
    byLayer.forEach((layer, indices) {
      final x = _hPad + layer * _layerGap;
      final totalHeight = (indices.length - 1) * _rowGap;
      final startY = (size.height - totalHeight) / 2;
      for (var i = 0; i < indices.length; i++) {
        positions[indices[i]] = Offset(x, startY + i * _rowGap);
      }
    });

    final edgePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = colors.border;
    for (final e in graph.edges) {
      final a = positions[e.source];
      final b = positions[e.target];
      if (a == null || b == null) continue;
      final path = Path()..moveTo(a.dx + _nodeWidth / 2, a.dy);
      final midX = (a.dx + b.dx) / 2 + _nodeWidth / 2;
      path.cubicTo(midX, a.dy, midX, b.dy, b.dx - _nodeWidth / 2, b.dy);
      canvas.drawPath(path, edgePaint);
    }

    for (var i = 0; i < graph.ruleNames.length; i++) {
      final pos = positions[i];
      if (pos == null) continue;
      _paintNode(canvas, pos, graph.ruleNames[i], statusByRule[graph.ruleNames[i]]);
    }
  }

  void _paintNode(Canvas canvas, Offset center, String rule, RunStatus? status) {
    final rect = Rect.fromCenter(center: center, width: _nodeWidth, height: _nodeHeight);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(9));

    final fill = status == null ? colors.surface : status.bg(colors);
    final stroke = status == null ? colors.border : status.fg(colors);

    canvas.drawRRect(rrect, Paint()..color = fill..style = PaintingStyle.fill);
    final strokePaint = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = status == RunStatus.running ? 2.2 : 1.3;
    canvas.drawRRect(rrect, strokePaint);

    // Status dot, same left-inset placement the step-tracker list uses for
    // its own status icon, so the two views read as the same visual system.
    final dotColor = status == null ? colors.textMuted : status.fg(colors);
    canvas.drawCircle(Offset(rect.left + 14, center.dy), 3.6, Paint()..color = dotColor);

    final textPainter = TextPainter(
      text: TextSpan(
        text: rule,
        style: TextStyle(
          color: colors.textPrimary,
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: _nodeWidth - 28);
    textPainter.paint(canvas, Offset(center.dx - textPainter.width / 2 + 4, center.dy - textPainter.height / 2));
  }

  @override
  bool shouldRepaint(covariant _RuleGraphPainter oldDelegate) {
    return oldDelegate.graph != graph || !_sameStatuses(oldDelegate.statusByRule, statusByRule);
  }

  bool _sameStatuses(Map<String, RunStatus> a, Map<String, RunStatus> b) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }
}
