// Unit tests for the chef data model — the servings scaler and meal history.

import 'package:flutter_test/flutter_test.dart';

import 'package:pantry/chef_models.dart';

void main() {
  group('servings scaler', () {
    test('grams scale and round to whole', () {
      const RecipeIngredient i = RecipeIngredient(item: 'chicken', amount: '300 g');
      expect(i.scaled(2), '600 g');
      expect(i.scaled(1.5), '450 g');
      expect(i.scaled(0.5), '150 g');
    });

    test('counts scale to the nearest half, not fractions like 0.37', () {
      const RecipeIngredient eggs = RecipeIngredient(item: 'eggs', amount: '2');
      expect(eggs.scaled(2), '4');
      expect(eggs.scaled(1.5), '3');
      // 2 eggs at 1.75x = 3.5 → rounds to 3.5 (nearest half), never 3.5→"3.500"
      expect(eggs.scaled(1.75), '3.5');
    });

    test('non-numeric amounts pass through untouched', () {
      const RecipeIngredient s = RecipeIngredient(item: 'salt', amount: 'to taste');
      expect(s.scaled(3), 'to taste');
    });

    test('tbsp/ml treated as measured (whole)', () {
      const RecipeIngredient oil = RecipeIngredient(item: 'sesame oil', amount: '1 tbsp');
      expect(oil.scaled(3), '3 tbsp');
    });
  });

  group('meal history', () {
    test('withCooked appends and de-dupes case-insensitively', () {
      const MealHistory h = MealHistory(<String>['Tacos', 'Chili']);
      final MealHistory h2 = h.withCooked('tacos');
      expect(h2.meals.length, 2);
      expect(h2.meals.last, 'tacos'); // moved to newest
    });

    test('recent() returns the tail', () {
      final MealHistory h = MealHistory(List<String>.generate(50, (int i) => 'meal$i'));
      final List<String> r = h.recent(n: 30);
      expect(r.length, 30);
      expect(r.first, 'meal20');
      expect(r.last, 'meal49');
    });

    test('decode falls back to the seed history when empty', () {
      expect(MealHistory.decode(null).meals, kSeedMealHistory);
      expect(MealHistory.decode('').meals, kSeedMealHistory);
    });

    test('encode/decode round-trips', () {
      const MealHistory h = MealHistory(<String>['A', 'B', 'C']);
      expect(MealHistory.decode(h.encode()).meals, <String>['A', 'B', 'C']);
    });
  });

  group('option parsing', () {
    test('MealOption tolerates strings for numeric fields', () {
      final MealOption o = MealOption.fromJson(<String, dynamic>{
        'title': 'Turkey Bowl',
        'desc': 'quick',
        'protein': 'ground turkey',
        'newBuys': 'No new buys',
        'proteinPerServing': '34',
        'caloriesPerServing': 380,
      });
      expect(o.title, 'Turkey Bowl');
      expect(o.proteinPerServing, 34);
      expect(o.caloriesPerServing, 380);
    });
  });

  group('three different dinners — the variety check', () {
    MealOption opt(String title, String protein, String form, String cuisine) =>
        MealOption(
            title: title,
            desc: '',
            protein: protein,
            form: form,
            cuisine: cuisine,
            newBuys: '',
            proteinPerServing: 30,
            caloriesPerServing: 400);

    test('three meatball dishes is one choice wearing three hats', () {
      final String why = optionsSimilarity(<MealOption>[
        opt('Swedish Meatballs', 'ground beef', 'meatballs', 'Swedish'),
        opt('Turkey Meatballs Marinara', 'ground turkey', 'meatballs', 'Italian'),
        opt('Greek Lamb Meatballs', 'ground lamb', 'meatballs', 'Greek'),
      ]);
      expect(why, contains('kind of dish'));
    });

    test('genuinely different dinners pass', () {
      expect(
          optionsSimilarity(<MealOption>[
            opt('Sheet-Pan Chicken & Veg', 'chicken', 'sheet-pan', 'Mediterranean'),
            opt('Beef Stir-Fry', 'flank steak', 'stir-fry', 'Chinese'),
            opt('Tofu Curry', 'firm tofu', 'curry', 'Thai'),
          ]),
          '');
    });

    test('two chicken dinners are fine — sharing a protein is allowed', () {
      expect(
          optionsSimilarity(<MealOption>[
            opt('A', 'chicken breast', 'sheet-pan', 'Greek'),
            opt('B', 'chicken thighs', 'stir-fry', 'Thai'),
            opt('C', 'tofu', 'bowl', 'Korean'),
          ]),
          '');
    });

    test('every option on one protein is still one dinner in five hats', () {
      expect(
          optionsSimilarity(<MealOption>[
            opt('A', 'chicken breast', 'sheet-pan', 'Greek'),
            opt('B', 'chicken thighs', 'stir-fry', 'Thai'),
            opt('C', 'chicken wings', 'grill', 'Korean'),
          ]),
          contains('all of them share one protein'));
    });

    test('a stew and a curry are one kind of dinner, whatever the label', () {
      // "I would get like three soups" — the form list alone never caught it,
      // because soup / curry / brothy bowl are three labels and one plate.
      final String why = optionsSimilarity(<MealOption>[
        opt('Chicken Noodle Soup', 'chicken', 'soup or stew', 'American'),
        opt('Chickpea Curry', 'chickpeas', 'curry', 'Indian'),
        opt('Beef Tacos', 'ground beef', 'tacos or wraps', 'Mexican'),
      ]);
      expect(why, contains('kind of dish'));
      expect(why, contains('simmered'));
    });

    test('other adjacent forms collapse too', () {
      for (final List<String> pair in <List<String>>[
        <String>['burger or patty', 'meatballs'],
        <String>['stir-fry', 'skillet'],
        <String>['sheet-pan', 'casserole or bake'],
      ]) {
        expect(
            optionsSimilarity(<MealOption>[
              opt('A', 'beef', pair[0], 'American'),
              opt('B', 'pork', pair[1], 'Italian'),
              opt('C', 'lentils', 'soup or stew', 'Greek'),
            ]),
            contains('kind of dish'),
            reason: '${pair[0]} vs ${pair[1]} should collapse');
      }
    });

    test('same form is one dinner twice, protein aside', () {
      final String why = optionsSimilarity(<MealOption>[
        opt('A', 'chicken breast', 'sheet-pan', 'Greek'),
        opt('B', 'chicken thighs', 'sheet-pan', 'Thai'),
        opt('C', 'tofu', 'bowl', 'Korean'),
      ]);
      expect(why, contains('kind of dish'));
    });

    test('a specific request may repeat the protein but not the form', () {
      // A craving pins the protein; form and cuisine still have to spread.
      final List<MealOption> opts = <MealOption>[
        opt('A', 'chicken', 'tacos or wraps', 'Mexican'),
        opt('B', 'chicken', 'soup or stew', 'Thai'),
        opt('C', 'chicken', 'sheet-pan', 'Greek'),
      ];
      expect(optionsSimilarity(opts, requireProteinVariety: false), '');
      // Even without a request, an all-chicken sweep trips the weak bar.
      expect(optionsSimilarity(opts),
          contains('all of them share one protein'));
    });

    test('form/cuisine casing and hyphens do not fool it', () {
      final String why = optionsSimilarity(<MealOption>[
        opt('A', 'beef', 'Sheet Pan', 'thai'),
        opt('B', 'pork', 'sheet-pan', 'Thai'),
        opt('C', 'tofu', 'bowl', 'Korean'),
      ]);
      expect(why, contains('kind of dish'));
      expect(why, contains('cuisine'));
    });

    test('a shared form is enough to fail the set', () {
      expect(
          optionsSimilarity(<MealOption>[
            opt('A', 'beef', 'sheet-pan', 'Mexican'),
            opt('B', 'chicken', 'sheet-pan', 'Greek'),
            opt('C', 'tofu', 'bowl', 'Korean'),
          ]),
          contains('kind of dish'));
    });

    test('five wildly different dinners pass', () {
      expect(
          optionsSimilarity(<MealOption>[
            opt('Roast Chicken', 'chicken', 'roast', 'American'),
            opt('Beef Tacos', 'ground beef', 'tacos or wraps', 'Mexican'),
            opt('Sausage Pasta', 'pork sausage', 'pasta or noodles', 'Italian'),
            opt('Shrimp Stir-Fry', 'shrimp', 'stir-fry', 'Chinese'),
            opt('Lentil Soup', 'lentils', 'soup or stew', 'Greek'),
          ]),
          '');
    });

    test('a set of five names the one repeat, not the whole set', () {
      final String why = optionsSimilarity(<MealOption>[
        opt('Roast Chicken', 'chicken', 'roast', 'American'),
        opt('Beef Tacos', 'ground beef', 'tacos or wraps', 'Mexican'),
        opt('Sausage Pasta', 'pork sausage', 'pasta or noodles', 'Italian'),
        opt('Shrimp Stir-Fry', 'shrimp', 'stir-fry', 'Chinese'),
        opt('Lentil Stew', 'lentils', 'soup or stew', 'Mexican'),
      ]);
      expect(why, contains('cuisine'));
      expect(why, contains('"Beef Tacos" and "Lentil Stew"'));
      expect(why, isNot(contains('kind of dish')));
      expect(why, isNot(contains('protein')));
    });

    test('a whole set on one axis fails, however the rest varies', () {
      expect(
          optionsSimilarity(<MealOption>[
            opt('A', 'beef', 'sheet-pan', 'Mexican'),
            opt('B', 'chicken', 'sheet-pan', 'Greek'),
            opt('C', 'tofu', 'sheet-pan', 'Korean'),
          ]),
          contains('kind of dish'));
      expect(
          optionsSimilarity(<MealOption>[
            opt('A', 'beef', 'skillet', 'Thai'),
            opt('B', 'chicken', 'bowl', 'Thai'),
            opt('C', 'tofu', 'curry', 'Thai'),
          ]),
          contains('cuisine'));
    });

    test('recent shapes are read off the history titles', () {
      const MealHistory h = MealHistory(<String>[
        'Sheet-Pan Lemon Chicken',
        'Turkey Meatballs',
        'Sheet Pan Sausage & Peppers',
        'Beef Meatball Subs',
        'Chicken Stir-Fry',
        'Meatballs Marinara',
      ]);
      final List<String> hot = h.frequentShapes();
      expect(hot.first, 'meatballs ×3');
      expect(hot, contains('sheet-pan ×2'));
      expect(hot, contains('chicken ×2'));
    });
  });
}
