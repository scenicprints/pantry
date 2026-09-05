import 'package:flutter_test/flutter_test.dart';
import 'package:pantry/chef.dart';
import 'package:pantry/models.dart';
import 'package:pantry/pricebook.dart';
import 'package:pantry/spending.dart';

// ═══════════════════════════════════════════════════════════════════════
// The cost-conscious half of the chef: the spend profile it reads, the
// protein-value list it costs a dinner with, and the price book's memory of
// how much protein a food carries.
// ═══════════════════════════════════════════════════════════════════════

PantryItem _item({
  String id = 'a',
  String name = 'Chicken',
  String unit = 'g',
  double total = 1000,
  double remaining = 1000,
  double price = 10, // $10 for 1000 g → $0.01/g
  Macros macros = const Macros(),
  double servingSize = 0,
  String servingUnit = 'g',
}) =>
    PantryItem(
      id: id,
      name: name,
      unit: unit,
      total: total,
      remaining: remaining,
      price: price,
      macros: macros,
      servingSize: servingSize,
      servingUnit: servingUnit,
      dateAdded: '2026-07-01',
      lastPrice: price,
    );

/// One consumption event of [cost] dollars on [day].
UsageEntry _use(String name, double cost, DateTime day) => UsageEntry(
      id: '$name-${day.millisecondsSinceEpoch}',
      ts: day.millisecondsSinceEpoch,
      itemId: name,
      name: name,
      amount: 100,
      unit: 'g',
      unitPrice: cost / 100,
      cost: cost,
    );

