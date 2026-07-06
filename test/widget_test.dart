// Smoke test + unit tests for the pantry data model.

import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';

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
      servingSize: 100,
      servingUnit: 'g',
      dateAdded: '2026-07-02',
      lastPrice: price,
      updatedAtMs: updatedAtMs,
      expirationDate: expiration,
    );

void main() {
  testWidgets('App boots to the Pantry screen', (WidgetTester tester) async {
    GoogleFonts.config.allowRuntimeFetching = false; // no network in tests
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

  test('a deleted item is tombstoned in merge and dropped from the chef file',
      () {
    // Remote still holds the live item; local has deleted it (newer stamp).
    final PantryData remote =
        PantryData(pantry: <PantryItem>[_weight(updatedAtMs: 100)]);
    final PantryItem gone = _weight(updatedAtMs: 200)..deleted = true;
    final PantryData local = PantryData(pantry: <PantryItem>[gone]);

    final PantryData merged = PantryData.merge(remote, local);
    expect(merged.pantry.single.deleted, isTrue); // tombstone wins, not resurrected

    // The GitHub file (keepDeleted:false) must NOT contain it...
    final PantryData remoteFile =
        PantryData.decode(merged.encode(DateTime(2026, 7, 2)));
    expect(remoteFile.pantry, isEmpty);

    // ...but the local cache (keepDeleted:true) keeps the tombstone.
    final PantryData cache = PantryData.decode(
        merged.encode(DateTime(2026, 7, 2), keepDeleted: true));
    expect(cache.pantry.single.deleted, isTrue);
  });

  test('weight item still emits the original grams schema', () {
    final Map<String, dynamic> j = _weight().toJson(DateTime(2026, 7, 2));
    expect(j['total_weight_g'], 454);
    expect(j['remaining_weight_g'], 454);
    expect(j.containsKey('price_per_gram'), isTrue);
    expect(j.containsKey('macros_per_100g'), isTrue);
    expect(j.containsKey('unit'), isFalse); // weight is the implicit default
  });

  test('per-serving macros derive per-100 g when the serving is in grams', () {
    // 30 g serving with 6 g protein → 20 g protein / 100 g.
    final PantryItem it = PantryItem(
      id: 's1',
      name: 'crackers',
      total: 200,
      remaining: 200,
      price: 3,
      macros: const Macros(proteinG: 6, calories: 120),
      servingSize: 30,
      servingUnit: 'g',
      dateAdded: '2026-07-02',
      lastPrice: 3,
    );
    final Map<String, dynamic> j = it.toJson(DateTime(2026, 7, 2));
    expect(j['serving_size'], 30);
    expect(j['serving_unit'], 'g');
    expect((j['macros_per_serving'] as Map)['protein_g'], 6);
    expect((j['macros_per_100g'] as Map)['protein_g'], closeTo(20, 1e-6));
  });

  test('a non-gram serving unit does not emit a derived per-100 g', () {
    final PantryItem it = PantryItem(
      id: 's2',
      name: 'protein cookies',
      total: 12,
      remaining: 12,
      unit: kUnitCount,
      price: 6,
      macros: const Macros(proteinG: 10, calories: 150),
      servingSize: 1,
      servingUnit: 'cookie',
      dateAdded: '2026-07-02',
      lastPrice: 6,
    );
    final Map<String, dynamic> j = it.toJson(DateTime(2026, 7, 2));
    expect(j['serving_unit'], 'cookie');
    expect(j.containsKey('macros_per_serving'), isTrue);
    expect(j.containsKey('macros_per_100g'), isFalse);
  });

  test('spice item: own category, untracked, round-trips', () {
    final PantryItem salt = PantryItem(
      id: 's',
      name: 'cumin',
      total: 0,
      remaining: 0,
      price: 0,
      macros: const Macros(),
      dateAdded: '2026-07-06',
      lastPrice: 0,
      spice: true,
    );
    expect(salt.category, 'Spices');
    expect(salt.untracked, isTrue);
    final Map<String, dynamic> j = salt.toJson(DateTime(2026, 7, 6));
    expect(j['category'], 'Spices');
    expect(j['spice'], true);
    final PantryItem back = PantryItem.fromJson(j);
    expect(back.spice, isTrue);
    expect(back.category, 'Spices');
  });

  test('quantity-unknown item is untracked in the Pantry category', () {
    final PantryItem it = PantryItem(
      id: 'q',
      name: 'leftover rice',
      total: 0,
      remaining: 0,
      price: 0,
      macros: const Macros(),
      dateAdded: '2026-07-06',
      lastPrice: 0,
      quantityUnknown: true,
    );
    expect(it.untracked, isTrue);
    expect(it.category, 'Pantry');
    final PantryItem back = PantryItem.fromJson(it.toJson(DateTime(2026, 7, 6)));
    expect(back.quantityUnknown, isTrue);
    expect(back.spice, isFalse);
  });

  test('legacy macros_per_100g migrates to a 100 g serving', () {
    final PantryItem it = PantryItem.fromJson(<String, dynamic>{
      'id': 'old',
      'name': 'rice',
      'total_weight_g': 900,
      'remaining_weight_g': 900,
      'price': 2.0,
      'macros_per_100g': <String, dynamic>{'protein_g': 7, 'calories': 360},
      'date_added': '2026-07-02',
      'last_price': 2.0,
    });
    expect(it.servingSize, 100);
    expect(it.servingUnit, 'g');
    expect(it.macros.proteinG, 7);
  });
}
