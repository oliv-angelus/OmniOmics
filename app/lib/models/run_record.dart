class RunRecord {
  final String id;
  /// Human label, distinct per run (auto-generated, renameable) -- separate
  /// from pipelineName, which is the same for every run of that pipeline and
  /// on its own doesn't tell two runs apart in the list. Deletion and every
  /// other backend lookup key off [id], never off this, so a duplicate or
  /// edited name can't cause the wrong run to be matched/deleted.
  final String name;
  final String pipelineId;
  final String pipelineName;
  final String outputDir;
  final String configPath;
  final int cores;
  final double startedAt;
  final double? finishedAt;
  final String status; // running | done | error | stopped
  final int? exitCode;
  /// Whether the run's output folder is still on disk, checked server-side on
  /// every listing (see main.py's api_list_runs). A folder can vanish without
  /// the app knowing -- deleted in a file manager, an external drive
  /// unmounted -- and the Results list would otherwise keep offering an entry
  /// that opens to nothing.
  final bool outputExists;

  RunRecord({
    required this.id,
    required this.name,
    required this.pipelineId,
    required this.pipelineName,
    required this.outputDir,
    required this.configPath,
    required this.cores,
    required this.startedAt,
    required this.finishedAt,
    required this.status,
    required this.exitCode,
    this.outputExists = true,
  });

  bool get isRunning => status == 'running';
  bool get isMissing => !outputExists;

  DateTime get startedAtDate => DateTime.fromMillisecondsSinceEpoch((startedAt * 1000).round());

  factory RunRecord.fromJson(Map<String, dynamic> json) => RunRecord(
        id: json['id'] as String,
        // Records created before this field existed simply won't have it --
        // fall back to a short id-based label instead of an empty string.
        name: (json['name'] as String?)?.trim().isNotEmpty == true
            ? json['name'] as String: 'run-${(json['id'] as String).substring(0, 6)}',
        pipelineId: json['pipeline_id'] as String,
        pipelineName: json['pipeline_name'] as String? ?? json['pipeline_id'] as String,
        outputDir: json['output_dir'] as String? ?? '',
        configPath: json['config_path'] as String? ?? '',
        cores: (json['cores'] as num?)?.toInt() ?? 0,
        startedAt: (json['started_at'] as num?)?.toDouble() ?? 0,
        finishedAt: (json['finished_at'] as num?)?.toDouble(),
        status: json['status'] as String? ?? 'running',
        exitCode: (json['exit_code'] as num?)?.toInt(),
        // Absent on records from an older backend: assume present rather than
        // flagging every run as missing.
        outputExists: json['output_exists'] as bool? ?? true,
      );
}
