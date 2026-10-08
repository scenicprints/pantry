import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'storage.dart';

// ═══════════════════════════════════════════════════════════════════════
// THE HUNGRYROOT COOKBOOK, READ FROM THE OUTSIDE.
//
// HungryRoot publishes its whole recipe catalogue at
// api.hungryroot.com/api/v3/pairings/ with no key and no login, and that is
// the only reason "replicate one of their meals" is a real feature rather
// than the chef guessing at a brand it half remembers. Each entry carries
// the real title, the servings, the cook time, the method as written on the
// card, and the nutrition panel.
//
// WHY v3 AND NOT v2. The same catalogue is served twice. v2 hands back the
// full component list with brands and gram amounts, but it is 53 KB PER
// RECIPE, and a hundred of those is not something to pull down a phone to
// find three dinners. v3 is the same recipes at about 1.5 KB each, with the
// method text intact. The components are named inside the method anyway
// ("add chicken to pan", "sauté the bok choy"), which is enough to match
// against what is on his shelf. v2 is still there if a single picked recipe
// ever needs its exact amounts; nothing calls it today.
//
// WHAT IT CANNOT DO. There is no ingredient filter on the API. `tag` and
// `limit` work, nothing else I could find does, so there is no way to ask
// it "which recipes use the chicken I have". The matching is ours: pull a
// slice of the catalogue, cache it, and score it locally against the items
// he has marked as HungryRoot.
//
// FAILING IS FINE. Every path here returns an empty list rather than
// throwing. A dead network, a changed endpoint or a rate limit must never
// stop "Cook something" from working: HungryRoot mode falls back to
// cooking his delivery food without replicating anything, which is still
// most of what the toggle is for.
// ═══════════════════════════════════════════════════════════════════════

/// One recipe out of HungryRoot's catalogue.
class HungryRootPairing {
  final int id;
  final String name;
  final int cookingTime; // minutes, as HungryRoot claims
  final int servings;
  final String method; // the card's own steps, one per line
  final String nutrition; // "Calories 430, Sat. Fat 9g, Protein 19g…"

