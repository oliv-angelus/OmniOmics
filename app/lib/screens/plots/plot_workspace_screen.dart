import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../l10n/app_strings.dart';
import '../../theme/app_theme.dart';
import '../../theme/category_colors.dart';
import '../../models/run_record.dart';
import '../../models/plot_analysis.dart';
import '../../models/plot_loaded_data.dart';
import '../../models/plot_params_state.dart';
import '../../models/plot_style_state.dart';
import '../../services/api_client.dart';
import '../../services/plot_run_provider.dart';
import '../../widgets/file_picker_field.dart';
import '../../widgets/metadata_table_editor.dart';
import '../../widgets/plot_param_form.dart';
import '../../widgets/plot_style_panel.dart';
import '../../widgets/mag_summary_table.dart';

/// Dedicated workspace for ONE finished run's analyses -- metadata (loaded
/// once, cached as a phyloseq object) -> pick a compatible analysis ->
/// parameter form -> run -> log -> preview + export. Embedded in AppShell's
/// body (see embeddedPlotRunProvider), same pattern as LaunchScreen for a
/// pipeline: the sidebar nav rail stays usable, and there's a real "Voltar"
/// out of this run's workspace instead of a shared pane that could show
/// stale content for a different run (the bug this screen replaces -- see
/// notes/Known Issues and Next Steps.md).
class PlotWorkspaceScreen extends ConsumerStatefulWidget {
  final RunRecord run;
  const PlotWorkspaceScreen({super.key, required this.run});

  @override
  ConsumerState<PlotWorkspaceScreen> createState() => _PlotWorkspaceScreenState();
}

class _PlotWorkspaceScreenState extends ConsumerState<PlotWorkspaceScreen> {
  bool _loadingAnalyses = true;
  /// Un-localized manifest JSON as returned by the API -- kept alongside the
  /// localized [_analyses] so switching PT/EN can re-derive names/
  /// descriptions instantly (see _rebuildForLocale) without an API refetch.
  List<dynamic> _analysesRaw = [];
  List<PlotAnalysis> _analyses = [];

  String? _metadataPath;
  /// Raw content of the file at [_metadataPath], read for the editable
  /// preview step -- null before a file is picked, and while [_loadedData]
  /// is set (the preview step is behind us by then, see _buildMetadataStep).
  String? _rawMetadataText;
  bool _loadingData = false;
  String? _loadError;
  PlotLoadedData? _loadedData;

  PlotAnalysis? _selectedAnalysis;
  PlotParamsState? _paramsState;
  bool _starting = false;

  /// Seeded from the first successful run's default_style.json (see
  /// _initStyleFromRun), then edited in place by PlotStylePanel and carried
  /// forward across every "Replotar" within this workspace session --
  /// never reset except when picking a different analysis (a different
  /// analysis has a differently-shaped palette).
  PlotStyleState? _styleState;
  bool _customizeExpanded = false;
  bool _replotting = false;

