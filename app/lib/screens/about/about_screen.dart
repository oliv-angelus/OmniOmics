import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../services/system_info_provider.dart';

/// App identity, its own citation, and the citation index -- all served from
/// the backend so nothing here can drift from CITATION.cff or the manifests.
final aboutProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/api/about') as Map<String, dynamic>;
});

final setupStatusProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/api/setup/status') as Map<String, dynamic>;
});

/// The R environment lives on its own endpoint, not in /api/setup/status --
/// it is installed by the Plots tab rather than the dependency gate.
final rEnvStatusProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final api = ref.watch(apiClientProvider);
  return await api.get('/api/plots/r-env/status') as Map<String, dynamic>;
});

/// What OmniOmics is, who wrote it, how to cite it, what it can cite, and under
/// what licence.
///
/// The screen used to delegate the two things it exists to provide: it told the
/// user to cite the app "using CITATION.cff" and to read docs/CITATIONS.md for
/// the tools, and the .deb installed neither. Both ship now, but the index
/// itself lives here -- built from the manifests the app already loads, so it
/// cannot fall out of step with what the app can actually run.
///
/// Contact details beyond the institutional identifiers are still deliberately
/// absent: this screen ships inside a binary anyone can download, and personal
/// data does not belong in it. Links are selectable text with a copy button
/// rather than opened in a browser, which works on a headless or restricted
/// machine -- where this tends to run.
class AboutScreen extends ConsumerStatefulWidget {
  const AboutScreen({super.key});

  static const String orcid = 'https://orcid.org/0000-0003-0831-447X';
  static const String repo = 'https://github.com/oliv-angelus/OmniOmics';

  @override
  ConsumerState<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends ConsumerState<AboutScreen> {
  int _tab = 0;
  String _query = '';
  String? _pipelineFilter;
  String _format = 'bibtex';

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final async = ref.watch(aboutProvider);

    return async.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(child: Text('${ref.t('error_prefix')}: $e')),
      data: (about) {
        final refs = (about['references'] as List? ?? const []).cast<Map<String, dynamic>>();
        return SingleChildScrollView(
          padding: const EdgeInsets.all(32),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1000),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _Identity(about: about),
                  const SizedBox(height: 18),
                  // The alpha caveat sits above everything, not in a footnote:
                  // someone deciding whether to trust a result should meet it
                  // before anything else.
                  _AlphaNote(colors: colors),
                  const SizedBox(height: 22),
                  _Tabs(
                    tab: _tab,
                    refCount: refs.length,
                    onChanged: (i) => setState(() => _tab = i),
                  ),
                  const SizedBox(height: 18),
                  switch (_tab) {
                    0 => _CiteView(
                        about: about,
                        format: _format,
                        onFormat: (f) => setState(() => _format = f),
                      ),
                    1 => _IndexView(
                        references: refs,
                        query: _query,
                        pipelineFilter: _pipelineFilter,
                        onQuery: (q) => setState(() => _query = q.trim().toLowerCase()),
                        onPipeline: (p) => setState(() => _pipelineFilter = p),
                      ),
                    2 => const _ProjectView(),
                    _ => _EnvView(about: about),
                  },
                  const SizedBox(height: 32),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _Identity extends ConsumerWidget {
  final Map<String, dynamic> about;
  const _Identity({required this.about});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Image.asset('assets/app_icon.png',
            width: 56,
            height: 56,
            errorBuilder: (_, _, _) => Icon(Icons.biotech, size: 48, color: colors.primary)),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(ref.t('about_title'),
                      style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  const SizedBox(width: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                        color: colors.statusRunningBg, borderRadius: BorderRadius.circular(20)),
                    child: Text(
                      '${ref.t('about_version_label')} ${about['version']}',
                      style: TextStyle(
                          fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.statusRunning),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(ref.t('about_what_body').split('\n\n').first,
                  style: TextStyle(fontSize: 13, height: 1.5, color: colors.textSecondary)),
            ],
          ),
        ),
      ],
    );
  }
}

class _AlphaNote extends ConsumerWidget {
  final AppPalette colors;
  const _AlphaNote({required this.colors});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: colors.statusRunningBg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colors.statusRunning.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.science_outlined, size: 18, color: colors.statusRunning),
          const SizedBox(width: 10),
          Expanded(
            child: Text(ref.t('about_alpha_note'),
                style: TextStyle(fontSize: 12.5, height: 1.5, color: colors.textPrimary)),
          ),
        ],
      ),
    );
  }
}

