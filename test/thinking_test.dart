// Which calls spend a reasoning pass. The Opus setting is on 4.8, where
// thinking is opt-in, so the picker stays quick and the cooking keeps its
// reasoning — and that split is the whole point of the per-call flag.

import 'package:flutter_test/flutter_test.dart';

import 'package:pantry/chef.dart';

void main() {
  group('per-call thinking', () {
    test('the options call does not think on Opus 4.8', () {
      expect(Chef.debugThinks(kChefModelOpus, think: false), isFalse);
    });

    test('the recipe, prep and substitution calls do', () {
      expect(Chef.debugThinks(kChefModelOpus, think: true), isTrue);
    });

    test('the Opus setting is 4.8 — thinking has to be asked for', () {
      expect(kChefModelOpus, 'claude-opus-4-8');
    });

    test('Haiku ignores a thinking request rather than sending a bad shape',
        () {
      expect(Chef.debugThinks(kChefModelHaiku, think: true), isFalse);
      expect(Chef.debugThinks(kChefModelHaiku, think: false), isFalse);
    });

    test('Sonnet 4.6 takes the adaptive switch when asked', () {
      expect(Chef.debugThinks(kChefModelSonnet, think: true), isTrue);
      expect(Chef.debugThinks(kChefModelSonnet, think: false), isFalse);
    });

    test('a 5-series model thinks whether asked or not, so the budget widens',
        () {
      expect(Chef.debugThinks('claude-opus-5', think: false), isTrue);
      expect(Chef.debugThinks('claude-sonnet-5', think: false), isTrue);
    });
  });
}
