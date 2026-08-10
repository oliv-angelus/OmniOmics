import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// Lazily-expanding folder/file browser rooted at [rootPath] -- reads the
/// local filesystem directly (dart:io), no backend round-trip needed since
/// this is a native desktop app running on the same machine as the pipeline.
/// Keeps a listing cache keyed by path so refresh can re-read only the
/// folders the user already has open, without collapsing the tree.
class ResultsFileTree extends StatefulWidget {
  final String rootPath;
  final String missingLabel;
  final String emptyLabel;
  final String nodeEmptyLabel;
  final String openWithTooltip;
  final String openWithDialogTitle;
  final String openWithNoneFound;
  final String openWithCustomLabel;
  final String openWithCustomHint;
  final String openWithOpenButton;
  final String openErrorPrefix;
  final String cancelLabel;
  const ResultsFileTree({
    super.key,
    required this.rootPath,
    required this.missingLabel,
    required this.emptyLabel,
    required this.nodeEmptyLabel,
    required this.openWithTooltip,
    required this.openWithDialogTitle,
    required this.openWithNoneFound,
    required this.openWithCustomLabel,
    required this.openWithCustomHint,
    required this.openWithOpenButton,
    required this.openErrorPrefix,
    required this.cancelLabel,
  });

  @override
  State<ResultsFileTree> createState() => ResultsFileTreeState();
}

class ResultsFileTreeState extends State<ResultsFileTree> {
  final Map<String, List<FileSystemEntity>> _cache = {};
  final Set<String> _expanded = {};
  bool _rootMissing = false;

  @override
  void initState() {
    super.initState();
    _load(widget.rootPath);
  }

  @override
  void didUpdateWidget(covariant ResultsFileTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.rootPath != widget.rootPath) {
      _cache.clear();
      _expanded.clear();
      _rootMissing = false;
      _load(widget.rootPath);
    }
  }

  Future<void> _load(String path) async {
    final dir = Directory(path);
    if (!await dir.exists()) {
      if (mounted) setState(() => _rootMissing = path == widget.rootPath ? true: _rootMissing);
      return;
    }
    try {
      final entries = await dir.list.toList();
      entries.sort((a, b) {
        final aDir = a is Directory;
        final bDir = b is Directory;
        if (aDir != bDir) return aDir ? -1: 1;
        return a.path.toLowerCase().compareTo(b.path.toLowerCase());
      });
      if (mounted) {
        setState(() {
          _cache[path] = entries;
          if (path == widget.rootPath) _rootMissing = false;
        });
      }
    } catch (_) {
      // Permission errors etc. -- leave that node's children empty.
    }
  }

  /// Re-reads the root and every currently-expanded folder, preserving which
  /// nodes are open -- called on manual refresh and while a run is "running".
  Future<void> refresh() async {
    await _load(widget.rootPath);
    for (final path in _expanded.toList()) {
      await _load(path);
    }
  }

  void toggleExpand(String path) {
    setState(() {
      if (_expanded.contains(path)) {
        _expanded.remove(path);
      } else {
        _expanded.add(path);
        if (!_cache.containsKey(path)) _load(path);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    if (_rootMissing) {
      return Center(
        child: Text(widget.missingLabel, style: TextStyle(color: colors.textMuted)),
      );
    }
    final rootEntries = _cache[widget.rootPath];
    if (rootEntries == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (rootEntries.isEmpty) {
      return Center(child: Text(widget.emptyLabel, style: TextStyle(color: colors.textMuted)));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: rootEntries.map((e) => _Node(entry: e, depth: 0, tree: this)).toList(),
    );
  }
}

/// GUI editors/viewers to offer in "Open with...", filtered down to whichever
/// are actually installed (checked via `which`) -- covers plain text editors
/// and LibreOffice for tabular files (.tsv/.csv), matching what the user
/// asked for. A free-text field in the dialog covers anything not listed.
class _KnownApp {
  final String label;
  final String binary;
  const _KnownApp(this.label, this.binary);
}

const _kKnownApps = [
  _KnownApp('GNOME Text Editor', 'gnome-text-editor'),
  _KnownApp('gedit', 'gedit'),
  _KnownApp('Kate', 'kate'),
  _KnownApp('Mousepad', 'mousepad'),
  _KnownApp('Xed', 'xed'),
  _KnownApp('FeatherPad', 'featherpad'),
  _KnownApp('LibreOffice', 'libreoffice'),
  _KnownApp('Visual Studio Code', 'code'),
];

Future<List<_KnownApp>> _detectInstalledApps async {
  final checks = await Future.wait(_kKnownApps.map((app) async {
    try {
      final res = await Process.run('which', [app.binary]);
      return res.exitCode == 0 ? app: null;
    } catch (_) {
      return null;
    }
  }));
  return checks.whereType<_KnownApp>().toList();
}

/// Opens with the system's default association for this file type --
/// `xdg-open` is the standard cross-desktop-environment way to do that on
/// Linux, and respects whatever the user has already configured (changeable
/// via their file manager's own "Open With -> set as default").
Future<void> _openWithDefault(BuildContext context, String path, String errorPrefix) async {
  try {
    await Process.start('xdg-open', [path], mode: ProcessStartMode.detached);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$errorPrefix: $e')));
    }
  }
}

Future<void> _showOpenWithDialog(BuildContext context, String path, ResultsFileTree cfg) async {
  final apps = await _detectInstalledApps;
  if (!context.mounted) return;

  final customController = TextEditingController();
  final chosen = await showDialog<String>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(cfg.openWithDialogTitle),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (apps.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(cfg.openWithNoneFound, style: const TextStyle(fontSize: 12.5)),
              )
            else...apps.map((app) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.open_in_new, size: 18),
                    title: Text(app.label, style: const TextStyle(fontSize: 13)),
                    onTap: () => Navigator.of(dialogContext).pop(app.binary),
                  )),
            const Divider(height: 20),
            Text(cfg.openWithCustomLabel, style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
            const SizedBox(height: 6),
            TextField(
              controller: customController,
              decoration: InputDecoration(isDense: true, hintText: cfg.openWithCustomHint),
              onSubmitted: (v) => Navigator.of(dialogContext).pop(v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(dialogContext).pop, child: Text(cfg.cancelLabel)),
        ElevatedButton(
          onPressed: () => Navigator.of(dialogContext).pop(customController.text),
          child: Text(cfg.openWithOpenButton),
        ),
      ],
    ),
  );
  customController.dispose();

  final command = chosen?.trim();
  if (command == null || command.isEmpty) return;
  try {
    await Process.start(command, [path], mode: ProcessStartMode.detached);
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${cfg.openErrorPrefix}: $e')));
    }
  }
}