  String _exportFormat = 'tiff';
  final _dpiController = TextEditingController(text: '600');
  bool _exporting = false;
  String? _exportMessage;
  bool _showLog = true;
  /// Keeps the log view pinned to its latest line -- see _scrollLogToBottom.
  final _logScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _loadAnalyses();
  }

  @override
  void dispose() {
    _dpiController.dispose();
    _logScrollController.dispose();
    super.dispose();
  }

  /// Auto-follows the tail of the log, like a terminal -- without it a new
  /// line arriving off-screen requires scrolling down manually to notice.
  /// Scheduled after the frame that adds the new line actually
  /// lays out, since maxScrollExtent isn't valid until then.
  void _scrollLogToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_logScrollController.hasClients) return;
      _logScrollController.jumpTo(_logScrollController.position.maxScrollExtent);
    });
  }

  Future<void> _loadAnalyses() async {
    try {
      final api = ref.read(apiClientProvider);
      final raw = await api.get('/api/plots/analyses?pipeline_id=${widget.run.pipelineId}') as List;
      final lang = ref.read(localeProvider).languageCode;
      final analyses = raw.map((e) => PlotAnalysis.fromJson(e as Map<String, dynamic>, lang)).toList();
      if (!mounted) return;
      setState(() {
        _analysesRaw = raw;
        _analyses = analyses;
        _loadingAnalyses = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _loadingAnalyses = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${ref.t('error_prefix')}: $e')));
      }
    }
  }

  /// Re-derives [_analyses] (and, if one is open, [_selectedAnalysis]) from
  /// the already-fetched [_analysesRaw] in the new language -- same pattern
  /// LaunchScreen already uses for its tool/database lists (see
  /// launch_screen.dart's own _rebuildForLocale). Without this, toggling
  /// PT/EN left every analysis name/description frozen in whatever language
  /// was active at the moment the list was first fetched -- the manifest
  /// content doesn't share app_strings.dart's ref.t mechanism, which is
  /// what makes the surrounding chrome (buttons, labels) react on its own.
  void _rebuildForLocale() {
    if (_analysesRaw.isEmpty) return;
    final lang = ref.read(localeProvider).languageCode;
    setState(() {
      _analyses = _analysesRaw.map((e) => PlotAnalysis.fromJson(e as Map<String, dynamic>, lang)).toList();
      if (_selectedAnalysis != null) {
        _selectedAnalysis = _analyses.firstWhere((a) => a.id == _selectedAnalysis!.id, orElse: () => _selectedAnalysis!);
      }
    });
  }

  /// Reads the just-picked metadata file's raw text so it can be shown in
  /// the editable preview (MetadataTableEditor) BEFORE anything is sent to
  /// the backend -- a chance to see and fix the table (a typo'd group
  /// label, a stray value) without leaving the app. Does not build the
  /// phyloseq object yet; see _confirmMetadata (POST /api/plots/load).
  Future<void> _pickMetadata(String path) async {
    setState(() {
      _metadataPath = path;
      _rawMetadataText = null;
      _loadError = null;
      _loadedData = null;
    });
    try {
      final text = await File(path).readAsString();
      if (!mounted) return;
      setState(() => _rawMetadataText = text);
    } catch (e) {
      if (mounted) setState(() => _loadError = e.toString());
    }
  }

  /// Writes the (possibly user-edited) TSV from the preview editor to its
  /// OWN copy under this run's folder -- the originally-picked file at
  /// [_metadataPath] is never touched -- then builds the phyloseq object
  /// from that copy exactly as the old direct-on-pick flow did. Every
  /// analysis picked afterward reuses the resulting PlotLoadedData.
  Future<void> _confirmMetadata(String editedTsv) async {
    setState(() { _loadingData = true; _loadError = null; _loadedData = null; });
    try {
      final dir = Directory('${widget.run.outputDir}/plots/_metadata');
      dir.createSync(recursive: true);
      final file = File('${dir.path}/current_metadata.tsv');
      file.writeAsStringSync(editedTsv);
      final api = ref.read(apiClientProvider);
      final res = await api.post('/api/plots/load', {
        'parent_run_id': widget.run.id,
        'metadata_path': file.path,
      }) as Map<String, dynamic>;
      if (!mounted) return;
      setState(() {
        _loadedData = PlotLoadedData.fromJson(res);
        _loadingData = false;
      });
    } catch (e) {
      if (mounted) setState(() { _loadError = e.toString(); _loadingData = false; });
    }
  }

  void _changeMetadata() {
    setState(() {
      _metadataPath = null;
      _rawMetadataText = null;
      _loadedData = null;
      _loadError = null;
      _selectedAnalysis = null;
      _paramsState = null;
    });
  }

  void _selectAnalysis(PlotAnalysis analysis) {
    setState(() {
      _selectedAnalysis = analysis;
      _paramsState = PlotParamsState.fromDefaults(analysis);
      // A different analysis has a differently-shaped palette (different
      // groups/taxa/phyla, or none at all) -- last analysis' style edits
      // don't carry over.
      _styleState = null;
      _customizeExpanded = false;
    });
  }

  Future<void> _run({String? styleJsonPath}) async {
    final analysis = _selectedAnalysis;
    final params = _paramsState;
    final loaded = _loadedData;
    if (analysis == null || params == null || loaded == null) return;
    if (!params.isComplete(analysis)) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(ref.t('plots_run_missing_required'))));
      return;
    }
    setState(() { _starting = true; _showLog = true; });
    try {
      await ref.read(plotRunProvider.notifier).start(
            analysisId: analysis.id,
            parentRunId: widget.run.id,
            dataRds: loaded.dataRds,
            parameters: params.toApiParameters(analysis),
            styleJson: styleJsonPath,
          );
    } on ApiException catch (e) {
      if (mounted) {
        final msg = e.statusCode == 400 ? ref.t('plots_r_env_missing'): e.toString();
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// Reads the just-finished run's default_style.json ONCE per analysis
  /// selection (guarded by the `_styleState == null` check at the call
  /// site) -- seeds the editable style state the "Personalizar" panel
  /// mutates. Best-effort: an analysis whose script didn't produce a
  /// preview (e.g. zero significant results) just won't offer customization.
  void _initStyleFromRun(String outDir) {
    try {
      final file = File('$outDir/default_style.json');
      if (!file.existsSync()) return;
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      if (mounted) setState(() => _styleState = PlotStyleState.fromJson(json));
    } catch (_) {
      // Best-effort -- the customize panel just stays hidden if this fails.
    }
  }

  /// Writes the current (possibly just-edited) style to a fixed path inside
  /// this run's own folder tree -- overwritten on every replot, no history
  /// needed for it the way the actual analysis outputs get one -- then
  /// starts a fresh run with it. Works even if the user only changed a
  /// parameter (rank, top_n,...) via the inline form and never touched a
  /// color: the last-known-good style just gets carried through unchanged.
  Future<void> _replot() async {
    setState(() => _replotting = true);
    try {
      String? styleJsonPath;
      if (_styleState != null) {
        final dir = Directory('${widget.run.outputDir}/plots/_style');
        dir.createSync(recursive: true);
        final file = File('${dir.path}/current_style.json');
        file.writeAsStringSync(jsonEncode(_styleState!.toJson()));
        styleJsonPath = file.path;
      }
      await _run(styleJsonPath: styleJsonPath);
    } finally {
      if (mounted) setState(() => _replotting = false);
    }
  }

  /// Back to the analyses list for this SAME run+metadata -- loading is
  /// per-run, not per-analysis, so there's nothing to redo here.
  void _newAnalysis() {
    ref.read(plotRunProvider.notifier).dismiss();
    setState(() {
      _selectedAnalysis = null;
      _paramsState = null;
      _exportMessage = null;
      _showLog = true;
      _styleState = null;
      _customizeExpanded = false;
    });
  }

  void _showPreviewDialog(File previewFile) {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        insetPadding: const EdgeInsets.all(24),
        child: InteractiveViewer(
          maxScale: 5,
          child: Image.file(previewFile),
        ),
      ),
    );
  }

  Future<void> _export(PlotRunState runState) async {
    setState(() { _exporting = true; _exportMessage = null; });
    try {
      final api = ref.read(apiClientProvider);
      await api.post('/api/plots/${runState.runId}/export', {
        'run_dir': runState.outDir,
        'format': _exportFormat,
        'dpi': int.tryParse(_dpiController.text) ?? 600,
      });
      if (mounted) setState(() => _exportMessage = ref.t('plots_export_success'));
    } catch (e) {
      if (mounted) setState(() => _exportMessage = '${ref.t('error_prefix')}: $e');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(localeProvider, (previous, next) {
      if (previous != next) _rebuildForLocale;
    });
    // First successful run for the currently-selected analysis seeds the
    // "Personalizar" panel's editable style from what the R script actually
    // computed (see _initStyleFromRun) -- a real side effect, so it belongs
    // in a listener, not inline during build.
    ref.listen(plotRunProvider, (previous, next) {
      if (next != null && next.parentRunId == widget.run.id && next.finished && next.succeeded && _styleState == null) {
        _initStyleFromRun(next.outDir);
      }
    });
    final colors = context.colors;
    // Only render a job whose parent run is THIS workspace's run -- a stale
    // job left running from a different run's workspace (back pressed
    // without dismissing, matching pipelineRunProvider's own
    // navigate-away-without-stopping behavior) must not bleed into this one.
    final rawRunState = ref.watch(plotRunProvider);
    final runState = rawRunState?.parentRunId == widget.run.id ? rawRunState: null;

    return Column(
      children: [
        _buildHeader(colors, runState),
        const Divider(height: 1),
        Expanded(child: _buildBody(colors, runState)),
      ],
    );
  }

  /// One step back at a time -- form -> analyses list -> metadata step ->
  /// exit the workspace, mirroring how the header's breadcrumb grows one
  /// segment per step. Previously this always exited straight to the
  /// run-picker regardless of how deep the user was (the reported bug: back
  /// from the parameter form landed on the run list, not the analyses list).
  void _goBack(PlotRunState? runState) {
    if (runState != null && runState.finished) {
      _newAnalysis(); // same "start over" as the button by that name -- one step back to the analyses list
      return;
    }
    if (runState != null && !runState.finished) {
      // Still running -- left going in the background (same navigate-away-
      // without-stopping idiom pipelineRunProvider already allows // pipeline runs), nothing finer-grained to step back to while it owns
      // the screen.
      ref.read(embeddedPlotRunProvider.notifier).state = null;
      return;
    }
    if (_selectedAnalysis != null) {
      setState(() { _selectedAnalysis = null; _paramsState = null; });
      return;
    }
    if (_loadedData != null || _rawMetadataText != null) {
      // Covers both "already loaded" (back to picking a different file) and
      // "still on the editable preview, not loaded yet" (back to the picker
      // too, discarding the in-progress edit) -- one step back either way.
      _changeMetadata();
      return;
    }
    ref.read(embeddedPlotRunProvider.notifier).state = null;
  }

  String _backTooltip(PlotRunState? runState) {
    if (runState != null && runState.finished) return ref.t('plots_analyses_title');
    if (runState != null) return ref.t('plots_back_to_list');
    if (_selectedAnalysis != null) return ref.t('plots_analyses_title');
    if (_loadedData != null || _rawMetadataText != null) return ref.t('plots_metadata_label');
    return ref.t('plots_back_to_list');
  }

  Widget _buildHeader(AppPalette colors, PlotRunState? runState) {
    return Container(
      color: colors.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            tooltip: _backTooltip(runState),
            onPressed: () => _goBack(runState),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(widget.run.name, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                    if (_selectedAnalysis != null)...[
                      Text('  /  ', style: TextStyle(color: colors.textMuted)),
                      Text(_selectedAnalysis!.name, style: TextStyle(fontSize: 13, color: colors.textSecondary, fontWeight: FontWeight.w600)),
                    ],
                  ],
                ),
                Text(widget.run.pipelineName, style: TextStyle(fontSize: 11, color: colors.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AppPalette colors, PlotRunState? runState) {
    if (runState != null) return _buildRunPanel(colors, runState);
    if (_selectedAnalysis != null) return _buildForm(colors, _selectedAnalysis!);
    if (_loadedData != null) return _buildAnalysesList(colors);
    return _buildMetadataStep(colors);
  }

  Widget _buildMetadataStep(AppPalette colors) {
    // Once a file has been picked and its raw text read, show the editable
    // preview instead of the plain picker card -- a chance to see (and
    // fix) the table before it's actually loaded
    // into a phyloseq object. "Trocar metadados" inside the editor routes
    // back to _changeMetadata, which clears this and falls through to the
    // picker card below. Not width-constrained like the picker step -- a
    // wide metadata table benefits from the extra room.
    if (_rawMetadataText != null && !_loadingData) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: MetadataTableEditor(
          key: ValueKey(_metadataPath),
          rawTsv: _rawMetadataText!,
          onConfirm: _confirmMetadata,
          onCancel: _changeMetadata,
        ),
      );
    }
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ref.t('plots_metadata_label'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 4),
            Text(ref.t('plots_metadata_hint'), style: TextStyle(fontSize: 12.5, color: colors.textSecondary)),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilePickerField(
                  label: ref.t('plots_metadata_label'),
                  path: _metadataPath,
                  extensions: const ['tsv'],
                  typeGroupLabel: 'TSV',
                  onPicked: _pickMetadata,
                ),
              ),
            ),
            if (_loadingData)...[
              const SizedBox(height: 16),
              Row(
                children: [
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                  const SizedBox(width: 8),
                  Text(ref.t('plots_loading_data'), style: TextStyle(color: colors.textSecondary)),
                ],
              ),
            ],
            if (_loadError != null)...[
              const SizedBox(height: 16),
              Text('${ref.t('error_prefix')}: $_loadError', style: TextStyle(color: colors.statusError, fontSize: 12.5)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAnalysesList(AppPalette colors) {
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ref.t('plots_analyses_title'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                    if (_metadataPath != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(_metadataPath!.split('/').last, style: TextStyle(fontSize: 11, color: colors.textMuted)),
                      ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: _changeMetadata,
                icon: const Icon(Icons.swap_horiz, size: 16),
                label: Text(ref.t('plots_change_metadata')),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loadingAnalyses
                ? const Center(child: CircularProgressIndicator()): _analyses.isEmpty
                    ? Text(ref.t('plots_no_analyses'), style: TextStyle(color: colors.textMuted))
                    // A plain Wrap (the previous fix for the truncation bug
                    // below) let every card keep its own intrinsic height,
                    // but that meant cards in the same visual row ended at
                    // different heights -- a real reported complaint, "os
                    // cards estão desorganizados" (screenshot: `pic01.png`
                    // showed the jagged bottom edges). This still avoids the
                    // ORIGINAL bug (a fixed global card height truncating
                    // long descriptions) -- rows are chunked by however many
                    // columns actually fit the available width, then each
                    // row's own cards are stretched (via IntrinsicHeight) to
                    // that row's own tallest card, so every row reads as a
                    // clean, aligned grid band, while a short-description row
                    // stays short and a long-description row stays tall --
                    // organized without truncating anything.
                        : SingleChildScrollView(
                        child: LayoutBuilder(
                          builder: (context, constraints) => _buildAnalysisRows(_analyses, constraints.maxWidth),
                        ),
                      ),
          ),
        ],
      ),
    );
  }

  static const _analysisCardWidth = 280.0;
  static const _analysisCardSpacing = 16.0;

  Widget _buildAnalysisRows(List<PlotAnalysis> analyses, double availableWidth) {
    // Lower-bounded at 1 only -- NOT upper-bounded by analyses.length. A
    // short list (e.g. a pipeline with only 2 compatible analyses) should
    // still get normal-width cards left-aligned with empty stretched slots
    // filling out the row, not a couple of columns stretched to abnormal
    // width just because there happened to be few items.
    final columns = math.max(1, ((availableWidth + _analysisCardSpacing) / (_analysisCardWidth + _analysisCardSpacing)).floor());
    final rows = <Widget>[];
    for (var i = 0; i < analyses.length; i += columns) {
      if (rows.isNotEmpty) rows.add(const SizedBox(height: _analysisCardSpacing));
      final rowChildren = <Widget>[];
      for (var col = 0; col < columns; col++) {
        if (col > 0) rowChildren.add(const SizedBox(width: _analysisCardSpacing));
        final index = i + col;
        rowChildren.add(Expanded(
          // An incomplete final row gets empty stretched slots rather than
          // letting its real cards grow wider to fill the row -- keeps every
          // card the same width regardless of which row it's in.
          child: index < analyses.length
              ? _AnalysisCard(analysis: analyses[index], onTap: () => _selectAnalysis(analyses[index])): const SizedBox(),
        ));
      }
      rows.add(IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: rowChildren)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
  }

  Widget _buildForm(AppPalette colors, PlotAnalysis analysis) {
    final params = _paramsState!;
    final loaded = _loadedData!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(analysis.description, style: TextStyle(fontSize: 12.5, color: colors.textSecondary)),
            const SizedBox(height: 16),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(ref.t('plots_params_title'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                    const SizedBox(height: 8),
                    PlotParamForm(
                      analysis: analysis,
                      state: params,
                      loadedData: loaded,
                      onChanged: () => setState(() {}),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerRight,
              child: ElevatedButton.icon(
                onPressed: _starting ? null: _run,
                icon: _starting
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)): const Icon(Icons.play_arrow),
                label: Text(_starting ? ref.t('plots_running'): ref.t('plots_run_button')),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Reads and decodes an analysis's own data.json, for analyses (currently
  /// just magma_mag_summary) whose real content is structured data rendered
  /// natively rather than a static image. Returns null on any read/parse
  /// failure -- the caller falls back to the plain image+log view, same as a
  /// run whose data.json genuinely doesn't have this shape.
  Map<String, dynamic>? _readDataJson(String outDir) {
    try {
      final raw = File('$outDir/data.json').readAsStringSync();
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
  }

  Widget _buildRunPanel(AppPalette colors, PlotRunState runState) {
    final previewFile = File('${runState.outDir}/preview.png');
    final hasPreview = runState.finished && runState.succeeded && previewFile.existsSync();
    // magma_mag_summary's real content is this interactive table (MIMAG +
    // genes + real sequences, per the user's own request that the static
    // report-card image be replaced, not just prettied up) -- shown ABOVE
    // the static scatter plot, which stays available for its own sake
    // (a real completeness-vs-contamination view) and so Customize/Export
    // keep working exactly as they do for every other analysis.
    final isMagSummary = runState.analysisId == 'magma_mag_summary';
    List? magRecords;
    if (isMagSummary && runState.finished && runState.succeeded) {
      magRecords = _readDataJson(runState.outDir)?['records'] as List?;
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (!runState.finished)...[
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
                Text(ref.t('plots_running'), style: TextStyle(color: colors.textSecondary)),
              ] else
                Expanded(
                  child: Text(
                    runState.succeeded ? ref.t('plots_result_success'): ref.t('plots_result_error'),
                    style: TextStyle(
                      color: runState.succeeded ? colors.statusDone: colors.statusError,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              if (runState.finished)
                TextButton.icon(
                  onPressed: _newAnalysis,
                  icon: const Icon(Icons.add),
                  label: Text(ref.t('plots_new_analysis')),
                ),
            ],
          ),
          if (magRecords != null && magRecords.isNotEmpty)...[
            const SizedBox(height: 16),
            MagSummaryTable(records: magRecords),
          ],
          // The preview is the whole point of running an analysis -- lead
          // with it, full-width, once it exists; the log (useful while
          // watching a run, less so afterward) collapses out of the way.
          if (hasPreview)...[
            const SizedBox(height: 16),
            // A thumbnail, not the export -- ggsave's real width/height/dpi
            // (what actually gets exported) are untouched; this only bounds
            // how big the on-screen preview renders, since at full intrinsic
            // size a 2000+px-wide PNG used to dominate the entire screen.
            // Tap to see it larger without leaving this screen.
            Center(
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => _showPreviewDialog(previewFile),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 420, maxWidth: 760),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.file(previewFile, fit: BoxFit.contain),
                  ),
                ),
              ),
            ),
            Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(ref.t('plots_tap_to_enlarge'), style: TextStyle(fontSize: 11, color: colors.textMuted)),
              ),
            ),
            const SizedBox(height: 16),
            _buildCustomizePanel(colors, runState),
            const SizedBox(height: 16),
            _buildExportPanel(colors, runState),
          ] else if (runState.finished && runState.succeeded)...[
            const SizedBox(height: 16),
            Text(ref.t('plots_preview_unavailable'), style: TextStyle(color: colors.textMuted, fontStyle: FontStyle.italic)),
          ],
          const SizedBox(height: 16),
          InkWell(
            onTap: () => setState(() => _showLog = !_showLog),
            child: Row(
              children: [
                Icon(_showLog ? Icons.expand_less: Icons.expand_more, size: 18, color: colors.textMuted),
                const SizedBox(width: 4),
                Text(ref.t('plots_log_title'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
              ],
            ),
          ),
          if (_showLog)...[
            const SizedBox(height: 6),
            Builder(builder: (context) {
              // Larger while a job is actually running (this is the view
              // that matters then -- a small 200px box showed almost
              // nothing of a live log) and follows the tail automatically;
              // once finished it shrinks back since the preview above is
              // the main thing to look at.
              _scrollLogToBottom();
              return Container(
                width: double.infinity,
                height: runState.finished ? 220: 380,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(8)),
                child: ListView.builder(
                  controller: _logScrollController,
                  itemCount: runState.log.length,
                  itemBuilder: (context, i) => Text(
                    runState.log[i],
                    style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: colors.textSecondary),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }

  /// Parameters + style, editable in place and replottable, without ever
  /// leaving this result screen -- the point raised directly: changing the
  /// taxonomic rank, a group's color, the background, or the font used to
  /// mean going back to the form step and starting over. Collapsed by
  /// default so a first-time "here's your result" view isn't immediately
  /// buried under a big form.
  Widget _buildCustomizePanel(AppPalette colors, PlotRunState runState) {
    final analysis = _selectedAnalysis;
    final params = _paramsState;
    final loaded = _loadedData;
    if (analysis == null || params == null || loaded == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            InkWell(
              onTap: () => setState(() => _customizeExpanded = !_customizeExpanded),
              child: Row(
                children: [
                  Icon(_customizeExpanded ? Icons.expand_less: Icons.expand_more, size: 18, color: colors.textMuted),
                  const SizedBox(width: 4),
                  Text(ref.t('plots_customize_title'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
                ],
              ),
            ),
            if (_customizeExpanded)...[
              const SizedBox(height: 12),
              Text(ref.t('plots_params_title'), style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12, color: colors.textSecondary)),
              const SizedBox(height: 8),
              PlotParamForm(analysis: analysis, state: params, loadedData: loaded, onChanged: () => setState(() {})),
              if (_styleState != null)...[
                const Divider(height: 28),
                PlotStylePanel(style: _styleState!, analysisId: analysis.id, onChanged: () => setState(() {})),
              ],
              const SizedBox(height: 16),
              Align(
                alignment: Alignment.centerRight,
                child: ElevatedButton.icon(
                  onPressed: _replotting ? null: _replot,
                  icon: _replotting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)): const Icon(Icons.refresh),
                  label: Text(_replotting ? ref.t('plots_customize_replotting'): ref.t('plots_customize_replot')),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildExportPanel(AppPalette colors, PlotRunState runState) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(ref.t('plots_export_title'), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<String>(
                    initialValue: _exportFormat,
                    decoration: InputDecoration(labelText: ref.t('plots_export_format'), isDense: true),
                    items: const [
                      DropdownMenuItem(value: 'tiff', child: Text('TIFF (600 dpi, LZW)')),
                      DropdownMenuItem(value: 'png', child: Text('PNG')),
                      DropdownMenuItem(value: 'svg', child: Text('SVG')),
                    ],
                    onChanged: (v) => setState(() => _exportFormat = v ?? 'tiff'),
                  ),
                ),
                const SizedBox(width: 12),
                SizedBox(
                  width: 100,
                  child: TextFormField(
                    controller: _dpiController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: ref.t('plots_export_dpi'), isDense: true),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: _exporting ? null: () => _export(runState),
                  icon: _exporting
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)): const Icon(Icons.file_download_outlined),
                  label: Text(_exporting ? ref.t('plots_export_running'): ref.t('plots_export_button')),
                ),
                if (_exportMessage != null)...[
                  const SizedBox(width: 12),
                  Expanded(child: Text(_exportMessage!, style: TextStyle(fontSize: 12, color: colors.textSecondary))),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One icon per analysis "shape" -- lets the grid be scanned by silhouette
/// (boxplot vs. scatter vs. network...) the same way the Hub's pipeline
/// cards are scanned by their own icons, rather than every card looking
/// identical except for its text.
IconData _analysisIcon(String analysisId) => switch (analysisId) {
      'alpha_diversity' => Icons.candlestick_chart_outlined,
      'beta_diversity' => Icons.scatter_plot_outlined,
      'taxonomic_composition' => Icons.stacked_bar_chart,
      'core_microbiome' => Icons.grid_on_outlined,
      'differential_abundance_deseq2' => Icons.compare_arrows,
      'rda_environmental_drivers' => Icons.explore_outlined,
      'cooccurrence_network' => Icons.hub_outlined,
      'indicator_species' => Icons.flag_outlined,
      'venn_diagram' => Icons.join_full_outlined,
      'upset_plot' => Icons.stacked_bar_chart_outlined,
      'sample_pca' => Icons.scatter_plot_outlined,
      'sample_distance_heatmap' => Icons.grid_on_outlined,
      'ma_plot' => Icons.blur_linear_outlined,
      'volcano_plot' => Icons.whatshot_outlined,
      'de_heatmap' => Icons.grid_view_outlined,
      'functional_enrichment' => Icons.hub_outlined,
      'de_upset' => Icons.call_split_outlined,
      _ => Icons.insights_outlined,
    };

/// Pill marking which kind of data an analysis reads, styled exactly like
/// the Hub's own category tags (see category_colors.dart's AnalysisShapeTagX).
class _ShapeTag extends ConsumerWidget {
  final String shape;
  const _ShapeTag({required this.shape});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final english = ref.watch(localeProvider).languageCode == 'en';
    final brightness = Theme.of(context).brightness;
    final style = shape.shapeTagStyle;
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: style.bg(brightness), borderRadius: BorderRadius.circular(6)),
        child: Text(
          shape.shapeTagLabel(english),
          style: TextStyle(color: style.fg(brightness), fontSize: 10.5, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class _AnalysisCard extends ConsumerWidget {
  final PlotAnalysis analysis;
  final VoidCallback onTap;
  const _AnalysisCard({required this.analysis, required this.onTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final card = Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(color: colors.primarySoft, borderRadius: BorderRadius.circular(9)),
                    child: Icon(_analysisIcon(analysis.id), size: 19, color: colors.primaryDark),
                  ),
                  if (!analysis.implemented)...[
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(6)),
                      child: Text(ref.t('coming_soon'), style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: colors.textMuted)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 10),
              Text(analysis.name, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700)),
              // What KIND of data this analysis works on -- community reads,
              // assembled MAGs, per-sample function, run QC. Carried as a tag
              // on the card (same idiom as the Hub's category/extra tags)
              // rather than by splitting the grid into headed sections, so
              // every analysis stays visible side by side in one grid.
              const SizedBox(height: 6),
              _ShapeTag(shape: analysis.inputShape),
              const SizedBox(height: 4),
              // No maxLines/ellipsis and no Expanded (that requires a
              // bounded-height parent, which this card no longer has now
              // that it sizes to its own content, see _buildAnalysesList) --
              // the full description always shows, however long.
              Text(
                analysis.description,
                style: TextStyle(fontSize: 11.5, color: colors.textSecondary, height: 1.25),
              ),
            ],
          ),
        ),
      ),
    );
    // Same de-emphasis the Hub uses for pipelines that aren't built yet
    // (hub_screen.dart's _PlaceholderCard). Still clickable, just visually
    // upfront about not having real statistics or a preview.
    return analysis.implemented ? card: Opacity(opacity: 0.65, child: card);
  }
}
