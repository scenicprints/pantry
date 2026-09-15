// What the chef is told a thing costs.
//
// Reported: a meal for three came back at $55. The chef was not being
// extravagant — it was quoting the price book faithfully, and the price book
// had the same chicken breast at both $5.67 and $22.68 a pound, plus entries
// where a mistyped pack weight left orange juice at $226 a pound.
//
// The prompt says to use these prices EXACTLY, so anything wrong here lands
// straight in the cost of dinner.

import 'package:flutter_test/flutter_test.dart';

import 'package:pantry/chef.dart';
import 'package:pantry/models.dart';
import 'package:pantry/pricebook.dart';

/// A price per gram from a $/lb figure, which is how a shelf label reads.
double perLb(double dollars) => dollars / 453.6;

PriceBook book(List<PriceEntry> entries) => PriceBook(<String, PriceEntry>{
      for (final PriceEntry e in entries) e.name.trim().toLowerCase(): e,
    });

PriceEntry weightEntry(String name, double dollarsPerLb) => PriceEntry(
      name: name,
      unitPrice: perLb(dollarsPerLb),
      unit: 'g',
      ts: 1,
    );

void main() {
  group('the prices handed to the chef', () {
    test('the same food twice quotes the cheaper one', () {
      final String out = Chef.formatKnownPrices(
          book(<PriceEntry>[
            weightEntry('Boneless, Skinless Chicken Breast Fillet (Just BARE)',
                22.68),
            weightEntry('Chicken Breast Fillets (Co-op)', 5.67),
          ]),
          const <PantryItem>[]);
      // One chicken line, and it is the affordable one.
      expect('chicken'.allMatches(out.toLowerCase()).length, 1);
      expect(out, contains('0.01')); // ~\$0.0125/g, not \$0.05/g
      expect(out, isNot(contains('0.05')));
    });

    test('a mistyped pack weight is dropped, not quoted', () {
      final String out = Chef.formatKnownPrices(
          book(<PriceEntry>[
            weightEntry('100% Fresh Squeezed Orange Juice', 226.26),
            weightEntry('Tomato Paste Sunny Select', 2.72),
          ]),
          const <PantryItem>[]);
      expect(out.toLowerCase(), isNot(contains('orange juice')));
      expect(out.toLowerCase(), contains('tomato paste'));
    });

    test('genuinely dear food still gets quoted', () {
      // Gruyere really is $40 a pound. Dropping it would make the chef
      // guess low on a dish that leans on it.
      final String out = Chef.formatKnownPrices(
          book(<PriceEntry>[weightEntry('Gruyere Cheese (Emmi)', 40.46)]),
          const <PantryItem>[]);
      expect(out.toLowerCase(), contains('gruyere'));
    });

    test('brand and packaging words do not split one food into two', () {
      final String out = Chef.formatKnownPrices(
          book(<PriceEntry>[
            weightEntry('fresh ground turkey breast (Jennie-O)', 10.80),
            weightEntry('GROUND TURKEY BREAST (Butterball)', 8.62),
          ]),
          const <PantryItem>[]);
      expect('turkey'.allMatches(out.toLowerCase()).length, 1);
    });

    test('a food in stock is not repeated in the new-buy list', () {
      final String out = Chef.formatKnownPrices(
          book(<PriceEntry>[weightEntry('Tahini', 8.44)]),
          <PantryItem>[
            PantryItem(
              id: '1',
              name: 'Tahini',
              unit: kUnitGrams,
              total: 500,
              remaining: 500,
              price: 12.99,
              lastPrice: 12.99,
              macros: const Macros(),
              dateAdded: '2026-09-01',
            ),
          ]);
      expect(out, isEmpty);
    });

    test('different foods are both kept', () {
      final String out = Chef.formatKnownPrices(
          book(<PriceEntry>[
            weightEntry('Chicken Breast Fillets (Co-op)', 5.67),
            weightEntry('Ground Beef 93%', 10.34),
          ]),
          const <PantryItem>[]);
      expect(out.toLowerCase(), contains('chicken'));
      expect(out.toLowerCase(), contains('beef'));
    });
  });
}
