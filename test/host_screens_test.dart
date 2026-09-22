// Widget tests for the Host Hub screens — they actually build, at phone size
// and at iPad size, because the phone/counter split is the whole design and a
// model test can't see it.
//
// Assertions are on what's on screen, never on overflow: the test font is not
// the shipped font and invents overflows of its own.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:pantry/chef_models.dart';
import 'package:pantry/host.dart';
import 'package:pantry/host_hub.dart';
import 'package:pantry/models.dart';
import 'package:pantry/pricebook.dart';
import 'package:pantry/theme.dart';

const Size kPhone = Size(390, 844);
const Size kIpad = Size(834, 1194);

Recipe _recipe(String title, List<String> items) => Recipe(
      title: title,
      description: 'Worth serving.',
      ingredients: items
          .map((String i) => RecipeIngredient(item: i, amount: '100 g'))
          .toList(),
      steps: const <RecipeStep>[
        RecipeStep(title: 'Cook', content: 'Cook it', timerSeconds: 60),
      ],
      notes: 'notes',
      baseServings: 6,
      estCostTotal: 71,
      estGroceryCost: 54,
    );

String _isoIn(int days) => DateTime.now()
    .add(Duration(days: days))
    .toIso8601String()
    .substring(0, 10);

HostEvent _dinner({
  String name = 'Sarah\'s Birthday',
  int days = 3,
  int guests = 6,
  bool built = true,
  List<String> checked = const <String>[],
  List<PrepDay> prepDays = const <PrepDay>[],
  List<ServiceStep> runSheet = const <ServiceStep>[],
}) =>
    HostEvent(
      createdAtMs: 1000,
      name: name,
      guests: guests,
      eventDate: _isoIn(days),
      guestNotes: 'one guest has a tree-nut allergy',
      checked: checked,
      prepDays: prepDays,
      runSheet: runSheet,
      dishes: <HostDish>[
        HostDish(
            text: 'Lasagna',
            course: 'Main',
            recipe: built
                ? _recipe('Braised Short Rib Lasagna',
                    <String>['Short ribs (new buy)', 'Noodles'])
                : null),
        HostDish(
            text: 'Broccolini',
            course: 'Side',
            recipe: _recipe('Charred Broccolini', <String>['Broccolini'])),
      ],
    );

Future<void> _pumpHub(
  WidgetTester tester,
  Size size, {
  List<HostEvent> events = const <HostEvent>[],
  void Function(HostEvent)? onRemove,
}) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildPantryTheme(),
    home: HostHubScreen(
      events: HostHubBox(events).sorted,
      items: const <PantryItem>[],
      prices: const PriceBook(),
      onSave: (HostEvent _) {},
      onRemove: onRemove ?? (HostEvent _) {},
    ),
  ));
  await tester.pump();
}

Future<void> _pumpResults(WidgetTester tester, Size size, HostEvent e) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    theme: buildPantryTheme(),
    home: HostResultsScreen(
      event: e,
      items: const <PantryItem>[],
      onSave: (HostEvent _) {},
      onRemove: (HostEvent _) {},
    ),
  ));
  await tester.pump();
}

