import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

// ═══════════════════════════════════════════════════════════════════════
// WARM EDITORIAL THEME — a well-designed cookbook, not a sterile utility.
// Shared palette + type across the whole app (pantry + chef).
// ═══════════════════════════════════════════════════════════════════════

const Color kBg = Color(0xFFF2EEE4); // warm bone background
const Color kCard = Color(0xFFFBF9F3); // near-white card surface
const Color kInset = Color(0xFFEDE7D8); // inset fill (macro boxes, fields, tracks)
const Color kBorder = Color(0xFFD8D1C0); // hairline divider
const Color kAccent = Color(0xFFB4462F); // clay red — buttons, badges, numbers
const Color kWarn = Color(0xFFC87A34); // ember/amber — expiring flags, timers
const Color kOlive = Color(0xFF5E6647); // olive — macro/data text
const Color kDanger = Color(0xFFA83E2B); // deep brick red — destructive
const Color kInk = Color(0xFF23201A); // primary text
const Color kMuted = Color(0xFF8A8172); // secondary text
const Color kFaint = Color(0xFFA89F8C); // faint text / placeholders

ThemeData buildPantryTheme() {
  final ThemeData base = ThemeData(
    useMaterial3: true,
    brightness: Brightness.light,
    scaffoldBackgroundColor: kBg,
    colorScheme: const ColorScheme.light(
      primary: kAccent,
      onPrimary: Colors.white,
      surface: kCard,
      onSurface: kInk,
      secondary: kOlive,
    ),
  );
  return base.copyWith(
    textTheme: GoogleFonts.interTextTheme(base.textTheme)
        .apply(bodyColor: kInk, displayColor: kInk),
    appBarTheme: const AppBarTheme(
      backgroundColor: kBg,
      foregroundColor: kInk,
      elevation: 0,
      surfaceTintColor: Colors.transparent,
    ),
    snackBarTheme: const SnackBarThemeData(
      backgroundColor: kInk,
      contentTextStyle: TextStyle(color: kCard),
      behavior: SnackBarBehavior.floating,
    ),
  );
}

/// Fraunces serif — meal titles, step numbers, display headings.
TextStyle serif({
  double size = 20,
  FontWeight weight = FontWeight.w600,
  Color color = kInk,
  double height = 1.15,
  FontStyle style = FontStyle.normal,
}) =>
    GoogleFonts.fraunces(
        fontSize: size,
        fontWeight: weight,
        color: color,
        height: height,
        fontStyle: style);

/// IBM Plex Mono — amounts, macros, prices, small data.
TextStyle mono({
  double size = 12,
  FontWeight weight = FontWeight.w500,
  Color color = kInk,
  double spacing = 0,
}) =>
    GoogleFonts.ibmPlexMono(
        fontSize: size, fontWeight: weight, color: color, letterSpacing: spacing);

/// Small-caps mono section label.
TextStyle labelCaps({Color color = kMuted}) => GoogleFonts.ibmPlexMono(
    fontSize: 11, fontWeight: FontWeight.w600, color: color, letterSpacing: 1.4);