class _Tabs extends ConsumerWidget {
  final int tab;
  final int refCount;
  final ValueChanged<int> onChanged;
  const _Tabs({required this.tab, required this.refCount, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final labels = [
      (ref.t('about_tab_cite'), null),
      (ref.t('about_tab_index'), '$refCount'),
      (ref.t('about_tab_project'), null),
      (ref.t('about_tab_env'), null),
    ];
    return Container(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            InkWell(
              onTap: () => onChanged(i),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 11),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: i == tab ? colors.primary : Colors.transparent,
                      width: 2,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Text(labels[i].$1,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: i == tab ? colors.primaryDark : colors.textMuted,
                        )),
                    if (labels[i].$2 != null) ...[
                      const SizedBox(width: 7),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                            color: colors.surfaceAlt, borderRadius: BorderRadius.circular(9)),
                        child: Text(labels[i].$2!,
                            style: TextStyle(fontSize: 10, color: colors.textMuted)),
                      ),
                    ],
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _CiteView extends ConsumerWidget {
  final Map<String, dynamic> about;
  final String format;
  final ValueChanged<String> onFormat;
  const _CiteView({required this.about, required this.format, required this.onFormat});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final citation = (about['citation'] as Map?)?.cast<String, dynamic>() ?? {};
    final text = citation[format] as String? ?? '';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Section(
          title: ref.t('about_cite_app'),
          copyText: text,
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final f in const ['bibtex', 'apa', 'cff'])
                Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => onFormat(f),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      decoration: BoxDecoration(
                        color: f == format ? colors.primarySoft : Colors.transparent,
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(color: f == format ? colors.primary : colors.border),
                      ),
                      child: Text(f.toUpperCase(),
                          style: TextStyle(
                            fontSize: 10.5,
                            fontWeight: FontWeight.w700,
                            color: f == format ? colors.primaryDark : colors.textMuted,
                          )),
                    ),
                  ),
                ),
            ],
          ),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(13),
            decoration: BoxDecoration(
                color: colors.surfaceAlt, borderRadius: BorderRadius.circular(8)),
            child: SelectableText(text,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11.5, height: 1.6)),
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: ref.t('about_cite_tools_title'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(ref.t('about_cite_tools_body'),
                  style: const TextStyle(fontSize: 13, height: 1.6)),
              const SizedBox(height: 10),
              Text(ref.t('about_cite_tools_prefer'),
                  style: TextStyle(fontSize: 12.5, height: 1.6, color: colors.textSecondary)),
            ],
          ),
        ),
      ],
    );
  }
}

class _IndexView extends ConsumerWidget {
  final List<Map<String, dynamic>> references;
  final String query;
  final String? pipelineFilter;
  final ValueChanged<String> onQuery;
  final ValueChanged<String?> onPipeline;

  const _IndexView({
    required this.references,
    required this.query,
    required this.pipelineFilter,
    required this.onQuery,
    required this.onPipeline,
  });

  bool _matches(Map<String, dynamic> r) {
    if (pipelineFilter != null &&
        !((r['pipelines'] as List? ?? const []).contains(pipelineFilter))) {
      return false;
    }
    if (query.isEmpty) return true;
    final hay = '${r['text']} ${(r['for'] as List? ?? const []).join(' ')} ${r['doi'] ?? ''}'
        .toLowerCase();
    return hay.contains(query);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final shown = references.where(_matches).toList();
    final pipes = <String>{for (final r in references) ...(r['pipelines'] as List? ?? const []).cast<String>()}
        .toList()
      ..sort();

    return _Section(
      title: ref.t('about_tab_index'),
      hint: ref
          .t('about_index_hint')
          .replaceAll('@n', '${shown.length}')
          .replaceAll('@d', '${shown.where((r) => r['doi'] != null).length}'),
      copyText: shown
          .map((r) => '[${r['n']}] ${r['text']}'
              '${r['doi'] != null ? ' https://doi.org/${r['doi']}' : ''}')
          .join('\n'),
      copyLabel: ref.t('about_index_copy_visible'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 260,
                height: 36,
                child: TextField(
                  onChanged: onQuery,
                  style: const TextStyle(fontSize: 12.5),
                  decoration: InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 17, color: colors.textMuted),
                    prefixIconConstraints: const BoxConstraints(minWidth: 34),
                    hintText: ref.t('about_index_search'),
                    hintStyle: TextStyle(fontSize: 12.5, color: colors.textMuted),
                    contentPadding: const EdgeInsets.symmetric(vertical: 9),
                  ),
                ),
              ),
              _PipeChip(
                label: ref.t('db_filter_all'),
                selected: pipelineFilter == null,
                onTap: () => onPipeline(null),
              ),
              for (final p in pipes)
                _PipeChip(
                  label: p.toUpperCase(),
                  count: references
                      .where((r) => (r['pipelines'] as List? ?? const []).contains(p))
                      .length,
                  selected: pipelineFilter == p,
                  onTap: () => onPipeline(pipelineFilter == p ? null : p),
                ),
            ],
          ),
          const SizedBox(height: 14),
          if (shown.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Center(
                  child: Text(ref.t('about_index_none'),
                      style: TextStyle(color: colors.textMuted, fontSize: 13))),
            )
          else
            for (var i = 0; i < shown.length; i++) ...[
              if (i > 0) Divider(height: 1, color: colors.border),
              _RefRow(reference: shown[i], index: i + 1),
            ],
        ],
      ),
    );
  }
}

