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

  /// This component ships compiled into the backend binary, so there is nothing
  /// on the machine to check or install (see check_python_deps in main.py).
  /// Without saying so, the row reports "installed" no matter what the user
  /// does to their system, which reads as a broken check rather than a
  /// component that was never theirs to manage.
  final bool bundled;

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
    this.bundled = false,
  });

  @override
  ConsumerState<InstallRow> createState() => _InstallRowState();
}

class _InstallRowState extends ConsumerState<InstallRow> {
  WsClient? _ws;
  final List<String> _log = [];
  final ScrollController _logScroll = ScrollController();
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

  /// Appends a log line and follows the tail, so a long install shows its
  /// latest output without the user scrolling. Following stops as soon as they
  /// scroll up to read something -- the jump back to the bottom would make the
  /// log unreadable exactly when they are trying to read it -- and resumes when
  /// they return to the end.
  void _appendLog(String line) {
    final wasAtBottom = !_logScroll.hasClients ||
        _logScroll.position.pixels >= _logScroll.position.maxScrollExtent - 24;
    setState(() => _log.add(line));
    if (!wasAtBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_logScroll.hasClients) return;
      _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
    });
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
        _appendLog((event['text'] as String? ?? '').trimRight());
      } else if (type == 'done') {
        setState(() => _running = false);
        widget.onDone();
      } else if (type == 'error') {
        setState(() => _running = false);
        _appendLog('${ref.t('error_prefix')}: ${event['text']}');
      }
    },
        // Without this the stream's error goes unhandled and only onDone fires,
        // which used to clear the spinner and restore the Install button with
        // nothing said -- the install looking untouched while it was in fact
        // still running in the backend.
        onError: (e) {
      if (!mounted) return;
      setState(() => _running = false);
      _appendLog('${ref.t('error_prefix')}: $e');
      _appendLog(ref.t('install_connection_lost'));
    }, onDone: () {
      if (!mounted) return;
      final wasRunning = _running;
      setState(() => _running = false);
      if (wasRunning) _appendLog(ref.t('install_connection_lost'));
      widget.onDone();
    });
  }

  void _cancel() {
    // Tells the backend to stop; closing the socket alone no longer does,
    // precisely so a dropped connection cannot abort an install.
    _ws?.send({'action': 'cancel'});
    _ws?.close();
    setState(() => _running = false);
    _appendLog(ref.read(localeProvider).languageCode == 'en' ? 'Cancelled.': 'Cancelado.');
  }

  @override
  void dispose() {
    // Closes this view of the install only. The job itself carries on in the
    // backend, which is what lets a reopened screen pick it back up.
    _ws?.close();
    _pathCtrl?.dispose();
    _logScroll.dispose();
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
                  Text(
                    // The caller's subtitle describes a check against the
                    // machine; when the component is compiled in, no such check
                    // happened and saying otherwise would be misleading.
                    widget.bundled ? ref.t('install_bundled_desc'): widget.subtitle,
                    style: TextStyle(color: colors.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
            if (widget.bundled)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: RunStatus.done.bg(colors),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  ref.t('install_bundled'),
                  style: TextStyle(
                      color: RunStatus.done.fg(colors), fontSize: 11, fontWeight: FontWeight.w600),
                ),
              )
            else if (!widget.installed)
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
              controller: _logScroll,
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
