import 'package:flutter_test/flutter_test.dart';
import 'package:pantry/chef_models.dart';

Recipe _r(String title, {double perServing = 0}) => Recipe(
      title: title,
      description: 'A test dish',
      ingredients: <RecipeIngredient>[
        const RecipeIngredient(item: 'Chicken', amount: '300 g'),
      ],
      steps: <RecipeStep>[
        const RecipeStep(title: 'Cook', content: 'Cook it', timerSeconds: 600),
      ],
      notes: 'notes',
      baseServings: 2,
      estCostPerServing: perServing,
    );

SavedRecipe _s(String title, int ms,
        {bool fav = false, int cooked = 0, int servings = 2}) =>
    SavedRecipe(
      savedAtMs: ms,
      recipe: _r(title),
      servings: servings,
      favourite: fav,
      timesCooked: cooked,
    );

void main() {
  group('SavedRecipe', () {
    test('round-trips through JSON with the whole recipe intact', () {
      final SavedRecipe r = SavedRecipe(
          savedAtMs: 1700000000000,
          recipe: _r('Glazed Turkey Meatballs', perServing: 3.25),
          servings: 4,
          favourite: true,
          timesCooked: 3);
      final SavedRecipe back = SavedRecipe.fromJson(r.toJson());
      expect(back.id, '1700000000000');
      expect(back.servings, 4);
      expect(back.favourite, true);
      expect(back.timesCooked, 3);
      expect(back.recipe.title, 'Glazed Turkey Meatballs');
      expect(back.recipe.steps.first.timerSeconds, 600);
      expect(back.recipe.ingredients.first.item, 'Chicken');
      expect(back.recipe.estCostPerServing, 3.25);
      expect(back.recipe.baseServings, 2);
    });

    test('defaults are sane for a plain save', () {
      final SavedRecipe back =
          SavedRecipe.fromJson(_s('Plain', 100).toJson());
      expect(back.favourite, false);
      expect(back.timesCooked, 0);
    });
  });

  group('RecipeBox', () {
    test('favourites float above everything, then newest first', () {
      final RecipeBox box = RecipeBox(<SavedRecipe>[
        _s('Oldest', 100),
        _s('Newest', 300),
        _s('Old favourite', 150, fav: true),
        _s('Middle', 200),
      ]);
      expect(box.sorted.map((SavedRecipe r) => r.recipe.title).toList(),
          <String>['Old favourite', 'Newest', 'Middle', 'Oldest']);
    });

    test('has() matches on title, case and padding insensitive', () {
      final RecipeBox box = RecipeBox(<SavedRecipe>[_s('Chicken Piccata', 1)]);
      expect(box.has('Chicken Piccata'), true);
      expect(box.has('  chicken piccata '), true);
      expect(box.has('Chicken Parm'), false);
    });

    test('encode → decode preserves order-independent content', () {
      final RecipeBox box = RecipeBox(<SavedRecipe>[
        _s('A', 1, fav: true, cooked: 2),
        _s('B', 2, servings: 6),
      ]);
      final RecipeBox back = RecipeBox.decode(box.encode());
      expect(back.recipes.length, 2);
      final SavedRecipe a =
          back.recipes.firstWhere((SavedRecipe r) => r.recipe.title == 'A');
      expect(a.favourite, true);
      expect(a.timesCooked, 2);
      final SavedRecipe b =
          back.recipes.firstWhere((SavedRecipe r) => r.recipe.title == 'B');
      expect(b.servings, 6);
    });

    test('decoding junk or nothing yields an empty box, never a throw', () {
      expect(RecipeBox.decode(null).recipes, isEmpty);
      expect(RecipeBox.decode('').recipes, isEmpty);
      expect(RecipeBox.decode('not json').recipes, isEmpty);
      expect(RecipeBox.decode('{"recipes":"nope"}').recipes, isEmpty);
    });

    test('copyWith flips only what it is given', () {
      final SavedRecipe r = _s('X', 1, cooked: 1);
      expect(r.copyWith(favourite: true).timesCooked, 1);
      expect(r.copyWith(timesCooked: 5).favourite, false);
      expect(r.copyWith(servings: 8).servings, 8);
      // The recipe and id are stable across edits.
      expect(r.copyWith(favourite: true).id, r.id);
      expect(r.copyWith(favourite: true).recipe.title, 'X');
    });
  });
}
