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

  const InstallRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.installed,
    required this.wsPath,
    required this.onDone,
    this.initialPayload,
    this.options,
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

  @override
  void initState() {
    super.initState();
    if (widget.options != null && widget.options!.isNotEmpty) {
      _selectedOption = widget.options!.first;
    }
  }

  void _install() {
    final api = ref.read(apiClientProvider);
    final url = api.wsUrl(widget.wsPath);
    setState(() {
      _running = true;
      _expanded = true;
      _log.clear();
    });
    final ws = WsClient.connect(url);
    _ws = ws;
    final payload = {...?widget.initialPayload};
    if (_selectedOption != null) payload['distribution'] = _selectedOption!.id;
    ws.send(payload);
    ws.events.listen((event) {
      final type = event['type'];
      if (type == 'log') {
        setState(() => _log.add((event['text'] as String).trimRight()));
      } else if (type == 'done') {
        setState(() => _running = false);
        widget.onDone();
      } else if (type == 'error') {
        setState(() {
          _running = false;
          _log.add('${ref.t('error_prefix')}: ${event['text']}');
        });
      }
    }, onDone: () {
      if (mounted) setState(() => _running = false);
    });
  }

  void _cancel() {
    _ws?.close();
    setState(() {
      _running = false;
      _log.add(ref.read(localeProvider).languageCode == 'en' ? 'Cancelled.': 'Cancelado.');
    });
  }

  @override
  void dispose() {
    _ws?.close();
    super.dispose();
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
