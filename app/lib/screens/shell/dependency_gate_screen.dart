import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../widgets/install_row.dart';
import '../../widgets/top_bar_controls.dart';

/// Shown once at app startup: checks the dependencies shared by every
/// pipeline (conda, snakemake, python deps). Has a skip button for users who
/// just want to look around without installing anything yet -- the same
/// checks are reachable later from Settings.
class DependencyGateScreen extends ConsumerStatefulWidget {
  final Widget next;
  const DependencyGateScreen({super.key, required this.next});

  @override
  ConsumerState<DependencyGateScreen> createState() => _DependencyGateScreenState();
}

class _DependencyGateScreenState extends ConsumerState<DependencyGateScreen> {
  Map<String, dynamic>? _status;
  List<InstallOption> _condaOptions = [];
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final api = ref.read(apiClientProvider);
      final status = await api.get('/api/setup/status') as Map<String, dynamic>;
      final lang = ref.read(localeProvider).languageCode;
      final raw = await api.get('/api/setup/conda-distributions?lang=$lang') as List;
      _condaOptions = raw.map((e) => InstallOption(id: e['id'] as String, name: e['name'] as String, description: e['description'] as String)).toList();
      if (mounted) setState(() => _status = status);
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _enter() {
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => widget.next));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    // Conda distribution descriptions come from the backend in whichever
    // language was requested -- refetch when the user flips PT/EN so they
    // don't stay stuck in the language that was active on first load.
    ref.listen(localeProvider, (previous, next) {
      if (previous != next) _load;
    });
    return Scaffold(
      body: Column(
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            color: colors.surface,
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                LanguageToggle(),
                SizedBox(width: 12),
                ThemeToggle(),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: SingleChildScrollView(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 560),
                  child: _error != null
                      ? Text('${ref.t('error_prefix')}: $_error'): _status == null
                          ? const Padding(padding: EdgeInsets.all(32), child: CircularProgressIndicator()): _buildBody(colors),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AppPalette colors) {
    final s = _status!;
    final missing = (s['python_deps']?['missing'] as List?)?.join(', ') ?? '';
    final packages = (s['python_deps']?['packages'] as List?)?.join(', ') ?? '';
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(ref.t('gate_title'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(ref.t('gate_subtitle'), style: TextStyle(color: colors.textSecondary)),
          const SizedBox(height: 28),
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
          const SizedBox(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(onPressed: _enter, child: Text(ref.t('gate_skip'))),
              const SizedBox(width: 12),
              ElevatedButton(onPressed: _enter, child: Text(ref.t('gate_continue'))),
            ],
          ),
        ],
      ),
    );
  }
}
