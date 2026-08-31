// Unit tests for the fatty liver limits — the app-side half of the rules.

import 'package:flutter_test/flutter_test.dart';

import 'package:pantry/chef_models.dart';
import 'package:pantry/liver.dart';

MealOption opt(String title,
        {double satFat = 0, double sugar = 0, double fiber = 0}) =>
    MealOption(
        title: title,
        desc: '',
        protein: 'chicken',
        newBuys: '',
        proteinPerServing: 34,
        caloriesPerServing: 430,
        satFatPerServing: satFat,
        addedSugarPerServing: sugar,
        fiberPerServing: fiber);

void main() {
  group('liver limits', () {
    test('a meal inside every limit is clean', () {
      final MealOption o =
          opt('Lemon Chicken & Lentils', satFat: 3, sugar: 2, fiber: 12);
      expect(optionLiverFlags(o), isEmpty);
      expect(isLiverFriendly(o), isTrue);
    });

    test('a cream sauce is caught on saturated fat', () {
      final List<LiverFlag> f =
          optionLiverFlags(opt('Chicken Alfredo', satFat: 22, sugar: 2, fiber: 9));
      expect(f.length, 1);
      expect(f.single.problem, contains('saturated fat'));
    });

    test('a brown sugar glaze is caught on added sugar', () {
      final List<LiverFlag> f = optionLiverFlags(
          opt('Glazed Turkey Meatballs', satFat: 4, sugar: 18, fiber: 9));
      expect(f.length, 1);
      expect(f.single.problem, contains('added sugar'));
    });

    test('a plate of white rice is caught on fiber', () {
      final List<LiverFlag> f =
          optionLiverFlags(opt('Chicken & Rice', satFat: 3, sugar: 1, fiber: 2));
      expect(f.length, 1);
      expect(f.single.problem, contains('fiber'));
    });

    test('one meal can miss on more than one axis', () {
      expect(
          optionLiverFlags(opt('Fried Sweet Chili Chicken',
                  satFat: 14, sugar: 20, fiber: 1))
              .length,
          3);
    });

    test('the slack keeps a near miss from costing an API call', () {
      // 8g sat fat is over the 7g limit but inside the tolerance — the point
      // is that these are the model's own estimates, not lab numbers.
      expect(optionLiverFlags(opt('Roast Chicken', satFat: 8, sugar: 1, fiber: 9)),
          isEmpty);
      expect(
          optionLiverFlags(opt('Roast Chicken', satFat: 11, sugar: 1, fiber: 9)),
          isNotEmpty);
    });

    test('an option that reported nothing is left alone, not flagged', () {
      // All three at zero means the chef skipped the fields. Flagging that
      // would burn a re-ask on a guess.
      final MealOption o = opt('Untold Dinner');
      expect(reportsLiverNumbers(o), isFalse);
      expect(optionLiverFlags(o), isEmpty);
      expect(isLiverFriendly(o), isFalse);
    });

    test('zero fiber IS flagged once the other numbers were reported', () {
      expect(optionLiverFlags(opt('Steak & Eggs', satFat: 6, sugar: 0, fiber: 0)),
          isNotEmpty);
    });
  });

  group('the complaint the chef gets re-asked with', () {
    test('names the option and the number', () {
      final String c = optionsLiverComplaint(<MealOption>[
        opt('Lentil Chili', satFat: 2, sugar: 3, fiber: 15),
        opt('Chicken Alfredo', satFat: 22, sugar: 2, fiber: 9),
      ]);
      expect(c, contains('Chicken Alfredo'));
      expect(c, contains('22g'));
      expect(c, isNot(contains('Lentil Chili')));
    });

    test('a clean set complains about nothing', () {
      expect(
          optionsLiverComplaint(<MealOption>[
            opt('Lentil Chili', satFat: 2, sugar: 3, fiber: 15),
            opt('Greek Chicken Bowl', satFat: 5, sugar: 4, fiber: 10),
          ]),
          '');
    });
  });

  group('option parsing carries the liver numbers', () {
    test('fromJson reads them, strings included', () {
      final MealOption o = MealOption.fromJson(<String, dynamic>{
        'title': 'Farro Bowl',
        'newBuys': '',
        'proteinPerServing': 32,
        'caloriesPerServing': 460,
        'satFatPerServing': '4.5',
        'addedSugarPerServing': 2,
        'fiberPerServing': 11,
      });
      expect(o.satFatPerServing, 4.5);
      expect(o.addedSugarPerServing, 2);
      expect(o.fiberPerServing, 11);
      expect(isLiverFriendly(o), isTrue);
    });

    test('an old reply with no liver fields parses to zeros', () {
      final MealOption o = MealOption.fromJson(<String, dynamic>{
        'title': 'Old Reply',
        'newBuys': '',
        'proteinPerServing': 30,
        'caloriesPerServing': 400,
      });
      expect(o.fiberPerServing, 0);
      expect(reportsLiverNumbers(o), isFalse);
    });
  });
}
