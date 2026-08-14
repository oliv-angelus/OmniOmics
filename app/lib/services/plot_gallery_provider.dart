import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';

/// Analysis runs already produced for a given pipeline run.
///
/// plot_runs_store has kept up to 200 of these since the Plots tab was built,
/// and GET /api/plots/runs has served them just as long -- but nothing in the
/// app ever asked. The workspace was a linear wizard, so it had to forget the
/// previous plot to show the next one, and the only way back to yesterday's
/// figure was a file manager.
final plotRunsProvider =
    FutureProvider.autoDispose.family<List<Map<String, dynamic>>, String>((ref, parentRunId) async {
  final api = ref.watch(apiClientProvider);
  final raw = await api.get('/api/plots/runs?parent_run_id=$parentRunId') as List;
  return raw.cast<Map<String, dynamic>>();
});

/// How many analyses each pipeline run has produced, for the run picker.
///
/// One request for the whole history rather than one per card: the endpoint
/// returns every plot run when given no parent, and the picker needs a count
/// for each of its cards at once.
final plotRunCountsProvider = FutureProvider.autoDispose<Map<String, int>>((ref) async {
  final api = ref.watch(apiClientProvider);
  final raw = await api.get('/api/plots/runs') as List;
  final counts = <String, int>{};
  for (final entry in raw.cast<Map<String, dynamic>>()) {
    if (entry['status'] != 'done') continue;
    final parent = entry['parent_run_id'] as String?;
    if (parent == null) continue;
    counts[parent] = (counts[parent] ?? 0) + 1;
  }
  return counts;
});
