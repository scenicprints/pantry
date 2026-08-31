import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pantry/theme.dart';

// The expiration calendar once shipped with a ColorScheme.dark override whose
// surface was set to the app's near-white card: white day numbers on a white
// dialog, so no expiration date could be read or tapped. These tests pin the
// contrast so that can't come back silently.

/// Perceived lightness, 0 (black) → 1 (white).
double _lum(Color c) => c.computeLuminance();

/// How far apart two colours read on screen. The broken build scored ~0.
double _contrast(Color a, Color b) {
  final double l1 = _lum(a), l2 = _lum(b);
  final double hi = l1 > l2 ? l1 : l2, lo = l1 > l2 ? l2 : l1;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  // google_fonts reads the asset manifest when the theme is built, so the
  // binding has to exist before buildPantryTheme() is called.
  // Every case is a testWidgets: buildPantryTheme() pulls Google Fonts, which
  // needs the binding and a widget-test zone. No network in tests; the colours
  // under test don't depend on the font file itself.
  DatePickerThemeData theme() {
    GoogleFonts.config.allowRuntimeFetching = false;
    return buildPantryTheme().datePickerTheme;
  }

  testWidgets('unselected day numbers contrast with the dialog background',
      (WidgetTester tester) async {
    final DatePickerThemeData dp = theme();
    final Color bg = dp.backgroundColor!;
    final Color fg = dp.dayForegroundColor!.resolve(<WidgetState>{})!;
    expect(_contrast(fg, bg), greaterThan(4.5),
        reason: 'day numbers must be readable on the calendar background');
  });

  testWidgets('selected day contrasts with its own filled chip',
      (WidgetTester tester) async {
    final DatePickerThemeData dp = theme();
    const Set<WidgetState> sel = <WidgetState>{WidgetState.selected};
    final Color chip = dp.dayBackgroundColor!.resolve(sel)!;
    final Color fg = dp.dayForegroundColor!.resolve(sel)!;
    expect(_contrast(fg, chip), greaterThan(4.5));
  });

  testWidgets('weekday letters and header are not painted on their own colour',
      (WidgetTester tester) async {
    final DatePickerThemeData dp = theme();
    expect(_contrast(dp.weekdayStyle!.color!, dp.backgroundColor!),
        greaterThan(3.0));
    expect(_contrast(dp.headerForegroundColor!, dp.headerBackgroundColor!),
        greaterThan(4.5));
  });

  testWidgets('the calendar opens and its days are visible and tappable',
      (WidgetTester tester) async {
    final DatePickerThemeData dp = theme();
    DateTime? picked;
    await tester.pumpWidget(MaterialApp(
      theme: buildPantryTheme(),
      home: Builder(
        builder: (BuildContext ctx) => Scaffold(
          body: TextButton(
            onPressed: () async {
              picked = await showDatePicker(
                context: ctx,
                initialDate: DateTime(2026, 8, 31),
                firstDate: DateTime(2025),
                lastDate: DateTime(2031),
              );
            },
            child: const Text('Pick date'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Pick date'));
    await tester.pumpAndSettle();

    // A day cell exists and carries a colour that isn't the background.
    final Finder day = find.text('15');
    expect(day, findsOneWidget);
    final Color? shown = tester.widget<Text>(day).style?.color;
    if (shown != null) {
      expect(_contrast(shown, dp.backgroundColor!), greaterThan(4.5),
          reason: 'the rendered day text must not match the dialog surface');
    }

    await tester.tap(day);
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(picked, DateTime(2026, 8, 15));
  });
}
