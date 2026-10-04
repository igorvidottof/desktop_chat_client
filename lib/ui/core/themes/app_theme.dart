import 'package:flutter/material.dart';
import 'layout_tokens.dart';

ThemeData buildAppTheme() {
  final colors = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6550A3),
  ).copyWith(
    surface: Colors.white,
    surfaceContainerLowest: Colors.white,
    surfaceContainerLow: const Color(0xFFF8F9FB),
    onSurface: const Color(0xFF252A32),
    onSurfaceVariant: const Color(0xFF697381),
    outlineVariant: const Color(0xFFE4E7EC),
    secondaryContainer: const Color(0xFFE9EDF2),
    onSecondaryContainer: const Color(0xFF252A32),
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    visualDensity: VisualDensity.standard,
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLowest,
      contentPadding: const EdgeInsets.all(LayoutTokens.gap),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LayoutTokens.radius),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(LayoutTokens.radius),
        borderSide: BorderSide(color: colors.primary, width: 2),
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      selectedColor: colors.onSecondaryContainer,
      selectedTileColor: colors.secondaryContainer,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(LayoutTokens.radius),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        elevation: 0,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
