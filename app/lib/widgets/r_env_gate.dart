import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import 'install_row.dart';

final rEnvSetupProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/api/setup/status') as Map<String, dynamic>;
});

/// Offers to build the r-plots environment, right where its absence stops you.
///
/// Renders nothing once it is installed. Until then the Plots tab was a dead
/// end: the only mention of the R environment anywhere in the interface was the
/// error a plot run raised after failing, which named the missing environment
/// and offered no way to get it -- while POST /api/plots/r-env/install had sat
/// in the backend the whole time with no caller.
///
/// Settings carries the same row alongside conda and snakemake, which is its
/// proper home; this is the copy at the point of failure, because that is where
/// someone actually discovers they need it.
class REnvGate extends ConsumerWidget {
  const REnvGate({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final async = ref.watch(rEnvSetupProvider);

    return async.when(
      loading: () => const SizedBox.shrink(),
      // Not worth an error banner above the run list: if the status call is
      // failing the backend has bigger problems, and they will announce
      // themselves elsewhere.
      error: (_, _) => const SizedBox.shrink(),
      data: (status) {
        if (status['r_env']?['installed'] == true) return const SizedBox.shrink();

        return Card(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: colors.statusRunning.withValues(alpha: 0.35)),
          ),
          color: colors.statusRunningBg,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.functions, size: 19, color: colors.statusRunning),
                    const SizedBox(width: 11),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(ref.t('r_env_gate_title'),
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                          const SizedBox(height: 3),
                          Text(ref.t('r_env_gate_body'),
                              style: TextStyle(
                                  fontSize: 12.5, height: 1.5, color: colors.textSecondary)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                InstallRow(
                  title: ref.t('r_env_label'),
                  subtitle: ref.t('r_env_not_installed'),
                  installed: false,
                  wsPath: '/ws/install/r-env',
                  alreadyRunning: status['installs']?['r-env'] == 'running',
                  onDone: () => ref.invalidate(rEnvSetupProvider),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
