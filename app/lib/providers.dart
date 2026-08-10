import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'services/api_client.dart';
import 'models/run_record.dart';

/// Overridden in main.dart once the backend sidecar process is confirmed healthy.
final apiClientProvider = Provider<ApiClient>((ref) {
  throw UnimplementedError('apiClientProvider must be overridden after backend health check');
});

final themeModeProvider = StateProvider<ThemeMode>((ref) => ThemeMode.light);

/// Which pipeline's Launch screen is currently shown embedded in AppShell's
/// body, alongside the persistent sidebar -- null means "show the normal
/// nav-rail tab" instead. Opening a pipeline from the Hub sets this instead
/// of pushing a full-screen route, so the sidebar (Databases/Results/...)
/// stays reachable without leaving the pipeline's configuration flow.
class EmbeddedPipelineRoute {
  final String pipelineId;
  final String pipelineName;
  const EmbeddedPipelineRoute({required this.pipelineId, required this.pipelineName});
}

final embeddedPipelineProvider = StateProvider<EmbeddedPipelineRoute?>((ref) => null);

/// Same idea as [embeddedPipelineProvider] but for the Monitor screen --
/// shown embedded in AppShell's body instead of pushed full-screen, so
/// starting a run (or reopening the "view running pipeline" banner) doesn't
/// hide the sidebar either. Setting this true takes priority over
/// embeddedPipelineProvider in AppShell's body.
final embeddedMonitorProvider = StateProvider<bool>((ref) => false);

/// Same idea as [embeddedPipelineProvider] but for the Plots tab's
/// per-run workspace -- picking a finished run opens a dedicated screen
/// scoped to that one run (metadata -> analyses -> params -> result),
/// instead of a split sidebar+panel where switching runs could leave a
/// stale analysis showing for the wrong run (the actual bug that prompted
/// this: see notes/Known Issues and Next Steps.md). null means "show the
/// plain run-picker grid" (PlotsScreen) instead.
final embeddedPlotRunProvider = StateProvider<RunRecord?>((ref) => null);

/// Which nav-rail tab AppShell's body shows (index into its `pages` list).
/// Lifted out of _AppShellState so widgets elsewhere in the tree -- e.g. the
/// top bar's database-downloads indicator -- can jump straight to a tab
/// (Databases) without needing a BuildContext-based Navigator call.
final selectedTabProvider = StateProvider<int>((ref) => 0);
