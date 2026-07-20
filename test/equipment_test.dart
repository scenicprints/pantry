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
}