void main() {
  group('Host Hub — phone', () {
    testWidgets('empty state invites you to plan one', (WidgetTester t) async {
      await _pumpHub(t, kPhone);
      expect(find.text('Nothing on the table yet'), findsOneWidget);
      expect(find.text('Plan a dinner'), findsOneWidget);
    });

    testWidgets('the next dinner leads, with countdown and menu',
        (WidgetTester t) async {
      await _pumpHub(t, kPhone, events: <HostEvent>[_dinner(days: 3)]);
      expect(find.text('Sarah\'s Birthday'), findsOneWidget);
      expect(find.text('IN 3 DAYS'), findsOneWidget);
      // The menu itself, by the chef's titles, not just a dish count.
      expect(find.text('Braised Short Rib Lasagna'), findsOneWidget);
      expect(find.text('Charred Broccolini'), findsOneWidget);
      expect(find.text('Plan another dinner'), findsOneWidget);
    });

    testWidgets('countdown reads TONIGHT and TOMORROW', (WidgetTester t) async {
      await _pumpHub(t, kPhone, events: <HostEvent>[_dinner(days: 0)]);
      expect(find.text('TONIGHT'), findsOneWidget);
      await _pumpHub(t, kPhone, events: <HostEvent>[_dinner(days: 1)]);
      expect(find.text('TOMORROW'), findsOneWidget);
    });

    testWidgets('shopping progress counts ticked rows', (WidgetTester t) async {
      // 3 ingredients across the two dishes; one ticked.
      await _pumpHub(t, kPhone,
          events: <HostEvent>[_dinner(checked: <String>['0:0'])]);
      expect(find.text('1 / 3'), findsOneWidget);
    });

    testWidgets('an unbuilt dish is called out, not hidden',
        (WidgetTester t) async {
      await _pumpHub(t, kPhone, events: <HostEvent>[_dinner(built: false)]);
      expect(find.text('1 dish still to build'), findsOneWidget);
    });

    testWidgets('deleting from the menu screen updates the hub behind it',
        (WidgetTester t) async {
      // The stale-list bug: the hub captured its list once, so a dinner
      // deleted inside still showed when you came back.
      await _pumpHub(t, kPhone, events: <HostEvent>[
        _dinner(),
        HostEvent(
            createdAtMs: 2000,
            name: 'Later Dinner',
            guests: 4,
            eventDate: _isoIn(20),
            dishes: const <HostDish>[],
            guestNotes: ''),
      ]);
      expect(find.text('Later Dinner'), findsOneWidget);

      await t.ensureVisible(find.text('Later Dinner'));
      await t.tap(find.text('Later Dinner'));
      await t.pumpAndSettle();
      await t.tap(find.byIcon(Icons.delete_outline_rounded));
      await t.pumpAndSettle();
      await t.tap(find.text('Remove'));
      await t.pumpAndSettle();

      expect(find.text('Later Dinner'), findsNothing);
    });
  });

  group('Host Hub — iPad is a cooking surface', () {
    testWidgets('no planning, no shopping progress', (WidgetTester t) async {
      await _pumpHub(t, kIpad, events: <HostEvent>[
        _dinner(checked: <String>['0:0']),
      ]);
      expect(find.text('Plan a dinner'), findsNothing);
      expect(find.text('Plan another dinner'), findsNothing);
      expect(find.text('SHOPPING'), findsNothing);
      expect(find.text('1 / 3'), findsNothing);
      // What it IS for.
      expect(find.text('Open to prep and cook'), findsOneWidget);
      expect(find.text('Braised Short Rib Lasagna'), findsOneWidget);
    });

    testWidgets('empty state points back at the phone', (WidgetTester t) async {
      await _pumpHub(t, kIpad);
      expect(find.text('No dinner planned yet'), findsOneWidget);
    });
  });

  group('The menu screen', () {
    testWidgets('phone: shopping list, cost and naming are all there',
        (WidgetTester t) async {
      await _pumpResults(t, kPhone, _dinner());
      expect(find.text('ESTIMATED COST'), findsOneWidget);
      expect(find.text('Shopping List'), findsOneWidget);
      // New buys are marked, pantry items aren't.
      expect(find.text('Buy'), findsWidgets);
      expect(find.text('Have it'), findsWidgets);
      // Naming lives at the bottom of the page.
      await t.scrollUntilVisible(find.text('NAME THIS DINNER'), 300,
          scrollable: find.byType(Scrollable).first);
      expect(find.text('NAME THIS DINNER'), findsOneWidget);
      expect(find.text('Save to Host Hub'), findsOneWidget);
    });

    testWidgets('phone: ticking a row marks it gathered',
        (WidgetTester t) async {
      await _pumpResults(t, kPhone, _dinner());
      expect(find.byIcon(Icons.check_box_rounded), findsNothing);
      await t.ensureVisible(find.text('Short ribs'));
      await t.pumpAndSettle();
      await t.tap(find.text('Short ribs'));
      await t.pump();
      expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);
    });

    testWidgets('iPad: recipes and timeline only — no shopping, no naming',
        (WidgetTester t) async {
      await _pumpResults(
          t,
          kIpad,
          _dinner(prepDays: const <PrepDay>[
            PrepDay(label: 'The day before', tasks: <PrepTask>[
              PrepTask(text: 'Braise the short ribs', dish: 'Lasagna'),
            ])
          ]));
      expect(find.text('Shopping List'), findsNothing);
      expect(find.text('NAME THIS DINNER'), findsNothing);
      expect(find.text('ESTIMATED COST'), findsNothing);
      expect(find.byIcon(Icons.delete_outline_rounded), findsNothing);
      expect(find.text('Prep Timeline'), findsOneWidget);
      expect(find.text('Braised Short Rib Lasagna'), findsOneWidget);
      expect(find.text('View full recipe'), findsWidgets);
    });

    testWidgets('the whole menu can be cooked at once, not a dish at a time',
        (WidgetTester t) async {
      await _pumpResults(
          t,
          kPhone,
          _dinner(runSheet: const <ServiceStep>[
            ServiceStep(
                dish: 'Braised Short Rib Lasagna',
                title: 'Braise',
                content: 'Into the oven',
                timerSeconds: 9000,
                offset: 150),
            ServiceStep(
                dish: 'Charred Broccolini',
                title: 'Sear',
                content: 'Hot pan',
                offset: 10),
          ]));
      expect(find.text('Cook the whole menu'), findsOneWidget);
      expect(find.text('Cook it all'), findsOneWidget);

      await t.tap(find.text('Cook it all'));
      await t.pumpAndSettle();
      // One recipe covering every dish, each step saying which it belongs to
      // and how long before serving it happens.
      expect(find.textContaining('the whole menu'), findsWidgets);
      expect(find.textContaining('2h 30m before'), findsWidgets);
      // The second dish's step is further down the same single method.
      for (int i = 0; i < 6 && !find.textContaining('Charred Broccolini').hasFound; i++) {
        await t.drag(find.byType(Scrollable).first, const Offset(0, -500));
        await t.pump();
      }
      expect(find.textContaining('Charred Broccolini'), findsWidgets);
    });

    testWidgets('one dish alone gets no run sheet', (WidgetTester t) async {
      await _pumpResults(t, kPhone, _dinner());
      expect(find.text('Cook the whole menu'), findsNothing);
    });

    testWidgets('make-ahead work reads as a schedule, by day and by dish',
        (WidgetTester t) async {
      await _pumpResults(
          t,
          kPhone,
          _dinner(days: 3, prepDays: <PrepDay>[
            PrepDay(date: _isoIn(1), label: 'whatever', tasks: const <PrepTask>[
              PrepTask(
                  text: 'Braise the short ribs; refrigerate the sauce',
                  dish: 'Braised Short Rib Lasagna'),
            ]),
          ]));
      // The day is labelled against the dinner, not by the chef's wording,
      // and the dish it belongs to is on the row.
      expect(find.text('2 DAYS BEFORE'), findsOneWidget);
      expect(find.text('Braise the short ribs; refrigerate the sauce'),
          findsOneWidget);
      expect(find.text('Braised Short Rib Lasagna'), findsWidgets);
    });

    testWidgets('an unbuilt dish offers a rebuild on the phone only',
        (WidgetTester t) async {
      await _pumpResults(t, kPhone, _dinner(built: false));
      expect(find.text('Build this dish'), findsOneWidget);
      await _pumpResults(t, kIpad, _dinner(built: false));
      expect(find.text('Build this dish'), findsNothing);
    });
  });
}
