// A brief is a dinner worked out in Claude and handed to the app's chef.
// These cover the shape it travels in and the screen that shows it.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:pantry/host.dart';
import 'package:pantry/host_brief.dart';
import 'package:pantry/host_hub.dart';
import 'package:pantry/models.dart';
import 'package:pantry/pricebook.dart';
import 'package:pantry/theme.dart';

HostBrief _brief({
  String name = 'Sarah\'s Birthday',
  int guests = 6,
  String date = '2026-10-03',
  String notes = 'They sit down at seven. Oven is busy with the main.',
  String guestNotes = 'one guest has a tree-nut allergy',
  int builtAtMs = 0,
}) =>
    HostBrief(
      createdAtMs: 1700000000000,
      name: name,
      guests: guests,
      eventDate: date,
      guestNotes: guestNotes,
      notes: notes,
      builtAtMs: builtAtMs,
      dishes: const <BriefDish>[
        BriefDish(
            text: 'Lasagna',
            course: 'Main',
            notes: 'Short rib, not mince. No cream sauce — keep it red.'),
        BriefDish(text: 'Charred broccolini', course: 'Side'),
      ],
    );

void main() {
  group('HostBrief', () {
    test('round-trips, per-dish instructions included', () {
      final HostBrief back = HostBrief.fromJson(_brief().toJson());
      expect(back.id, '1700000000000');
      expect(back.name, 'Sarah\'s Birthday');
      expect(back.guests, 6);
      expect(back.eventDate, '2026-10-03');
      expect(back.notes, contains('seven'));
      expect(back.guestNotes, contains('tree-nut'));
      expect(back.dishes.first.notes, contains('No cream sauce'));
      expect(back.dishes.last.notes, isEmpty);
    });

    test('a brief is consumed once built, not kept', () {
      final HostBrief b = _brief();
      expect(b.isBuilt, false);
      final HostBrief done = b.markBuilt(DateTime(2026, 10, 3));
      expect(done.isBuilt, true);
      expect(done.id, b.id); // same brief, stamped
      expect(HostBrief.fromJson(done.toJson()).isBuilt, true);
    });

    test('defaults are sane when a field is left out', () {
      final HostBrief b = HostBrief.fromJson(<String, dynamic>{
        'createdAtMs': 1,
        'dishes': <dynamic>[
          <String, dynamic>{'text': 'Paella'},
        ],
      });
      expect(b.guests, 2);
      expect(b.dishes.single.course, 'Main');
      expect(b.dishes.single.notes, isEmpty);
      expect(b.isBuilt, false);
    });
  });

  group('A brief on screen', () {
    Future<void> pump(WidgetTester t, HostBrief b) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildPantryTheme(),
        home: HostBriefScreen(
          brief: b,
          items: const <PantryItem>[],
          prices: const PriceBook(),
          onSave: (HostEvent _) {},
          onRemove: (HostEvent _) {},
          onBuilt: (HostBrief _) {},
        ),
      ));
      await t.pump();
    }

    testWidgets('shows what was asked for, per dish', (WidgetTester t) async {
      await pump(t, _brief());
      expect(find.text('Sarah\'s Birthday'), findsWidgets);
      expect(find.text('Lasagna'), findsOneWidget);
      // The instruction the app had no way to accept before.
      expect(find.text('Short rib, not mince. No cream sauce — keep it red.'),
          findsOneWidget);
      expect(find.textContaining('sit down at seven'), findsOneWidget);
      expect(find.textContaining('tree-nut'), findsOneWidget);
      expect(find.text('Build this menu'), findsOneWidget);
    });

    testWidgets('the hub surfaces one waiting to be built',
        (WidgetTester t) async {
      GoogleFonts.config.allowRuntimeFetching = false;
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildPantryTheme(),
        home: HostHubScreen(
          events: const <HostEvent>[],
          briefs: <HostBrief>[_brief()],
          items: const <PantryItem>[],
          prices: const PriceBook(),
          onSave: (HostEvent _) {},
          onRemove: (HostEvent _) {},
        ),
      ));
      await t.pump();
      expect(find.text('WAITING TO BE BUILT'), findsOneWidget);
      expect(find.text('Tap to have the chef build it'), findsOneWidget);
    });

    testWidgets('the iPad does not offer to build one', (WidgetTester t) async {
      // Planning is phone work; the counter is for cooking.
      GoogleFonts.config.allowRuntimeFetching = false;
      t.view.physicalSize = const Size(834, 1194);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        theme: buildPantryTheme(),
        home: HostHubScreen(
          events: const <HostEvent>[],
          briefs: <HostBrief>[_brief()],
          items: const <PantryItem>[],
          prices: const PriceBook(),
          onSave: (HostEvent _) {},
          onRemove: (HostEvent _) {},
        ),
      ));
      await t.pump();
      expect(find.text('WAITING TO BE BUILT'), findsNothing);
    });
  });
}
