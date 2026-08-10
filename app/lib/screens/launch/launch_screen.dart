import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../models/tool.dart';
import '../../models/database.dart';
import '../../models/tool_params_state.dart';
import '../../logic/tool_dependency_graph.dart';
import '../../widgets/folder_picker_field.dart';
import '../../widgets/file_picker_field.dart';
import '../../widgets/reference_validation_dialog.dart';
import '../../widgets/tool_category_section.dart';
import '../../services/pipeline_run_provider.dart';

class LaunchScreen extends ConsumerStatefulWidget {
  final String pipelineId;
  final String pipelineName;
  const LaunchScreen({super.key, required this.pipelineId, required this.pipelineName});

  @override
  ConsumerState<LaunchScreen> createState() => _LaunchScreenState();
}

class _LaunchScreenState extends ConsumerState<LaunchScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  Map<String, dynamic>? _manifest;
  /// Raw `/tools` response, kept around so flipping the language toggle can
  /// re-derive [_categories] (tool/flag descriptions are locale-dependent)
  /// without a network round-trip or disturbing active tools/flag params.
  List<dynamic> _toolsRaw = [];
  List<ToolCategory> _categories = [];
  /// Raw `/databases` response, kept for the same reason as [_toolsRaw] --
  /// database/download-option descriptions are locale-dependent too.
  Map<String, dynamic> _databasesRaw = {};
  Map<String, DatabaseDef> _databases = {};
  Map<String, ToolDef> _toolsById = {};
  final Map<String, ToolParamsState> _toolParams = {};
  DependencyGraph get _graph => DependencyGraph(_toolsById);

  final Map<String, String> _inputDirs = {};
  // Which "toggle"-type sample_sheet.input_dirs entries (currently just
  // DOGMA's paired MAGMA run) are switched on -- keyed by spec['key']. Off by
  // default: the picked path in _inputDirs is only actually sent/used when
  // its key is in here (see _buildAndSaveConfig), so flipping the toggle off
  // means "run without this" even if a path was picked earlier.
  final Set<String> _toggledInputDirs = {};
  // SIGMA-only: how the reference genome(s) attach to samples for RagTag's
  // reference-guided scaffolding.
  // 'none': no scaffolding at all -- every sample stays de-novo-only.
  // 'single': one fasta (_referenceFile) applied to every sample -- for
  // mass-assembly of one organism across many samples.
  // 'per_sample': reference_dir/<sample>/ matched by
  // folder name. A sample with no matching folder is flagged by
  // _checkReferenceMatches so the user can pick a file manually or confirm
  // running that sample without a reference (_referenceOverrides /
  // _referenceSkipped).
  String _referenceMode = 'none';
  String? _referenceFile;
  final Map<String, String> _referenceOverrides = {};
  final Set<String> _referenceSkipped = {};
  String? _outputDir;
  // Which long-read platform (Nanopore raw/HQ, PacBio raw/HiFi) this run's
  // long reads came from -- Flye and SPAdes/Unicycler each need a different
  // flag for it, so this drives config.yaml's long_read_platform block
  // instead of a hardcoded flag in the Snakemake rules. One choice for the
  // whole run (not per-sample); see manifest's long_read_platforms.
  String? _longReadPlatform;
  // PRISM-only: which amplicon the run targets. One run-wide choice that
  // carries the marker gene, its reference database, its primer sequences
  // AND its expected length window together -- those four previously lived
  // in three independent places that could silently disagree (see
  // config_engine.py's amplicon_preset block). Drives config.yaml's
  // amplicon_preset block; see manifest's amplicon_presets.
  String? _ampliconPreset;
  // Campos reais de primer (aba Entradas), pré-preenchidos pelo preset escolhido
  // mas editáveis: presets como "18S -- informe os primers" e "Personalizado"
  // deliberadamente não trazem sequência, e mesmo os que trazem podem ser
  // trocados (existem primers diferentes que amplificam a mesma região).
  // Vários primers separados por vírgula -- o kit ONT SQK-MAB114.24 é um mix real
  // (par universal + pares taxon-específicos), não um par único.
  final _fwdPrimersController = TextEditingController();
  final _revPrimersController = TextEditingController();
  /// Preenche os campos de primer a partir de um preset do manifest, sem
  /// sobrescrever o que o usuário já digitou à mão (only=true força).
  void _seedPrimersFromPreset(String? presetId, {bool force = false}) {
    final list = (_manifest?['amplicon_presets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final p = list.firstWhere((e) => e['id'] == presetId, orElse: () => const <String, dynamic>{});
    if (p.isEmpty) return;
    final fwd = ((p['fwd_primers'] as List?) ?? const []).join(', ');
    final rev = ((p['rev_primers'] as List?) ?? const []).join(', ');
    if (force || _fwdPrimersController.text.trim().isEmpty) _fwdPrimersController.text = fwd;
    if (force || _revPrimersController.text.trim().isEmpty) _revPrimersController.text = rev;
  }
  final Set<String> _activeTools = {};
  // Per-track activation for dual-track tools (Prodigal, antiSMASH,...): tool_id
  // -> which of its tracks ("sample" | "mags") are on. Absent/empty tracks map
  // means "not a dual-track tool" or "not yet initialized" -- see _onToggleTool.
  final Map<String, Set<String>> _activeTracks = {};
  // "toolId" (non-track tool) or "toolId:track" (track-specific) units that
  // got turned off by *cascade* (a dependency going away under them), not by
  // a direct user click -- eligible to come back automatically once their
  // requirements are satisfied again. A unit the user switched off directly
  // is never in here, so re-enabling some unrelated dependency elsewhere
  // can't silently override a deliberate choice.
  final Set<String> _cascadeDisabled = {};
  final _ramController = TextEditingController(text: '32');
  final _coresController = TextEditingController(text: '8');
  // Per-tool thread overrides (Resources tab): tool_id -> controller. Empty
  // text means "use the manifest's default_threads value for this tool" --
  // one controller per tool known from the manifest, created once in _load.
  final Map<String, TextEditingController> _threadControllers = {};

  bool _loading = true;
  String? _error;
  bool _starting = false;
  bool _saving = false;

  // Autosave: any change to inputs/tools/params/resources schedules a save a
  // short debounce later (so rapid changes -- typing in a flag field, several
  // toggles in a row -- collapse into one write instead of one per keystroke)
  // instead of relying on the user to remember to hit "Salvar". _dirty is
  // true from the moment a change happens until that save actually lands;
  // _everSaved distinguishes "nothing to report yet" from "clean, and has
  // been saved at least once" for the bottom-bar indicator.
  Timer? _autosaveDebounce;
  bool _dirty = false;
  bool _autosaving = false;
  bool _everSaved = false;

  void _markDirty() {
    setState(() => _dirty = true);
    _autosaveDebounce?.cancel();
    _autosaveDebounce = Timer(const Duration(milliseconds: 1200), _runAutosave);
  }

  Future<void> _runAutosave() async {
    if (!mounted || _outputDir == null || _outputDir!.isEmpty) return;
    setState(() => _autosaving = true);
    await _saveDraft();
    if (!mounted) return;
    setState(() {
      _autosaving = false;
      _dirty = false;
      _everSaved = true;
    });
  }

  String? _previewCommand;
  String? _previewSamples;
  String? _previewConfig;
  bool _previewLoading = false;
  String? _previewError;

  /// For use in callbacks (snackbars, etc.) outside build, where ref.t's
  /// internal ref.watch would be inappropriate.
  String _tr(String key) => translate(key, ref.read(localeProvider).languageCode);

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _tabController.addListener(_onTabChanged);
    _load();
  }

  void _onTabChanged() {
    if (_tabController.indexIsChanging) return;
    setState(() {});
    if (_tabController.index == 4) _refreshPreview;
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _autosaveDebounce?.cancel();
    _fwdPrimersController.dispose();
    _revPrimersController.dispose();
    _ramController.dispose();
    _coresController.dispose();
    for (final c in _threadControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final api = ref.read(apiClientProvider);
      final manifest = await api.get('/api/pipelines/${widget.pipelineId}') as Map<String, dynamic>;
      final toolsRaw = await api.get('/api/pipelines/${widget.pipelineId}/tools') as List;
      final dbsRaw = await api.get('/api/pipelines/${widget.pipelineId}/databases') as Map<String, dynamic>;
      final draft = await api.get('/api/pipelines/${widget.pipelineId}/draft') as Map<String, dynamic>;

      final lang = ref.read(localeProvider).languageCode;
      final categories = toolsRaw.map((e) => ToolCategory.fromJson(e as Map<String, dynamic>, lang)).toList();
      final databases = dbsRaw.map((k, v) => MapEntry(k, DatabaseDef.fromJson(k, v as Map<String, dynamic>, lang)));

      setState(() {
        _manifest = manifest;
        _toolsRaw = toolsRaw;
        _categories = categories;
        _databasesRaw = dbsRaw;
        _databases = databases;
        _longReadPlatform = manifest['default_long_read_platform'] as String?;
        _ampliconPreset = manifest['default_amplicon_preset'] as String?;
        _seedPrimersFromPreset(_ampliconPreset, force: true);
        _toolsById = {for (final t in categories.expand((c) => c.tools)) t.id: t};
        _toolParams..clear()..addEntries(_toolsById.entries.map((e) => MapEntry(e.key, ToolParamsState.fromDefaults(e.value))));
        _activeTools..clear()..addAll(_toolsById.keys.where((id) => _toolsById[id]!.activeByDefault));
        _activeTracks.clear();
        for (final t in _toolsById.values) {
          if (t.tracks.isNotEmpty) _activeTracks[t.id] = t.tracks.keys.toSet();
        }
        for (final c in _threadControllers.values) {
          c.dispose();
        }
        _threadControllers.clear();
        for (final id in _toolsById.keys) {
          _threadControllers[id] = TextEditingController();
        }
        _applyDraft(draft);
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Re-derives [_categories]/[_toolsById]/[_databases] from the
  /// already-fetched [_toolsRaw]/[_databasesRaw] in the new language -- no
  /// network call, and active tools/flag params (keyed by tool id, not by
  /// the ToolDef object) survive untouched.
  void _rebuildForLocale() {
    final lang = ref.read(localeProvider).languageCode;
    setState(() {
      if (_toolsRaw.isNotEmpty) {
        final categories = _toolsRaw.map((e) => ToolCategory.fromJson(e as Map<String, dynamic>, lang)).toList();
        _categories = categories;
        _toolsById = {for (final t in categories.expand((c) => c.tools)) t.id: t};
      }
      if (_databasesRaw.isNotEmpty) {
        _databases = _databasesRaw.map((k, v) => MapEntry(k, DatabaseDef.fromJson(k, v as Map<String, dynamic>, lang)));
      }
    });
  }

  /// Restores whatever was last saved via _saveDraft (called from Salvar and
  /// Iniciar) -- input/output folders, RAM/cores, active tools and per-tool
  /// flag overrides -- so navigating back to the Hub and reopening this
  /// pipeline doesn't start from a blank slate.
  void _applyDraft(Map<String, dynamic> draft) {
    if (draft.isEmpty) return;

    final inputDirs = draft['input_dirs'] as Map<String, dynamic>?;
    if (inputDirs != null) {
      _inputDirs..clear()..addAll(inputDirs.map((k, v) => MapEntry(k, v as String)));
    }
    final toggledInputDirs = draft['toggled_input_dirs'] as List?;
    if (toggledInputDirs != null) {
      _toggledInputDirs..clear()..addAll(toggledInputDirs.map((e) => e as String));
    }
    final outputDir = draft['output_dir'] as String?;
    if (outputDir != null && outputDir.isNotEmpty) _outputDir = outputDir;
    final savedMode = draft['reference_mode'] as String?;
    if (savedMode != null && const ['none', 'single', 'per_sample'].contains(savedMode)) _referenceMode = savedMode;
    final referenceFile = draft['reference_file'] as String?;
    if (referenceFile != null && referenceFile.isNotEmpty) _referenceFile = referenceFile;
    final referenceOverrides = draft['reference_overrides'] as Map<String, dynamic>?;
    if (referenceOverrides != null) {
      _referenceOverrides..clear()..addAll(referenceOverrides.map((k, v) => MapEntry(k, v as String)));
    }
    final referenceSkipped = draft['reference_skipped'] as List?;
    if (referenceSkipped != null) {
      _referenceSkipped..clear()..addAll(referenceSkipped.map((e) => e as String));
    }
    if (draft['ram_gb'] != null) _ramController.text = draft['ram_gb'].toString();
    if (draft['cores'] != null) _coresController.text = draft['cores'].toString();
    final savedPlatform = draft['long_read_platform'] as String?;
    if (savedPlatform != null && savedPlatform.isNotEmpty) _longReadPlatform = savedPlatform;
    final savedPreset = draft['amplicon_preset'] as String?;
    if (savedPreset != null && savedPreset.isNotEmpty) _ampliconPreset = savedPreset;
    if (savedPreset != null && savedPreset.isNotEmpty) _seedPrimersFromPreset(savedPreset, force: true);
    // Primers digitados à mão vencem o que o preset preencheu.
    final savedFwd = draft['amplicon_fwd_primers'] as String?;
    if (savedFwd != null && savedFwd.isNotEmpty) _fwdPrimersController.text = savedFwd;
    final savedRev = draft['amplicon_rev_primers'] as String?;
    if (savedRev != null && savedRev.isNotEmpty) _revPrimersController.text = savedRev;

    final threadOverrides = draft['thread_overrides'] as Map<String, dynamic>?;
    if (threadOverrides != null) {
      for (final entry in threadOverrides.entries) {
        final controller = _threadControllers[entry.key];
        if (controller != null) controller.text = entry.value.toString();
      }
    }

    final activeTools = draft['active_tools'] as List?;
    if (activeTools != null) {
      final valid = activeTools.map((e) => e as String).where(_toolsById.containsKey).toSet();
      if (valid.isNotEmpty) {
        _activeTools..clear()..addAll(valid);
      }
    }

    final activeTracks = draft['active_tracks'] as Map<String, dynamic>?;
    if (activeTracks != null) {
      for (final entry in activeTracks.entries) {
        final tool = _toolsById[entry.key];
        if (tool == null || tool.tracks.isEmpty) continue;
        final tracks = (entry.value as List).map((e) => e as String).where(tool.tracks.containsKey).toSet();
        _activeTracks[entry.key] = tracks;
      }
    }

    final toolParams = draft['tool_params'] as Map<String, dynamic>?;
    if (toolParams != null) {
      for (final entry in toolParams.entries) {
        final state = _toolParams[entry.key];
        if (state == null) continue;
        final saved = entry.value as Map<String, dynamic>;
        final enabled = (saved['enabledFlags'] as List?)?.map((e) => e as String).toSet();
        if (enabled != null) {
          state.enabledFlags..clear()..addAll(enabled);
        }
        final values = saved['flagValues'] as Map<String, dynamic>?;
        if (values != null) {
          state.flagValues..clear()..addAll(values.map((k, v) => MapEntry(k, v as String)));
        }
        state.extraParams = saved['extraParams'] as String? ?? '';
      }
    }
  }

  Map<String, dynamic> _draftPayload() => {
        'input_dirs': _inputDirs,
        'toggled_input_dirs': _toggledInputDirs.toList(),
        'output_dir': _outputDir,
        'reference_mode': _referenceMode,
        'reference_file': _referenceFile,
        'reference_overrides': _referenceOverrides,
        'reference_skipped': _referenceSkipped.toList(),
        'ram_gb': _ramController.text,
        'cores': _coresController.text,
        'long_read_platform': _longReadPlatform,
        'amplicon_preset': _ampliconPreset,
        'amplicon_fwd_primers': _fwdPrimersController.text,
        'amplicon_rev_primers': _revPrimersController.text,
        'thread_overrides': {
          for (final entry in _threadControllers.entries)
            if (entry.value.text.trim().isNotEmpty) entry.key: entry.value.text.trim(),
        },
        'active_tools': _activeTools.toList(),
        'active_tracks': {for (final entry in _activeTracks.entries) entry.key: entry.value.toList()},
        'tool_params': {
          for (final entry in _toolParams.entries)
            entry.key: {
              'enabledFlags': entry.value.enabledFlags.toList(),
              'flagValues': entry.value.flagValues,
              'extraParams': entry.value.extraParams,
            },
        },
      };

  /// Best-effort -- draft persistence failing shouldn't block Save/Start.
  Future<void> _saveDraft() async {
    final api = ref.read(apiClientProvider);
    try {
      await api.post('/api/pipelines/${widget.pipelineId}/draft', _draftPayload());
    } catch (_) {}
  }

  Future<void> _reloadDatabases() async {
    final api = ref.read(apiClientProvider);
    final dbsRaw = await api.get('/api/pipelines/${widget.pipelineId}/databases') as Map<String, dynamic>;
    final lang = ref.read(localeProvider).languageCode;
    setState(() {
      _databasesRaw = dbsRaw;
      _databases = dbsRaw.map((k, v) => MapEntry(k, DatabaseDef.fromJson(k, v as Map<String, dynamic>, lang)));
    });
  }

  bool get _canStart => _outputDir != null && _outputDir!.isNotEmpty && _inputDirs.isNotEmpty && !_starting;
  bool get _canSave => _outputDir != null && _outputDir!.isNotEmpty && !_starting && !_saving;

  /// Writes samples.tsv + config.yaml from the current in-memory state
  /// (inputs/databases/tools tabs) into `<output_dir>/config/`. Shared by the
  /// standalone "Salvar" action and by `_start`, which saves then launches.
  Future<Map<String, dynamic>> _buildAndSaveConfig() async {
    await _saveDraft();

    final api = ref.read(apiClientProvider);
    final payload = {
      'output_dir': _outputDir,..._inputDirs,
      'reference_mode': _referenceMode,
      if (_referenceMode == 'single' && _referenceFile != null) 'reference_file': _referenceFile,
      if (_referenceMode == 'per_sample' && _referenceOverrides.isNotEmpty) 'reference_overrides': _referenceOverrides,
    };

    final samplesRes = await api.post('/api/pipelines/${widget.pipelineId}/samples/generate', payload) as Map<String, dynamic>;

    // mags_annot and domain_filter aren't CLI tools -- their flags merge into
    // config.yaml as a nested dict (thresholds / a domain "mode" string), not
    // a flag string like every other tool.
    final toolFlags = <String, dynamic>{};
    for (final id in _activeTools) {
      final tool = _toolsById[id];
      final state = _toolParams[id];
      if (tool == null || state == null) continue;
      if (id == 'mags_annot' || id == 'domain_filter') {
        final values = <String, dynamic>{};
        for (final flag in tool.flags) {
          final raw = state.flagValues[flag.flag];
          if (raw != null) values[flag.flag] = num.tryParse(raw) ?? raw;
        }
        if (values.isNotEmpty) toolFlags[id] = values;
      } else {
        final assembled = buildToolParamsString(tool, state);
        if (assembled.isNotEmpty) toolFlags[id] = assembled;
      }
    }

    final threadOverrides = {
      for (final entry in _threadControllers.entries)
        if (entry.value.text.trim().isNotEmpty) entry.key: entry.value.text.trim(),
    };

    // Toggle-type input_dirs (currently just DOGMA's paired MAGMA run) and
    // "kind": "file" ones (currently just DEFINE's reference genome) are
    // per-run, not persistent databases -- config/generate needs the picked
    // path (plus, for a toggle, whether it's actually on, since "off" must
    // blank the value even if a path was picked earlier) -- see
    // config_engine.generate_config.
    final toggleInputs = <String, dynamic>{};
    for (final rawSpec in (_manifest?['sample_sheet']?['input_dirs'] as List? ?? [])) {
      final spec = rawSpec as Map<String, dynamic>;
      final isToggle = spec['toggle'] == true;
      final isFile = spec['kind'] == 'file';
      if (!isToggle && !isFile) continue;
      final key = spec['key'] as String;
      toggleInputs[key] = _inputDirs[key] ?? '';
      if (isToggle) toggleInputs['${key}_enabled'] = _toggledInputDirs.contains(key);
    }

    final configPayload = {
      'output_dir': _outputDir,
      'active_tools': _activeTools.toList(),
      'tool_flags': toolFlags,
      'tsv_path': samplesRes['tsv_path'],
      'ram_gb': int.tryParse(_ramController.text) ?? 0,
      'thread_overrides': threadOverrides,
      if (_longReadPlatform != null) 'long_read_platform': _longReadPlatform,
      if (_ampliconPreset != null) 'amplicon_preset': _ampliconPreset,
      'amplicon_fwd_primers': _fwdPrimersController.text,
      'amplicon_rev_primers': _revPrimersController.text,...toggleInputs,
    };
    final configRes = await api.post('/api/pipelines/${widget.pipelineId}/config/generate', configPayload) as Map<String, dynamic>;
    return {...configRes, 'tsv_content': samplesRes['tsv_content'], 'tsv_path': samplesRes['tsv_path']};
  }

  /// Refreshes the Review tab's preview (final Snakemake command, samples.tsv,
  /// config.yaml) from the current in-memory state -- also writes both files
  /// to disk via _buildAndSaveConfig, same as Salvar.
  Future<void> _refreshPreview() async {
    if (_outputDir == null || _outputDir!.isEmpty) {
      setState(() {
        _previewCommand = null;
        _previewSamples = null;
        _previewConfig = null;
        _previewError = null;
      });
      return;
    }
    setState(() {
      _previewLoading = true;
      _previewError = null;
    });
    try {
      final res = await _buildAndSaveConfig();
      final cores = int.tryParse(_coresController.text) ?? 4;
      final omit = _graph.omitFromRuleNames(_activeTools, _activeTracks);
      final cmd = [
        'snakemake',
        '--use-conda', '--conda-frontend', 'conda',
        '--cores=$cores',
        '--configfile=${res['path']}',
        '--directory=$_outputDir',
        if (omit.isNotEmpty) '--omit-from ${omit.join(' ')}',
      ].join(' ');
      if (!mounted) return;
      setState(() {
        _previewCommand = cmd;
        _previewSamples = res['tsv_content'] as String? ?? '';
        _previewConfig = res['content'] as String? ?? '';
        _previewLoading = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _previewError = e.toString();
          _previewLoading = false;
        });
      }
    }
  }

  Future<void> _saveAndContinue() async {
    setState(() => _saving = true);
    try {
      await _saveDraft();
      if (!mounted) return;
      _tabController.animateTo(_tabController.index + 1);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveConfig() async {
    setState(() => _saving = true);
    try {
      final configRes = await _buildAndSaveConfig();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_tr('config_saved')}: ${configRes['path']}')),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_tr('error_saving')}: $e')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _start() async {
    setState(() => _starting = true);
    try {
      // Last-chance gate: catches any per_sample sample left unresolved
      // (never explicitly skipped or given a manual reference) before the
      // run actually starts, even if the user dismissed/ignored the check
      // earlier in the Inputs tab.
      await _checkReferenceMatches();
      if (!mounted) return;
      final configRes = await _buildAndSaveConfig();

      if (!mounted) return;
      ref.read(pipelineRunProvider.notifier).start(
            pipelineId: widget.pipelineId,
            pipelineName: widget.pipelineName,
            configPath: configRes['path'] as String,
            cores: int.tryParse(_coresController.text) ?? 4,
            omitFrom: _graph.omitFromRuleNames(_activeTools, _activeTracks),
          );

      if (!mounted) return;
      ref.read(embeddedMonitorProvider.notifier).state = true;
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${_tr('error_starting')}: $e')));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Embedded directly in AppShell's body (see embeddedPipelineProvider) --
  /// no own Scaffold/AppBar, so the sidebar nav rail stays visible/usable
  /// while a pipeline is being configured, instead of covering it the way a
  /// full-screen pushed route would.
  @override
  Widget build(BuildContext context) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return Center(child: Text('${ref.t('error_prefix')}: $_error'));

    ref.listen(localeProvider, (previous, next) {
      if (previous != next) _rebuildForLocale;
    });
    final colors = context.colors;
    final run = ref.watch(pipelineRunProvider);
    return Column(
      children: [
        Container(
          color: colors.surface,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back),
                tooltip: ref.t('back_to_hub'),
                onPressed: () => ref.read(embeddedPipelineProvider.notifier).state = null,
              ),
              Expanded(
                child: Text(widget.pipelineName, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              if (run != null)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: TextButton.icon(
                    onPressed: () => ref.read(embeddedMonitorProvider.notifier).state = true,
                    icon: Icon(run.finished ? Icons.fact_check_outlined: Icons.play_circle_outline, size: 18),
                    label: Text(run.finished ? ref.t('view_last_run'): ref.t('view_running_pipeline')),
                  ),
                ),
            ],
          ),
        ),
        TabBar(
          controller: _tabController,
          labelColor: colors.primaryDark,
          unselectedLabelColor: colors.textSecondary,
          indicatorColor: colors.primary,
          tabs: [
            Tab(text: ref.t('tab_inputs')),
            Tab(text: ref.t('tab_tools')),
            Tab(text: ref.t('tab_databases')),
            Tab(text: ref.t('tab_resources')),
            Tab(text: ref.t('tab_review')),
          ],
        ),
        const Divider(height: 1),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            children: [_buildInputsTab(), _buildToolsTab(), _buildDatabasesTab(), _buildResourcesTab(), _buildReviewTab()],
          ),
        ),
        _buildBottomBar(colors),
      ],
    );
  }

  /// Known input dir keys get fixed translated labels (every pipeline that
  /// declares one names it the same thing); anything else falls back to
  /// whatever label the manifest itself declares, since it's pipeline-specific
  /// and not worth hardcoding here -- that fallback won't track the app's
  /// language toggle, so prefer adding a key above when a new shared input
  /// dir shows up in more than one manifest.
  String _inputDirLabel(Map<String, dynamic> spec) {
    final key = spec['key'] as String;
    return switch (key) {
      'short_reads_dir' => ref.t('input_short_reads'),
      'long_reads_dir' => ref.t('input_long_reads'),
      'reference_dir' => ref.t('input_reference_dir'),
      'magma_run_dir' => ref.t('input_magma_run_dir'),
      'reference_genome' => ref.t('input_reference_genome'),
      _ => spec['label'] as String? ?? key,
    };
  }

  /// Explanatory hint shown under a "toggle"-type input_dirs entry (currently
  /// just DOGMA's paired MAGMA run) -- like [_inputDirLabel], known keys get a
  /// translated string that tracks the language toggle; the manifest's own
  /// (Portuguese-only) `toggle_hint` field is never read directly, since that
  /// would silently stay in Portuguese after switching to English.
  String? _inputDirToggleHint(String key) => switch (key) {
        'magma_run_dir' => ref.t('input_magma_run_hint'),
        _ => null,
      };

  /// Best-effort dry-run of sample discovery (no tsv/config written) to find
  /// samples that have reads but, in 'per_sample' mode, no reference_dir
  /// folder matching their name -- then prompts for each one via
  /// [showReferenceValidationDialog] so the run doesn't silently proceed
  /// without a reference the user didn't explicitly sign off on. A no-op
  /// outside 'per_sample' mode, or for samples already resolved by a
  /// previous check (an override on file, or an explicit skip).
  Future<void> _checkReferenceMatches() async {
    if (_referenceMode != 'per_sample') return;
    final refDir = _inputDirs['reference_dir'];
    if (refDir == null || refDir.isEmpty) return;
    final shortDir = _inputDirs['short_reads_dir'];
    final longDir = _inputDirs['long_reads_dir'];
    if ((shortDir == null || shortDir.isEmpty) && (longDir == null || longDir.isEmpty)) return;

    final api = ref.read(apiClientProvider);
    Map<String, dynamic> res;
    try {
      res = await api.post('/api/pipelines/${widget.pipelineId}/samples/preview', {..._inputDirs,
        'reference_mode': 'per_sample',
      }) as Map<String, dynamic>;
    } catch (_) {
      return;
    }
    if (!mounted) return;

    final rows = (res['samples'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final unmatched = [
      for (final r in rows)
        if (((r['fq1'] as String?)?.isNotEmpty ?? false) || ((r['fq_long'] as String?)?.isNotEmpty ?? false))
          if ((r['reference'] as String?)?.isEmpty ?? true)
            if (!_referenceOverrides.containsKey(r['sample']) && !_referenceSkipped.contains(r['sample']))
              r['sample'] as String,
    ];
    if (unmatched.isEmpty) return;

    await showReferenceValidationDialog(
      context: context,
      ref: ref,
      unmatchedSamples: unmatched,
      overrides: _referenceOverrides,
      skipped: _referenceSkipped,
    );
    if (!mounted) return;
    setState(() {});
    _markDirty();
  }

  /// Every input_dirs entry is a plain folder picker, except: SIGMA's
  /// reference_dir, which gets a three-way toggle (no reference / single
  /// reference for all samples / one reference per sample) since RagTag's
  /// reference-guided scaffolding can run in any of those modes; a
  /// "toggle"-type entry (currently just DOGMA's paired MAGMA run), which is
  /// an explicit on/off switch plus a folder picker shown only while on --
  /// this is a per-run value (unlike the persistent Databases screen), so
  /// each run can pair a different MAGMA run, or none at all; and a
  /// "kind": "file" entry (currently just DEFINE's reference genome), a
  /// single required file rather than a folder to scan for samples.
  Widget _buildInputDirField(Map<String, dynamic> spec) {
    final key = spec['key'] as String;
    if (spec['kind'] == 'file') {
      return FilePickerField(
        label: _inputDirLabel(spec),
        path: _inputDirs[key],
        onPicked: (p) {
          setState(() => _inputDirs[key] = p);
          _markDirty();
        },
      );
    }
    if (spec['toggle'] == true) {
      final on = _toggledInputDirs.contains(key);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(_inputDirLabel(spec), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            subtitle: _inputDirToggleHint(key) != null
                ? Text(_inputDirToggleHint(key)!, style: TextStyle(fontSize: 12, color: context.colors.textSecondary)): null,
            value: on,
            onChanged: (v) {
              setState(() => v ? _toggledInputDirs.add(key): _toggledInputDirs.remove(key));
              _markDirty();
            },
          ),
          if (on)...[
            const SizedBox(height: 8),
            FolderPickerField(
              label: _inputDirLabel(spec),
              path: _inputDirs[key],
              onPicked: (p) {
                setState(() => _inputDirs[key] = p);
                _markDirty();
              },
            ),
          ],
        ],
      );
    }
    if (key != 'reference_dir') {
      return FolderPickerField(
        label: _inputDirLabel(spec),
        path: _inputDirs[key],
        onPicked: (p) {
          setState(() => _inputDirs[key] = p);
          _markDirty();
          if (key == 'short_reads_dir' || key == 'long_reads_dir') _checkReferenceMatches;
        },
      );
    }
    final hint = switch (_referenceMode) {
      'single' => ref.t('input_reference_single_hint'),
      'per_sample' => ref.t('input_reference_per_sample_hint'),
      _ => ref.t('input_reference_none_hint'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(ref.t('input_reference_mode_label'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: [
            ButtonSegment(value: 'none', label: Text(ref.t('input_reference_mode_none'), style: const TextStyle(fontSize: 12.5))),
            ButtonSegment(value: 'single', label: Text(ref.t('input_reference_mode_single'), style: const TextStyle(fontSize: 12.5))),
            ButtonSegment(
                value: 'per_sample', label: Text(ref.t('input_reference_mode_per_sample'), style: const TextStyle(fontSize: 12.5))),
          ],
          selected: {_referenceMode},
          onSelectionChanged: (selection) {
            final mode = selection.first;
            setState(() => _referenceMode = mode);
            _markDirty();
            if (mode == 'per_sample') _checkReferenceMatches;
          },
        ),
        const SizedBox(height: 6),
        Text(hint, style: TextStyle(fontSize: 12, color: context.colors.textSecondary)),
        const SizedBox(height: 10),
        if (_referenceMode == 'single')
          FilePickerField(
            label: ref.t('input_reference_single_file'),
            path: _referenceFile,
            onPicked: (p) {
              setState(() => _referenceFile = p);
              _markDirty();
            },
          )
        else if (_referenceMode == 'per_sample')...[
          FolderPickerField(
            label: _inputDirLabel(spec),
            path: _inputDirs[key],
            onPicked: (p) {
              setState(() => _inputDirs[key] = p);
              _markDirty();
              _checkReferenceMatches();
            },
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _checkReferenceMatches,
              icon: const Icon(Icons.fact_check_outlined, size: 16),
              label: Text(ref.t('input_reference_recheck_button')),
            ),
          ),
        ],
      ],
    );
  }

  Widget _primerField(String label, TextEditingController c) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        const SizedBox(height: 6),
        TextField(
          controller: c,
          style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
          decoration: const InputDecoration(isDense: true, hintText: 'AGRGTTYGATYMTGGCTCAG'),
          onChanged: (_) => _markDirty,
        ),
      ],
    );
  }

  Widget _buildInputsTab() {
    final inputDirsSpec = (_manifest?['sample_sheet']?['input_dirs'] as List?) ?? [];
    final platforms = (_manifest?['long_read_platforms'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final ampliconPresets = (_manifest?['amplicon_presets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final rawSpec in inputDirsSpec)...[
            _buildInputDirField(rawSpec as Map<String, dynamic>),
            const SizedBox(height: 16),
          ],
          if (platforms.isNotEmpty)...[
            Text(ref.t('input_long_read_platform'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: platforms.any((p) => p['id'] == _longReadPlatform) ? _longReadPlatform: null,
              isExpanded: true,
              style: TextStyle(fontSize: 13, color: context.colors.textPrimary),
              decoration: const InputDecoration(isDense: true),
              items: [
                for (final p in platforms)
                  DropdownMenuItem(value: p['id'] as String, child: Text(p['label'] as String, style: const TextStyle(fontSize: 13))),
              ],
              onChanged: (v) {
                setState(() => _longReadPlatform = v);
                _markDirty();
              },
            ),
            const SizedBox(height: 4),
            Text(ref.t('input_long_read_platform_hint'), style: TextStyle(fontSize: 12, color: context.colors.textSecondary)),
            const SizedBox(height: 16),
          ],
          if (ampliconPresets.isNotEmpty)...[
            Text(ref.t('input_amplicon_preset'), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              initialValue: ampliconPresets.any((p) => p['id'] == _ampliconPreset) ? _ampliconPreset: null,
              isExpanded: true,
              style: TextStyle(fontSize: 13, color: context.colors.textPrimary),
              decoration: const InputDecoration(isDense: true),
              items: [
                for (final p in ampliconPresets)
                  DropdownMenuItem(
                    value: p['id'] as String,
                    child: Text(
                      (ref.watch(localeProvider).languageCode == 'en' ? (p['label_en'] ?? p['label']): p['label']) as String,
                      style: const TextStyle(fontSize: 13),
                    ),
                  ),
              ],
              onChanged: (v) {
                setState(() {
                  _ampliconPreset = v;
                  _seedPrimersFromPreset(v, force: true);
                });
                _markDirty();
              },
            ),
            const SizedBox(height: 4),
            // The chosen preset's own caveat (e.g. "primers not confirmed --
            // supply your own", or which ONT kit the sequences came from) is
            // more useful here than a single static hint, since the presets
            // genuinely differ in how ready-to-run they are.
            Builder(builder: (_) {
              final sel = ampliconPresets.firstWhere(
                (p) => p['id'] == _ampliconPreset,
                orElse: () => const <String, dynamic>{},
              );
              final note = (sel['note'] as Map?)?[ref.watch(localeProvider).languageCode == 'en' ? 'en': 'pt'] as String?;
              return Text(
                (note != null && note.isNotEmpty) ? note: ref.t('input_amplicon_preset_hint'),
                style: TextStyle(fontSize: 12, color: context.colors.textSecondary),
              );
            }),
            const SizedBox(height: 12),
            // Campos reais de primer. Existem porque presets como "18S --
            // informe os primers" e "Personalizado" deliberadamente não trazem
            // sequência: sem isto o usuário lê "informe os primers" e não tem
            // onde informar (só digitando -g/-G cru no cutadapt, nada
            // descobrível). Também permite trocar os primers de um preset que
            // JÁ traz sequência -- primers diferentes amplificam a mesma região.
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _primerField(ref.t('input_primer_fwd'), _fwdPrimersController)),
                const SizedBox(width: 12),
                Expanded(child: _primerField(ref.t('input_primer_rev'), _revPrimersController)),
              ],
            ),
            const SizedBox(height: 4),
            Text(ref.t('input_primer_hint'), style: TextStyle(fontSize: 12, color: context.colors.textSecondary)),
            const SizedBox(height: 16),
          ],
          FolderPickerField(
            label: ref.t('output_folder'),
            path: _outputDir,
            onPicked: (p) {
              setState(() => _outputDir = p);
              _markDirty();
            },
          ),
        ],
      ),
    );
  }

  /// Global CPU budget (the run-wide Snakemake --cores) plus optional
  /// per-tool thread overrides -- each tool's field is blank by default,
  /// showing its manifest default_threads value as a hint; typing a number
  /// overrides just that tool, leaving every other tool at its default.
  /// RAM (GB) isn't a general setting -- only the few tools listed in the
  /// manifest's special_overrides.ram_gb_targets actually read it (it fills
  /// in their -m/--memory flag), so its field sits next to those tools'
  /// thread field instead of at the top like it used to.
  Widget _buildResourcesTab() {
    final colors = context.colors;
    final defaultThreads = (_manifest?['default_threads'] as Map<String, dynamic>?) ?? {};
    final ramTargets = ((_manifest?['special_overrides'] as Map<String, dynamic>?)?['ram_gb_targets'] as List?)
            ?.map((e) => e.toString()).toSet() ??
        {};
    final relevantCategories = _categories.map((c) => ToolCategory(
              category: c.category,
              tools: c.tools.where((t) => _activeTools.contains(t.id) && defaultThreads.containsKey(t.id)).toList(),
            )).where((c) => c.tools.isNotEmpty).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 260,
            child: Card(
              margin: EdgeInsets.zero,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ref.t('global_cpus_title'), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(ref.t('global_cpus_hint'), style: TextStyle(fontSize: 11.5, color: colors.textSecondary)),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _coresController,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => _markDirty,
                      decoration: InputDecoration(
                        labelText: ref.t('global_cpus_label'),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        isDense: true,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 28),
          Row(
            children: [
              Expanded(
                child: Text(ref.t('resources_per_tool_title'),
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
              TextButton.icon(
                onPressed: () {
                  setState(() {
                    for (final c in _threadControllers.values) {
                      c.clear();
                    }
                    _ramController.clear();
                  });
                  _markDirty();
                },
                icon: const Icon(Icons.restart_alt, size: 16),
                label: Text(ref.t('resources_reset_all')),
              ),
            ],
          ),
          Text(ref.t('resources_per_tool_hint'), style: TextStyle(fontSize: 12, color: colors.textSecondary)),
          const SizedBox(height: 12),
          if (relevantCategories.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(ref.t('resources_no_active_tools'), style: TextStyle(color: colors.textMuted, fontStyle: FontStyle.italic)),
            )
          else
            for (final cat in relevantCategories)...[
              Text(cat.category, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: colors.textSecondary)),
              const SizedBox(height: 8),
              _ResourceCardGrid(
                tools: cat.tools,
                ramTargets: ramTargets,
                defaultThreads: defaultThreads,
                threadControllers: _threadControllers,
                ramController: _ramController,
                onChanged: _markDirty,
              ),
              const SizedBox(height: 20),
            ],
        ],
      ),
    );
  }

  /// Read-only status check -- actual configuration (path/download) now lives
  /// in the Hub-level Databases screen, shared across every pipeline that
  /// references the same database, instead of being repeated per pipeline.
  Widget _buildDatabasesTab() {
    final colors = context.colors;
    final dbs = _databases.values.toList()..sort((a, b) => a.name.compareTo(b.name));
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.info_outline, color: colors.primaryDark),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(ref.t('databases_configure_elsewhere_hint'),
                        style: TextStyle(fontSize: 12.5, color: colors.textSecondary)),
                  ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: ref.t('databases_refresh_status'),
                    child: IconButton(icon: const Icon(Icons.refresh), onPressed: _reloadDatabases),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          if (dbs.isEmpty)
            Text(ref.t('databases_none_needed'), style: TextStyle(color: colors.textMuted, fontStyle: FontStyle.italic))
          else
            Card(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final db in dbs)
                    ListTile(
                      dense: true,
                      leading: Icon(
                        db.configured ? Icons.check_circle: Icons.radio_button_unchecked,
                        color: db.configured ? colors.statusDone: colors.textMuted,
                        size: 20,
                      ),
                      title: Text(db.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
                      subtitle: db.configured
                          ? Text(db.path ?? '', style: TextStyle(fontSize: 11.5, color: colors.textSecondary), overflow: TextOverflow.ellipsis): Text(ref.t('db_absent'), style: TextStyle(fontSize: 11.5, color: colors.textMuted)),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  /// Every currently-on (toolId) or (toolId:track) unit -- used to diff
  /// before/after settle so we know exactly what cascade turned off.
  Set<String> _unitSnapshot() {
    final units = <String>{};
    for (final id in _activeTools) {
      final tool = _toolsById[id];
      if (tool == null || tool.tracks.isEmpty) {
        units.add(id);
      } else {
        final tracks = _activeTracks[id] ?? tool.tracks.keys.toSet();
        units.addAll(tracks.map((t) => '$id:$t'));
      }
    }
    return units;
  }

  /// Runs settle and records whatever it turns off as cascade-caused (as
  /// opposed to a direct user click), so it's eligible for _reviveCascaded.
  void _settleAndTrackCascade() {
    final before = _unitSnapshot();
    _graph.settle(_activeTools, _activeTracks);
    _cascadeDisabled.addAll(before.difference(_unitSnapshot()));
  }

  /// After the user turns something on, bring back anything that's only off
  /// because *that* cascaded away earlier and is now satisfiable again --
  /// e.g. re-enabling Prodigal/sample should also revive eggNOG/sample, but
  /// not a track the user turned off on purpose. Iterates to a fixed point:
  /// reviving one unit can satisfy another's requirement in turn.
  void _reviveCascaded() {
    var changed = true;
    while (changed) {
      changed = false;
      for (final unit in _cascadeDisabled.toList()) {
        final sep = unit.indexOf(':');
        final toolId = sep < 0 ? unit: unit.substring(0, sep);
        final track = sep < 0 ? null: unit.substring(sep + 1);
        if (!_toolsById.containsKey(toolId)) {
          _cascadeDisabled.remove(unit);
          continue;
        }
        final canEnable = track != null
            ? _graph.canEnableTrack(toolId, track, _activeTools, _activeTracks): _graph.canEnable(toolId, _activeTools, _activeTracks);
        if (!canEnable) continue;
        _cascadeDisabled.remove(unit);
        _activeTools.add(toolId);
        if (track != null) _activeTracks.putIfAbsent(toolId, () => {}).add(track);
        changed = true;
      }
    }
  }

  void _onToggleTool(String id) {
    if (_activeTools.contains(id)) {
      setState(() {
        _activeTools.remove(id);
        _activeTracks.remove(id);
        _cascadeDisabled.remove(id);
        _settleAndTrackCascade();
      });
      _markDirty();
    } else if (_graph.canEnable(id, _activeTools, _activeTracks)) {
      setState(() {
        _activeTools.add(id);
        final tool = _toolsById[id];
        if (tool != null && tool.tracks.isNotEmpty) _activeTracks[id] = tool.tracks.keys.toSet();
        _cascadeDisabled.remove(id);
        _reviveCascaded();
      });
      _markDirty();
    } else {
      final missing = _graph.missingRequirementLabel(id, _activeTools, _activeTracks);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${_tr('requires_label')}: $missing')),
      );
    }
  }

  /// Toggles one track (sample/mags) of a dual-track tool independently --
  /// e.g. run Prodigal on MAGs only, skip the per-sample track. Turning a
  /// track off cascades same-track dependents off too (and remembers that it
  /// was cascade, not deliberate); turning one back on revives whatever was
  /// only off because of that -- see _settleAndTrackCascade/_reviveCascaded.
  void _onToggleTrack(String toolId, String track) {
    setState(() {
      final tracks = _activeTracks.putIfAbsent(toolId, () => {});
      final turningOn = !tracks.contains(track);
      if (turningOn) {
        tracks.add(track);
      } else {
        tracks.remove(track);
      }
      if (tracks.isEmpty) {
        _activeTools.remove(toolId);
        _activeTracks.remove(toolId);
      } else {
        _activeTools.add(toolId);
      }
      _cascadeDisabled.remove('$toolId:$track');
      if (turningOn) {
        _reviveCascaded();
      } else {
        _settleAndTrackCascade();
      }
    });
    _markDirty();
  }

  Widget _buildToolsTab() {
    return ListView.builder(
      padding: const EdgeInsets.all(24),
      itemCount: _categories.length,
      itemBuilder: (context, i) => Padding(
        padding: const EdgeInsets.only(bottom: 16),
        child: ToolCategorySection(
          category: _categories[i],
          activeTools: _activeTools,
          activeTracks: _activeTracks,
          graph: _graph,
          toolParams: _toolParams,
          onToggle: _onToggleTool,
          onToggleTrack: _onToggleTrack,
          onParamsChanged: () {
            setState(() {});
            _markDirty();
          },
        ),
      ),
    );
  }

  Widget _buildReviewTab() {
    final colors = context.colors;
    if (_outputDir == null || _outputDir!.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(ref.t('review_missing_output_dir'), style: TextStyle(color: colors.textMuted)),
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(ref.t('tab_review'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              ),
              TextButton.icon(
                onPressed: _previewLoading ? null: _refreshPreview,
                icon: _previewLoading
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)): const Icon(Icons.refresh, size: 18),
                label: Text(ref.t('review_refresh')),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_previewError != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text('${ref.t('error_prefix')}: $_previewError', style: TextStyle(color: colors.statusError)),
            ),
          if (_previewCommand != null)...[
            _PreviewBlock(title: ref.t('review_command_title'), content: _previewCommand!),
            const SizedBox(height: 16),
          ],
          if (_previewSamples != null)...[
            _PreviewBlock(title: ref.t('review_samples_title'), content: _previewSamples!),
            const SizedBox(height: 16),
          ],
          if (_previewConfig != null) _PreviewBlock(title: ref.t('review_config_title'), content: _previewConfig!),
        ],
      ),
    );
  }

  Widget _buildBottomBar(AppPalette colors) {
    final onReviewTab = _tabController.index == 4;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      child: Row(
        children: [
          Text('${_activeTools.length} ${ref.t('active_tools_suffix')}', style: TextStyle(color: colors.textSecondary)),
          const SizedBox(width: 16),
          _AutosaveIndicator(dirty: _dirty, saving: _autosaving, everSaved: _everSaved),
          const Spacer(),
          if (!onReviewTab)
            ElevatedButton.icon(
              onPressed: !_saving ? _saveAndContinue: null,
              icon: _saving
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)): const Icon(Icons.arrow_forward),
              label: Text(ref.t('save_and_continue')),
            )
          else...[
            OutlinedButton.icon(
              onPressed: _canSave ? _saveConfig: null,
              icon: _saving
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)): const Icon(Icons.save_outlined),
              label: Text(ref.t('save_config')),
            ),
            const SizedBox(width: 12),
            ElevatedButton.icon(
              onPressed: _canStart ? _start: null,
              icon: _starting
                  ? const SizedBox(
                      width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)): const Icon(Icons.play_arrow),
              label: Text(ref.t('start_pipeline')),
            ),
          ],
        ],
      ),
    );
  }
}

