// Smoke test + unit tests for the pantry data model.

import 'package:flutter_test/flutter_test.dart';

import 'package:pantry/main.dart';
import 'package:pantry/models.dart';

void main() {
  testWidgets('App boots to the Pantry screen', (WidgetTester tester) async {
    await tester.pumpWidget(const PantryApp());
    await tester.pump();
    expect(find.text('Pantry'), findsWidgets);
  });

  test('price_per_gram is price ÷ total weight', () {
    final PantryItem it = PantryItem(
      id: '1',
      name: 'ground turkey',
      totalWeightG: 454,
      remainingWeightG: 454,
      price: 5.99,
      macrosPer100g: const Macros(proteinG: 27, calories: 170, fatG: 9),
      dateAdded: '2026-07-02',
      lastPrice: 5.99,
    );
    expect(it.pricePerGram, closeTo(5.99 / 454, 1e-9));
  });

  test('expiring_soon flags within the window and ignores far-off dates', () {
    final DateTime now = DateTime(2026, 7, 2);
    PantryItem withExp(String date) => PantryItem(
          id: 'x',
          name: 'milk',
          totalWeightG: 1000,
          remainingWeightG: 1000,
          price: 3,
          macrosPer100g: const Macros(),
          dateAdded: '2026-07-02',
          lastPrice: 3,
          expirationDate: date,
        );
    expect(withExp('2026-07-05').isExpiringSoon(now), isTrue); // 3 days out
    expect(withExp('2026-08-01').isExpiringSoon(now), isFalse); // far off
    expect(withExp('2026-07-01').isExpiringSoon(now), isTrue); // already past
  });

  test('merge keeps the newer copy per id (last-write-wins)', () {
    PantryItem v(int ms, double remaining) => PantryItem(
          id: 'same',
          name: 'eggs',
          totalWeightG: 600,
          remainingWeightG: remaining,
          price: 4,
          macrosPer100g: const Macros(),
          dateAdded: '2026-07-02',
          lastPrice: 4,
          updatedAtMs: ms,
        );
    final PantryData remote = PantryData(pantry: <PantryItem>[v(100, 600)]);
    final PantryData local = PantryData(pantry: <PantryItem>[v(200, 350)]);
    final PantryData merged = PantryData.merge(remote, local);
    expect(merged.pantry.length, 1);
    expect(merged.pantry.first.remainingWeightG, 350); // newer wins
  });
}
