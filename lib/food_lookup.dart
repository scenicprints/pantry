import 'dart:convert';
import 'package:http/http.dart' as http;

import 'models.dart';

// ═══════════════════════════════════════════════════════════════════════
// FOOD LOOKUP — two sources, one ranked search.
//
//   USDA FoodData Central (generic datasets) — the food ITSELF: "Plantains,
//     raw", "Onions, raw". No brands. Searching "plantain" must lead with
//     these, never with plantain chips.
//   Open Food Facts — branded/barcode products. This is where a brand query
//     ("valletta", "jennie-o") finds its match, and where barcode scans of
//     real packages resolve.
//
// foodMatchScore() ranks the merged results: the whole food first for plain
// queries, brand hits first for brand queries. Same scheme as BodyComp.
//
// USDA key: --dart-define=USDA_API_KEY (falls back to the rate-limited
// DEMO_KEY so search still works in unkeyed builds).
// ═══════════════════════════════════════════════════════════════════════

/// What a barcode lookup returns.
class ProductInfo {
  final String name;
  final String? barcode;
  final Macros macrosPer100g;
  final double? servingGrams; // parsed default serving, if any
  final double? packGrams; // total pack size from `quantity`, if parseable

  const ProductInfo({
    required this.name,
    this.barcode,
    required this.macrosPer100g,
    this.servingGrams,
    this.packGrams,
  });
}

// ── ranking ─────────────────────────────────────────────────────────────

/// One search candidate with the raw pieces the ranker needs. [head] is the
/// food's head noun ("Plantains" from "Plantains, raw"; the product name for
/// branded items), [qualityBonus] breaks ties toward curated whole foods.
class FoodHit {
  final ProductInfo info;
  final String head;
  final String full;
  final String brand;
  final int qualityBonus;
  const FoodHit({
    required this.info,
    required this.head,
    required this.full,
    this.brand = '',
    this.qualityBonus = 0,
  });
}

List<String> _qWords(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z0-9]+'), ' ')
    .split(' ')
    .where((String w) => w.isNotEmpty)
    .map((String w) => w.length > 3 && w.endsWith('s')
        ? w.substring(0, w.length - 1)
        : w)
    .toList();

bool _wordsIn(List<String> query, String text, {bool any = false}) {
  final List<String> words = _qWords(text);
  bool hit(String q) =>
      words.any((String w) => w == q || w.startsWith(q));
  return any ? query.any(hit) : query.isNotEmpty && query.every(hit);
}

/// Relevance of one candidate for [query]. Higher = shown first.
///   +100 the head noun IS the queried food ("Plantains, raw" for "plantain")
///    +30 …and it's an exact head match, nothing extra
///    +40 query merely appears somewhere in the full name (chips, sauces…)
///    +50 the query names this product's BRAND — surfaced when asked for
///   + qualityBonus (curated generic datasets beat crowd data on ties)
int foodMatchScore(String query, FoodHit h) {
  final List<String> q = _qWords(query);
  if (q.isEmpty) {
    return 0;
  }
  int s = 0;
  // The head-noun tier only applies to curated generic entries (they carry a
  // qualityBonus). A branded product's name has no taxonomy — without this
  // gate "Plantain Chips Sea Salt" would score like the whole food.
  if (h.qualityBonus > 0 && _wordsIn(q, h.head)) {
    s += 100;
    final List<String> headWords = _qWords(h.head);
    if (headWords.length == q.length) {
      s += 30;
    }
  } else if (_wordsIn(q, h.full)) {
    s += 40;
  }
  if (h.brand.isNotEmpty && _wordsIn(q, h.brand, any: true)) {
    s += 50;
  }
  return s == 0 ? 0 : s + h.qualityBonus;
}

/// Merged, ranked search across USDA generics + Open Food Facts.
class FoodSearch {
  static Future<List<ProductInfo>> search(String query) async {
    final List<List<FoodHit>> pages = await Future.wait(<Future<List<FoodHit>>>[
      UsdaGeneric.search(query).catchError((Object _) => <FoodHit>[]),
      OpenFoodFacts.searchHits(query).catchError((Object _) => <FoodHit>[]),
    ]);
    final List<FoodHit> all = <FoodHit>[...pages[0], ...pages[1]];
    final List<int> order = List<int>.generate(all.length, (int i) => i);
    final List<int> scores =
        all.map((FoodHit h) => foodMatchScore(query, h)).toList();
    // Stable sort: score desc, original order (USDA first) on ties.
    order.sort((int a, int b) {
      final int d = scores[b] - scores[a];
      return d != 0 ? d : a - b;
    });
    return <ProductInfo>[
      for (final int i in order)
        if (scores[i] > 0 || all[i].brand.isEmpty) all[i].info,
    ].take(30).toList();
  }
}

