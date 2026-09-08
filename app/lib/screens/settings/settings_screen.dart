import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/install_row.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Map<String, dynamic>? _status;
  List<InstallOption> _condaOptions = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final api = ref.read(apiClientProvider);
    final status = await api.get('/api/setup/status') as Map<String, dynamic>;
    final lang = ref.read(localeProvider).languageCode;
    final raw = await api.get('/api/setup/conda-distributions?lang=$lang') as List;
    _condaOptions = raw.map((e) => InstallOption(id: e['id'] as String, name: e['name'] as String, description: e['description'] as String)).toList();
    if (mounted) setState(() => _status = status);
  }

  /// Whether the backend says this component is mid-install. The job lives in
  /// the backend, so this stays true across a closed window or a switch between
  /// this screen and the first-run gate.
  bool _installing(String name) => _status?['installs']?[name] == 'running';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final s = _status;
    final missing = (s?['python_deps']?['missing'] as List?)?.join(', ') ?? '';
    final packages = (s?['python_deps']?['packages'] as List?)?.join(', ') ?? '';

    // Refetch conda distribution descriptions (backend-sourced) when PT/EN changes.
    ref.listen(localeProvider, (previous, next) {
      if (previous != next) _load();
    });

    return SingleChildScrollView(
      padding: const EdgeInsets.all(32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ref.t('settings_dependencies'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
                    const SizedBox(height: 4),
                    Text(ref.t('shared_by_pipelines'), style: TextStyle(color: colors.textSecondary, fontSize: 13)),
                    const SizedBox(height: 16),
                    if (s == null)
                      const Center(child: CircularProgressIndicator())
                    else...[
                      InstallRow(
                        title: ref.t('conda_label'),
                        subtitle: s['conda']?['installed'] == true
                            ? '${ref.t('installed_at')} ${s['conda']['path']}': ref.t('not_installed'),
                        installed: s['conda']?['installed'] == true,
                        wsPath: '/ws/install/conda',
                        defaultPath: '~/miniforge3',
                        alreadyRunning: _installing('conda'),
                        options: _condaOptions,
                        onDone: _load,
                      ),
                      const Divider(height: 32),
                      InstallRow(
                        title: ref.t('snakemake_label'),
                        subtitle: s['snakemake']?['installed'] == true
                            ? '${ref.t('installed_at')} (${s['snakemake']['version']})': ref.t('not_installed'),
                        installed: s['snakemake']?['installed'] == true,
                        wsPath: '/ws/install/snakemake',
                        alreadyRunning: _installing('snakemake'),
                        onDone: _load,
                      ),
                      const Divider(height: 32),
                      InstallRow(
                        title: ref.t('app_python_deps'),
                        subtitle: s['python_deps']?['installed'] == true
                            ? '${ref.t('installed_packages')}: $packages': '${ref.t('missing')}: $missing',
                        installed: s['python_deps']?['installed'] == true,
                        bundled: s['python_deps']?['bundled'] == true,
                        wsPath: '/ws/install/python-deps',
                        alreadyRunning: _installing('python-deps'),
                        onDone: _load,
                      ),
                      const Divider(height: 32),
                      InstallRow(
                        title: ref.t('r_env_label'),
                        subtitle: s['r_env']?['installed'] == true
                            ? '${ref.t('r_env_installed')} (${s['r_env']['version'] ?? ''})'
                            : ref.t('r_env_not_installed'),
                        installed: s['r_env']?['installed'] == true,
                        wsPath: '/ws/install/r-env',
                        alreadyRunning: _installing('r-env'),
                        onDone: _load,
                      ),
                      const Divider(height: 32),
                      InstallRow(
                        title: ref.t('vibrant_tools_label'),
                        subtitle: s['vibrant_tools']?['installed'] == true ? ref.t('vibrant_installed'): ref.t('vibrant_not_installed'),
                        installed: s['vibrant_tools']?['installed'] == true,
                        wsPath: '/ws/install/vibrant-tools',
                        alreadyRunning: _installing('vibrant-tools'),
                        onDone: _load,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const _GraphScaleCard(),
          ],
          ),
        ),
      ),
    );
  }
}

/// Manual override for the Monitor tab's live DAG node/font size -- exists
/// because a small graph (e.g. PRISM's 14 rules) already fits the panel at
/// its native size, so RuleGraphView's own "never zoom in past 1:1" fit
/// logic leaves it looking tiny with no automatic way to grow it. Backed by
/// [graphScaleProvider], which every open RuleGraphView watches directly --
/// dragging this slider takes effect immediately, no app restart needed.
class _GraphScaleCard extends ConsumerWidget {
  const _GraphScaleCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final scale = ref.watch(graphScaleProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ref.t('settings_graph_scale_title'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 4),
            Text(ref.t('settings_graph_scale_subtitle'), style: TextStyle(color: colors.textSecondary, fontSize: 13)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: scale,
                    min: 0.7,
                    max: 2.2,
                    divisions: 15,
                    label: '${(scale * 100).round()}%',
                    onChanged: (v) => ref.read(graphScaleProvider.notifier).setScale(v),
                  ),
                ),
                SizedBox(
                  width: 52,
                  child: Text('${(scale * 100).round()}%',
                      textAlign: TextAlign.end, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
