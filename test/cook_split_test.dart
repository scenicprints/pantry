import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pantry/chef_models.dart';
import 'package:pantry/cook_session.dart';
import 'package:pantry/models.dart';

// "It cannot ask for 30 grams of oil, and then another grouping is sharing
// that oil. It makes it impossible to split after i dumped it all in one
// container." One recipe line, two uses, one weight: whichever bowl he poured
// first took all of it.

Recipe recipeWith(List<(String, String)> ingredients) => Recipe(
      title: 'Test dinner',
      description: '',
      ingredients: <RecipeIngredient>[
        for (final (String item, String amount) in ingredients)
          RecipeIngredient(item: item, amount: amount),
      ],
      steps: const <RecipeStep>[],
      notes: '',
      baseServings: 2,
    );

PrepPlan planOf(List<(String, List<(String, String)>)> bowls) => PrepPlan(
      bowls: <PrepBowl>[
        for (final (String label, List<(String, String)> items) in bowls)
          PrepBowl(
            label: label,
            items: <PrepItem>[
              for (final (String item, String amount) in items)
                PrepItem(item: item, amount: amount),
            ],
          ),
      ],
      cookGroups: const <CookGroup>[],
      baseServings: 2,
    );

CookSession sessionFor(Recipe r) =>
    CookSession(recipe: r, servings: 2, factor: 1, pantry: <PantryItem>[]);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('oil used in two bowls becomes two portions that add up', () {
    final CookSession s = sessionFor(recipeWith(<(String, String)>[
      ('Olive oil', '30 g'),
      ('Broccoli', '400 g'),
    ]));
    expect(s.entries.length, 2);
    expect(s.byName('Olive oil')!.measuredG, 30);

    s.setPlan(planOf(<(String, List<(String, String)>)>[
      ('Pan', <(String, String)>[('Olive oil', '15 g')]),
      ('Vegetables', <(String, String)>[
        ('Broccoli', '400 g'),
        ('Olive oil', '15 g'),
      ]),
    ]));

    final List<CookEntry> oil = s.entries
        .where((CookEntry e) => e.item == 'Olive oil')
        .toList();
    expect(oil.length, 2, reason: 'one weighing per use');
    expect(oil.map((CookEntry e) => e.bowl), <String>['Pan', 'Vegetables']);
    expect(oil.fold<double>(0, (double a, CookEntry e) => a + e.measuredG), 30,
        reason: 'the portions still add up to the recipe');
  });

  test('each portion is looked up by its own bowl', () {
    final CookSession s = sessionFor(recipeWith(<(String, String)>[
      ('Olive oil', '30 g'),
    ]));
    s.setPlan(planOf(<(String, List<(String, String)>)>[
      ('Pan', <(String, String)>[('Olive oil', '20 g')]),
      ('Dressing', <(String, String)>[('Olive oil', '10 g')]),
    ]));

    expect(s.inBowl('Pan', 'Olive oil')!.measuredG, 20);
    expect(s.inBowl('Dressing', 'Olive oil')!.measuredG, 10);
    expect(s.inBowl('Pan', 'Olive oil'),
        isNot(same(s.inBowl('Dressing', 'Olive oil'))));
  });

  test('a weight he already typed is not wiped when the plan lands', () {
    final CookSession s = sessionFor(recipeWith(<(String, String)>[
      ('Olive oil', '30 g'),
    ]));
    s.byName('Olive oil')!.grams.text = '27';

    s.setPlan(planOf(<(String, List<(String, String)>)>[
      ('Pan', <(String, String)>[('Olive oil', '15 g')]),
      ('Dressing', <(String, String)>[('Olive oil', '15 g')]),
    ]));

    expect(s.inBowl('Pan', 'Olive oil')!.measuredG, 27);
  });

  // The trap inside the fix itself: the grams field is PREFILLED from the
  // recipe, so "there is a number in it" does not mean the cook typed it.
  // Reading the prefill as his gave the first bowl the whole 30 g.
  test('the recipe prefill is not mistaken for something he typed', () {
    final CookSession s = sessionFor(recipeWith(<(String, String)>[
      ('Olive oil', '30 g'),
    ]));
    expect(s.byName('Olive oil')!.grams.text, '30');

    s.setPlan(planOf(<(String, List<(String, String)>)>[
      ('Pan', <(String, String)>[('Olive oil', '15 g')]),
      ('Dressing', <(String, String)>[('Olive oil', '15 g')]),
    ]));

    expect(s.inBowl('Pan', 'Olive oil')!.measuredG, 15,
        reason: 'not the untouched 30 from the recipe line');
    expect(
        s.entries
            .where((CookEntry e) => e.item == 'Olive oil')
            .fold<double>(0, (double a, CookEntry e) => a + e.measuredG),
        30);
  });

  test('an ingredient used once is left alone', () {
    final CookSession s = sessionFor(recipeWith(<(String, String)>[
      ('Broccoli', '400 g'),
      ('Olive oil', '30 g'),
    ]));
    s.setPlan(planOf(<(String, List<(String, String)>)>[
      ('Tray', <(String, String)>[
        ('Broccoli', '400 g'),
        ('Olive oil', '30 g'),
      ]),
    ]));

    expect(s.entries.length, 2);
    expect(s.byName('Broccoli')!.bowl, 'Tray');
    expect(s.byName('Olive oil')!.measuredG, 30);
  });

  test('an ingredient the plan never mentions is still weighable', () {
    final CookSession s = sessionFor(recipeWith(<(String, String)>[
      ('Broccoli', '400 g'),
      ('Salt', 'to taste'),
    ]));
    s.setPlan(planOf(<(String, List<(String, String)>)>[
      ('Tray', <(String, String)>[('Broccoli', '400 g')]),
    ]));

    expect(s.entries.length, 2);
    expect(s.byName('Salt')!.bowl, isEmpty);
  });
}
