import '../theme/app_theme.dart';

class JobEntry {
  final int jobid;
  final String rule;
  final String? sample;
  RunStatus status;

  JobEntry({required this.jobid, required this.rule, this.sample, this.status = RunStatus.running});
}
