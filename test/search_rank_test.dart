import 'package:flutter_test/flutter_test.dart';
import 'package:pantry/food_lookup.dart';
import 'package:pantry/models.dart';

FoodHit _hit(String head, String full,
        {String brand = '', int bonus = 0}) =>
    FoodHit(
      info: ProductInfo(name: full, macrosPer100g: const Macros()),
      head: head,
      full: full,
      brand: brand,
      qualityBonus: bonus,
    );

void main() {
  group('foodMatchScore', () {
    test('"plantain" — whole food beats chips beats branded chips', () {
      final int raw =
          foodMatchScore('plantain', _hit('Plantains', 'Plantains, raw', bonus: 5));
      final int chips =
          foodMatchScore('plantain', _hit('Chips', 'Chips, plantain', bonus: 4));
      final int branded = foodMatchScore(
          'plantain', _hit('Plantain Chips', 'Plantain Chips (Barnana)', brand: 'Barnana'));
      expect(raw, greaterThan(chips));
      expect(raw, greaterThan(branded));
    });

    test('"onion" — plural head counts as exact', () {
      final int s =
          foodMatchScore('onion', _hit('Onions', 'Onions, raw', bonus: 5));
      expect(s, greaterThanOrEqualTo(130));
    });

    test('brand query boosts that brand', () {
      final int brand = foodMatchScore(
          'valletta', _hit('Orange Juice', 'Orange Juice (Valletta)', brand: 'Valletta'));
      final int other = foodMatchScore(
          'valletta', _hit('Orange Juice', 'Orange Juice (Tropicana)', brand: 'Tropicana'));
      expect(brand, greaterThan(other));
      expect(other, 0);
    });

    test('unrelated item scores zero', () {
      expect(foodMatchScore('plantain', _hit('Milk', 'Milk, whole', bonus: 5)), 0);
    });
  });
}
