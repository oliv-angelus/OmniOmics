import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers.dart';
import '../l10n/app_strings.dart';
import '../theme/app_theme.dart';

/// Language (PT/EN) + theme (light/dark) toggles, shared between the
/// DependencyGateScreen (first thing shown on launch) and AppShell's top bar
/// -- these controls should work identically before and after the gate.
class LanguageToggle extends ConsumerWidget {
  const LanguageToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.colors;
    final locale = ref.watch(localeProvider);
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: colors.surfaceAlt, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _LangButton(label: 'PT', selected: locale.languageCode == 'pt', onTap: () => ref.read(localeProvider.notifier).state = const Locale('pt')),
          _LangButton(label: 'EN', selected: locale.languageCode == 'en', onTap: () => ref.read(localeProvider.notifier).state = const Locale('en')),
        ],
      ),
    );
  }
}

class _LangButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _LangButton({required this.label, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? colors.surface: Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? colors.primaryDark: colors.textMuted,
          ),
        ),
      ),
    );
  }
}

class ThemeToggle extends ConsumerWidget {
  const ThemeToggle({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeModeProvider);
    final isDark = mode == ThemeMode.dark;
    return IconButton(
      icon: Icon(isDark ? Icons.dark_mode: Icons.light_mode_outlined),
      tooltip: isDark ? ref.t('dark'): ref.t('light'),
      onPressed: () => ref.read(themeModeProvider.notifier).state = isDark ? ThemeMode.light: ThemeMode.dark,
    );
  }
}
