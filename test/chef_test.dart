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
}
