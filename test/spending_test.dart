import 'package:flutter_test/flutter_test.dart';
import 'package:pantry/models.dart';
import 'package:pantry/pricebook.dart';
import 'package:pantry/spending.dart';

PantryItem _item({
  String id = 'a',
  String name = 'Chicken',
  String unit = 'g',
  double total = 1000,
  double remaining = 1000,
  double price = 10, // $10 for 1000 g → $0.01/g
  String? barcode,
}) =>
    PantryItem(
      id: id,
      name: name,
      unit: unit,
      total: total,
      remaining: remaining,
      price: price,
      macros: const Macros(),
      dateAdded: '2026-07-01',
      lastPrice: price,
      barcode: barcode,
    );

void main() {
  group('week (Sun–Sat) math', () {
    test('weekStart is always a Sunday and contains the date', () {
      for (int i = 0; i < 14; i++) {
        final DateTime d = DateTime(2026, 7, 1 + i, 13, 30);
        final DateTime ws = SpendingLog.weekStart(d);
        expect(ws.weekday, DateTime.sunday, reason: 'day $d');
        expect(ws.hour, 0);
        expect(ws.minute, 0);
        expect(!d.isBefore(ws), true);
        expect(d.isBefore(ws.add(const Duration(days: 7))), true);
      }
    });

    test('an entry on Saturday 23:59 counts this week; Sunday next week does not',
        () {
      final DateTime wed = DateTime(2026, 7, 8, 12); // reference "now"
      final DateTime ws = SpendingLog.weekStart(wed);
      final DateTime sat = ws.add(const Duration(days: 6, hours: 23, minutes: 59));
      final DateTime nextSun = ws.add(const Duration(days: 7));
      final SpendingLog log = SpendingLog(<UsageEntry>[
        UsageEntry(
            id: '1',
            ts: sat.millisecondsSinceEpoch,
            itemId: 'a',
            name: 'A',
            amount: 1,
            unit: 'g',
            unitPrice: 1,
            cost: 5),
        UsageEntry(
            id: '2',
            ts: nextSun.millisecondsSinceEpoch,
            itemId: 'b',
            name: 'B',
            amount: 1,
            unit: 'g',
            unitPrice: 1,
            cost: 9),
      ]);
      expect(log.weekTotal(wed), 5.0);
    });
  });

  group('month math', () {
    test('this month vs last month split correctly', () {
      final DateTime now = DateTime(2026, 7, 15, 9);
      final SpendingLog log = SpendingLog(<UsageEntry>[
        _entryOn(DateTime(2026, 7, 2), 3.00),
        _entryOn(DateTime(2026, 7, 20), 4.50),
        _entryOn(DateTime(2026, 6, 28), 7.25),
      ]);
      expect(log.monthTotal(now), 7.50);
      expect(log.lastMonthTotal(now), 7.25);
    });

    test('December → January wraps years', () {
      final DateTime jan = DateTime(2026, 1, 10);
      final SpendingLog log = SpendingLog(<UsageEntry>[
        _entryOn(DateTime(2025, 12, 20), 12.00),
        _entryOn(DateTime(2026, 1, 5), 2.00),
      ]);
      expect(log.monthTotal(jan), 2.00);
      expect(log.lastMonthTotal(jan), 12.00);
    });
  });

  group('averages (per active week / month)', () {
    test('avg per month = total ÷ months that had spend', () {
      final SpendingLog log = SpendingLog(<UsageEntry>[
        _entryOn(DateTime(2026, 5, 3), 10.00), // May
        _entryOn(DateTime(2026, 5, 20), 20.00), // May → May total 30
        _entryOn(DateTime(2026, 7, 4), 6.00), // July → July total 6
      ]);
      // two active months (May=30, July=6) → (30+6)/2 = 18
      expect(log.averagePerMonth(), 18.00);
    });

    test('avg per week = total ÷ weeks that had spend', () {
      final SpendingLog log = SpendingLog(<UsageEntry>[
        _entryOn(DateTime(2026, 7, 6), 4.00), // week A (Mon)
        _entryOn(DateTime(2026, 7, 7), 6.00), // week A (Tue) → 10
        _entryOn(DateTime(2026, 7, 15), 2.00), // week B → 2
      ]);
      expect(log.averagePerWeek(), 6.00); // (10 + 2) / 2
    });

    test('empty ledger averages to 0', () {
      expect(const SpendingLog().averagePerWeek(), 0);
      expect(const SpendingLog().averagePerMonth(), 0);
    });

    test('zero-cost entries are ignored, no divide-by-zero', () {
      final SpendingLog log = SpendingLog(<UsageEntry>[
        _entryOn(DateTime(2026, 7, 6), 0.00),
      ]);
      expect(log.averagePerWeek(), 0);
      expect(log.averagePerMonth(), 0);
    });
  });

  group('ledger merge (append-only, union by id)', () {
    test('union keeps all distinct ids and dedupes matching ones', () {
      final SpendingLog a = SpendingLog(<UsageEntry>[
        _entryOn(DateTime(2026, 7, 1), 1.00, id: 'x'),
        _entryOn(DateTime(2026, 7, 2), 2.00, id: 'y'),
      ]);
      final SpendingLog b = SpendingLog(<UsageEntry>[
        _entryOn(DateTime(2026, 7, 2), 2.00, id: 'y'), // dup
        _entryOn(DateTime(2026, 7, 3), 3.00, id: 'z'),
      ]);
      final SpendingLog m = SpendingLog.merge(a, b);
      expect(m.entries.length, 3);
      expect(m.entries.map((UsageEntry e) => e.id).toSet(), {'x', 'y', 'z'});
      // sorted oldest → newest
      expect(m.entries.first.id, 'x');
      expect(m.entries.last.id, 'z');
    });

    test('encode → decode round-trips', () {
      final SpendingLog a = SpendingLog(<UsageEntry>[
        _entryOn(DateTime(2026, 7, 1), 1.23, id: 'x'),
      ]);
      final SpendingLog b = SpendingLog.decode(a.encode());
      expect(b.entries.length, 1);
      expect(b.entries.first.cost, 1.23);
      expect(b.entries.first.id, 'x');
    });
  });

  group('UsageEntry cost snapshot', () {
    test('cost = amount × price-per-unit at time of use', () {
      final PantryItem it = _item(price: 10, total: 1000); // $0.01/g
      final UsageEntry e =
          UsageEntry.forUse(it, 250, DateTime(2026, 7, 8)); // 250 g used
      expect(e.unitPrice, 0.01);
      expect(e.cost, 2.5); // 250 × 0.01
      expect(e.unit, 'g');
    });

    test('count item costs per unit', () {
      final PantryItem eggs =
          _item(id: 'e', name: 'Eggs', unit: 'count', total: 12, price: 3.60);
      final UsageEntry e = UsageEntry.forUse(eggs, 2, DateTime(2026, 7, 8));
      expect(e.unitPrice, 0.30); // $3.60 / 12
      expect(e.cost, 0.60);
    });
  });

  group('PriceBook', () {
    test('records item price, looks it up case-insensitively', () {
      final PriceBook pb =
          const PriceBook().withItem(_item(name: 'Olive Oil', price: 15, total: 1000), DateTime(2026, 7, 1));
      expect(pb.lookup('olive oil')?.unitPrice, 0.015);
      expect(pb.lookup('OLIVE OIL')?.unitPrice, 0.015);
    });

    test('untracked / unpriced items are not recorded', () {
      final PantryItem spice = PantryItem(
        id: 's',
        name: 'Cumin',
        total: 0,
        remaining: 0,
        price: 0,
        macros: const Macros(),
        dateAdded: '2026-07-01',
        lastPrice: 0,
        spice: true,
      );
      final PriceBook pb = const PriceBook().withItem(spice, DateTime(2026, 7, 1));
      expect(pb.isEmpty, true);
    });

    test('merge keeps the newer price', () {
      final PriceBook older = const PriceBook()
          .withItem(_item(name: 'Rice', price: 5, total: 1000), DateTime(2026, 6, 1));
      final PriceBook newer = const PriceBook()
          .withItem(_item(name: 'Rice', price: 8, total: 1000), DateTime(2026, 7, 1));
      final PriceBook m = PriceBook.merge(older, newer);
      expect(m.lookup('rice')?.unitPrice, 0.008);
      // reverse order, same result (newer ts wins)
      final PriceBook m2 = PriceBook.merge(newer, older);
      expect(m2.lookup('rice')?.unitPrice, 0.008);
    });

    test('encode → decode round-trips', () {
      final PriceBook pb = const PriceBook()
          .withItem(_item(name: 'Butter', price: 4, total: 454), DateTime(2026, 7, 1));
      final PriceBook back = PriceBook.decode(pb.encode());
      expect(back.lookup('butter')?.unit, 'g');
      expect(back.lookup('butter')?.unitPrice != null, true);
    });
  });
}

UsageEntry _entryOn(DateTime d, double cost, {String? id}) => UsageEntry(
      id: id ?? '${d.millisecondsSinceEpoch}',
      ts: d.millisecondsSinceEpoch,
      itemId: 'i',
      name: 'Item',
      amount: 1,
      unit: 'g',
      unitPrice: cost,
      cost: cost,
    );
