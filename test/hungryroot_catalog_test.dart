// Unit tests for HungryRoot mode: reading their catalogue, matching it to
// what is actually on the shelf, and the three things the mode changes about
// how the chef is asked and judged.

import 'package:flutter_test/flutter_test.dart';

import 'package:pantry/avoid.dart';
import 'package:pantry/chef.dart';
import 'package:pantry/chef_models.dart';
import 'package:pantry/hungryroot_catalog.dart';
import 'package:pantry/models.dart';

HungryRootPairing pairing(String name,
        {String method = 'Cook the thing', int servings = 2, int time = 10}) =>
    HungryRootPairing(
        id: 1,
        name: name,
        cookingTime: time,
        servings: servings,
        method: method,
        nutrition: '');

PantryItem item(String name, {bool hungryroot = false, double remaining = 400}) =>
    PantryItem(
      id: name,
      name: name,
      total: 500,
      remaining: remaining,
      price: 6,
      macros: const Macros(proteinG: 20, calories: 120),
      servingSize: 100,
      dateAdded: '2026-10-07',
      lastPrice: 6,
      hungryroot: hungryroot,
    );

MealOption opt(String title,
        {String protein = 'chicken',
        String form = 'skillet',
        String cuisine = 'Thai',
        String hungryRootName = ''}) =>
    MealOption(
        title: title,
        desc: '',
        protein: protein,
        form: form,
        cuisine: cuisine,
        newBuys: '',
        proteinPerServing: 30,
        caloriesPerServing: 420,
        hungryRootName: hungryRootName);