class _Node extends StatelessWidget {
  final FileSystemEntity entry;
  final int depth;
  final ResultsFileTreeState tree;
  const _Node({required this.entry, required this.depth, required this.tree});

  String get _name => entry.path.split(Platform.pathSeparator).last;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final isDir = entry is Directory;

    if (!isDir) {
      return InkWell(
        onTap: () => _openWithDefault(context, entry.path, tree.widget.openErrorPrefix),
        child: Padding(
          padding: EdgeInsets.only(left: 16.0 * depth + 16, top: 2, bottom: 2, right: 4),
          child: Row(
            children: [
              Icon(Icons.insert_drive_file_outlined, size: 16, color: colors.textMuted),
              const SizedBox(width: 8),
              Expanded(child: Text(_name, style: const TextStyle(fontSize: 12.5), overflow: TextOverflow.ellipsis)),
              _FileSize(path: entry.path),
              const SizedBox(width: 4),
              InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: () => _showOpenWithDialog(context, entry.path, tree.widget),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Tooltip(
                    message: tree.widget.openWithTooltip,
                    child: Icon(Icons.more_vert, size: 15, color: colors.textMuted),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final expanded = tree._expanded.contains(entry.path);
    final children = tree._cache[entry.path];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => tree.toggleExpand(entry.path),
          child: Padding(
            padding: EdgeInsets.only(left: 16.0 * depth + 8, top: 4, bottom: 4, right: 8),
            child: Row(
              children: [
                Icon(expanded ? Icons.expand_more: Icons.chevron_right, size: 16, color: colors.textMuted),
                Icon(Icons.folder_outlined, size: 16, color: colors.primaryDark),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_name,
                      style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
        if (expanded)
          children == null
              ? Padding(
                  padding: EdgeInsets.only(left: 16.0 * (depth + 1) + 16),
                  child: const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
                ): children.isEmpty
                  ? Padding(
                      padding: EdgeInsets.only(left: 16.0 * (depth + 1) + 16),
                      child: Text(tree.widget.nodeEmptyLabel,
                          style: TextStyle(fontSize: 11.5, color: colors.textMuted, fontStyle: FontStyle.italic)),
                    ): Column(
                      children: children.map((e) => _Node(entry: e, depth: depth + 1, tree: tree)).toList(),
                    ),
      ],
    );
  }
}

class _FileSize extends StatelessWidget {
  final String path;
  const _FileSize({required this.path});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return FutureBuilder<int>(
      future: File(path).length.catchError((_) => 0),
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        if (bytes == null) return const SizedBox.shrink;
        return Text(_formatBytes(bytes), style: TextStyle(fontSize: 11, color: colors.textMuted));
      },
    );
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
