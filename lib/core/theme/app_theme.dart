import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

abstract class AppTheme {
  static bool isLight = false;

  static const _darkBg = Color(0xFF0F1123);
  static const _darkSurface = Color(0xFF171932);
  static const _darkCard = Color(0xFF1E2045);
  static const _darkCardAlt = Color(0xFF151730);
  static const _darkPrimary = Color(0xFF6C63FF);
  static const _darkPrimaryLight = Color(0xFF9D97FF);
  static const _darkAccent = Color(0xFF00D4FF);
  static const _darkGreen = Color(0xFF00E676);
  static const _darkDanger = Color(0xFFFF5252);
  static const _darkWarning = Color(0xFFFFAB00);
  static const _darkText = Color(0xFFFFFFFF);
  static const _darkTextSecondary = Color(0xFF9EA2C4);
  static const _darkDivider = Color(0xFF2A2D52);

  static const _lightBg = Color(0xFFF4F6FC);
  static const _lightSurface = Color(0xFFFFFFFF);
  static const _lightCard = Color(0xFFFFFFFF);
  static const _lightCardAlt = Color(0xFFEEF0F8);
  static const _lightPrimary = Color(0xFF584DE0);
  static const _lightAccent = Color(0xFF007E9E);
  static const _lightGreen = Color(0xFF087A49);
  static const _lightDanger = Color(0xFFC62828);
  static const _lightText = Color(0xFF1D2033);
  static const _lightTextSecondary = Color(0xFF5E6478);
  static const _lightDivider = Color(0xFFD9DEEB);

  static Color get bgDark => isLight ? _lightBg : _darkBg;
  static Color get bgSurface => isLight ? _lightSurface : _darkSurface;
  static Color get bgCard => isLight ? _lightCard : _darkCard;
  static Color get bgCardAlt => isLight ? _lightCardAlt : _darkCardAlt;
  static Color get green => isLight ? _lightGreen : _darkGreen;
  static const Color primary = _darkPrimary;
  static const Color primaryLight = _darkPrimaryLight;
  static const Color accent = _darkAccent;
  static const Color accentGreen = _darkGreen;
  static const Color danger = _darkDanger;
  static const Color warning = _darkWarning;
  static Color get textPrimary => isLight ? _lightText : _darkText;
  static Color get textSecondary =>
      isLight ? _lightTextSecondary : _darkTextSecondary;
  static Color get divider => isLight ? _lightDivider : _darkDivider;

  static const LinearGradient primaryGradient = LinearGradient(
    colors: [_darkPrimary, Color(0xFF3D5AFE)],
  );
  static const LinearGradient accentGradient = LinearGradient(
    colors: [_darkAccent, Color(0xFF0091EA)],
  );

  static LinearGradient get bgGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: isLight
        ? const [Color(0xFFF4F6FC), Color(0xFFEDEBFA)]
        : const [Color(0xFF0F1123), Color(0xFF1A0A33)],
  );

  static LinearGradient get cardGradient => LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: isLight
        ? const [Color(0xFFFFFFFF), Color(0xFFF5F6FB)]
        : const [Color(0xFF1E2045), Color(0xFF16183A)],
  );

  static ThemeData get dark {
    final base = ThemeData.dark();
    return base.copyWith(
      scaffoldBackgroundColor: _darkBg,
      colorScheme: const ColorScheme.dark(
        primary: _darkPrimary,
        secondary: _darkAccent,
        surface: _darkCard,
        error: _darkDanger,
      ),
      textTheme: GoogleFonts.poppinsTextTheme(
        base.textTheme,
      ).apply(bodyColor: _darkText, displayColor: _darkText),
      cardTheme: CardThemeData(
        color: _darkCard,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _darkPrimary,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.poppins(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _darkPrimary,
          side: const BorderSide(color: _darkPrimary, width: 1.5),
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.poppins(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _darkCardAlt,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _darkPrimary, width: 1.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: _darkPrimary.withAlpha(80)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _darkPrimary, width: 2),
        ),
        labelStyle: const TextStyle(color: _darkTextSecondary),
        prefixIconColor: _darkTextSecondary,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: _darkBg,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: GoogleFonts.poppins(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: _darkText,
        ),
        iconTheme: IconThemeData(color: _darkText),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: _darkPrimary,
        foregroundColor: Colors.white,
        elevation: 4,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: _darkSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: _darkCard,
        contentTextStyle: GoogleFonts.poppins(color: _darkText),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: const DividerThemeData(color: _darkDivider, thickness: 1),
      chipTheme: ChipThemeData(
        backgroundColor: _darkCardAlt,
        selectedColor: _darkPrimary.withAlpha(50),
        labelStyle: GoogleFonts.poppins(fontSize: 12, color: _darkText),
        side: const BorderSide(color: _darkDivider),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  static ThemeData get light {
    final base = ThemeData.light();
    return base.copyWith(
      scaffoldBackgroundColor: _lightBg,
      colorScheme: const ColorScheme.light(
        primary: _lightPrimary,
        secondary: _lightAccent,
        surface: _lightSurface,
        error: _lightDanger,
      ),
      textTheme: GoogleFonts.poppinsTextTheme(
        base.textTheme,
      ).apply(bodyColor: _lightText, displayColor: _lightText),
      cardTheme: CardThemeData(
        color: _lightCard,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: _lightPrimary,
          foregroundColor: Colors.white,
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.poppins(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: _lightPrimary,
          side: const BorderSide(color: _lightPrimary, width: 1.5),
          minimumSize: const Size(double.infinity, 48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: GoogleFonts.poppins(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: _lightCardAlt,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _lightDivider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _lightDivider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: _lightPrimary, width: 2),
        ),
        labelStyle: const TextStyle(color: _lightTextSecondary),
        prefixIconColor: _lightTextSecondary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: _lightBg,
        elevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: _lightText),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: _lightPrimary,
        foregroundColor: Colors.white,
        elevation: 4,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: _lightSurface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: _lightText,
        contentTextStyle: GoogleFonts.poppins(color: Colors.white),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
      dividerTheme: const DividerThemeData(color: _lightDivider, thickness: 1),
      chipTheme: ChipThemeData(
        backgroundColor: _lightCardAlt,
        selectedColor: _lightPrimary.withAlpha(35),
        labelStyle: GoogleFonts.poppins(fontSize: 12, color: _lightText),
        side: const BorderSide(color: _lightDivider),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      ),
    );
  }

  static BoxDecoration glassDecoration({double opacity = 0.08}) =>
      BoxDecoration(
        color: (isLight ? Colors.black : Colors.white).withAlpha(
          (opacity * 255).round(),
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: (isLight ? Colors.black : Colors.white).withAlpha(20),
        ),
      );

  static BoxDecoration gradientCardDecoration() => BoxDecoration(
    gradient: cardGradient,
    borderRadius: BorderRadius.circular(16),
    border: Border.all(color: divider),
  );
}