class _RefRow extends ConsumerWidget {
  final Map<String, dynamic> reference;
  final int index;
  const _RefRow({required this.reference, required this.index});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final isDb = reference['kind'] == 'database';
    final owners = (reference['for'] as List? ?? const []).join(', ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 34,
            child: Text('$index',
                style: TextStyle(fontSize: 11, color: colors.textMuted)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 7,
                  runSpacing: 4,
                  children: [
                    Text(owners,
                        style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600)),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: isDb
                            ? const Color(0xFFCA8A04).withValues(alpha: 0.15)
                            : colors.surfaceAlt,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        isDb ? ref.t('about_kind_database') : ref.t('about_kind_tool'),
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.w700,
                          color: isDb ? const Color(0xFFCA8A04) : colors.textMuted,
                        ),
                      ),
                    ),
                    for (final p in (reference['pipelines'] as List? ?? const []))
                      Text(p.toString().toUpperCase(),
                          style: TextStyle(
                              fontSize: 9.5, fontWeight: FontWeight.w700, color: colors.textMuted)),
                  ],
                ),
                const SizedBox(height: 3),
                SelectableText.rich(
                  TextSpan(
                    style: TextStyle(fontSize: 11.5, height: 1.5, color: colors.textSecondary),
                    children: [
                      TextSpan(text: reference['text'] as String? ?? ''),
                      if (reference['doi'] != null)
                        TextSpan(
                          text: '  https://doi.org/${reference['doi']}',
                          style: TextStyle(color: colors.primaryDark),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ProjectView extends ConsumerWidget {
  const _ProjectView();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _Section(
          title: ref.t('about_author'),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SelectableText(
                '${ref.t('about_author_name')}\n\n'
                '${ref.t('about_author_role')}\n\n'
                '${ref.t('about_author_research')}',
                style: TextStyle(fontSize: 13, height: 1.6, color: colors.textPrimary),
              ),
              const SizedBox(height: 14),
              Wrap(spacing: 8, runSpacing: 8, children: const [
                _LinkChip(label: 'ORCID', url: AboutScreen.orcid),
                _LinkChip(label: 'GitHub', url: AboutScreen.repo),
              ]),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _Section(
          title: ref.t('about_license'),
          child: SelectableText(ref.t('about_license_body'),
              style: TextStyle(fontSize: 13, height: 1.6, color: colors.textPrimary)),
        ),
        const SizedBox(height: 16),
        _Section(
          title: ref.t('about_tools'),
          child: SelectableText(ref.t('about_tools_body'),
              style: TextStyle(fontSize: 13, height: 1.6, color: colors.textPrimary)),
        ),
      ],
    );
  }
}

class _EnvView extends ConsumerWidget {
  final Map<String, dynamic> about;
  const _EnvView({required this.about});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final setup = ref.watch(setupStatusProvider).value;
    final rEnv = ref.watch(rEnvStatusProvider).value;
    final system = ref.watch(systemInfoProvider);

    String yesNo(bool? ok) => ok == true ? ref.t('about_env_ready') : ref.t('about_env_missing');

    final rows = <(String, String)>[
      (ref.t('about_env_app'), 'OmniOmics ${about['version']}'),
      (
        ref.t('about_env_backend'),
        setup?['python_deps']?['bundled'] == true
            ? ref.t('about_env_bundled')
            : ref.t('about_env_source')
      ),
      (
        ref.t('about_env_conda'),
        setup?['conda']?['installed'] == true
            ? '${setup!['conda']['path']} · ${setup['conda']['version']}'
            : ref.t('about_env_missing')
      ),
      (
        ref.t('about_env_snakemake'),
        setup?['snakemake']?['installed'] == true
            ? '${setup!['snakemake']['version']}'
            : ref.t('about_env_missing')
      ),
      (ref.t('about_env_r'), yesNo(rEnv?['installed'] as bool?)),
      if (system != null)
        (
          ref.t('about_env_machine'),
          '${system['cpu']['cores']} threads · '
              '${system['ram']['total_gb']} GB RAM · '
              '${system['disk']['free_gb']} GB ${ref.t('resources_free')}'
        ),
    ];

    return _Section(
      title: ref.t('about_tab_env'),
      copyText: rows.map((r) => '${r.$1}: ${r.$2}').join('\n'),
      copyLabel: ref.t('about_env_copy'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.only(bottom: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 120,
                    child: Text(row.$1.toUpperCase(),
                        style: TextStyle(
                            fontSize: 9.5,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.9,
                            color: colors.textMuted)),
                  ),
                  Expanded(
                    child: SelectableText(row.$2,
                        style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace')),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 4),
          Text(ref.t('about_env_hint'),
              style: TextStyle(fontSize: 11.5, height: 1.5, color: colors.textMuted)),
        ],
      ),
    );
  }
}

class _PipeChip extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;
  const _PipeChip({required this.label, this.count, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final onSelected =
        Theme.of(context).brightness == Brightness.dark ? const Color(0xFF0B1416) : Colors.white;
    return Material(
      color: selected ? colors.primary : Colors.transparent,
      borderRadius: BorderRadius.circular(13),
      child: InkWell(
        borderRadius: BorderRadius.circular(13),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: selected ? colors.primary : colors.border),
          ),
          child: Text(
            count == null ? label : '$label $count',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: selected ? onSelected : colors.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}

class _LinkChip extends ConsumerWidget {
  final String label;
  final String url;
  const _LinkChip({required this.label, required this.url});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: colors.surfaceAlt,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: colors.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('$label: ',
              style: TextStyle(
                  fontSize: 11.5, fontWeight: FontWeight.w600, color: colors.textSecondary)),
          SelectableText(url, style: const TextStyle(fontSize: 11.5, fontFamily: 'monospace')),
          const SizedBox(width: 6),
          InkWell(
            onTap: () async {
              await Clipboard.setData(ClipboardData(text: url));
              if (!context.mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text(ref.t('about_copied')), duration: const Duration(seconds: 2)),
              );
            },
            child: Icon(Icons.copy, size: 14, color: colors.textMuted),
          ),
        ],
      ),
    );
  }
}

