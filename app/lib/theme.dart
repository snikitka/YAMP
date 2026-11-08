import 'package:flutter/material.dart';

const brandYellow = Color(0xFFFFD43B);
const brandOrange = Color(0xFFFF9E1B);

const plusGradient = LinearGradient(
  colors: [Color(0xFFD93A2B), Color(0xFFC92F84), Color(0xFF8341EF), Color(0xFF3F68F9)],
);

const uiFont = 'Segoe UI Variable Text';
const uiFontFallback = ['Segoe UI', 'Roboto', 'Noto Sans'];

const brandGradient = LinearGradient(
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
  colors: [brandYellow, brandOrange],
);

@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({required this.success, required this.warning, required this.accent});

  final Color success, warning, accent;

  @override
  StatusColors copyWith({Color? success, Color? warning, Color? accent}) => StatusColors(
        success: success ?? this.success,
        warning: warning ?? this.warning,
        accent: accent ?? this.accent,
      );

  @override
  StatusColors lerp(StatusColors? other, double t) => other == null
      ? this
      : StatusColors(
          success: Color.lerp(success, other.success, t)!,
          warning: Color.lerp(warning, other.warning, t)!,
          accent: Color.lerp(accent, other.accent, t)!,
        );
}

extension StatusColorsX on BuildContext {
  StatusColors get status => Theme.of(this).extension<StatusColors>()!;
}

ThemeData buildTheme(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  final base = ColorScheme.fromSeed(seedColor: brandYellow, brightness: brightness);
  final scheme = dark
      ? base.copyWith(
          primary: brandYellow,
          onPrimary: const Color(0xFF1A1600),
          primaryContainer: const Color(0xFF3A3000),
          onPrimaryContainer: const Color(0xFFFFE89A),
          surface: const Color(0xFF0E0E12),
          onSurface: const Color(0xFFF1F0F4),
          onSurfaceVariant: const Color(0xFFA3A1AD),
          surfaceContainerLowest: const Color(0xFF0A0A0D),
          surfaceContainerLow: const Color(0xFF16161C),
          surfaceContainer: const Color(0xFF1B1B22),
          surfaceContainerHigh: const Color(0xFF22222A),
          surfaceContainerHighest: const Color(0xFF2A2A33),
          outlineVariant: const Color(0xFF2E2E38),
          error: const Color(0xFFFF6B6B),
        )
      : base.copyWith(
          primary: const Color(0xFFF2B600),
          onPrimary: const Color(0xFF1A1600),
          primaryContainer: const Color(0xFFFFF1C2),
          onPrimaryContainer: const Color(0xFF3A2E00),
          surface: const Color(0xFFF5F5F7),
          onSurface: const Color(0xFF16161A),
          onSurfaceVariant: const Color(0xFF63616C),
          surfaceContainerLowest: Colors.white,
          surfaceContainerLow: Colors.white,
          surfaceContainer: const Color(0xFFF0F0F3),
          surfaceContainerHigh: const Color(0xFFEAEAEE),
          surfaceContainerHighest: const Color(0xFFE3E3E8),
          outlineVariant: const Color(0xFFE2E2E8),
        );

  final accent = dark ? brandYellow : const Color(0xFF8A6100);
  final theme = ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: uiFont,
    fontFamilyFallback: uiFontFallback,
    extensions: [
      StatusColors(
        success: dark ? const Color(0xFF4ADE80) : const Color(0xFF16A34A),
        warning: dark ? const Color(0xFFFBBF24) : const Color(0xFFD97706),
        accent: accent,
      ),
    ],
    visualDensity: VisualDensity.standard,
    splashFactory: InkSparkle.splashFactory,
    dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        textStyle: const TextStyle(
          fontFamily: uiFont,
          fontFamilyFallback: uiFontFallback,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: dark ? null : scheme.onSurface,
        minimumSize: const Size(0, 44),
        side: BorderSide(color: scheme.outlineVariant),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: dark ? null : scheme.onSurface,
        minimumSize: const Size(0, 40),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        selectedBackgroundColor: scheme.primary,
        selectedForegroundColor: scheme.onPrimary,
        foregroundColor: scheme.onSurface,
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    sliderTheme: SliderThemeData(
      showValueIndicator: ShowValueIndicator.onDrag,
      activeTrackColor: accent,
      thumbColor: accent,
      inactiveTrackColor: scheme.surfaceContainerHighest,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      linearTrackColor: scheme.surfaceContainerHighest,
      linearMinHeight: 6,
      borderRadius: BorderRadius.circular(3),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHigh,
      hintStyle: TextStyle(color: scheme.onSurfaceVariant),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    dialogTheme: DialogThemeData(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      backgroundColor: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll(scheme.surfaceContainerHigh),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: scheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 400),
      decoration: BoxDecoration(
        color: scheme.inverseSurface,
        borderRadius: BorderRadius.circular(8),
      ),
    ),
  );

  final text = theme.textTheme;
  return theme.copyWith(
    textTheme: text.copyWith(
      headlineSmall: text.headlineSmall?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.4),
      titleLarge: text.titleLarge?.copyWith(fontWeight: FontWeight.w700, letterSpacing: -0.2),
      titleMedium: text.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    ),
  );
}
