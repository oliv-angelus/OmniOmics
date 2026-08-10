import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/install_row.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState => _SettingsScreenState;
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  Map<String, dynamic>? _status;
  List<InstallOption> _condaOptions = [];

  @override
  void initState {
    super.initState;
    _load;
  }

  Future<void> _load async {
    final api = ref.read(apiClientProvider);
    final status = await api.get('/api/setup/status') as Map<String, dynamic>;
    final lang = ref.read(localeProvider).languageCode;
    final raw = await api.get('/api/setup/conda-distributions?lang=$lang') as List;
    _condaOptions = raw.map((e) => InstallOption(id: e['id'] as String, name: e['name'] as String, description: e['description'] as String)).toList;
    if (mounted) setState( => _status = status);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final s = _status;
    final missing = (s?['python_deps']?['missing'] as List?)?.join(', ') ?? '';
    final packages = (s?['python_deps']?['packages'] as List?)?.join(', ') ?? '';

    // Refetch conda distribution descriptions (backend-sourced) when PT/EN changes.
    ref.listen(localeProvider, (previous, next) {
      if (previous != next) _load;
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
                      const Center(child: CircularProgressIndicator)
                    else...[
                      InstallRow(
                        title: ref.t('conda_label'),
                        subtitle: s['conda']?['installed'] == true
                            ? '${ref.t('installed_at')} ${s['conda']['path']}': ref.t('not_installed'),
                        installed: s['conda']?['installed'] == true,
                        wsPath: '/ws/install/conda',
                        initialPayload: const {'install_path': '~/miniforge3'},
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
                        onDone: _load,
                      ),
                      const Divider(height: 32),
                      InstallRow(
                        title: ref.t('app_python_deps'),
                        subtitle: s['python_deps']?['installed'] == true
                            ? '${ref.t('installed_packages')}: $packages': '${ref.t('missing')}: $missing',
                        installed: s['python_deps']?['installed'] == true,
                        wsPath: '/ws/install/python-deps',
                        onDone: _load,
                      ),
                      const Divider(height: 32),
                      InstallRow(
                        title: ref.t('vibrant_tools_label'),
                        subtitle: s['vibrant_tools']?['installed'] == true ? ref.t('vibrant_installed'): ref.t('vibrant_not_installed'),
                        installed: s['vibrant_tools']?['installed'] == true,
                        wsPath: '/ws/install/vibrant-tools',
                        onDone: _load,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }
}
