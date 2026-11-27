import 'package:flutter/material.dart';

/// Shared light interface tokens. Camera imagery and data-status colors are separate roles.
abstract final class LabStyle {
  static const canvas = Color(0xfff2f4f8);
  static const surface = Colors.white;
  static const ink = Color(0xff151c2b);
  static const secondary = Color(0xff586479);
  static const line = Color(0xffe2e7ef);
  static const blue = Color(0xff2454d6);
  static const blueWash = Color(0xffeaf0ff);
  static const violet = Color(0xff6550ac);
  static const violetWash = Color(0xfff0ecfb);
  static const amber = Color(0xff87520c);
  static const amberWash = Color(0xfffff1d8);
  static const red = Color(0xffa83147);
  static const redWash = Color(0xffffebee);
  static const green = Color(0xff11745e);
  static const greenWash = Color(0xffe5f6ef);
  static const radius = 22.0;
  static const gap = 16.0;
  static const chartSeries = [
    blue,
    Color(0xff0a887a),
    violet,
    Color(0xffb25d18),
    red,
    Color(0xff577927),
    Color(0xff36708f),
    Color(0xff98438d),
  ];
  static const number = TextStyle(fontFeatures: [FontFeature.tabularFigures()]);
  static const eyebrow = TextStyle(
    fontSize: 11,
    letterSpacing: 1.45,
    fontWeight: FontWeight.w700,
    color: blue,
  );

  static ThemeData theme({String? fontFamily}) {
    final base = ThemeData(
      useMaterial3: true,
      fontFamily: fontFamily,
      visualDensity: VisualDensity.standard,
      scaffoldBackgroundColor: canvas,
      colorScheme: const ColorScheme.light(
        primary: blue,
        onPrimary: Colors.white,
        primaryContainer: blueWash,
        onPrimaryContainer: ink,
        secondary: violet,
        secondaryContainer: violetWash,
        onSecondaryContainer: ink,
        tertiary: green,
        error: red,
        errorContainer: redWash,
        surface: surface,
        onSurface: ink,
        onSurfaceVariant: secondary,
        outline: Color(0xff78859b),
        outlineVariant: line,
      ),
      dividerColor: line,
      appBarTheme: const AppBarTheme(
        backgroundColor: canvas,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        titleSpacing: 12,
        titleTextStyle: TextStyle(
          fontSize: 17,
          fontWeight: FontWeight.w700,
          color: ink,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        elevation: 0,
        margin: const EdgeInsets.only(bottom: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 46),
          textStyle: TextStyle(
            fontFamily: fontFamily,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          backgroundColor: surface,
          side: const BorderSide(color: line),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(13),
          ),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        iconColor: secondary,
        textColor: ink,
      ),
    );
    return base.copyWith(
      appBarTheme: base.appBarTheme.copyWith(
        titleTextStyle: base.appBarTheme.titleTextStyle?.copyWith(
          fontFamily: fontFamily,
        ),
      ),
      textTheme: base.textTheme
          .apply(bodyColor: ink, displayColor: ink)
          .copyWith(
            headlineLarge: TextStyle(
              fontFamily: fontFamily,
              fontSize: 34,
              height: 1.12,
              letterSpacing: -.7,
              fontWeight: FontWeight.w800,
              color: ink,
            ),
            titleLarge: TextStyle(
              fontFamily: fontFamily,
              fontSize: 21,
              height: 1.3,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
            titleMedium: TextStyle(
              fontFamily: fontFamily,
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
            bodyMedium: TextStyle(
              fontFamily: fontFamily,
              fontSize: 14,
              height: 1.48,
              color: ink,
            ),
            bodySmall: TextStyle(
              fontFamily: fontFamily,
              fontSize: 12,
              height: 1.4,
              color: secondary,
            ),
          ),
    );
  }
}

class LabBadge extends StatelessWidget {
  const LabBadge(
    this.label, {
    super.key,
    this.color = LabStyle.blue,
    this.background = LabStyle.blueWash,
    this.icon,
  });
  final String label;
  final Color color, background;
  final IconData? icon;
  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    ),
  );
}