void main() {
  group('reading their card', () {
    test('paragraphs become one step per line', () {
      expect(
          stripHtml('<p>Toast 5 bagels</p><p>Thinly slice onion</p>'),
          'Toast 5 bagels\nThinly slice onion');
    });

    test('entities and stray tags come out', () {
      expect(stripHtml('<p>Salt &amp; pepper<br/>Serve</p>'),
          'Salt & pepper\nServe');
    });

    test('the daily-value boilerplate is cut off the nutrition panel', () {
      const String info = '<br/>Amount per serving: Calories 430, Sat. Fat 9g, '
          'Protein 19g.<br/><br/>The % daily value tells you how much a '
          'nutrient in a serving of food is part of a daily diet.';
      expect(trimNutrition(info),
          'Calories 430, Sat. Fat 9g, Protein 19g.');
    });

    test('a pairing with no method is no use and is dropped', () {
      expect(
          HungryRootPairing.fromApi(<String, dynamic>{
            'id': 1,
            'name': 'Mystery Box',
            'short_instruction_html': '',
          }),
          isNull);
      expect(
          HungryRootPairing.fromApi(<String, dynamic>{
            'id': 1,
            'name': '',
            'short_instruction_html': '<p>Cook it</p>',
          }),
          isNull);
    });

    test('a real one keeps its name, times and method', () {
      final HungryRootPairing? p =
          HungryRootPairing.fromApi(<String, dynamic>{
        'id': 1957486,
        'name': 'Saucy Green Chicken + Bok Choy Veggies',
        'cooking_time': 10,
        'servings': 2,
        'short_instruction_html': '<p>Sauté the veggies</p><p>Brown the '
            'chicken</p>',
        'nutrition_info': '<br/>Amount per serving: Calories 420.',
      });
      expect(p, isNotNull);
      expect(p!.name, 'Saucy Green Chicken + Bok Choy Veggies');
      expect(p.cookingTime, 10);
      expect(p.servings, 2);
      expect(p.method.split('\n').length, 2);
      expect(p.nutrition, 'Calories 420.');
    });
  });

  group('matching the box to the catalogue', () {
    test('the brand in a pantry name is not something to match on', () {
      final Set<String> w = foodWords('Cilantro Lime Chicken (Kevin\'s '
          'Natural Foods)');
      expect(w, contains('chicken'));
      expect(w, contains('cilantro'));
      expect(w, isNot(contains('kevin')));
      expect(w, isNot(contains('natural')));
      expect(w, isNot(contains('foods')));
    });

    test('a recipe using none of his food scores nothing', () {
      final List<Set<String>> mine = <Set<String>>[foodWords('Bok Choy Veggie Mix')];
      expect(matchScore(pairing('Wagyu Filet Mignon + Tomato Salad'), mine), 0);
    });

    test('naming his food in the title beats naming it in a step', () {
      final List<Set<String>> mine = <Set<String>>[foodWords('Bok Choy Veggie Mix')];
      final double titled =
          matchScore(pairing('Saucy Chicken + Bok Choy'), mine);
      final double buried = matchScore(
          pairing('Saucy Chicken Skillet', method: 'Add the bok choy'), mine);
      expect(titled, greaterThan(buried));
      expect(buried, greaterThan(0));
    });

    test('using two of his things beats using one of them twice', () {
      final List<Set<String>> mine = <Set<String>>[
        foodWords('Cilantro Lime Chicken'),
        foodWords('Bok Choy Veggie Mix'),
      ];
      final double two = matchScore(pairing('Chicken + Bok Choy'), mine);
      final double one = matchScore(
          pairing('Cilantro Lime Chicken',
              method: 'Brown the chicken\nRest the chicken'),
          mine);
      expect(two, greaterThan(one));
    });

    test('two names for one dinner are caught before the chef sees them', () {
      expect(
          tooAlike(pairing('Saucy Green Chicken + Bok Choy Veggies'),
              pairing('Saucy Green Chicken Bowl')),
          isTrue);
      expect(
          tooAlike(pairing('Garlic Steak Naan Wrap'),
              pairing('Horseradish Salmon + Couscous')),
          isFalse);
    });

    test('only tagged stock that is actually in the house counts', () {
      final List<PantryItem> pantry = <PantryItem>[
        item('Cilantro Lime Chicken', hungryroot: true),
        item('Bok Choy Veggie Mix', hungryroot: true, remaining: 0),
        item('Olive Oil'),
      ];
      final List<PantryItem> stock =
          HungryRootCatalog.hungryRootStock(pantry);
      expect(stock.map((PantryItem i) => i.name), <String>['Cilantro Lime Chicken']);
    });
  });

  group('the item flag', () {
    test('survives a round trip through the pantry file', () {
      final PantryItem i = item('Cilantro Lime Chicken', hungryroot: true);
      final Map<String, dynamic> j = i.toJson(DateTime(2026, 10, 7));
      expect(j['hungryroot'], isTrue);
      expect(PantryItem.fromJson(j).hungryroot, isTrue);
    });

    test('is absent, not false, on everything else', () {
      final Map<String, dynamic> j = item('Olive Oil').toJson(DateTime(2026, 10, 7));
      expect(j.containsKey('hungryroot'), isFalse);
      expect(PantryItem.fromJson(j).hungryroot, isFalse);
    });

    test('a quick-add remembers where the food came from', () {
      final QuickAddItem q = QuickAddItem(
          name: 'Cilantro Lime Chicken',
          lastPrice: 6,
          macros: const Macros(),
          hungryroot: true);
      expect(QuickAddItem.fromJson(q.toJson()).hungryroot, isTrue);
    });
  });

  group('what the chef is told', () {
    test('the pantry listing says which food came in the box', () {
      final String out = Chef.formatPantry(<PantryItem>[
        item('Cilantro Lime Chicken', hungryroot: true),
        item('Olive Oil'),
      ]);
      expect(out, contains('[HUNGRYROOT]'));
      expect(
          out.split('\n').firstWhere((String l) => l.contains('Olive Oil')),
          isNot(contains('[HUNGRYROOT]')));
    });

    test('an on-hand item still shows its source', () {
      final PantryItem i = item('Ranch Seasoning', hungryroot: true)
        ..quantityUnknown = true;
      expect(Chef.formatPantry(<PantryItem>[i]), contains('[HUNGRYROOT]'));
    });

    test('their recipes are handed over with the method intact', () {
      final String out = Chef.formatPairings(<HungryRootPairing>[
        pairing('Saucy Green Chicken + Bok Choy Veggies',
            method: 'Sauté the veggies\nBrown the chicken'),
      ]);
      expect(out, contains('Saucy Green Chicken + Bok Choy Veggies'));
      expect(out, contains('serves 2, HungryRoot says 10 min'));
      expect(out, contains('- Sauté the veggies'));
      expect(out, contains('- Brown the chicken'));
    });
  });

  group('what the mode stops enforcing', () {
    test('three dinners off one delivery may share a cuisine', () {
      final List<MealOption> opts = <MealOption>[
        opt('A', form: 'skillet', cuisine: 'Thai'),
        opt('B', form: 'tacos or wraps', cuisine: 'Thai'),
        opt('C', form: 'salad-as-a-meal', cuisine: 'Thai'),
      ];
      expect(optionsSimilarity(opts, requireProteinVariety: false),
          contains('cuisine'));
      expect(
          optionsSimilarity(opts,
              requireProteinVariety: false, requireCuisineVariety: false),
          isEmpty);
    });

    test('but the same kind of dinner twice is still wrong', () {
      final List<MealOption> opts = <MealOption>[
        opt('A', form: 'skillet', cuisine: 'Thai'),
        opt('B', form: 'skillet', cuisine: 'Thai'),
        opt('C', form: 'roast', cuisine: 'Thai'),
      ];
      expect(
          optionsSimilarity(opts,
              requireProteinVariety: false, requireCuisineVariety: false),
          contains('kind of dish'));
    });
  });

  group('the avoid list against his own delivery', () {
    const String box = 'cilantro lime chicken | bok choy veggie mix | '
        'cheese tortellini | sliced mushroom';
    List<AvoidHit> hit(String term) =>
        <AvoidHit>[AvoidHit(entry: term, term: term)];

    test('a food that came in the box is cooked, not refused', () {
      expect(Chef.forgivenHits(hit('mushroom'), box), isEmpty);
      expect(Chef.forgivenHits(hit('bok choy'), box), isEmpty);
    });

    test('a plural on either side is the same food', () {
      expect(Chef.forgivenHits(hit('mushrooms'), box), isEmpty);
      expect(Chef.forgivenHits(hit('chickens'), box), isEmpty);
    });

    test('a food the chef reached for is still refused', () {
      expect(Chef.forgivenHits(hit('salmon'), box), hasLength(1));
      expect(Chef.forgivenHits(hit('walnuts'), box), hasLength(1));
    });

    test('sharing one word with the box is not being in the box', () {
      // The whole point of matching the phrase: he has cheese tortellini,
      // which is not permission to put blue cheese on his plate.
      expect(Chef.forgivenHits(hit('blue cheese'), box), hasLength(1));
    });

    test('part of a word is not the word', () {
      expect(Chef.forgivenHits(hit('chick'), box), hasLength(1));
    });

    test('with the mode off nothing is forgiven', () {
      expect(Chef.forgivenHits(hit('mushroom'), ''), hasLength(1));
    });
  });

  group('the option knows where it came from', () {
    test('a replicated option carries their name', () {
      final MealOption o = MealOption.fromJson(<String, dynamic>{
        'title': 'Saucy green chicken',
        'hungryroot': 'Saucy Green Chicken + Bok Choy Veggies',
      });
      expect(o.fromHungryRoot, isTrue);
      expect(o.hungryRootName, 'Saucy Green Chicken + Bok Choy Veggies');
    });

    test("the chef's own idea carries nothing", () {
      final MealOption o =
          MealOption.fromJson(<String, dynamic>{'title': 'Chicken and rice'});
      expect(o.fromHungryRoot, isFalse);
      expect(o.hungryRootName, '');
    });
  });
}
