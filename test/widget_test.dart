// Smoke test + unit tests for the pantry data model.

import 'package:flutter_test/flutter_test.dart';

import 'package:pantry/main.dart';
import 'package:pantry/models.dart';

PantryItem _weight({
  String id = '1',
  double total = 454,
  double remaining = 454,
  double price = 5.99,
  int updatedAtMs = 0,
  String? expiration,
}) =>
    PantryItem(
      id: id,
      name: 'ground turkey',
      unit: kUnitGrams,
      total: total,
      remaining: remaining,
      price: price,
      macros: const Macros(proteinG: 27, calories: 170, fatG: 9),
      dateAdded: '2026-07-02',
      lastPrice: price,
      updatedAtMs: updatedAtMs,
      expirationDate: expiration,
    );

void main() {
  testWidgets('App boots to the Pantry screen', (WidgetTester tester) async {
    await tester.pumpWidget(const PantryApp());
    await tester.pump();
    expect(find.text('Pantry'), findsWidgets);
  });

  test('price_per (weight) is price ÷ total grams', () {
    expect(_weight().pricePer, closeTo(5.99 / 454, 1e-9));
  });

  test('expiring_soon flags within the window, ignores far-off dates', () {
    final DateTime now = DateTime(2026, 7, 2);
    expect(_weight(expiration: '2026-07-05').isExpiringSoon(now), isTrue);
    expect(_weight(expiration: '2026-08-01').isExpiringSoon(now), isFalse);
    expect(_weight(expiration: '2026-07-01').isExpiringSoon(now), isTrue);
  });

  test('merge keeps the newer copy per id (last-write-wins)', () {
    final PantryData remote =
        PantryData(pantry: <PantryItem>[_weight(remaining: 600, updatedAtMs: 100)]);
    final PantryData local =
        PantryData(pantry: <PantryItem>[_weight(remaining: 350, updatedAtMs: 200)]);
    final PantryData merged = PantryData.merge(remote, local);
    expect(merged.pantry.length, 1);
    expect(merged.pantry.first.remaining, 350);
  });

  test('count item round-trips through JSON with count keys', () {
    final PantryItem eggs = PantryItem(
      id: 'e1',
      name: 'eggs',
      unit: kUnitCount,
      total: 12,
      remaining: 12,
      price: 3.49,
      macros: const Macros(),
      dateAdded: '2026-07-02',
      lastPrice: 3.49,
    );
    final Map<String, dynamic> j = eggs.toJson(DateTime(2026, 7, 2));
    expect(j['unit'], 'count');
    expect(j['total_count'], 12);
    expect(j['remaining_count'], 12);
    expect(j.containsKey('total_weight_g'), isFalse);
    expect(j['price_per_unit'], closeTo(3.49 / 12, 1e-3)); // rounded to 4 dp

    final PantryItem back = PantryItem.fromJson(j);
    expect(back.isCount, isTrue);
    expect(back.total, 12);
    expect(back.remaining, 12);
  });

  test('weight item still emits the original grams schema', () {
    final Map<String, dynamic> j = _weight().toJson(DateTime(2026, 7, 2));
    expect(j['total_weight_g'], 454);
    expect(j['remaining_weight_g'], 454);
    expect(j.containsKey('price_per_gram'), isTrue);
    expect(j.containsKey('macros_per_100g'), isTrue);
    expect(j.containsKey('unit'), isFalse); // weight is the implicit default
  });
}
