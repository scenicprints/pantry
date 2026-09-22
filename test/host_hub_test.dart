import 'package:flutter_test/flutter_test.dart';
import 'package:pantry/chef_models.dart';
import 'package:pantry/host_hub.dart';

Recipe _r(String title,
        {double total = 0, double grocery = 0, List<String>? items}) =>
    Recipe(
      title: title,
      description: 'A test dish',
      ingredients: (items ?? <String>['Chicken (new buy)'])
          .map((String i) => RecipeIngredient(item: i, amount: '1'))
          .toList(),
      steps: const <RecipeStep>[
        RecipeStep(title: 'Cook', content: 'Cook it', timerSeconds: 60),
      ],
      notes: 'notes',
      baseServings: 6,
      estCostTotal: total,
      estGroceryCost: grocery,
    );

HostDish _d(String text, String course, {Recipe? recipe}) =>
    HostDish(text: text, course: course, recipe: recipe);

HostEvent _e(int ms,
        {String name = '',
        int guests = 2,
        String date = '',
        List<HostDish> dishes = const <HostDish>[],
        String notes = ''}) =>
    HostEvent(
      createdAtMs: ms,
      name: name,
      guests: guests,
      eventDate: date,
      dishes: dishes,
      guestNotes: notes,
    );

void main() {
  group('HostDish', () {
    test('round-trips through JSON, recipe included', () {
      final HostDish d =
          _d('Lasagna', 'Main', recipe: _r('Braised Short Rib Lasagna'));
      final HostDish back = HostDish.fromJson(d.toJson());
      expect(back.text, 'Lasagna');
      expect(back.course, 'Main');
      expect(back.recipe?.title, 'Braised Short Rib Lasagna');
    });

    test('round-trips with no recipe yet (not generated)', () {
      final HostDish back = HostDish.fromJson(_d('Salad', 'Starter').toJson());
      expect(back.recipe, isNull);
    });
  });

  group('HostEvent', () {
    test('allIngredients flattens across dishes in dish order', () {
      final HostEvent e = _e(1, dishes: <HostDish>[
        _d('Lasagna', 'Main',
            recipe: _r('Lasagna', items: <String>['Noodles', 'Beef (new buy)'])),
        _d('Broccolini', 'Side',
            recipe: _r('Broccolini', items: <String>['Broccolini (new buy)'])),
      ]);
      expect(e.allIngredients.map((RecipeIngredient i) => i.item).toList(),
          <String>['Noodles', 'Beef (new buy)', 'Broccolini (new buy)']);
    });

    test('a dish with no recipe yet contributes nothing to the list', () {
      final HostEvent e = _e(1, dishes: <HostDish>[
        _d('Lasagna', 'Main', recipe: _r('Lasagna')),
        _d('Not yet generated', 'Dessert'),
      ]);
      expect(e.recipes.length, 1);
      expect(e.allIngredients.length, 1);
    });

    test('estCostTotal and estGroceryCost sum across dishes', () {
      final HostEvent e = _e(1, dishes: <HostDish>[
        _d('Main', 'Main', recipe: _r('Main', total: 40, grocery: 25)),
        _d('Side', 'Side', recipe: _r('Side', total: 10, grocery: 4)),
        _d('Dessert', 'Dessert', recipe: _r('Dessert', total: 15, grocery: 15)),
      ]);
      expect(e.estCostTotal, 65);
      expect(e.estGroceryCost, 44);
    });

    test('isBuilt is true only once every dish has a recipe', () {
      expect(_e(1, dishes: <HostDish>[_d('A', 'Main', recipe: _r('A'))]).isBuilt,
          true);
      expect(
          _e(1, dishes: <HostDish>[
            _d('A', 'Main', recipe: _r('A')),
            _d('B', 'Side'),
          ]).isBuilt,
          false);
      expect(_e(1, dishes: const <HostDish>[]).isBuilt, false);
    });

    test('isUpcoming: no date counts as upcoming, future and today do, past does not', () {
      final DateTime now = DateTime(2026, 10, 3, 14, 30);
      expect(_e(1, date: '').isUpcoming(now), true);
      expect(_e(1, date: '2026-10-03').isUpcoming(now), true); // today
      expect(_e(1, date: '2026-10-04').isUpcoming(now), true); // tomorrow
      expect(_e(1, date: '2026-10-02').isUpcoming(now), false); // yesterday
      expect(_e(1, date: 'not a date').isUpcoming(now), true); // unparsable
    });

    test('gatheredCount counts ticks, ignoring keys for dishes that are gone',
        () {
      final HostEvent e = _e(1, dishes: <HostDish>[
        _d('Lasagna', 'Main',
            recipe: _r('Lasagna', items: <String>['Noodles', 'Beef'])),
        _d('Broccolini', 'Side',
            recipe: _r('Broccolini', items: <String>['Broccolini'])),
      ]).copyWith(checked: <String>['0:0', '1:0', '7:3']);
      expect(e.ingredientCount, 3);
      expect(e.gatheredCount, 2); // the 7:3 key belongs to nothing
    });

    test('ticks survive encode → decode', () {
      final HostEvent e = _e(1, dishes: <HostDish>[
        _d('Lasagna', 'Main',
            recipe: _r('Lasagna', items: <String>['Noodles', 'Beef'])),
      ]).copyWith(checked: <String>['0:1']);
      final HostEvent back = HostEvent.fromJson(e.toJson());
      expect(back.checked, <String>['0:1']);
      expect(back.gatheredCount, 1);
    });

    test('copyWith only renames, everything else is stable', () {
      final HostEvent e = _e(42, guests: 8, date: '2026-10-03', notes: 'no shellfish');
      final HostEvent named = e.copyWith(name: "Sarah's Birthday");
      expect(named.id, e.id);
      expect(named.name, "Sarah's Birthday");
      expect(named.guests, 8);
      expect(named.eventDate, '2026-10-03');
      expect(named.guestNotes, 'no shellfish');
    });

    test('encode → decode round-trips a full event, prep days included', () {
      final HostEvent e = HostEvent(
        createdAtMs: 1700000000000,
        name: 'Friendsgiving',
        guests: 6,
        eventDate: '2026-10-03',
        dishes: <HostDish>[_d('Lasagna', 'Main', recipe: _r('Lasagna'))],
        guestNotes: 'one guest has a tree-nut allergy',
        prepDays: const <PrepDay>[
          PrepDay(
              date: '2026-10-02',
              label: 'The day before',
              tasks: <PrepTask>[
                PrepTask(text: 'Assemble the lasagna', dish: 'Lasagna'),
              ]),
        ],
      );
      final HostEvent back = HostEvent.fromJson(e.toJson());
      expect(back.id, '1700000000000');
      expect(back.name, 'Friendsgiving');
      expect(back.guests, 6);
      expect(back.eventDate, '2026-10-03');
      expect(back.guestNotes, 'one guest has a tree-nut allergy');
      expect(back.dishes.single.recipe?.title, 'Lasagna');
      expect(back.prepDays.single.label, 'The day before');
      expect(back.prepDays.single.tasks.single.text, 'Assemble the lasagna');
      expect(back.prepDays.single.tasks.single.dish, 'Lasagna');
      expect(back.prepDays.single.relativeTo('2026-10-03'), 'The day before');
    });
  });

  group('HostHubBox', () {
    test('sorted puts upcoming before past', () {
      final DateTime now = DateTime.now();
      final String tomorrow =
          now.add(const Duration(days: 1)).toIso8601String().substring(0, 10);
      final String yesterday =
          now.subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
      final HostHubBox box = HostHubBox(<HostEvent>[
        _e(100, name: 'Yesterday', date: yesterday),
        _e(200, name: 'Tomorrow', date: tomorrow),
        _e(300, name: 'Undated'),
      ]);
      final List<String> order =
          box.sorted.map((HostEvent e) => e.name).toList();
      expect(order.indexOf('Yesterday'), order.length - 1); // past is last
      expect(order.contains('Tomorrow'), true);
      expect(order.contains('Undated'), true);
      expect(order.indexOf('Tomorrow'), lessThan(order.indexOf('Yesterday')));
      expect(order.indexOf('Undated'), lessThan(order.indexOf('Yesterday')));
    });

    test('within upcoming, soonest date first; undated plans lead', () {
      final DateTime now = DateTime.now();
      final String in3 =
          now.add(const Duration(days: 3)).toIso8601String().substring(0, 10);
      final String in1 =
          now.add(const Duration(days: 1)).toIso8601String().substring(0, 10);
      final HostHubBox box = HostHubBox(<HostEvent>[
        _e(100, name: 'In 3 days', date: in3),
        _e(200, name: 'Undated'),
        _e(300, name: 'In 1 day', date: in1),
      ]);
      expect(box.sorted.map((HostEvent e) => e.name).toList(),
          <String>['Undated', 'In 1 day', 'In 3 days']);
    });

    test('within past, most recently created first', () {
      final DateTime now = DateTime.now();
      final String yesterday =
          now.subtract(const Duration(days: 1)).toIso8601String().substring(0, 10);
      final HostHubBox box = HostHubBox(<HostEvent>[
        _e(100, name: 'Older', date: yesterday),
        _e(300, name: 'Newer', date: yesterday),
      ]);
      expect(box.sorted.map((HostEvent e) => e.name).toList(),
          <String>['Newer', 'Older']);
    });

    test('decoding junk or nothing yields an empty box, never a throw', () {
      expect(HostHubBox.decode(null).events, isEmpty);
      expect(HostHubBox.decode('').events, isEmpty);
      expect(HostHubBox.decode('not json').events, isEmpty);
      expect(HostHubBox.decode('{"events":"nope"}').events, isEmpty);
    });

    test('encode → decode preserves every saved event', () {
      final HostHubBox box = HostHubBox(<HostEvent>[
        _e(1, name: 'A', guests: 4),
        _e(2, name: 'B', guests: 8, date: '2026-11-01'),
      ]);
      final HostHubBox back = HostHubBox.decode(box.encode());
      expect(back.events.length, 2);
      expect(back.events.firstWhere((HostEvent e) => e.name == 'B').guests, 8);
    });
  });
}
