import 'package:flutter_test/flutter_test.dart';
import 'package:pantry/chef.dart';

/// The cookware is hard-coded, so these tests guard the two things a wrong
/// edit would quietly break: a lid appearing on a pan that hasn't got one,
/// and the heat table drifting back to the generic electric-stove numbers
/// the chef used to ship with.
void main() {
  group('cookware catalog', () {
    test('not one frying pan or the cast iron has a lid', () {
      for (final CookPan p in kCookware) {
        final bool fryer =
            p.name.contains('frying pan') || p.name.contains('skillet');
        if (fryer) {
          expect(p.lid, false, reason: '${p.name} must not claim a lid');
        }
      }
    });

    test('every sauce pan and the stock pot does have a lid', () {
      for (final CookPan p in kCookware) {
        if (p.name.contains('sauce pan') || p.name.contains('stock pot')) {
          expect(p.lid, true, reason: '${p.name} has a lid');
        }
      }
    });

    test('he owns exactly one cast iron piece; the rest is stainless', () {
      final List<CookPan> iron = kCookware
          .where((CookPan p) => p.material == 'cast iron')
          .toList();
      expect(iron.length, 1);
      expect(iron.single.name, contains('cast iron skillet'));
      expect(
        kCookware.every(
            (CookPan p) => p.material == 'cast iron' || p.material == 'stainless'),
        true,
      );
    });

    test('nothing is nonstick', () {
      for (final CookPan p in kCookware) {
        expect(p.material, isNot('nonstick'));
        expect((p.note ?? '').toLowerCase(), isNot(contains('nonstick')));
      }
    });

    test('pan names are unique', () {
      final List<String> names =
          kCookware.map((CookPan p) => p.name).toList();
      expect(names.length, names.toSet().length);
    });
  });

  group('formatCookware', () {
    final String s = formatCookware();

    test('names all seven pieces', () {
      for (final CookPan p in kCookware) {
        expect(s, contains(p.name), reason: '${p.name} missing from prompt');
      }
    });

    test('states the list is complete and that nothing is nonstick', () {
      expect(s, contains('COMPLETE list'));
      expect(s, contains('NOTHING IN THIS KITCHEN IS NONSTICK'));
    });

    test('marks the lidless pans NO LID and forbids covering them', () {
      expect(s, contains('NO LID'));
      expect(s, contains('NO LID ON ANY FRYING PAN'));
      expect(s, contains('sauce pan or the stock pot'));
    });

    test('carries the strainer insert, the bakeware and the utensils', () {
      expect(s, contains('strainer insert'));
      expect(s, contains('rimmed sheet pan'));
      expect(s, contains('basting brush'));
    });

    test('tells the chef to name the pan rather than say "a hot pan"', () {
      expect(s, contains('NAME THE PAN'));
      expect(s, contains('dial number'));
    });

    test('never states a bakeware size, because his is generic', () {
      expect(s, contains('never state a size'));
      expect(s, isNot(contains('half-sheet')));
      expect(s, isNot(contains('9x13')));
    });
  });

  group('kHeatReference', () {
    test('is a 1-10 gas dial, not the old generic 0-10', () {
      expect(kHeatReference, contains('GAS WITH A 1-10 DIAL'));
      expect(kHeatReference, isNot(contains('0-10 dial')));
    });

    test('demands a number every time', () {
      expect(kHeatReference, contains('GIVE A NUMBER, EVERY TIME'));
      expect(kHeatReference, contains('Never write "medium-high"'));
    });

    test('sears at 6-7 and never at the top of the dial', () {
      final String sear = kHeatReference
          .split('\n')
          .firstWhere((String l) => l.contains('Searing'));
      expect(sear, contains('6-7'));
      // The old prompt said a sear was 8-9. If that ever comes back, the pan
      // scorches and the oil smokes before the food goes in.
      expect(kHeatReference, isNot(contains('sear is 8-9')));
    });

    test('puts the simmer low, where a gas burner actually simmers', () {
      final String simmer = kHeatReference
          .split('\n')
          .firstWhere((String l) => l.contains('Simmer and hold'));
      expect(simmer, contains('1-2'));
    });

    test('carries both readiness checks and the flame check', () {
      expect(kHeatReference, contains('WATER TEST'));
      expect(kHeatReference, contains('BUTTER TEST'));
      expect(kHeatReference, contains('FLAME:'));
      // Drops vanishing on contact means too hot, not ready. Getting this
      // backwards is the single most common version of this advice online.
      expect(kHeatReference, contains('vanish on\n  contact = TOO HOT'));
    });

    test('keeps oil out of the water test and off the cold pan', () {
      expect(kHeatReference, contains('never with oil in it'));
      expect(kHeatReference, contains('THE OIL GOES IN AFTER'));
    });

    test('covers the measured temperatures the numbers came from', () {
      expect(kHeatReference, contains('185-205F')); // simmer
      expect(kHeatReference, contains('250F')); // omelet
      expect(kHeatReference, contains('285F')); // browning floor
      expect(kHeatReference, contains('365-379F')); // water-test window
    });
  });
}
