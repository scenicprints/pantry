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

    test('"bell peppers" — modifier after the comma still counts as the head',
        () {
      // USDA taxonomy: "Peppers, bell, green, raw". Must beat a brand that
      // merely starts with "Bell" and any packaged bell-pepper product.
      final int whole = foodMatchScore('bell peppers',
          _hit('Peppers', 'Peppers, bell, green, raw', bonus: 6));
      final int brandCoincidence = foodMatchScore('bell peppers',
          _hit('Chicken Tenders', 'Chicken Tenders (Bell & Evans)', brand: 'Bell & Evans'));
      final int packaged = foodMatchScore('bell peppers',
          _hit('Bell Peppers, Red', 'Bell Peppers, Red (Kroger)', brand: 'Kroger'));
      final int hot = foodMatchScore(
          'bell peppers', _hit('Peppers', 'Peppers, hot, raw', bonus: 4));
      expect(whole, greaterThanOrEqualTo(100));
      expect(whole, greaterThan(brandCoincidence));
      expect(whole, greaterThan(packaged));
      expect(hot, 0);
    });
  });

  group('UsdaGeneric parsing — Foundation foods without nutrient 208', () {
    Map<String, dynamic> food(List<Map<String, dynamic>> nutrients) =>
        <String, dynamic>{
          'description': 'Peppers, bell, green, raw',
          'dataType': 'Foundation',
          'foodNutrients': nutrients,
        };
    Map<String, dynamic> n(String number, double value) =>
        <String, dynamic>{'nutrientNumber': number, 'value': value};

    test('the real bell-pepper shape (957/958, no 208) is NOT dropped', () {
      final FoodHit? h = UsdaGeneric.parseForTest(food(<Map<String, dynamic>>[
        n('203', 0.86), n('204', 0.13), n('205', 4.71),
        n('957', 20.0), n('958', 19.0),
      ]));
      expect(h, isNotNull);
      expect(h!.info.macrosPer100g.calories, 20.0);
    });

    test('208 wins when present; macros derive energy when nothing else', () {
      expect(
          UsdaGeneric.parseForTest(food(<Map<String, dynamic>>[
            n('208', 25.0), n('957', 20.0)
          ]))!.info.macrosPer100g.calories,
          25.0);
      expect(
          UsdaGeneric.parseForTest(food(<Map<String, dynamic>>[
            n('203', 10.0), n('204', 5.0), n('205', 20.0)
          ]))!.info.macrosPer100g.calories,
          closeTo(165.0, 1e-9));
    });

    test('a row with no nutrition at all is still dropped', () {
      expect(UsdaGeneric.parseForTest(food(<Map<String, dynamic>>[n('291', 2.0)])),
          isNull);
    });
  });
}