// ── USDA generic datasets ───────────────────────────────────────────────

class UsdaGeneric {
  static String get _apiKey {
    const String k = String.fromEnvironment('USDA_API_KEY');
    return k.isEmpty ? 'DEMO_KEY' : k;
  }

  static Future<List<FoodHit>> search(String query) async {
    final String q = query.trim();
    if (q.isEmpty) {
      return <FoodHit>[];
    }
    final Uri uri = Uri.parse('https://api.nal.usda.gov/fdc/v1/foods/search'
        '?api_key=$_apiKey&query=${Uri.encodeQueryComponent(q)}'
        '&pageSize=25&dataType='
        '${Uri.encodeQueryComponent('Foundation,SR Legacy,Survey (FNDDS)')}');
    final http.Response resp =
        await http.get(uri).timeout(const Duration(seconds: 15));
    if (resp.statusCode != 200) {
      return <FoodHit>[];
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final List<FoodHit> out = <FoodHit>[];
    for (final Map<String, dynamic> f
        in ((data['foods'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()) {
      final FoodHit? h = _parse(f);
      if (h != null) {
        out.add(h);
      }
    }
    return out;
  }

  static int _bonus(String? dataType) {
    switch (dataType ?? '') {
      case 'Foundation':
        return 6;
      case 'SR Legacy':
        return 5;
      default:
        return 4; // Survey (FNDDS)
    }
  }

  static FoodHit? _parse(Map<String, dynamic> food) {
    final String desc = (food['description'] as String?)?.trim() ?? '';
    if (desc.isEmpty) {
      return null;
    }
    double? kcal, prot, fat, carb;
    for (final dynamic fn
        in (food['foodNutrients'] as List<dynamic>?) ?? <dynamic>[]) {
      if (fn is! Map<String, dynamic>) {
        continue;
      }
      final String number =
          (fn['nutrientNumber'] ?? fn['number'])?.toString() ?? '';
      final double? value = _numOrNull(fn['value'] ?? fn['amount']);
      if (value == null) {
        continue;
      }
      switch (number) {
        case '208':
          kcal = value;
        case '203':
          prot = value;
        case '204':
          fat = value;
        case '205':
          carb = value;
      }
    }
    if (kcal == null) {
      return null;
    }
    return FoodHit(
      info: ProductInfo(
        name: desc,
        macrosPer100g: Macros(
          proteinG: prot ?? 0,
          calories: kcal,
          carbsG: carb ?? 0,
          fatG: fat ?? 0,
        ),
      ),
      head: desc.split(',').first,
      full: desc,
      qualityBonus: _bonus(food['dataType'] as String?),
    );
  }

  static double? _numOrNull(dynamic v) {
    if (v is num) {
      return v.toDouble();
    }
    if (v is String) {
      return double.tryParse(v);
    }
    return null;
  }
}

class OpenFoodFacts {
  static const Map<String, String> _headers = <String, String>{
    'User-Agent': 'Pantry/0.1 (github.com/scenicprints/pantry)',
  };

  /// [search], but keeping the raw name/brand pieces the ranker needs.
  static Future<List<FoodHit>> searchHits(String query) async {
    final String q = query.trim();
    if (q.isEmpty) {
      return <FoodHit>[];
    }
    final Uri uri = Uri.parse(
        'https://world.openfoodfacts.org/cgi/search.pl'
        '?search_terms=${Uri.encodeQueryComponent(q)}'
        '&search_simple=1&action=process&json=1&page_size=25'
        '&fields=product_name,brands,nutriments,serving_size,quantity,code');
    final http.Response resp = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 20),
        );
    if (resp.statusCode != 200) {
      return <FoodHit>[];
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final List<FoodHit> out = <FoodHit>[];
    for (final Map<String, dynamic> p
        in ((data['products'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()) {
      final ProductInfo? info = _parse(p, p['code'] as String?);
      if (info == null) {
        continue;
      }
      final String rawName = (p['product_name'] as String?)?.trim() ?? '';
      final String brand = (p['brands'] as String?)?.trim() ?? '';
      out.add(FoodHit(
        info: info,
        head: rawName.isEmpty ? brand : rawName,
        full: info.name,
        brand: brand,
      ));
    }
    return out;
  }

  /// Search products by name. Returns up to ~25 matches that have usable
  /// calorie data (others are dropped). Empty list on any failure.
  static Future<List<ProductInfo>> search(String query) async {
    final String q = query.trim();
    if (q.isEmpty) {
      return <ProductInfo>[];
    }
    final Uri uri = Uri.parse(
        'https://world.openfoodfacts.org/cgi/search.pl'
        '?search_terms=${Uri.encodeQueryComponent(q)}'
        '&search_simple=1&action=process&json=1&page_size=25'
        '&fields=product_name,brands,nutriments,serving_size,quantity,code');
    final http.Response resp = await http.get(uri, headers: _headers).timeout(
          const Duration(seconds: 20),
        );
    if (resp.statusCode != 200) {
      return <ProductInfo>[];
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    final List<dynamic> products =
        (data['products'] as List<dynamic>?) ?? <dynamic>[];
    final List<ProductInfo> out = <ProductInfo>[];
    for (final Map<String, dynamic> p
        in products.whereType<Map<String, dynamic>>()) {
      final ProductInfo? info = _parse(p, p['code'] as String?);
      if (info != null) {
        out.add(info);
      }
    }
    return out;
  }

  /// Look up a barcode. Returns null if not found / no usable nutrition.
  static Future<ProductInfo?> fetchByBarcode(String barcode) async {
    final Uri uri = Uri.parse(
        'https://world.openfoodfacts.org/api/v2/product/$barcode.json'
        '?fields=product_name,brands,nutriments,serving_size,quantity');
    final http.Response resp =
        await http.get(uri, headers: _headers).timeout(
              const Duration(seconds: 15),
            );
    if (resp.statusCode != 200) {
      return null;
    }
    final Map<String, dynamic> data =
        jsonDecode(resp.body) as Map<String, dynamic>;
    if ((data['status'] as num?)?.toInt() != 1) {
      return null;
    }
    return _parse(data['product'] as Map<String, dynamic>, barcode);
  }

  static ProductInfo? _parse(Map<String, dynamic> product, String? barcode) {
    final Map<String, dynamic> nut =
        (product['nutriments'] as Map<String, dynamic>?) ??
            <String, dynamic>{};

    final double? kcal = _kcalPer100(nut);
    if (kcal == null) {
      return null; // no calorie data → not worth pre-filling
    }

    String name = (product['product_name'] as String?)?.trim() ?? '';
    final String brand = (product['brands'] as String?)?.trim() ?? '';
    if (name.isEmpty) {
      name = brand.isNotEmpty ? brand : 'Unknown product';
    } else if (brand.isNotEmpty) {
      name = '$name ($brand)';
    }

    return ProductInfo(
      name: name,
      barcode: barcode,
      macrosPer100g: Macros(
        proteinG: _num(nut['proteins_100g']) ?? 0,
        calories: kcal,
        carbsG: _num(nut['carbohydrates_100g']) ?? 0,
        fatG: _num(nut['fat_100g']) ?? 0,
      ),
      servingGrams: _parseGrams(product['serving_size'] as String?),
      packGrams: _parseGrams(product['quantity'] as String?),
    );
  }

  static double? _kcalPer100(Map<String, dynamic> nut) {
    final double? kcal = _num(nut['energy-kcal_100g']);
    if (kcal != null) {
      return kcal;
    }
    final double? kj = _num(nut['energy_100g']) ?? _num(nut['energy-kj_100g']);
    if (kj != null) {
      return kj / 4.184;
    }
    return null;
  }

  static double? _num(dynamic v) {
    if (v is num) {
      return v.toDouble();
    }
    if (v is String) {
      return double.tryParse(v);
    }
    return null;
  }

  /// Pulls grams out of strings like "454 g", "1 lb (454 g)", "1kg", "500g".
  static double? _parseGrams(String? s) {
    if (s == null) {
      return null;
    }
    final String t = s.toLowerCase();
    // kg first so "1kg" doesn't match the "g" branch as "1 g".
    final RegExpMatch? kg =
        RegExp(r'(\d+(?:\.\d+)?)\s*kg\b').firstMatch(t);
    if (kg != null) {
      final double? v = double.tryParse(kg.group(1)!);
      if (v != null) {
        return v * 1000;
      }
    }
    final RegExpMatch? g = RegExp(r'(\d+(?:\.\d+)?)\s*g\b').firstMatch(t);
    if (g != null) {
      return double.tryParse(g.group(1)!);
    }
    return null;
  }
}
