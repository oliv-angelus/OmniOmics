import 'package:flutter/material.dart';

/// Theme-aware design tokens for OmniOmics, exposed as a ThemeExtension so
/// every screen can do `context.colors.textPrimary` and get the right value
/// in both light and dark mode from a single call site.
class AppPalette extends ThemeExtension<AppPalette> {
  final Color background;
  final Color surface;
  final Color surfaceAlt;
  final Color border;

  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;

  final Color primary;
  final Color primaryDark;
  final Color primarySoft;

  final Color statusQueued;
  final Color statusRunning;
  final Color statusDone;
  final Color statusError;
  final Color statusQueuedBg;
  final Color statusRunningBg;
  final Color statusDoneBg;
  final Color statusErrorBg;

  const AppPalette({
    required this.background,
    required this.surface,
    required this.surfaceAlt,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.primary,
    required this.primaryDark,
    required this.primarySoft,
    required this.statusQueued,
    required this.statusRunning,
    required this.statusDone,
    required this.statusError,
    required this.statusQueuedBg,
    required this.statusRunningBg,
    required this.statusDoneBg,
    required this.statusErrorBg,
  });

  static const light = AppPalette(
    background: Color(0xFFF7F8FA),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFEFF2F5),
    border: Color(0xFFE2E5EA),
    textPrimary: Color(0xFF1B1F24),
    textSecondary: Color(0xFF5B6470),
    textMuted: Color(0xFF8A93A0),
    primary: Color(0xFF0D9488),
    primaryDark: Color(0xFF0F766E),
    primarySoft: Color(0xFFE6F5F3),
    statusQueued: Color(0xFF94A3B8),
    statusRunning: Color(0xFF2563EB),
    statusDone: Color(0xFF16A34A),
    statusError: Color(0xFFDC2626),
    statusQueuedBg: Color(0xFFF1F4F8),
    statusRunningBg: Color(0xFFEAF1FE),
    statusDoneBg: Color(0xFFE9F7EF),
    statusErrorBg: Color(0xFFFCEBEA),
  );

  static const dark = AppPalette(
    background: Color(0xFF14171B),
    surface: Color(0xFF1C2025),
    surfaceAlt: Color(0xFF262B31),
    border: Color(0xFF343B43),
    textPrimary: Color(0xFFEDEEF0),
    textSecondary: Color(0xFFAAB2BD),
    textMuted: Color(0xFF7C8591),
    primary: Color(0xFF2DD4BF),
    primaryDark: Color(0xFF5EEAD4),
    primarySoft: Color(0xFF1B3A37),
    statusQueued: Color(0xFF94A3B8),
    statusRunning: Color(0xFF60A5FA),
    statusDone: Color(0xFF4ADE80),
    statusError: Color(0xFFF87171),
    statusQueuedBg: Color(0xFF262B31),
    statusRunningBg: Color(0xFF1E2A44),
    statusDoneBg: Color(0xFF1B3324),
    statusErrorBg: Color(0xFF3A2224),
  );

  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return AppPalette(
      background: c(background, other.background),
      surface: c(surface, other.surface),
      surfaceAlt: c(surfaceAlt, other.surfaceAlt),
      border: c(border, other.border),
      textPrimary: c(textPrimary, other.textPrimary),
      textSecondary: c(textSecondary, other.textSecondary),
      textMuted: c(textMuted, other.textMuted),
      primary: c(primary, other.primary),
      primaryDark: c(primaryDark, other.primaryDark),
      primarySoft: c(primarySoft, other.primarySoft),
      statusQueued: c(statusQueued, other.statusQueued),
      statusRunning: c(statusRunning, other.statusRunning),
      statusDone: c(statusDone, other.statusDone),
      statusError: c(statusError, other.statusError),
      statusQueuedBg: c(statusQueuedBg, other.statusQueuedBg),
      statusRunningBg: c(statusRunningBg, other.statusRunningBg),
      statusDoneBg: c(statusDoneBg, other.statusDoneBg),
      statusErrorBg: c(statusErrorBg, other.statusErrorBg),
    );
  }
}

extension PaletteX on BuildContext {
  AppPalette get colors => Theme.of(this).extension<AppPalette>()!;
}

enum RunStatus { queued, running, done, error }

extension RunStatusColors on RunStatus {
  Color fg(AppPalette p) => switch (this) {
        RunStatus.queued => p.statusQueued,
        RunStatus.running => p.statusRunning,
        RunStatus.done => p.statusDone,
        RunStatus.error => p.statusError,
      };

  Color bg(AppPalette p) => switch (this) {
        RunStatus.queued => p.statusQueuedBg,
        RunStatus.running => p.statusRunningBg,
        RunStatus.done => p.statusDoneBg,
        RunStatus.error => p.statusErrorBg,
      };
}

ThemeData _buildTheme(AppPalette p, Brightness brightness) {
  final base = ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.primary,
      brightness: brightness,
      primary: p.primary,
      surface: p.surface,
    ),
    scaffoldBackgroundColor: p.background,
    fontFamily: 'Roboto',
    extensions: [p],
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: p.textPrimary, displayColor: p.textPrimary),
    appBarTheme: AppBarTheme(
      backgroundColor: p.surface,
      foregroundColor: p.textPrimary,
      elevation: 0,
      scrolledUnderElevation: 1,
      surfaceTintColor: Colors.transparent,
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: p.border),
      ),
    ),
    dividerTheme: DividerThemeData(color: p.border, thickness: 1),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.surface,
      selectedIconTheme: IconThemeData(color: p.primaryDark),
      selectedLabelTextStyle: TextStyle(color: p.primaryDark, fontWeight: FontWeight.w600),
      unselectedIconTheme: IconThemeData(color: p.textMuted),
      unselectedLabelTextStyle: TextStyle(color: p.textMuted),
      indicatorColor: p.primarySoft,
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.primary,
        foregroundColor: Colors.white,
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.textPrimary,
        side: BorderSide(color: p.border),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.primary: Colors.white,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? p.primarySoft: p.surfaceAlt,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surfaceAlt,
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.primary, linearTrackColor: p.surfaceAlt),
  );
}

ThemeData buildLightTheme() => _buildTheme(AppPalette.light, Brightness.light);
ThemeData buildDarkTheme() => _buildTheme(AppPalette.dark, Brightness.dark);
