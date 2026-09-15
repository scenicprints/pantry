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
      onSurfaceVariant: kMuted,
      outline: kBorder,
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
    datePickerTheme: _datePickerTheme(),
  );
}

// The expiration-date calendar. This is themed explicitly rather than left to
// Material's defaults because it once shipped with a *dark* ColorScheme whose
// surface was overridden to the app's near-white card — white day numbers on a
// white dialog, so no date could be read or picked. Every foreground colour
// below is stated against a known background for that reason.
DatePickerThemeData _datePickerTheme() {
  Color dayFg(Set<WidgetState> st) {
    if (st.contains(WidgetState.disabled)) {
      return kFaint;
    }
    return st.contains(WidgetState.selected) ? Colors.white : kInk;
  }

  Color? daySelectedBg(Set<WidgetState> st) =>
      st.contains(WidgetState.selected) ? kAccent : null;

  return DatePickerThemeData(
    backgroundColor: kCard,
    surfaceTintColor: Colors.transparent,
    headerBackgroundColor: kAccent,
    headerForegroundColor: Colors.white,
    dividerColor: kBorder,
    weekdayStyle: mono(size: 12, weight: FontWeight.w600, color: kMuted),
    dayStyle: mono(size: 13),
    dayForegroundColor: WidgetStateProperty.resolveWith(dayFg),
    dayBackgroundColor: WidgetStateProperty.resolveWith(daySelectedBg),
    todayForegroundColor: WidgetStateProperty.resolveWith(
        (Set<WidgetState> st) =>
            st.contains(WidgetState.selected) ? Colors.white : kAccent),
    todayBackgroundColor: WidgetStateProperty.resolveWith(daySelectedBg),
    todayBorder: const BorderSide(color: kAccent, width: 1.4),
    yearForegroundColor: WidgetStateProperty.resolveWith(dayFg),
    yearBackgroundColor: WidgetStateProperty.resolveWith(daySelectedBg),
    cancelButtonStyle: TextButton.styleFrom(foregroundColor: kMuted),
    confirmButtonStyle: TextButton.styleFrom(foregroundColor: kAccent),
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

/// Cap a phone-shaped layout at a readable column and centre it on the page
/// background, so a tablet shows deliberate margins instead of a pantry row
/// stretched across 1100px. Below [maxWidth] it does nothing.
///
/// Applied per screen, never app-wide: cooking mode and the measuring sheet
/// want the whole tablet, and an app-wide cap would quietly deny it to them.
Widget readableColumn(Widget child, {double maxWidth = 640}) {
  return LayoutBuilder(
    builder: (BuildContext context, BoxConstraints c) {
      if (c.maxWidth <= maxWidth) {
        return child;
      }
      return ColoredBox(
        color: kBg,
        child: Center(
          child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: maxWidth), child: child),
        ),
      );
    },
  );
}

/// Side padding that turns into a centred column once the screen is wider
/// than a phone. Same effect as [readableColumn] but as padding, for the
/// list-bodied screens where wrapping the ListView would cost a layer.
EdgeInsets pagePadding(
  BuildContext context, {
  double top = 0,
  double bottom = 0,
  double side = 20,
  double maxWidth = 640,
}) {
  final double w = MediaQuery.sizeOf(context).width;
  final double gutter = w > maxWidth + side * 2 ? (w - maxWidth) / 2 : side;
  return EdgeInsets.fromLTRB(gutter, top, gutter, bottom);
}