/// Small status readout next to the bottom bar's "N ferramentas ativas" --
/// lets the user trust that toggling a tool, tweaking a flag, or picking a
/// folder is being saved on its own (see _markDirty/_runAutosave) without
/// needing to hit "Salvar". Shows nothing until the first change of the
/// session, so a freshly-opened pipeline with nothing to report yet doesn't
/// display a stale/misleading "saved" state.
class _AutosaveIndicator extends ConsumerWidget {
  final bool dirty;
  final bool saving;
  final bool everSaved;
  const _AutosaveIndicator({required this.dirty, required this.saving, required this.everSaved});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    if (saving) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2, color: colors.textMuted)),
          const SizedBox(width: 6),
          Text(ref.t('autosave_saving'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
        ],
      );
    }
    if (dirty) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.circle, size: 8, color: colors.textMuted),
          const SizedBox(width: 6),
          Text(ref.t('autosave_pending'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
        ],
      );
    }
    if (everSaved) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 13, color: colors.statusDone),
          const SizedBox(width: 6),
          Text(ref.t('autosave_saved'), style: TextStyle(fontSize: 12, color: colors.textMuted)),
        ],
      );
    }
    return const SizedBox.shrink();
  }
}

/// Replaces a Wrap of fixed-200/300px cards, which either left a wide window
/// full of unused space or squeezed a narrow one -- widths are computed from
/// whatever space is actually available, so cards stretch/shrink with the
/// window instead of sitting at a hardcoded pixel size. RAM-target tools
/// (their card has a second field) span two columns' worth of width instead
/// of one; every card shares the same height regardless; since the RAM field
/// sits beside the threads field, not below it.
class _ResourceCardGrid extends StatelessWidget {
  final List<ToolDef> tools;
  final Set<String> ramTargets;
  final Map<String, dynamic> defaultThreads;
  final Map<String, TextEditingController> threadControllers;
  final TextEditingController ramController;
  final VoidCallback onChanged;
  static const double _targetColumnWidth = 210;
  static const double _spacing = 12;

