import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';
import '../services/system_info_provider.dart';

/// Permanent footer inside AppShell: CPU, RAM and disk, always visible.
///
/// It replaces the Resources tab rather than summarising it. That screen showed
/// three cards built from exactly this payload and nothing else, so once the
/// numbers are on every screen there is nothing left for a tab to add -- and
/// deciding how many cores to give a run is something you do *while* looking at
/// the launch form, not after navigating away from it.
class ResourceStrip extends ConsumerWidget {
  const ResourceStrip({super.key});

  /// Above this, the meter turns red. A run that pushes memory past ~80% starts
  /// risking swap, which is the only thing a glanceable meter is for -- a bar
  /// that goes red at 60% would be red most of the time and stop meaning
  /// anything.
  static const double alertFraction = 0.80;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final info = ref.watch(systemInfoProvider);

    return Container(
      height: 46,
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border(top: BorderSide(color: colors.border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          _BackendStatus(colors: colors, live: info != null),
          const Spacer(),
          if (info == null)
            // A muted line, not a spinner: this strip is always on screen, and
            // a spinner sitting in the footer of every tab reads as something
            // being wrong rather than as a reading that has not arrived yet.
            Text(
              ref.t('strip_waiting'),
              style: TextStyle(fontSize: 11.5, color: colors.textMuted),
            )
          else ...[
            _Stat(
              colors: colors,
              icon: Icons.memory,
              label: ref.t('strip_cpu'),
              value: '${info['cpu']['cores']} ${ref.t('strip_threads')}',
              fraction: _num(info['cpu']['percent']) / 100,
              trailing: '${_num(info['cpu']['percent']).round()}%',
            ),
            const SizedBox(width: 22),
            _Stat(
              colors: colors,
              icon: Icons.developer_board,
              label: ref.t('strip_ram'),
              value: '${_fmt(info['ram']['used_gb'])} / ${_fmt(info['ram']['total_gb'])} GB',
              fraction: _num(info['ram']['percent']) / 100,
              trailing: '${_num(info['ram']['percent']).round()}%',
            ),
            const SizedBox(width: 22),
            _Stat(
              colors: colors,
              icon: Icons.storage,
              label: ref.t('strip_disk'),
              // Free space is the number that decides whether a database or a
              // run fits, so it leads; the total is context.
              value: '${_fmt(info['disk']['free_gb'])} GB ${ref.t('resources_free')}',
              fraction: _diskFraction(info['disk']),
              trailing: '${_fmt(info['disk']['total_gb'])} GB',
            ),
          ],
        ],
      ),
    );
  }

  static double _num(dynamic v) => (v as num?)?.toDouble() ?? 0;

  static String _fmt(dynamic v) {
    final d = _num(v);
    return d >= 100 ? d.round().toString() : d.toStringAsFixed(1);
  }

  /// The payload carries used/total/free but no percentage for disk, unlike cpu
  /// and ram (see system_monitor.get_system_info).
  static double _diskFraction(dynamic disk) {
    final total = _num(disk['total_gb']);
    if (total <= 0) return 0;
    return _num(disk['used_gb']) / total;
  }
}

class _BackendStatus extends ConsumerWidget {
  final AppPalette colors;
  final bool live;
  const _BackendStatus({required this.colors, required this.live});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final color = live ? colors.statusDone : colors.textMuted;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Text(
          ref.t('strip_backend'),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(width: 6),
        Text(
          live ? ref.t('strip_backend_ok') : ref.t('strip_waiting'),
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: colors.textPrimary),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final AppPalette colors;
  final IconData icon;
  final String label;
  final String value;
  final double fraction;
  final String trailing;

  const _Stat({
    required this.colors,
    required this.icon,
    required this.label,
    required this.value,
    required this.fraction,
    required this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final clamped = fraction.clamp(0.0, 1.0);
    final alert = clamped >= ResourceStrip.alertFraction;
    // Tabular figures throughout: these numbers are replaced every two seconds,
    // and proportional digits make the whole row twitch sideways on each tick.
    const digits = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: colors.textMuted),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.4,
            color: colors.textMuted,
          ),
        ),
        const SizedBox(width: 7),
        Text(
          value,
          style: digits.copyWith(
              fontSize: 12, fontWeight: FontWeight.w600, color: colors.textPrimary),
        ),
        const SizedBox(width: 9),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: SizedBox(
            width: 72,
            height: 5,
            child: LinearProgressIndicator(
              value: clamped,
              backgroundColor: colors.surfaceAlt,
              valueColor: AlwaysStoppedAnimation(alert ? colors.statusError : colors.primary),
            ),
          ),
        ),
        const SizedBox(width: 9),
        Text(
          trailing,
          style: digits.copyWith(
              fontSize: 11.5,
              color: alert ? colors.statusError : colors.textSecondary,
              fontWeight: alert ? FontWeight.w600 : FontWeight.w400),
        ),
      ],
    );
  }
}
