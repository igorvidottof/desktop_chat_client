import 'package:flutter/material.dart';
import 'layout_tokens.dart';

ThemeData buildAppTheme() {
  final colors = ColorScheme.fromSeed(
    seedColor: const Color.fromARGB(255, 11, 16, 161),
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
    appBarTheme: AppBarTheme(
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
    ),
  );
}
