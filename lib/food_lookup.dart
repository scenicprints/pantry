import 'dart:convert';
import 'package:http/http.dart' as http;

import 'models.dart';

// ═══════════════════════════════════════════════════════════════════════
// OPEN FOOD FACTS — free barcode → product + per-100 g macros.
// Adapted from the BodyComp food client, trimmed to the four macros the
// pantry cares about (protein / calories / carbs / fat) plus a default
// serving/pack weight when the product provides one.
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

class OpenFoodFacts {
  static const Map<String, String> _headers = <String, String>{
    'User-Agent': 'Pantry/0.1 (github.com/scenicprints/pantry)',
  };

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
