import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../services/ws_client.dart';

class InstallOption {
  final String id;
  final String name;
  final String description;
  const InstallOption({required this.id, required this.name, required this.description});
}

/// One dependency check/install row (Conda, Snakemake, Python deps,...), shared
/// between the first-run DependencyGateScreen and the Settings screen so the
/// same install flow works from either entry point.
///
/// When [options] is given (e.g. Miniforge/Miniconda/Anaconda for conda), the
/// user picks one before installing and its `id` is sent as `distribution` in
/// the initial WS payload.
class InstallRow extends ConsumerStatefulWidget {
  final String title;
  final String subtitle;
  final bool installed;
  final String wsPath;
  final Map<String, dynamic>? initialPayload;
  final List<InstallOption>? options;
  final VoidCallback onDone;

  /// The backend reports an install of this component already in flight (see
  /// /api/setup/status -> installs). The row attaches to it on mount instead of
  /// offering a button for work that is already happening.
  final bool alreadyRunning;

  /// When set, the row offers an editable destination directory, sent as
  /// `install_path`. Only conda needs this -- everything else installs into a
  /// location conda itself decides.
  final String? defaultPath;

  const InstallRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.installed,
    required this.wsPath,
    required this.onDone,
    this.initialPayload,
    this.options,
    this.alreadyRunning = false,
    this.defaultPath,
  });

  @override
  ConsumerState<InstallRow> createState() => _InstallRowState();
}

class _InstallRowState extends ConsumerState<InstallRow> {
  WsClient? _ws;
  final List<String> _log = [];
  bool _running = false;
  bool _expanded = false;
  InstallOption? _selectedOption;
  TextEditingController? _pathCtrl;

  @override
  void initState() {
    super.initState();
    if (widget.options != null && widget.options!.isNotEmpty) {
      _selectedOption = widget.options!.first;
    }
    if (widget.defaultPath != null) {
      _pathCtrl = TextEditingController(text: widget.defaultPath);
    }
    // Attaching is safe even though it uses the same call as starting: the
    // backend returns the running job rather than spawning a second one, and
    // replays its log from the beginning.
    if (widget.alreadyRunning && !widget.installed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _install(reattach: true);
      });
    }
  }

  void _install({bool reattach = false}) {
    final api = ref.read(apiClientProvider);
    final url = api.wsUrl(widget.wsPath);
    setState(() {
      _running = true;
      _expanded = true;
      _log.clear();
      if (reattach) _log.add(ref.t('install_reattached'));
    });
    final ws = WsClient.connect(url);
    _ws = ws;
    final payload = {...?widget.initialPayload};
    if (_selectedOption != null) payload['distribution'] = _selectedOption!.id;
    final path = _pathCtrl?.text.trim();
    if (path != null && path.isNotEmpty) payload['install_path'] = path;
    ws.send(payload);
    ws.events.listen((event) {
      final type = event['type'];
      if (type == 'log' || type == 'progress') {
        setState(() => _log.add((event['text'] as String? ?? '').trimRight()));
      } else if (type == 'done') {
        setState(() => _running = false);
        widget.onDone();
      } else if (type == 'error') {
        setState(() {
          _running = false;
          _log.add('${ref.t('error_prefix')}: ${event['text']}');
        });
      }
    },
        // Without this the stream's error goes unhandled and only onDone fires,
        // which used to clear the spinner and restore the Install button with
        // nothing said -- the install looking untouched while it was in fact
        // still running in the backend.
        onError: (e) {
      if (!mounted) return;
      setState(() {
        _running = false;
        _log.add('${ref.t('error_prefix')}: $e');
        _log.add(ref.t('install_connection_lost'));
      });
    }, onDone: () {
      if (!mounted) return;
      setState(() {
        if (_running) _log.add(ref.t('install_connection_lost'));
        _running = false;
      });
      widget.onDone();
    });
  }

  void _cancel() {
    // Tells the backend to stop; closing the socket alone no longer does,
    // precisely so a dropped connection cannot abort an install.
    _ws?.send({'action': 'cancel'});
    _ws?.close();
    setState(() {
      _running = false;
      _log.add(ref.read(localeProvider).languageCode == 'en' ? 'Cancelled.': 'Cancelado.');
    });
  }

  @override
  void dispose() {
    // Closes this view of the install only. The job itself carries on in the
    // backend, which is what lets a reopened screen pick it back up.
    _ws?.close();
    _pathCtrl?.dispose();
    super.dispose();
  }

  Future<void> _pickPath() async {
    final path = await getDirectoryPath();
    if (path == null || _pathCtrl == null) return;
    // The picker returns an existing directory, but the conda installers refuse
    // a target that already exists, so the chosen folder becomes the parent and
    // conda gets a new subdirectory inside it.
    setState(() => _pathCtrl!.text = '$path/miniforge3');
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final status = widget.installed ? RunStatus.done: RunStatus.queued;
    final hasOptions = widget.options != null && widget.options!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: status.fg(colors), shape: BoxShape.circle),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                  Text(widget.subtitle, style: TextStyle(color: colors.textSecondary, fontSize: 13)),
                ],
              ),
            ),
            if (!widget.installed)
              _running
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                        const SizedBox(width: 8),
                        TextButton(onPressed: _cancel, child: Text(ref.t('cancel'))),
                      ],
                    ): OutlinedButton(onPressed: _install, child: Text(ref.t('install'))),
          ],
        ),
        if (_pathCtrl != null && !widget.installed && !_running)...[
          const SizedBox(height: 10),
          Text(ref.t('install_location'),
              style: TextStyle(fontSize: 11.5, color: colors.textSecondary)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _pathCtrl,
                  style: const TextStyle(fontSize: 12.5, fontFamily: 'monospace'),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: ref.t('install_location_hint'),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(6)),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                icon: const Icon(Icons.folder_open, size: 16),
                label: Text(ref.t('install_choose_folder')),
                onPressed: _pickPath,
              ),
            ],
          ),
        ],
        if (hasOptions && !widget.installed && !_running)...[
          const SizedBox(height: 8),...widget.options!.map((opt) => RadioListTile<InstallOption>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: opt,
                groupValue: _selectedOption,
                onChanged: (v) => setState(() => _selectedOption = v),
                title: Text(opt.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                subtitle: Text(opt.description, style: const TextStyle(fontSize: 11.5)),
              )),
        ],
        if (_expanded && _log.isNotEmpty)...[
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            height: 140,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(8)),
            child: ListView.builder(
              itemCount: _log.length,
              itemBuilder: (context, i) => Text(
                _log[i],
                style: TextStyle(fontFamily: 'monospace', fontSize: 11.5, color: colors.textSecondary),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
