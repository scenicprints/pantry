// How an amount rounds when a recipe is scaled, and the cook notes that feed
// back into the next version of it.

import 'package:flutter_test/flutter_test.dart';

import 'package:pantry/chef_models.dart';
import 'package:pantry/storage.dart';

void main() {
  group('rounding by what measures it', () {
    String scale(String amount, double f) =>
        RecipeIngredient(item: 'x', amount: amount).scaled(f);

    test('weights go to whole units', () {
      expect(scale('480 g', 0.5), '240 g');
      expect(scale('101 g', 0.5), '51 g');
      expect(scale('250 ml', 1.5), '375 ml');
    });

    test('spoons go to quarters, not to whole spoons', () {
      // The old rule rounded a halved teaspoon back up to a whole one.
      expect(scale('1 tsp', 0.5), '0.5 tsp');
      expect(scale('1 tbsp', 0.25), '0.25 tbsp');
      expect(scale('1 tsp', 0.75), '0.75 tsp');
      expect(scale('2 tsp', 2), '4 tsp');
    });

    test('counts go to halves', () {
      expect(scale('2', 0.75), '1.5');
      expect(scale('3 cloves', 0.5), '1.5 cloves');
    });

    test('scaling down never rounds a real amount away to nothing', () {
      expect(scale('1 tsp', 0.1), '0.25 tsp');
      expect(scale('480 g', 0.001), '1 g');
      expect(scale('1', 0.1), '0.5');
    });

    test('a whole result carries no decimal point', () {
      expect(scale('200 g', 1), '200 g');
      expect(scale('2 tbsp', 1), '2 tbsp');
    });
  });

  group('cook notes', () {
    setUp(() {
      for (final String t in <String>['Chili', 'Risotto']) {
        while (LocalCache.loadNotes(t).isNotEmpty) {
          LocalCache.removeNote(t, 0);
        }
      }
    });

    test('notes are kept per recipe, oldest first', () {
      LocalCache.addNote('Chili', 'Too salty.');
      LocalCache.addNote('Chili', 'Wanted 5 more minutes.');
      LocalCache.addNote('Risotto', 'Stock ran out.');
      expect(LocalCache.loadNotes('Chili'),
          <String>['Too salty.', 'Wanted 5 more minutes.']);
      expect(LocalCache.loadNotes('Risotto'), <String>['Stock ran out.']);
    });

    test('an empty note is not a note', () {
      LocalCache.addNote('Chili', '   ');
      LocalCache.addNote('Chili', '');
      expect(LocalCache.loadNotes('Chili'), isEmpty);
    });

    test('notes are trimmed', () {
      LocalCache.addNote('Chili', '  Too salty.  ');
      expect(LocalCache.loadNotes('Chili').single, 'Too salty.');
    });

    test('only the last six survive, oldest dropped first', () {
      for (int i = 1; i <= 8; i++) {
        LocalCache.addNote('Chili', 'note $i');
      }
      final List<String> notes = LocalCache.loadNotes('Chili');
      expect(notes, hasLength(6));
      expect(notes.first, 'note 3');
      expect(notes.last, 'note 8');
    });

    test('removing one leaves the rest in order', () {
      LocalCache.addNote('Chili', 'a');
      LocalCache.addNote('Chili', 'b');
      LocalCache.addNote('Chili', 'c');
      LocalCache.removeNote('Chili', 1);
      expect(LocalCache.loadNotes('Chili'), <String>['a', 'c']);
    });

    test('an out-of-range remove changes nothing', () {
      LocalCache.addNote('Chili', 'a');
      LocalCache.removeNote('Chili', 7);
      LocalCache.removeNote('Chili', -1);
      expect(LocalCache.loadNotes('Chili'), <String>['a']);
    });

    test('a recipe never cooked has no notes', () {
      expect(LocalCache.loadNotes('Something else'), isEmpty);
    });
  });
}
