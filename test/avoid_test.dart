// The avoid list is a hard rule, so it is checked app-side. These cover the
// bug it was written for (an "All seafood" entry that still offered salmon and
// cod) and the opposite failure, a chef that invents restrictions.

import 'package:flutter_test/flutter_test.dart';

import 'package:pantry/avoid.dart';
import 'package:pantry/chef_models.dart';

MealOption opt({
  String title = '',
  String desc = '',
  String protein = '',
  String form = '',
  String cuisine = '',
  String sides = '',
  String newBuys = '',
}) =>
    MealOption(
      title: title,
      desc: desc,
      protein: protein,
      form: form,
      cuisine: cuisine,
      sides: sides,
      newBuys: newBuys,
      proteinPerServing: 30,
      caloriesPerServing: 400,
    );

void main() {
  const List<String> seafood = <String>['All seafood'];

  group('category expansion', () {
    test('"All seafood" covers the fish nobody spelled out', () {
      final List<String> terms = expandAvoid('All seafood');
      expect(terms, contains('salmon'));
      expect(terms, contains('cod'));
      expect(terms, contains('anchovy'));
      expect(terms, contains('scallop'));
      // "all seafood" is not itself a food — the category replaced it
      expect(terms, isNot(contains('all seafood')));
    });

    test('a plain food expands to itself only', () {
      expect(expandAvoid('Yogurt'), <String>['yogurt']);
    });

    test('empty entries expand to nothing', () {
      expect(expandAvoid('   '), isEmpty);
    });
  });

  group('the reported bug', () {
    test('a salmon option is caught', () {
      final List<AvoidHit> hits = optionAvoidHits(
          opt(title: 'Miso-Glazed Salmon', protein: 'salmon'), seafood);
      expect(hits.map((AvoidHit h) => h.term), contains('salmon'));
    });

    test('a cod option is caught', () {
      final List<AvoidHit> hits = optionAvoidHits(
          opt(title: 'Baked Cod with Lemon', protein: 'cod'), seafood);
      expect(hits.map((AvoidHit h) => h.term), contains('cod'));
    });

    test('caught in the sides and new buys too, not just the protein', () {
      expect(optionAvoidHits(opt(title: 'Caesar salad', newBuys: 'anchovy paste'),
              seafood),
          isNotEmpty);
      expect(
          optionAvoidHits(
              opt(title: 'Rice bowl', sides: 'shrimp chips'), seafood),
          isNotEmpty);
    });

    test('chicken is left alone', () {
      expect(
          optionAvoidHits(
              opt(
                  title: 'Chicken Shawarma Bowl',
                  protein: 'chicken thigh',
                  sides: 'roasted broccoli'),
              seafood),
          isEmpty);
    });
  });

  group('no over-blocking', () {
    test('"code" is not cod, "codes" is not cods', () {
      expect(textAvoidHits('write the code', seafood), isEmpty);
    });

    test('turkey bacon is not pork', () {
      expect(textAvoidHits('turkey bacon', <String>['Pork']), isEmpty);
      expect(textAvoidHits('bacon', <String>['Pork']), isNotEmpty);
    });

    test('peanut butter is not dairy', () {
      expect(textAvoidHits('peanut butter toast', <String>['Dairy']), isEmpty);
      expect(textAvoidHits('almond milk', <String>['Dairy']), isEmpty);
      expect(textAvoidHits('whole milk', <String>['Dairy']), isNotEmpty);
    });

    test('imitation crab still counts as seafood', () {
      expect(textAvoidHits('imitation crab', seafood), isNotEmpty);
    });

    test('"shrimp free" and "no salmon" are not offers', () {
      expect(textAvoidHits('shrimp free stir fry', seafood), isEmpty);
      expect(textAvoidHits('no salmon in this one', seafood), isEmpty);
    });

    test('an empty avoid list blocks nothing', () {
      expect(textAvoidHits('salmon with butter', <String>[]), isEmpty);
    });

    test('eggplant is not egg, hamburger is not ham', () {
      expect(textAvoidHits('roasted eggplant', <String>['Eggs']), isEmpty);
      expect(textAvoidHits('turkey hamburger', <String>['Pork']), isEmpty);
    });
  });

  group('prompt text', () {
    test('spells the category out for the model', () {
      final String s = formatAvoidsForPrompt(<String>['All seafood', 'Yogurt']);
      expect(s, contains('salmon'));
      expect(s, contains('cod'));
      expect(s, contains('- Yogurt'));
      // a plain entry gets no invented member list
      expect(s.split('\n').last, '- Yogurt');
    });

    test('an empty list reads as nothing off limits', () {
      expect(formatAvoidsForPrompt(<String>[]), contains('nothing'));
    });
  });

  group('across a set of options', () {
    test('reports each offending food once', () {
      final List<AvoidHit> hits = optionsAvoidHits(<MealOption>[
        opt(title: 'Salmon bowl', protein: 'salmon'),
        opt(title: 'Salmon tacos', protein: 'salmon'),
        opt(title: 'Chicken curry', protein: 'chicken'),
      ], seafood);
      expect(hits.length, 1);
      expect(hits.first.term, 'salmon');
      expect(hits.first.toString(), contains('All seafood'));
    });
  });
}
