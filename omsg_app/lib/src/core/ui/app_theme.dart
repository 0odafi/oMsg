import 'package:flutter/material.dart';

import 'app_appearance.dart';

ThemeData buildAstraTheme(AppAppearanceData appearance) {
  final scheme =
      ColorScheme.fromSeed(
        seedColor: appearance.accentColor,
        brightness: Brightness.dark,
      ).copyWith(
        primary: appearance.accentColor,
        secondary: appearance.accentColorMuted,
        surface: appearance.surfaceColor,
        surfaceContainer: appearance.surfaceRaisedColor,
        outline: appearance.outlineColor,
      );

  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: appearance.scaffoldColor,
    appBarTheme: AppBarTheme(
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      backgroundColor: appearance.scaffoldColor,
    ),
    cardTheme: CardThemeData(
      color: appearance.surfaceColor,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: appearance.outlineColor),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: appearance.surfaceRaisedColor,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: appearance.outlineColor),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: appearance.outlineColor),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: appearance.accentColor, width: 1.3),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: appearance.navBarColor,
      indicatorColor: appearance.accentColor.withValues(alpha: 0.18),
      iconTheme: WidgetStateProperty.resolveWith((states) {
        final color = states.contains(WidgetState.selected)
            ? appearance.accentColor
            : scheme.onSurfaceVariant;
        return IconThemeData(color: color);
      }),
      labelTextStyle: WidgetStateProperty.resolveWith((states) {
        final color = states.contains(WidgetState.selected)
            ? appearance.accentColor
            : scheme.onSurfaceVariant;
        return TextStyle(fontWeight: FontWeight.w600, color: color);
      }),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: appearance.outlineColor),
      ),
      backgroundColor: appearance.surfaceRaisedColor,
      selectedColor: appearance.chipFillColor,
      side: BorderSide(color: appearance.outlineColor),
      labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
  );
}
