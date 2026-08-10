import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../providers.dart';
import '../../widgets/top_bar_controls.dart';
import '../../services/pipeline_run_provider.dart';
import '../../services/database_download_provider.dart';
import '../../services/database_download_all_provider.dart';
import '../../widgets/download_all_databases_dialog.dart';
import '../hub/hub_screen.dart';
import '../databases/databases_screen.dart';
import '../results/results_screen.dart';
import '../plots/plots_screen.dart';
import '../plots/plot_workspace_screen.dart';
import '../resources/resources_screen.dart';
import '../about/about_screen.dart';
import '../settings/settings_screen.dart';
import '../monitor/monitor_screen.dart';
import '../launch/launch_screen.dart';

/// Persistent app frame: sidebar nav (Pipelines / Resources / About) on the
/// left, a slim top bar with language + theme toggles and the settings gear
/// on the right -- present no matter which section is showing.
class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final pages = const [HubScreen(), DatabasesScreen(), ResultsScreen(), PlotsScreen(), ResourcesScreen(), AboutScreen()];
    final index = ref.watch(selectedTabProvider);
    final embedded = ref.watch(embeddedPipelineProvider);
    final embeddedMonitor = ref.watch(embeddedMonitorProvider);
    final embeddedPlotRun = ref.watch(embeddedPlotRunProvider);

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: index,
            onDestinationSelected: (i) {
              ref.read(selectedTabProvider.notifier).state = i;
              // Clicking a sidebar item always leaves whatever pipeline/monitor/
              // plot workspace was open embedded -- same as closing it, just via
              // the rail instead of that screen's own back button.
              ref.read(embeddedPipelineProvider.notifier).state = null;
              ref.read(embeddedMonitorProvider.notifier).state = false;
              ref.read(embeddedPlotRunProvider.notifier).state = null;
            },
            labelType: NavigationRailLabelType.all,
            leading: Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Image.asset(
                'assets/app_icon.png',
                width: 32,
                height: 32,
                errorBuilder: (context, error, stack) => Icon(Icons.biotech, size: 28, color: colors.primary),
              ),
            ),
            destinations: [
              NavigationRailDestination(
                icon: const Icon(Icons.dashboard_outlined),
                selectedIcon: const Icon(Icons.dashboard),
                label: Text(ref.t('nav_pipelines')),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.storage_outlined),
                selectedIcon: const Icon(Icons.storage),
                label: Text(ref.t('nav_databases')),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.folder_open_outlined),
                selectedIcon: const Icon(Icons.folder_open),
                label: Text(ref.t('nav_results')),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.bar_chart_outlined),
                selectedIcon: const Icon(Icons.bar_chart),
                label: Text(ref.t('nav_plots')),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.speed_outlined),
                selectedIcon: const Icon(Icons.speed),
                label: Text(ref.t('nav_resources')),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.info_outline),
                selectedIcon: const Icon(Icons.info),
                label: Text(ref.t('nav_about')),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                const _TopBar(),
                const Divider(height: 1),
                Expanded(
                  child: embeddedMonitor
                      ? const MonitorScreen(): embedded != null
                          ? LaunchScreen(pipelineId: embedded.pipelineId, pipelineName: embedded.pipelineName): embeddedPlotRun != null
                              ? PlotWorkspaceScreen(run: embeddedPlotRun): pages[index],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      color: colors.surface,
      child: Row(
        children: [
          Text(ref.t('app_name'), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15, color: colors.textPrimary)),
          const Spacer(),
          const _RunningPipelineBanner(),
          const SizedBox(width: 12),
          const _DownloadAllIndicator(),
          const SizedBox(width: 12),
          const _DatabaseDownloadsIndicator(),
          const SizedBox(width: 12),
          const LanguageToggle(),
          const SizedBox(width: 12),
          const ThemeToggle(),
          const SizedBox(width: 12),
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: ref.t('settings'),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => Scaffold(
                  appBar: AppBar(
                    title: Text(ref.t('settings_title')),
                    actions: const [
                      LanguageToggle(),
                      SizedBox(width: 12),
                      ThemeToggle(),
                      SizedBox(width: 12),
                    ],
                  ),
                  body: const SettingsScreen(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Visible from the Hub (or Resources/About) whenever a pipeline is running
/// or just finished -- lets the user get back to the Monitor screen after
/// having navigated away from it, without restarting anything.
class _RunningPipelineBanner extends ConsumerWidget {
  const _RunningPipelineBanner();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final run = ref.watch(pipelineRunProvider);
    if (run == null) return const SizedBox.shrink();

    final running = !run.finished;
    return InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: () => ref.read(embeddedMonitorProvider.notifier).state = true,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: (running ? colors.statusRunning: colors.statusDone).withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (running)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(strokeWidth: 2, color: colors.statusRunning),
              )
            else
              Icon(Icons.check_circle, size: 14, color: colors.statusDone),
            const SizedBox(width: 8),
            Text(
              run.pipelineName,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: running ? colors.statusRunning: colors.statusDone,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Top-bar indicator for the Hub-level "download all/selected databases" batch,
/// which runs detached in [downloadAllProvider] and keeps going after its
/// progress dialog is closed ("Fechar (continua em segundo plano)"). Without
/// this, a background batch had no visible sign and no way back to its progress
/// -- tapping here reopens the progress dialog (reattaching, never restarting).
class _DownloadAllIndicator extends ConsumerWidget {
  const _DownloadAllIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final batch = ref.watch(downloadAllProvider)[kHubDownloadBatchId];
    if (batch == null) return const SizedBox.shrink();

    final total = batch.targets.length;
    final done = batch.dbStatus.values.where((s) => s == DbBatchState.done || s == DbBatchState.error || s == DbBatchState.skipped).length;

    final IconData icon;
    final Color color;
    final String tooltip;
    switch (batch.phase) {
      case DownloadAllPhase.running:
        icon = Icons.downloading;
        color = colors.statusRunning;
        tooltip = '${ref.t('downloads_indicator_batch')} ($done/$total)';
      case DownloadAllPhase.error:
        icon = Icons.error_outline;
        color = colors.statusError;
        tooltip = ref.t('downloads_indicator_error');
      case DownloadAllPhase.done:
        icon = Icons.check_circle_outline;
        color = colors.statusDone;
        tooltip = ref.t('downloads_indicator_done');
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => showDownloadAllDatabasesDialog(
          context: context,
          ref: ref,
          api: ref.read(apiClientProvider),
          pipelineId: kHubDownloadBatchId,
          missing: const [], // reattaches to the existing batch; missing unused on that path
          onChanged: () {},
        ),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (batch.phase == DownloadAllPhase.running)
                SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: color))
              else
                Icon(icon, size: 14, color: color),
              const SizedBox(width: 6),
              Text('$done/$total', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
            ],
          ),
        ),
      ),
    );
  }
}

