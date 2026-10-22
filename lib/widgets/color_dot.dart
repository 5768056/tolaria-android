import 'package:flutter/material.dart';

/// Parse `#RRGGBB` into a colour, or null when the value is not hex.
///
/// Tolaria's view and type definitions store a colour either as a named accent
/// key (`blue`, `amber`) or as hex. The phone can only render hex; named keys
/// fall back to the entry's icon, which is why every caller keeps an icon
/// around.
Color? parseHexColor(String? value) {
  if (value == null) return null;
  final hex = value.replaceAll('#', '').trim();
  if (hex.length != 6) return null;
  final parsed = int.tryParse(hex, radix: 16);
  return parsed == null ? null : Color(0xFF000000 | parsed);
}

/// A small coloured dot, or [icon] when the sidebar entry has no hex colour.
class ColorDot extends StatelessWidget {
  const ColorDot({super.key, required this.color, required this.icon});

  final String? color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final parsed = parseHexColor(color);
    if (parsed == null) return Icon(icon, size: 20);
    return SizedBox(
      width: 24,
      height: 24,
      child: Center(
        child: Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(color: parsed, shape: BoxShape.circle),
        ),
      ),
    );
  }
}