void main() {
  // Wednesday 2026-09-02. Its week starts Sunday 2026-08-30.
  final DateTime now = DateTime(2026, 9, 2, 18, 0);

  group('SpendProfile', () {
    test('an empty ledger claims no history', () {
      const SpendingLog log = SpendingLog();
      final SpendProfile p = log.profile(now);
      expect(p.hasHistory, false);
      expect(p.typicalWeek, 0);
      expect(p.drivers, isEmpty);
    });

    test('one week is not yet a habit', () {
      final SpendingLog log =
          const SpendingLog().add(_use('Beef', 40, DateTime(2026, 8, 25)));
      expect(log.profile(now).hasHistory, false);
    });

    test('the current partial week never dilutes the average', () {
      // Two complete weeks at $40 each, plus $5 so far this week.
      final SpendingLog log = const SpendingLog()
          .add(_use('Beef', 40, DateTime(2026, 8, 18))) // week of Aug 16
          .add(_use('Beef', 40, DateTime(2026, 8, 25))) // week of Aug 23
          .add(_use('Rice', 5, DateTime(2026, 9, 1))); // current week
      final SpendProfile p = log.profile(now);
      expect(p.activeWeeks, 2);
      expect(p.avgPerWeek, 40);
      expect(p.weekToDate, 5);
      expect(p.lastWeek, 40); // the last COMPLETE week, not this one
    });

    test('weeks with no spend at all are simply absent, not zeroes', () {
      final SpendingLog log = const SpendingLog()
          .add(_use('Beef', 40, DateTime(2026, 8, 4)))
          .add(_use('Beef', 60, DateTime(2026, 8, 25)));
      final SpendProfile p = log.profile(now);
      expect(p.activeWeeks, 2);
      expect(p.avgPerWeek, 50); // (40 + 60) / 2, not / 4
    });

    test('a climbing bill is detected against the weeks before it', () {
      SpendingLog log = const SpendingLog();
      // Jul 5 - Jul 26 quiet at $30, then Aug 2 - Aug 23 at $60. The two
      // windows have to be adjacent or there is nothing to compare.
      for (int i = 0; i < 4; i++) {
        log = log.add(_use('Beans', 30, DateTime(2026, 7, 5 + i * 7)));
      }
      for (int i = 0; i < 4; i++) {
        log = log.add(_use('Bison', 60, DateTime(2026, 8, 2 + i * 7)));
      }
      final SpendProfile p = log.profile(now);
      expect(p.recentAvgPerWeek, 60);
      expect(p.priorAvgPerWeek, 30);
      expect(p.trendPct, 100);
      expect(p.isClimbing, true);
      expect(p.typicalWeek, 60); // recent reality, not the all-time $45
    });

    test('a steady bill is not reported as climbing', () {
      SpendingLog log = const SpendingLog();
      for (int i = 0; i < 8; i++) {
        log = log.add(_use('Beans', 42, DateTime(2026, 7, 5 + i * 7)));
      }
      final SpendProfile p = log.profile(now);
      expect(p.isClimbing, false);
      expect(p.trendPct, 0);
    });

    test('drivers are the recent window, and include the current week', () {
      final SpendingLog log = const SpendingLog()
          // Old and expensive, but outside the window.
          .add(_use('Ribeye', 500, DateTime(2026, 5, 5)))
          .add(_use('Bison', 50, DateTime(2026, 8, 11)))
          .add(_use('Bison', 50, DateTime(2026, 8, 18)))
          .add(_use('Lentils', 4, DateTime(2026, 8, 25)))
          .add(_use('Bison', 20, DateTime(2026, 9, 1))); // current week
      final SpendProfile p = log.profile(now);
      final List<String> names =
          p.drivers.map((MapEntry<String, double> e) => e.key).toList();
      expect(names.first, 'Bison');
      expect(names.contains('Ribeye'), false, reason: 'outside the window');
      expect(p.drivers.first.value, 120); // 50 + 50 + 20, current week counted
    });

    test('weeklyTotals buckets by Sunday, oldest first', () {
      final SpendingLog log = const SpendingLog()
          .add(_use('A', 10, DateTime(2026, 8, 25)))
          .add(_use('B', 5, DateTime(2026, 8, 27))) // same week
          .add(_use('C', 7, DateTime(2026, 8, 18)));
      final List<MapEntry<DateTime, double>> weeks = log.weeklyTotals();
      expect(weeks.length, 2);
      expect(weeks.first.key.weekday, DateTime.sunday);
      expect(weeks.first.value, 7);
      expect(weeks.last.value, 15);
    });
  });

  group('protein value', () {
    test('cost per gram of protein comes off the scanned macros', () {
      // $10 / 1000 g = $0.01/g. 30 g protein per 100 g serving → 0.3 g/g.
      final PantryItem chicken =
          _item(macros: const Macros(proteinG: 30), servingSize: 100);
      expect(chicken.proteinPerUnit, closeTo(0.3, 1e-9));
      expect(chicken.costPerProteinGram, closeTo(0.01 / 0.3, 1e-9));
    });

    test('a serving measured in something other than grams says nothing', () {
      final PantryItem juice = _item(
          macros: const Macros(proteinG: 1),
          servingSize: 8,
          servingUnit: 'oz');
      expect(juice.proteinPerUnit, 0);
      expect(juice.costPerProteinGram, 0);
    });

    test('count items price protein per unit', () {
      // 12 eggs for $4.20 → $0.35 each; 6 g protein per egg.
      final PantryItem eggs = _item(
          name: 'Eggs',
          unit: 'count',
          total: 12,
          remaining: 12,
          price: 4.20,
          macros: const Macros(proteinG: 6),
          servingSize: 1,
          servingUnit: 'egg');
      expect(eggs.proteinPerUnit, 6);
      expect(eggs.costPerProteinGram, closeTo(0.35 / 6, 1e-9));
    });

    test('no macros means no claim about value', () {
      expect(_item().costPerProteinGram, 0);
    });

    test('a mis-scanned label is refused, not ranked', () {
      // A real entry from his pantry: 40 g of protein claimed in a 5 g
      // serving. That is 8 g of protein per gram of food, which no food can
      // do — and it would otherwise top the cheapest-protein list.
      final PantryItem badScan = _item(
          name: 'Parmesan Freshly Grated',
          total: 140,
          remaining: 140,
          price: 6.69,
          macros: const Macros(proteinG: 40),
          servingSize: 5);
      expect(badScan.proteinPerUnit, 0);
      expect(badScan.costPerProteinGram, 0);
    });

    test('a countable unit cannot carry 100 g of protein either', () {
      final PantryItem nonsense = _item(
          unit: 'count',
          total: 10,
          remaining: 10,
          macros: const Macros(proteinG: 500),
          servingSize: 1,
          servingUnit: 'egg');
      expect(nonsense.proteinPerUnit, 0);
    });

    test('only real protein sources are ranked as protein', () {
      // 10 g per 100 g for a weight item, 3 g per unit for a countable one.
      expect(Chef.isProteinSource(0.30, false), true); // chicken
      expect(Chef.isProteinSource(0.10, false), true); // right on the bar
      expect(Chef.isProteinSource(0.09, false), false); // oregano, blueberries
      expect(Chef.isProteinSource(6, true), true); // an egg
      expect(Chef.isProteinSource(1, true), false);
    });

    test('a spice never turns up as the dearest protein', () {
      // Dried oregano: $3.99 for 8.8 g, 9 g of protein per 100 g. Priced per
      // gram of protein it looks like the most expensive protein in the
      // house, which is a meaningless thing to tell a chef.
      final List<PantryItem> pantry = <PantryItem>[
        _item(
            id: '1',
            name: 'Chicken thigh',
            macros: const Macros(proteinG: 30),
            servingSize: 100),
        _item(
            id: '2',
            name: 'Dry lentils',
            price: 4,
            macros: const Macros(proteinG: 25),
            servingSize: 100),
        _item(
            id: '3',
            name: 'Eggs',
            unit: 'count',
            total: 12,
            remaining: 12,
            price: 4.20,
            macros: const Macros(proteinG: 6),
            servingSize: 1,
            servingUnit: 'egg'),
        _item(
            id: '4',
            name: 'Spices, oregano, dried',
            total: 8.8,
            remaining: 8.8,
            price: 3.99,
            macros: const Macros(proteinG: 9),
            servingSize: 100),
      ];
      final String out = Chef.formatProteinValue(const PriceBook(), pantry);
      expect(out, contains('Chicken thigh'));
      expect(out, contains('Eggs'));
      expect(out, isNot(contains('oregano')));
    });

    test('the list ranks cheapest protein first and names the dearest', () {
      final List<PantryItem> pantry = <PantryItem>[
        // $0.01/g, 30 g/100 g → $0.033 per g protein
        _item(
            id: '1',
            name: 'Chicken thigh',
            macros: const Macros(proteinG: 30),
            servingSize: 100),
        // $0.04/g, 25 g/100 g → $0.16 per g protein
        _item(
            id: '2',
            name: 'Ribeye',
            price: 40,
            macros: const Macros(proteinG: 25),
            servingSize: 100),
        // Dry lentils: $0.004/g, 25 g/100 g → $0.016 per g protein
        _item(
            id: '3',
            name: 'Dry lentils',
            price: 4,
            macros: const Macros(proteinG: 25),
            servingSize: 100),
      ];
      final String out = Chef.formatProteinValue(const PriceBook(), pantry);
      expect(out, contains('CHEAPEST'));
      expect(out, contains('per g of protein'));
      expect(out, contains('(in the pantry)'));
      // Cheapest protein first: lentils, then chicken thigh, then ribeye.
      expect(out.indexOf('Dry lentils') >= 0, true);
      expect(out.indexOf('Dry lentils') < out.indexOf('Chicken thigh'), true);
      expect(out.indexOf('Chicken thigh') < out.indexOf('Ribeye'), true);
    });

    test('fewer than three priced proteins is not worth a list', () {
      final List<PantryItem> pantry = <PantryItem>[
        _item(macros: const Macros(proteinG: 30), servingSize: 100),
      ];
      expect(Chef.formatProteinValue(const PriceBook(), pantry), '');
    });
  });

  group('price book remembers protein', () {
    test('recording an item keeps its protein density', () {
      final PantryItem chicken =
          _item(macros: const Macros(proteinG: 30), servingSize: 100);
      final PriceBook book =
          const PriceBook().withItem(chicken, DateTime(2026, 9, 1));
      final PriceEntry e = book.lookup('Chicken')!;
      expect(e.proteinPerUnit, closeTo(0.3, 1e-9));
      expect(e.costPerProteinGram, closeTo(0.01 / 0.3, 1e-9));
    });

    test('a restock with no macros does not erase what was known', () {
      final PriceBook first = const PriceBook().withItem(
          _item(macros: const Macros(proteinG: 30), servingSize: 100),
          DateTime(2026, 8, 1));
      // Same food scanned again, this time without macros.
      final PriceBook second =
          first.withItem(_item(price: 12), DateTime(2026, 9, 1));
      final PriceEntry e = second.lookup('Chicken')!;
      expect(e.unitPrice, closeTo(0.012, 1e-9), reason: 'newer price wins');
      expect(e.proteinPerUnit, closeTo(0.3, 1e-9), reason: 'protein survives');
    });

    test('protein survives a merge from a writer that never recorded it', () {
      final PriceBook withProtein = const PriceBook().withItem(
          _item(macros: const Macros(proteinG: 30), servingSize: 100),
          DateTime(2026, 8, 1));
      final PriceBook newerWithout =
          const PriceBook().withItem(_item(price: 12), DateTime(2026, 9, 1));
      final PriceBook merged = PriceBook.merge(withProtein, newerWithout);
      final PriceEntry e = merged.lookup('Chicken')!;
      expect(e.unitPrice, closeTo(0.012, 1e-9));
      expect(e.proteinPerUnit, closeTo(0.3, 1e-9));
    });

    test('protein round-trips through JSON, and its absence is fine', () {
      final PriceBook book = const PriceBook().withItem(
          _item(macros: const Macros(proteinG: 30), servingSize: 100),
          DateTime(2026, 9, 1));
      final PriceBook back = PriceBook.decode(book.encode());
      expect(back.lookup('Chicken')!.proteinPerUnit, closeTo(0.3, 1e-4));
      // An older file with no protein key decodes to 0, not a crash.
      final PriceBook old = PriceBook.decode(
          '{"prices":[{"name":"Rice","unit_price":0.003,"unit":"g","ts":1}]}');
      expect(old.lookup('Rice')!.proteinPerUnit, 0);
      expect(old.lookup('Rice')!.costPerProteinGram, 0);
    });
  });

  group('what the chef is told', () {
    test('a thin ledger tells it nothing rather than something wrong', () {
      expect(Chef.formatSpending(SpendProfile.empty), '');
    });

    test('the spending block names the drivers and the climb', () {
      SpendingLog log = const SpendingLog();
      for (int i = 0; i < 4; i++) {
        log = log.add(_use('Lentils', 30, DateTime(2026, 7, 5 + i * 7)));
      }
      for (int i = 0; i < 4; i++) {
        log = log.add(_use('Ground Bison', 60, DateTime(2026, 8, 2 + i * 7)));
      }
      final String out = Chef.formatSpending(log.profile(now));
      expect(out, contains('A normal week for him'));
      expect(out, contains('CLIMBING'));
      expect(out, contains('Ground Bison'));
      expect(out, contains('% of it'), reason: 'a driver reads as a share');
    });
  });
}
