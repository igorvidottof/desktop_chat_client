import 'package:flutter/material.dart';

/// Identidade visual local enquanto a aplicação não carrega fotos de perfil.
class InitialAvatar extends StatelessWidget {
  const InitialAvatar({super.key, required this.name, this.radius = 20});

  final String name;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final label = name.trim();
    final initial = label.isEmpty ? '?' : label.characters.first.toUpperCase();
    const palette = [
      Color(0xFF08658A),
      Color(0xFF7050B5),
      Color(0xFFAB4E30),
      Color(0xFF237564),
    ];
    final index = label.runes.fold<int>(0, (sum, rune) => sum + rune);
    final color = palette[index % palette.length];
    return ExcludeSemantics(
      child: CircleAvatar(
        radius: radius,
        backgroundColor: color.withValues(alpha: .09),
        foregroundColor: color,
        child: Text(
          initial,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