  const HungryRootPairing({
    required this.id,
    required this.name,
    required this.cookingTime,
    required this.servings,
    required this.method,
    required this.nutrition,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'cooking_time': cookingTime,
        'servings': servings,
        'method': method,
        'nutrition': nutrition,
      };

  factory HungryRootPairing.fromCache(Map<String, dynamic> j) =>
      HungryRootPairing(
        id: (j['id'] as num?)?.round() ?? 0,
        name: (j['name'] as String?) ?? '',
        cookingTime: (j['cooking_time'] as num?)?.round() ?? 0,
        servings: (j['servings'] as num?)?.round() ?? 0,
        method: (j['method'] as String?) ?? '',
        nutrition: (j['nutrition'] as String?) ?? '',
      );

  /// Straight off the API. Returns null for anything with no name or no
  /// method, which is no use to a cook.
  static HungryRootPairing? fromApi(Map<String, dynamic> j) {
    final String name = ((j['name'] as String?) ?? '').trim();
    final String method = stripHtml((j['short_instruction_html'] as String?) ?? '');
    if (name.isEmpty || method.isEmpty) {
      return null;
    }
    return HungryRootPairing(
      id: (j['id'] as num?)?.round() ?? 0,
      name: name,
      cookingTime: (j['cooking_time'] as num?)?.round() ?? 0,
      servings: (j['servings'] as num?)?.round() ?? 0,
      method: method,
      nutrition: trimNutrition((j['nutrition_info'] as String?) ?? ''),
    );
  }
}

/// `<p>Toast the bagels</p><p>Slice the onion</p>` → two lines.
String stripHtml(String html) => html
    .replaceAll(RegExp(r'</p>\s*<p>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
    .replaceAll(RegExp(r'<[^>]+>'), '')
    .replaceAll('&amp;', '&')
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&#39;', "'")
    .replaceAll('&quot;', '"')
    .split('\n')
    .map((String l) => l.trim())
    .where((String l) => l.isNotEmpty)
    .join('\n');

/// The nutrition blob carries a paragraph of daily-value boilerplate after
/// the numbers. Keep the numbers.
String trimNutrition(String info) {
  final String flat = stripHtml(info).replaceAll('\n', ' ').trim();
  final int cut = flat.indexOf('The % daily value');
  final String out = (cut > 0 ? flat.substring(0, cut) : flat).trim();
  return out.replaceFirst(RegExp(r'^Amount per serving:\s*'), '');
}

// ── matching ────────────────────────────────────────────────────────────

/// Words that say nothing about what a dish is made of. Brand and packaging
/// noise mostly: his pantry entries read "Cilantro Lime Chicken (Kevin's
/// Natural Foods)" and the brand must not match a recipe.
const Set<String> _kNoise = <String>{
  'the', 'and', 'with', 'style', 'fresh', 'organic', 'natural', 'foods',
  'farms', 'brand', 'pack', 'packet', 'mix', 'blend', 'sauce', 'seasoned',
  'seasoning', 'cooked', 'precooked', 'pre', 'cut', 'sliced', 'diced',
  'chopped', 'frozen', 'free', 'range', 'grass', 'fed', 'raised', 'whole',
  'baby', 'mini', 'large', 'small', 'medium', 'original', 'classic', 'oz',
  'lb', 'count', 'ct', 'serving', 'servings', 'each', 'our', 'your', 'kit',
};

/// The words in a food name worth matching on.
Set<String> foodWords(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'\([^)]*\)'), ' ') // "(Taylor Farms)"
    .replaceAll(RegExp(r'[^a-z]+'), ' ')
    .split(' ')
    .where((String w) => w.length > 2 && !_kNoise.contains(w))
    .toSet();

/// How well [p] matches the food he actually has.
///
/// A word landing in the TITLE counts double: "Saucy Green Chicken + Bok
/// Choy Veggies" naming his bok choy is a far stronger signal than the word
/// turning up in a step. Matching whole items counts for more than matching
/// many words off one item, so a recipe that uses two of his things beats
/// one that says "chicken" three times.
double matchScore(HungryRootPairing p, List<Set<String>> itemWords) {
  final Set<String> title = foodWords(p.name);
  final Set<String> body = foodWords(p.method);
  double score = 0;
  int itemsHit = 0;
  for (final Set<String> words in itemWords) {
    final int inTitle = words.where(title.contains).length;
    final int inBody = words.where(body.contains).length;
    if (inTitle == 0 && inBody == 0) {
      continue;
    }
    itemsHit++;
    score += inTitle * 2.0 + inBody * 1.0;
  }
  if (itemsHit == 0) {
    return 0;
  }
  return score + itemsHit * 3.0;
}

/// Two recipes that are the same dinner under different names. The chef is
/// told to invent its own rather than serve a near-repeat, and this is what
/// stops near-repeats reaching it in the first place.
bool tooAlike(HungryRootPairing a, HungryRootPairing b) {
  final Set<String> x = foodWords(a.name), y = foodWords(b.name);
  if (x.isEmpty || y.isEmpty) {
    return false;
  }
  final int shared = x.intersection(y).length;
  return shared >= 2 || shared == x.length || shared == y.length;
}

// ── the catalogue ───────────────────────────────────────────────────────

class HungryRootCatalog {
  static const String _base = 'https://api.hungryroot.com/api/v3/pairings/';

  /// Three pages of a hundred. Enough of the menu to find his food in, small
  /// enough to pull over a phone connection once a week.
  static const int _pageSize = 100;
  static const int _pages = 3;
  static const Duration _maxAge = Duration(days: 7);

  /// How many recipes the chef is shown. More than the three it needs, so it
  /// has room to drop the ones that do not really fit.
  static const int _handOver = 10;

  static File get _cacheFile =>
      File('${LocalCache.filesDir.path}/hungryroot_catalog.json');

  /// In-memory copy, so a second cook in one session costs nothing.
  static List<HungryRootPairing>? _memory;

  /// The recipes he has the food for, best match first. Empty when nothing
  /// is tagged, when nothing matches, or when the catalogue can't be read —
  /// all three mean the same thing to the caller: cook without replicating.
  static Future<List<HungryRootPairing>> candidates(
      List<PantryItem> pantry) async {
    final List<PantryItem> mine = hungryRootStock(pantry);
    if (mine.isEmpty) {
      return <HungryRootPairing>[];
    }
    final List<HungryRootPairing> all = await _load();
    if (all.isEmpty) {
      return <HungryRootPairing>[];
    }
    final List<Set<String>> words =
        mine.map((PantryItem i) => foodWords(i.name)).toList();
    final Map<HungryRootPairing, double> scores =
        <HungryRootPairing, double>{};
    for (final HungryRootPairing p in all) {
      final double score = matchScore(p, words);
      if (score > 0) {
        scores[p] = score;
      }
    }
    final List<HungryRootPairing> ranked = scores.keys.toList()
      ..sort((HungryRootPairing a, HungryRootPairing b) =>
          scores[b]!.compareTo(scores[a]!));

    final List<HungryRootPairing> out = <HungryRootPairing>[];
    for (final HungryRootPairing p in ranked) {
      if (out.any((HungryRootPairing k) => tooAlike(k, p))) {
        continue;
      }
      out.add(p);
      if (out.length >= _handOver) {
        break;
      }
    }
    return out;
  }

  /// What he has marked as having come in the box.
  static List<PantryItem> hungryRootStock(List<PantryItem> pantry) => pantry
      .where((PantryItem i) =>
          i.hungryroot && !i.deleted && (i.remaining > 0 || i.untracked))
      .toList();

  /// Cache first, network second, stale cache third. A refresh that fails
  /// keeps whatever was already on disk, however old: last week's catalogue
  /// is a far better answer than none.
  static Future<List<HungryRootPairing>> _load() async {
    if (_memory != null) {
      return _memory!;
    }
    final (List<HungryRootPairing>, DateTime)? cached = _readCache();
    if (cached != null &&
        DateTime.now().difference(cached.$2) < _maxAge &&
        cached.$1.isNotEmpty) {
      _memory = cached.$1;
      return _memory!;
    }
    final List<HungryRootPairing> fetched = await _fetch();
    if (fetched.isNotEmpty) {
      _writeCache(fetched);
      _memory = fetched;
      return fetched;
    }
    _memory = cached?.$1 ?? <HungryRootPairing>[];
    return _memory!;
  }

  static Future<List<HungryRootPairing>> _fetch() async {
    final List<HungryRootPairing> out = <HungryRootPairing>[];
    for (int page = 0; page < _pages; page++) {
      try {
        final Uri uri = Uri.parse('$_base?is_featured=true&limit=$_pageSize'
            '&offset=${page * _pageSize}');
        final http.Response r = await http.get(uri, headers: <String, String>{
          'accept': 'application/json',
          'user-agent': 'Pantry (github.com/scenicprints/pantry)',
        }).timeout(const Duration(seconds: 20));
        if (r.statusCode != 200) {
          break;
        }
        final dynamic d = jsonDecode(r.body);
        if (d is! Map<String, dynamic>) {
          break;
        }
        final List<dynamic> results =
            (d['results'] as List<dynamic>?) ?? <dynamic>[];
        if (results.isEmpty) {
          break;
        }
        for (final Map<String, dynamic> j
            in results.whereType<Map<String, dynamic>>()) {
          final HungryRootPairing? p = HungryRootPairing.fromApi(j);
          if (p != null) {
            out.add(p);
          }
        }
      } catch (_) {
        break; // keep the pages we already have
      }
    }
    return out;
  }

  static (List<HungryRootPairing>, DateTime)? _readCache() {
    try {
      final File f = _cacheFile;
      if (!f.existsSync()) {
        return null;
      }
      final dynamic d = jsonDecode(f.readAsStringSync());
      if (d is! Map<String, dynamic>) {
        return null;
      }
      final int ms = (d['fetched_at_ms'] as num?)?.round() ?? 0;
      final List<dynamic> rs = (d['pairings'] as List<dynamic>?) ?? <dynamic>[];
      return (
        rs
            .whereType<Map<String, dynamic>>()
            .map(HungryRootPairing.fromCache)
            .where((HungryRootPairing p) => p.name.isNotEmpty)
            .toList(),
        DateTime.fromMillisecondsSinceEpoch(ms),
      );
    } catch (_) {
      return null;
    }
  }

  static void _writeCache(List<HungryRootPairing> ps) {
    try {
      _cacheFile.writeAsStringSync(jsonEncode(<String, dynamic>{
        'fetched_at_ms': DateTime.now().millisecondsSinceEpoch,
        'pairings': ps.map((HungryRootPairing p) => p.toJson()).toList(),
      }));
    } catch (_) {}
  }

  /// Tests only: forget what this session pulled.
  static void resetForTest() => _memory = null;
}
