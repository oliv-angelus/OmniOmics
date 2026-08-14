import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../theme/category_colors.dart';
import '../../models/run_record.dart';
import '../../models/pipeline_summary.dart';
import '../hub/hub_screen.dart' show pipelinesProvider;
import '../../widgets/import_plot_folder_dialog.dart';
import '../../services/plot_gallery_provider.dart';
import '../../widgets/r_env_gate.dart';

/// Plots tab entry point: a grid of finished-run cards, same visual language
/// as the Hub's pipeline cards (icon + category tag + subtitle) -- picking
/// one opens a dedicated per-run workspace (see PlotWorkspaceScreen) instead
/// of showing analysis state in a shared side panel. Replaces an earlier
/// split sidebar+panel design where switching the selected run on the left
/// didn't reset the analysis pane on the right, i.e. two different runs
/// could appear to share one analysis session -- see notes/Known Issues and
/// Next Steps.md for the full story.
class PlotsScreen extends ConsumerStatefulWidget {
  const PlotsScreen({super.key});

  @override
  ConsumerState<PlotsScreen> createState() => _PlotsScreenState();
}

class _PlotsScreenState extends ConsumerState<PlotsScreen> {
  bool _loading = true;
  List<RunRecord> _runs = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadRuns();
  }

  Future<void> _loadRuns() async {
    setState(() => _loading = true);
    try {
      final api = ref.read(apiClientProvider);
      final raw = await api.get('/api/runs') as List;
      final runs = raw.map((e) => RunRecord.fromJson(e as Map<String, dynamic>)).where((r) => r.status == 'done').toList();
      if (!mounted) return;
      setState(() { _runs = runs; _loading = false; _error = null; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _importFolder() async {
    final imported = await showDialog<bool>(
      context: context,
      builder: (_) => const ImportPlotFolderDialog(),
    );
    if (imported == true) await _loadRuns();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pipelinesAsync = ref.watch(pipelinesProvider);

    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ref.t('plots_pick_run_title'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(ref.t('plots_pick_run_hint'), style: TextStyle(color: colors.textSecondary)),
                  ],
                ),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.drive_folder_upload, size: 18),
                label: Text(ref.t('plots_import_button')),
                onPressed: _importFolder,
              ),
              const SizedBox(width: 8),
              IconButton(icon: const Icon(Icons.refresh), tooltip: ref.t('review_refresh'), onPressed: _loadRuns),
            ],
          ),
          const SizedBox(height: 16),
          // Before the run list, not after a failed plot: this is where someone
          // discovers the Plots tab needs R, and it used to be a dead end.
          const REnvGate(),
          const SizedBox(height: 8),
          Expanded(child: _buildBody(colors, pipelinesAsync)),
        ],
      ),
    );
  }

  Widget _buildBody(AppPalette colors, AsyncValue<List<PipelineSummary>> pipelinesAsync) {
    if (_loading || pipelinesAsync.isLoading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Text('${ref.t('error_prefix')}: $_error', style: TextStyle(color: colors.statusError)));
    }
    if (_runs.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(ref.t('plots_no_finished_runs'), style: TextStyle(color: colors.textMuted), textAlign: TextAlign.center),
            const SizedBox(height: 16),
            // No runs is not necessarily "nothing to plot" -- results can
            // exist on disk that this app has no record of, which is exactly
            // what importing a folder is for. Offering it here turns a dead
            // end into the next step.
            OutlinedButton.icon(
              icon: const Icon(Icons.drive_folder_upload, size: 18),
              label: Text(ref.t('plots_import_button')),
              onPressed: _importFolder,
            ),
          ],
        ),
      );
    }
    final pipelinesById = {for (final p in pipelinesAsync.value ?? const <PipelineSummary>[]) p.id: p};

    return GridView.builder(
      itemCount: _runs.length,
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 320,
        mainAxisExtent: 214,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemBuilder: (context, i) => _RunCard(run: _runs[i], pipeline: pipelinesById[_runs[i].pipelineId]),
    );
  }
}

class _RunCard extends ConsumerWidget {
  final RunRecord run;
  final PipelineSummary? pipeline;
  const _RunCard({required this.run, required this.pipeline});

  String _formatWhen(DateTime dt) {
    two(int n) => n.toString().padLeft(2, '0');
    return '${two(dt.day)}/${two(dt.month)}/${dt.year} ${two(dt.hour)}:${two(dt.minute)}';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final category = pipeline != null ? PipelineCategoryX.fromId(pipeline!.category): null;
    final english = ref.watch(localeProvider).languageCode == 'en';

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => ref.read(embeddedPlotRunProvider.notifier).state = run,
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(color: colors.primarySoft, borderRadius: BorderRadius.circular(10)),
                    child: pipeline != null && pipeline!.icon.isNotEmpty
                        ? Image.asset(
                            pipeline!.icon,
                            fit: BoxFit.cover,
                            errorBuilder: (context, error, stack) => Icon(Icons.bar_chart_outlined, color: colors.primaryDark),
                          ): Icon(Icons.bar_chart_outlined, color: colors.primaryDark),
                  ),
                  const SizedBox(width: 12),
                  if (category != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: category.style.bg(Theme.of(context).brightness),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        category.label(english),
                        style: TextStyle(color: category.style.fg(Theme.of(context).brightness), fontSize: 11, fontWeight: FontWeight.w600),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
              Text(run.name, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Text(run.pipelineName, style: TextStyle(fontSize: 12.5, color: colors.textSecondary)),
              const SizedBox(height: 8),
              // How much of this run has already been plotted. The count comes
              // from the plot history the backend has always kept and nothing
              // ever read -- it is what answers "which of these was I already
              // working on?" without opening each one.
              _PlotCount(runId: run.id),
              const Spacer(),
              Row(
                children: [
                  Icon(Icons.schedule, size: 13, color: colors.textMuted),
                  const SizedBox(width: 4),
                  Text(_formatWhen(run.startedAtDate), style: TextStyle(fontSize: 11.5, color: colors.textMuted)),
                  const Spacer(),
                  Icon(Icons.arrow_forward, size: 18, color: colors.textMuted),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}


/// "8 gráficos gerados", or "nenhum gráfico ainda", from the plot history the
/// backend has always kept and nothing ever read. It is what answers "which of
/// these was I already working on?" without opening each run in turn.
class _PlotCount extends ConsumerWidget {
  final String runId;
  const _PlotCount({required this.runId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final counts = ref.watch(plotRunCountsProvider);
    final n = counts.value?[runId] ?? 0;

    return Row(
      children: [
        Icon(n > 0 ? Icons.insights : Icons.insights_outlined,
            size: 14, color: n > 0 ? colors.primaryDark : colors.textMuted),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            n == 0
                ? ref.t('plots_run_none')
                : n == 1
                    ? ref.t('plots_run_count_one')
                    : ref.t('plots_run_count').replaceAll('@n', '$n'),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: n > 0 ? FontWeight.w600 : FontWeight.w400,
              color: n > 0 ? colors.textPrimary : colors.textMuted,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