class _Section extends ConsumerStatefulWidget {
  final String title;
  final String? hint;
  final String? copyText;
  final String? copyLabel;
  final Widget? trailing;
  final Widget child;

  const _Section({
    required this.title,
    required this.child,
    this.hint,
    this.copyText,
    this.copyLabel,
    this.trailing,
  });

  @override
  ConsumerState<_Section> createState() => _SectionState();
}

class _SectionState extends ConsumerState<_Section> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.copyText ?? ''));
    if (!mounted) return;
    setState(() => _copied = true);
    await Future.delayed(const Duration(milliseconds: 1400));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.fromLTRB(16, 11, 12, 11),
            decoration: BoxDecoration(border: Border(bottom: BorderSide(color: colors.border))),
            child: Row(
              children: [
                Text(widget.title.toUpperCase(),
                    style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                        color: colors.textSecondary)),
                if (widget.hint != null) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(widget.hint!,
                        style: TextStyle(fontSize: 11, color: colors.textMuted)),
                  ),
                ] else
                  const Spacer(),
                if (widget.trailing != null) widget.trailing!,
                if (widget.copyText != null) ...[
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    onPressed: _copy,
                    icon: Icon(_copied ? Icons.check : Icons.copy, size: 14),
                    label: Text(_copied ? ref.t('res_copied') : (widget.copyLabel ?? ref.t('res_copy'))),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: _copied ? colors.statusDone : colors.textPrimary,
                      side: BorderSide(color: _copied ? colors.statusDone : colors.border),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      textStyle: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600),
                    ),
                  ),
                ],
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.all(16), child: widget.child),
        ],
      ),
    );
  }
}