  const _ResourceCardGrid({
    required this.tools,
    required this.ramTargets,
    required this.defaultThreads,
    required this.threadControllers,
    required this.ramController,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = ((constraints.maxWidth + _spacing) / (_targetColumnWidth + _spacing)).floor().clamp(1, 8);
        final columnWidth = (constraints.maxWidth - _spacing * (columns - 1)) / columns;
        return Wrap(
          spacing: _spacing,
          runSpacing: _spacing,
          children: [
            for (final tool in tools)
              SizedBox(
                width: ramTargets.contains(tool.id) && columns > 1
                    ? columnWidth * 2 + _spacing: columnWidth,
                child: _ResourceCard(
                  tool: tool,
                  showRam: ramTargets.contains(tool.id),
                  defaultThreadsHint: defaultThreads[tool.id]?.toString() ?? '',
                  threadController: threadControllers[tool.id],
                  ramController: ramController,
                  onChanged: onChanged,
                ),
              ),
          ],
        );
      },
    );
  }
}

class _ResourceCard extends ConsumerWidget {
  final ToolDef tool;
  final bool showRam;
  final String defaultThreadsHint;
  final TextEditingController? threadController;
  final TextEditingController ramController;
  final VoidCallback onChanged;

  const _ResourceCard({
    required this.tool,
    required this.showRam,
    required this.defaultThreadsHint,
    required this.threadController,
    required this.ramController,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tool.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: threadController,
                    keyboardType: TextInputType.number,
                    onChanged: (_) => onChanged,
                    decoration: InputDecoration(
                      labelText: ref.t('resources_threads_field'),
                      floatingLabelBehavior: FloatingLabelBehavior.always,
                      hintText: '${ref.t('resources_default_prefix')} $defaultThreadsHint',
                      isDense: true,
                    ),
                  ),
                ),
                if (showRam)...[
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: ramController,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => onChanged,
                      decoration: InputDecoration(
                        labelText: ref.t('ram_label'),
                        floatingLabelBehavior: FloatingLabelBehavior.always,
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewBlock extends StatelessWidget {
  final String title;
  final String content;
  const _PreviewBlock({required this.title, required this.content});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
        const SizedBox(height: 6),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 240),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(8)),
          child: SingleChildScrollView(
            child: SelectableText(
              content,
              style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: colors.textSecondary),
            ),
          ),
        ),
      ],
    );
  }
}