/// Visible from anywhere in the app whenever a database download is running,
/// just errored, or just finished -- the download itself lives in
/// [databaseDownloadsProvider] (see database_card.dart), independent of the
/// Databases screen's widget lifecycle, so this is what lets the user notice
/// progress/failure/completion without having to stay on (or come back to)
/// that screen. Tapping it jumps to the Databases tab and, for entries the
/// user has now had a chance to see, clears anything that isn't still running.
class _DatabaseDownloadsIndicator extends ConsumerWidget {
  const _DatabaseDownloadsIndicator();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final downloads = ref.watch(databaseDownloadsProvider).values;
    if (downloads.isEmpty) return const SizedBox.shrink();

    final downloading = downloads.where((d) => d.phase == DownloadPhase.running);
    final errored = downloads.where((d) => d.phase == DownloadPhase.error);

    final IconData icon;
    final Color color;
    final String tooltip;
    if (downloading.isNotEmpty) {
      icon = Icons.downloading;
      color = colors.statusRunning;
      tooltip = '${ref.t('downloads_indicator_downloading')} (${downloading.map((d) => d.dbName).join(', ')})';
    } else if (errored.isNotEmpty) {
      icon = Icons.error_outline;
      color = colors.statusError;
      tooltip = '${ref.t('downloads_indicator_error')} (${errored.map((d) => d.dbName).join(', ')})';
    } else {
      icon = Icons.check_circle_outline;
      color = colors.statusDone;
      tooltip = ref.t('downloads_indicator_done');
    }

    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () {
          ref.read(selectedTabProvider.notifier).state = 1; // Databases tab
          ref.read(embeddedPipelineProvider.notifier).state = null;
          ref.read(embeddedMonitorProvider.notifier).state = false;
          ref.read(databaseDownloadsProvider.notifier).dismissFinished;
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (downloading.isNotEmpty)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 2, color: color),
                )
              else
                Icon(icon, size: 14, color: color),
              if (downloads.length > 1)...[
                const SizedBox(width: 6),
                Text('${downloads.length}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
