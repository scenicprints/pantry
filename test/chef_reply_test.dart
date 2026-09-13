// Reading the chef's reply.
//
// "I told the chef I wanted anything without ground meat and it said the
// chef's reply was not valid." The extractor took everything between the
// first "{" and the last "}", which breaks on a stray brace in prose and on
// two objects, and it reported every failure with one message so the report
// could not be acted on. These pin the shapes that come back from a model.

import 'package:flutter_test/flutter_test.dart';

import 'package:pantry/chef.dart';

void main() {
  group('reading a reply', () {
    test('plain JSON', () {
      final Map<String, dynamic> r =
          Chef.debugExtractJson('{"options":[{"title":"Chili"}]}');
      expect((r['options'] as List<dynamic>), hasLength(1));
    });

    test('wrapped in a markdown fence', () {
      final Map<String, dynamic> r = Chef.debugExtractJson(
          '```json\n{"options":[{"title":"Chili"}]}\n```');
      expect(r['options'], isNotNull);
    });

    test('prose before the JSON', () {
      final Map<String, dynamic> r = Chef.debugExtractJson(
          'Sure, here are five options.\n{"options":[{"title":"Chili"}]}');
      expect(r['options'], isNotNull);
    });

    test('a stray brace in the prose does not swallow the JSON', () {
      // The old first-{-to-last-} scan started here and produced nonsense.
      final Map<String, dynamic> r = Chef.debugExtractJson(
          'Note: use {curly} quotes.\n{"options":[{"title":"Chili"}]}');
      expect(r['options'], isNotNull);
    });

    test('trailing prose after the JSON', () {
      final Map<String, dynamic> r = Chef.debugExtractJson(
          '{"options":[{"title":"Chili"}]}\nLet me know if you want more.');
      expect((r['options'] as List<dynamic>), hasLength(1));
    });

    test('an answer in words quotes the chef instead of saying "not valid"',
        () {
      try {
        Chef.debugExtractJson(
            "I can't put together five dinners without ground meat from this "
            'pantry.');
        fail('should have thrown');
      } on ChefException catch (e) {
        expect(e.message, contains('answered in words'));
        expect(e.message, contains('without ground meat'));
        expect(e.unreadable, isTrue);
      }
    });

    test('a long refusal is trimmed, not dumped whole', () {
      try {
        Chef.debugExtractJson('no. ' * 200);
        fail('should have thrown');
      } on ChefException catch (e) {
        expect(e.message.length, lessThan(260));
        expect(e.message, contains('…'));
      }
    });

    test('an empty reply says so', () {
      try {
        Chef.debugExtractJson('   ');
        fail('should have thrown');
      } on ChefException catch (e) {
        expect(e.message, contains('empty'));
        expect(e.unreadable, isTrue);
      }
    });

    test('garbled JSON is marked retryable', () {
      try {
        Chef.debugExtractJson('{"options":[{"title":');
        fail('should have thrown');
      } on ChefException catch (e) {
        expect(e.unreadable, isTrue);
      }
    });

    test('a brace inside a string is not mistaken for structure', () {
      final Map<String, dynamic> r =
          Chef.debugExtractJson('{"desc":"rice with a } in it","n":1}');
      expect(r['desc'], 'rice with a } in it');
      expect(r['n'], 1);
    });

    test('an escaped quote inside a string is handled', () {
      final Map<String, dynamic> r =
          Chef.debugExtractJson(r'{"desc":"he said \"hot\"","n":2}');
      expect(r['n'], 2);
    });

  });
}
