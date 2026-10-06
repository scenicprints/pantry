// Cook for HungryRoot. The food is bought and portioned, so the only thing
// under test is the plan: what the model handed back, whether the amounts
// came out in grams, and whether the screens actually build.
//
// The example that started this feature is a real HungryRoot card that runs
// burgers, then zucchini, then buns through one skillet and calls it eight
// minutes. The honesty of the time row is the point, so it is tested in both
// directions.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:pantry/chef_models.dart';
import 'package:pantry/hungryroot.dart';
import 'package:pantry/measures.dart';
import 'package:pantry/theme.dart';

const Size kPhone = Size(390, 844);

Map<String, dynamic> _reply({
  int totalMinutes = 14,
  int cardMinutes = 8,
  List<Map<String, dynamic>>? stations,
  List<Map<String, dynamic>>? ingredients,
  List<Map<String, dynamic>>? steps,
}) =>
    <String, dynamic>{
      'title': 'Ranch burgers with zucchini',
      'verdict': 'Zucchini goes in the air fryer and the buns on Tovala '
          'Toast, so the stove is free for the burgers and all three land hot.',
      'totalMinutes': totalMinutes,
      'cardMinutes': cardMinutes,
      'stations': stations ??
          <Map<String, dynamic>>[
            <String, dynamic>{
              'appliance': 'Air fryer',
              'job': 'Zucchini rounds, 200C, 8 min, shake halfway',
            },
            <String, dynamic>{
              'appliance': 'Stove',
              'job': 'Burgers, high, 3 min a side to 71C',
            },
            <String, dynamic>{
              'appliance': 'Tovala Smart Oven',
              'job': 'Buns, Toast, dry, 2 min',
            },
          ],
      'ingredients': ingredients ??
          <Map<String, dynamic>>[
            <String, dynamic>{'item': 'Burger patties', 'amount': '2'},
            <String, dynamic>{'item': 'Zucchini', 'amount': '1 medium'},
            <String, dynamic>{'item': 'Olive oil', 'amount': '1 tsp'},
            <String, dynamic>{'item': 'Ranch seasoning', 'amount': '1 tsp'},
            <String, dynamic>{'item': 'Salt and pepper', 'amount': 'to taste'},
          ],
      'steps': steps ??
          <Map<String, dynamic>>[
            <String, dynamic>{
              'title': 'Preheat the air fryer',
              'content': 'Set it to 200C and give it 3 minutes.',
              'timerSeconds': 180,
            },
            <String, dynamic>{
              'title': 'Burgers on the stove',
              'content': 'Dry pan over high. 3 minutes a side, to 71C.',
              'timerSeconds': 360,
            },
          ],
      'notes': 'Burgers come to 71C. No oil under the patties, they render '
          'their own.',
    };

Future<void> _pumpPlan(WidgetTester t, CookPlan plan) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  t.view.physicalSize = kPhone;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildPantryTheme(),
    home: CookPlanScreen(plan: plan),
  ));
  await t.pump();
}

Future<void> _pumpPaste(WidgetTester t) async {
  GoogleFonts.config.allowRuntimeFetching = false;
  t.view.physicalSize = kPhone;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildPantryTheme(),
    home: const HungryRootScreen(),
  ));
  await t.pump();
}

