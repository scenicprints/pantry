import 'package:flutter_test/flutter_test.dart';
import 'package:pantry/chef.dart';

void main() {
  group('equipment catalog', () {
    test('every default device exists in the catalog', () {
      final Set<String> known =
          kKnownDevices.map((CookDevice d) => d.name).toSet();
      for (final String d in kDefaultDevices) {
        expect(known.contains(d), true, reason: '$d missing from catalog');
      }
    });

    test('device names are unique', () {
      final List<String> names =
          kKnownDevices.map((CookDevice d) => d.name).toList();
      expect(names.length, names.toSet().length);
    });

    test('the Tovala carries a capability note; a plain device does not', () {
      expect(deviceNote('Tovala Smart Oven'), isNotNull);
      expect(deviceNote('Tovala Smart Oven')!.toLowerCase(), contains('steam'));
      expect(deviceNote('Oven'), isNull);
      expect(deviceNote('Some Custom Gadget'), isNull);
    });
  });

  group('formatEquipment', () {
    test('lists each owned device on its own line', () {
      final String s =
          Chef.formatEquipment(<String>['Air fryer', 'Outdoor grill']);
      expect(s, contains('- Air fryer'));
      expect(s, contains('- Outdoor grill'));
      expect(s.split('\n').length, 2);
    });

    test('appends the capability note for devices that have one', () {
      final String s = Chef.formatEquipment(<String>['Tovala Smart Oven']);
      expect(s.startsWith('- Tovala Smart Oven — '), true);
      expect(s.toLowerCase(), contains('broil'));
    });

    test('custom devices pass through with no note', () {
      final String s = Chef.formatEquipment(<String>['Pizza oven']);
      expect(s, '- Pizza oven');
    });

    test('empty/blank selection falls back to stove + oven', () {
      expect(Chef.formatEquipment(<String>[]), contains('Stove'));
      expect(Chef.formatEquipment(<String>['  ']), contains('Oven'));
    });

    test('blank entries are skipped', () {
      final String s = Chef.formatEquipment(<String>['Air fryer', '', '  ']);
      expect(s, '- Air fryer');
    });
  });

  group('avoid list', () {
    test('the starting list is the old hardcoded dislikes, nothing more', () {
      expect(kDefaultAvoids, contains('Pork'));
      expect(kDefaultAvoids, contains('All seafood'));
      expect(kDefaultAvoids, contains('Spicy food'));
      expect(kDefaultAvoids, contains('Yogurt'));
      // No preset menu — just the five that were already being enforced.
      expect(kDefaultAvoids.length, 5);
      expect(kDefaultAvoids.length, kDefaultAvoids.toSet().length);
    });

    test('formats one per line for the prompt', () {
      final String s = Chef.formatAvoids(<String>['Pork', 'Mushrooms']);
      // Since v0.13.1 a known group also carries its expansion on the
      // same line, so this asserts the shape — one entry per line, each
      // led by its own name — not the exact string. avoid_test.dart
      // covers the expansion itself.
      final List<String> lines = s.split('\n');
      expect(lines, hasLength(2));
      expect(lines[0], startsWith('- Pork'));
      expect(lines[1], startsWith('- Mushrooms'));
    });

    test('an emptied list says nothing is off limits', () {
      final String s = Chef.formatAvoids(<String>[]);
      expect(s.toLowerCase(), contains('nothing'));
      expect(s.toLowerCase(), contains('allergy'));
    });

    test('blank entries are skipped', () {
      final List<String> lines =
          Chef.formatAvoids(<String>['Pork', '', '   ']).split('\n');
      expect(lines, hasLength(1));
      expect(lines.single, startsWith('- Pork'));
    });

    test('removing yogurt from the list removes it from the prompt', () {
      final List<String> without =
          kDefaultAvoids.where((String a) => a != 'Yogurt').toList();
      expect(Chef.formatAvoids(kDefaultAvoids), contains('Yogurt'));
      expect(Chef.formatAvoids(without), isNot(contains('Yogurt')));
    });

    test('custom foods pass straight through', () {
      expect(Chef.formatAvoids(<String>['Bell peppers']), '- Bell peppers');
    });
  });

}
