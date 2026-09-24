import 'package:flutter_test/flutter_test.dart';
import 'package:pantry/measures.dart';

// The chef is told to write grams for anything that pours or scoops, and it
// keeps coming back with tablespoons anyway. A recipe already saved to the
// box keeps its tablespoons forever whatever the prompt does later, so the
// app converts rather than trusting.

void main() {
  group('spoons of things that pour', () {
    test('a tablespoon of olive oil', () {
      expect(gramsFor('Olive oil', '1 tbsp'), 13.6);
      expect(gramsFor('Extra virgin olive oil', '2 tablespoons'), 27.2);
    });

    test('teaspoons are a third of a tablespoon', () {
      expect(gramsFor('Olive oil', '3 tsp'), 13.6);
    });

    test('cups are sixteen tablespoons', () {
      expect(gramsFor('Chicken stock', '1 cup'), 240.0);
    });

    test('minced garlic beats plain garlic', () {
      // Longest key wins, or a jar of minced garlic would be priced as cloves.
      expect(gramsFor('Minced garlic', '1 tbsp'), 9.0);
    });

    test('tomato paste beats bare paste', () {
      expect(gramsFor('Tomato paste', '2 tbsp'), 32.0);
    });

    test('soy sauce', () {
      expect(gramsFor('Soy sauce', '1 tbsp'), 16.0);
    });
  });

  group('what must stay in spoons', () {
    // "I don't see why it asks for grams on spices. Like, who measures how
    // much salt and pepper?"
    test('salt and pepper are never weighed', () {
      expect(gramsFor('Salt', '1 tsp'), isNull);
      expect(gramsFor('Black pepper', '1 tsp'), isNull);
    });

    test('dried ground spices are never weighed', () {
      expect(gramsFor('Ground cumin', '2 tsp'), isNull);
      expect(gramsFor('Smoked paprika', '1 tbsp'), isNull);
      expect(gramsFor('Garlic powder', '1 tsp'), isNull);
      expect(gramsFor('Dried oregano', '1 tsp'), isNull);
    });

    test('garlic powder is not minced garlic', () {
      expect(gramsFor('Garlic powder', '1 tbsp'), isNull);
      expect(gramsFor('Minced garlic', '1 tbsp'), 9.0);
    });

    test('to taste is not a number', () {
      expect(gramsFor('Salt', 'to taste'), isNull);
      expect(gramsFor('Olive oil', 'a drizzle'), isNull);
    });
  });

  group('pieces', () {
    test('cloves of garlic', () {
      expect(gramsFor('Garlic', '2 cloves'), 6.0);
      expect(gramsFor('Garlic cloves', '4'), 12.0);
    });

    test('a medium onion', () {
      expect(gramsFor('Onion', '1 medium'), 110.0);
      expect(gramsFor('White onion', '2'), 220.0);
    });

    test('eggs stay a count', () {
      expect(gramsFor('Eggs', '2'), isNull);
      expect(gramsFor('Tortillas', '4'), isNull);
    });

    test('something with no sensible weight stays blank', () {
      expect(gramsFor('Mystery vegetable', '2'), isNull);
      expect(gramsFor('Mystery sauce', '1 tbsp'), isNull);
    });
  });

  group('weights already', () {
    test('grams pass straight through', () {
      expect(gramsFor('Beef', '480 g'), 480.0);
      expect(gramsFor('Beef', '480 grams'), 480.0);
    });

    test('other weight units are converted', () {
      // Whole grams above 100, because that is what the scale shows.
      expect(gramsFor('Beef', '1 lb'), 454.0);
      expect(gramsFor('Beef', '8 oz'), 227.0);
      expect(gramsFor('Beef', '1.2 kg'), 1200.0);
    });

    test('millilitres of water are grams of water', () {
      expect(gramsFor('Water', '200 ml'), 200.0);
    });
  });

  group('rounding reads like a scale', () {
    test('small amounts keep one decimal, large ones are whole', () {
      expect(gramsFor('Olive oil', '1 tbsp'), 13.6);
      expect(gramsFor('Chicken stock', '2 cups'), 480.0);
    });
  });

  group('the classifiers themselves', () {
    test('seasonings are recognised', () {
      expect(isSeasoning('Ground cumin'), isTrue);
      expect(isSeasoning('Kosher salt'), isTrue);
      expect(isSeasoning('Olive oil'), isFalse);
      expect(isSeasoning('Minced garlic'), isFalse);
    });

    test('counted things are recognised', () {
      expect(staysACount('Large eggs'), isTrue);
      expect(staysACount('Corn tortillas'), isTrue);
      expect(staysACount('Onion'), isFalse);
    });
  });
}
