import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pantry/cook_session.dart';
import 'package:pantry/models.dart';

// The fixture is a slice of the real pantry.json, kept because the bug was
// invisible against made-up data: minced garlic and soy sauce carry
// "quantity_unknown": true and no gram count at all, which an earlier filter
// read as "none left" and hid.

List<PantryItem> loadFixture() {
  final Map<String, dynamic> j = jsonDecode(
          File('test/fixtures/pantry_sample.json').readAsStringSync())
      as Map<String, dynamic>;
  return (j['pantry'] as List<dynamic>)
      .whereType<Map<String, dynamic>>()
      .map(PantryItem.fromJson)
      .toList();
}

PantryItem? named(List<PantryItem> items, String part) {
  for (final PantryItem p in items) {
    if (p.name.toLowerCase().contains(part.toLowerCase())) {
      return p;
    }
  }
  return null;
}

void main() {
  late List<PantryItem> pantry;

  setUp(() => pantry = loadFixture());

  test('the fixture really does hold untracked items', () {
    expect(named(pantry, 'Minced California Garlic')!.quantityUnknown, isTrue);
    expect(named(pantry, 'Minced California Garlic')!.remaining, 0);
    expect(named(pantry, 'Soy Sauce')!.quantityUnknown, isTrue);
    expect(named(pantry, 'Garlic Salt')!.spice, isTrue);
  });

  test('an item with no tracked amount can still be paired', () {
    final List<String> names =
        pickablePantry(pantry).map((PantryItem p) => p.name).toList();
    expect(names, contains(named(pantry, 'Minced California Garlic')!.name));
    expect(names, contains(named(pantry, 'Soy Sauce')!.name));
    expect(names, contains(named(pantry, 'Garlic Salt')!.name));
  });

  test('typing narrows it, and still reaches the untracked ones', () {
    final List<String> names = pickablePantry(pantry, query: 'garlic')
        .map((PantryItem p) => p.name)
        .toList();
    expect(names, contains(named(pantry, 'Minced California Garlic')!.name));
    expect(names.every((String n) => n.toLowerCase().contains('garlic')),
        isTrue);
  });

  test('a tracked item that has run out is hidden until asked for', () {
    // Broccoli (Tesco) is really at 0 g in his pantry.
    bool hasEmptyBroccoli(List<PantryItem> l) =>
        l.any((PantryItem p) => p.name.contains('Tesco'));
    expect(hasEmptyBroccoli(pickablePantry(pantry)), isFalse);
    expect(hasEmptyBroccoli(pickablePantry(pantry, includeEmpty: true)), isTrue);
  });

  test('what is in stock is offered', () {
    final List<String> names =
        pickablePantry(pantry).map((PantryItem p) => p.name).toList();
    expect(names, contains('Brown Whole Grain Rice (Mahatma)'));
    expect(names, contains('Onions, white, raw'));
    expect(names, contains('Extra Virgin Olive Oil (Sunny Select)'));
  });

  test('the list is alphabetical so it can be scanned', () {
    final List<String> names = pickablePantry(pantry)
        .map((PantryItem p) => p.name.toLowerCase())
        .toList();
    final List<String> sorted = <String>[...names]..sort();
    expect(names, sorted);
  });

  group('auto-match', () {
    test('pairs an untracked item instead of leaving it blank', () {
      // This is why he was re-pairing garlic on every single cook.
      final PantryItem? m = matchPantryItem('minced garlic', pantry);
      expect(m, isNotNull);
      expect(m!.name, contains('Minced California Garlic'));
    });

    test('pairs soy sauce', () {
      expect(matchPantryItem('soy sauce', pantry)?.name, contains('Kikkoman'));
    });

    test('will not pair something that has run out', () {
      // Every broccoli in the fixture is at zero.
      expect(matchPantryItem('broccoli', pantry), isNull);
    });

    test('prefers the exact name over a longer one that contains it', () {
      expect(matchPantryItem('brown whole grain rice', pantry)?.name,
          'Brown Whole Grain Rice (Mahatma)');
    });

    // The shelf puts words in the MIDDLE of a name. "minced garlic" is not a
    // substring of "Minced California Garlic", which is why containment alone
    // found nothing and he re-paired it every cook.
    test('reaches a name with an extra word buried in it', () {
      expect(matchPantryItem('minced garlic', pantry)?.name,
          contains('Minced California Garlic'));
    });

    test('a plural on the shelf still matches a singular in the recipe', () {
      expect(matchPantryItem('white onion', pantry)?.name, 'Onions, white, raw');
    });

    test('picks the closest fit, not merely a fit', () {
      // Both sirloin and ribeye are steak; only sirloin is in stock.
      expect(matchPantryItem('top sirloin steak', pantry)?.name,
          'Beef, top sirloin steak, raw');
    });

    test('unrelated words do not match', () {
      expect(matchPantryItem('chocolate', pantry), isNull);
    });
  });
}