void main() {
  group('the plan comes back readable', () {
    test('every field survives the round trip', () {
      final CookPlan p = CookPlan.fromJson(_reply());
      expect(p.title, 'Ranch burgers with zucchini');
      expect(p.verdict, contains('air fryer'));
      expect(p.totalMinutes, 14);
      expect(p.cardMinutes, 8);
      expect(p.stations.length, 3);
      expect(p.stations.first.appliance, 'Air fryer');
      expect(p.steps.length, 2);
      expect(p.steps.first.timerSeconds, 180);
      expect(p.notes, contains('71C'));
    });

    test('empty rows are dropped rather than rendered blank', () {
      final CookPlan p = CookPlan.fromJson(_reply(
        stations: <Map<String, dynamic>>[
          <String, dynamic>{'appliance': '', 'job': 'nothing'},
          <String, dynamic>{'appliance': 'Stove', 'job': 'burgers'},
        ],
        steps: <Map<String, dynamic>>[
          <String, dynamic>{'title': '', 'content': '', 'timerSeconds': 0},
          <String, dynamic>{'title': 'Cook', 'content': 'Cook it'},
        ],
      ));
      expect(p.stations.length, 1);
      expect(p.steps.length, 1);
    });

    test('a reply with nothing in it does not throw', () {
      final CookPlan p = CookPlan.fromJson(<String, dynamic>{});
      expect(p.steps, isEmpty);
      expect(p.stations, isEmpty);
      expect(p.totalMinutes, 0);
      expect(p.minutesVsCard, isNull);
    });

    test('the recipe handed to cooking mode never scales', () {
      // The box decided the portions. A servings stepper would be a lie.
      final Recipe r = CookPlan.fromJson(_reply()).recipe;
      expect(r.baseServings, 1);
      expect(r.estCostTotal, 0);
      expect(r.description, contains('air fryer'));
      expect(r.steps.length, 2);
    });
  });

  group('the time row is honest', () {
    test('faster than the card', () {
      final CookPlan p =
          CookPlan.fromJson(_reply(totalMinutes: 6, cardMinutes: 8));
      expect(p.minutesVsCard, 2);
    });

    test('slower than the card', () {
      final CookPlan p =
          CookPlan.fromJson(_reply(totalMinutes: 14, cardMinutes: 8));
      expect(p.minutesVsCard, -6);
    });

    test('no comparison when the card never said one', () {
      expect(CookPlan.fromJson(_reply(cardMinutes: 0)).minutesVsCard, isNull);
      expect(CookPlan.fromJson(_reply(totalMinutes: 0)).minutesVsCard, isNull);
    });
  });

  group('amounts arrive in grams', () {
    test('a teaspoon of oil is weighed', () {
      final CookPlan p = gramsOnly(CookPlan.fromJson(_reply()));
      final RecipeIngredient oil = p.ingredients
          .firstWhere((RecipeIngredient i) => i.item == 'Olive oil');
      expect(oil.amount, '4.5 g');
    });

    test('salt and pepper stay to taste', () {
      final CookPlan p = gramsOnly(CookPlan.fromJson(_reply()));
      final RecipeIngredient sp = p.ingredients
          .firstWhere((RecipeIngredient i) => i.item == 'Salt and pepper');
      expect(sp.amount, 'to taste');
    });

    test('a dried seasoning keeps its spoon', () {
      // Nobody weighs the ranch packet.
      final CookPlan p = gramsOnly(CookPlan.fromJson(_reply()));
      final RecipeIngredient r = p.ingredients
          .firstWhere((RecipeIngredient i) => i.item == 'Ranch seasoning');
      expect(r.amount, '1 tsp');
    });

    test('a piece keeps the count and gains the weight', () {
      // "1 medium" is how he would say it; the grams are what the scale
      // reads. Both, not one instead of the other.
      final CookPlan p = gramsOnly(CookPlan.fromJson(_reply()));
      final RecipeIngredient z = p.ingredients
          .firstWhere((RecipeIngredient i) => i.item == 'Zucchini');
      expect(z.amount, startsWith('1 medium ('));
      expect(z.amount, endsWith(' g)'));
    });

    test('an amount already in grams is left exactly alone', () {
      final CookPlan p = gramsOnly(CookPlan.fromJson(_reply(
        ingredients: <Map<String, dynamic>>[
          <String, dynamic>{'item': 'Olive oil', 'amount': '14 g'},
        ],
      )));
      expect(p.ingredients.single.amount, '14 g');
    });
  });

  group('the screens build', () {
    testWidgets('the paste box will not call out on a stray tap',
        (WidgetTester t) async {
      await _pumpPaste(t);
      expect(find.text('Paste the card'), findsOneWidget);
      final Finder go = find.widgetWithText(ElevatedButton, 'How should I '
          'cook this?');
      expect(_enabled(t, go), isFalse);

      await t.enterText(find.byType(TextField), 'too short');
      await t.pump();
      expect(_enabled(t, go), isFalse);

      await t.enterText(find.byType(TextField),
          'Cook time: 8 minutes. Heat lightly oiled skillet over high.');
      await t.pump();
      expect(_enabled(t, go), isTrue);
    });

    testWidgets('the plan leads with the verdict and names the appliances',
        (WidgetTester t) async {
      await _pumpPlan(t, gramsOnly(CookPlan.fromJson(_reply())));
      expect(find.textContaining('air fryer'), findsWidgets);
      expect(find.text('WHAT COOKS WHERE'), findsOneWidget);
      expect(find.text('3 appliances.'), findsOneWidget);
      expect(find.text('Air fryer'), findsOneWidget);
      expect(find.text('Tovala Smart Oven'), findsOneWidget);
      expect(find.text('14 min'), findsOneWidget);
      expect(find.text('the card said 8 min'), findsOneWidget);
      expect(find.text('6 min longer, worth it'), findsOneWidget);
    });

    testWidgets('the method and the cooking mode button are below the plan',
        (WidgetTester t) async {
      // Scrolled to rather than asserted in place: the verdict and the
      // station jobs wrap further in the test font than in Fraunces, so
      // where the button lands is not a fact this test can pin. That it is
      // reachable is.
      await _pumpPlan(t, gramsOnly(CookPlan.fromJson(_reply())));
      // In page order, because scrolling only goes one way and reaching a
      // later one takes an earlier one off screen. scrollUntilVisible throws
      // when it runs out of list, so a missing section fails here.
      for (final String text in <String>[
        'Cooking mode',
        'WHAT CAME IN THE BOX',
        'Olive oil',
        'METHOD',
        'Burgers on the stove',
        'NOTES',
      ]) {
        await t.scrollUntilVisible(find.text(text), 200);
        expect(find.text(text), findsOneWidget, reason: text);
      }
    });

    testWidgets('one appliance reads as the good answer, not a thin one',
        (WidgetTester t) async {
      // The whole correction: "It wanted me to use a griddle, an air fryer
      // and a tovala oven three separate things. Way more work than the
      // original instructions." A single-pan plan is the win, so the screen
      // has to say so rather than render a lonely table row.
      await _pumpPlan(
          t,
          CookPlan.fromJson(_reply(
            stations: <Map<String, dynamic>>[
              <String, dynamic>{
                'appliance': 'Stove',
                'job': 'Burgers, then the zucchini in their fat, then buns',
              },
            ],
          )));
      expect(find.text('One appliance, start to finish.'), findsOneWidget);
      expect(find.text('Stove'), findsOneWidget);
      expect(find.textContaining('appliances.'), findsNothing);
    });

    testWidgets('beating the card says so', (WidgetTester t) async {
      await _pumpPlan(
          t, CookPlan.fromJson(_reply(totalMinutes: 6, cardMinutes: 8)));
      expect(find.text('2 min faster'), findsOneWidget);
    });

    testWidgets('no card time means no comparison on screen',
        (WidgetTester t) async {
      await _pumpPlan(t, CookPlan.fromJson(_reply(cardMinutes: 0)));
      expect(find.text('14 min'), findsOneWidget);
      expect(find.textContaining('the card said'), findsNothing);
    });

    testWidgets('there is no cost, no servings and no save',
        (WidgetTester t) async {
      // The things this screen is defined by not having.
      await _pumpPlan(t, CookPlan.fromJson(_reply()));
      expect(find.text('SERVINGS'), findsNothing);
      expect(find.text('ESTIMATED COST'), findsNothing);
      expect(find.byIcon(Icons.bookmark_border_rounded), findsNothing);
    });
  });
}

/// Whether the button [f] finds is tappable.
bool _enabled(WidgetTester t, Finder f) =>
    (t.widget<ElevatedButton>(f)).onPressed != null;
