import 'dart:convert';

// ═══════════════════════════════════════════════════════════════════════
// DATA MODEL
//
// This is the pantry's schema — and it is the CONTRACT with the AI chef,
// which reads the same JSON from GitHub. The on-disk / on-GitHub keys are
// snake_case exactly as the master spec defines them; do not rename them
// without updating the chef. `price_per_gram` and `expiring_soon` are
// DERIVED and written out so the chef doesn't have to recompute them.
//
// `updated_at_ms` is an extra field the chef simply ignores; it lets the
// sync layer do a last-write-wins merge instead of a blind overwrite.
// ═══════════════════════════════════════════════════════════════════════

/// Per-100 g nutrition. Open Food Facts is already per-100 g; label OCR is
/// converted to per-100 g before it lands here.
class Macros {
  final double proteinG;
  final double calories;
  final double carbsG;
  final double fatG;

  const Macros({
    this.proteinG = 0,
    this.calories = 0,
    this.carbsG = 0,
    this.fatG = 0,
  });

  Macros copyWith({
    double? proteinG,
    double? calories,
    double? carbsG,
    double? fatG,
  }) =>
      Macros(
        proteinG: proteinG ?? this.proteinG,
        calories: calories ?? this.calories,
        carbsG: carbsG ?? this.carbsG,
        fatG: fatG ?? this.fatG,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'protein_g': _round(proteinG),
        'calories': _round(calories),
        'carbs_g': _round(carbsG),
        'fat_g': _round(fatG),
      };

  factory Macros.fromJson(Map<String, dynamic>? j) {
    if (j == null) {
      return const Macros();
    }
    return Macros(
      proteinG: _num(j['protein_g']),
      calories: _num(j['calories']),
      carbsG: _num(j['carbs_g']),
      fatG: _num(j['fat_g']),
    );
  }
}

/// One item in the kitchen.
class PantryItem {
  final String id;
  String name;
  String? barcode;
  double totalWeightG;
  double remainingWeightG;
  double price;
  Macros macrosPer100g;
  String? expirationDate; // 'YYYY-MM-DD' or null
  String dateAdded; // 'YYYY-MM-DD'
  double lastPrice;
  int updatedAtMs; // sync bookkeeping (chef ignores this)

  PantryItem({
    required this.id,
    required this.name,
    this.barcode,
    required this.totalWeightG,
    required this.remainingWeightG,
    required this.price,
    required this.macrosPer100g,
    this.expirationDate,
    required this.dateAdded,
    required this.lastPrice,
    this.updatedAtMs = 0,
  });

  /// price ÷ total weight. Guards divide-by-zero for count-based items.
  double get pricePerGram =>
      totalWeightG > 0 ? price / totalWeightG : 0;

  /// True when an expiration date is set and within [withinDays] of [now].
  /// Also true once already expired.
  bool isExpiringSoon(DateTime now, {int withinDays = 5}) {
    final DateTime? exp = _parseDate(expirationDate);
    if (exp == null) {
      return false;
    }
    final DateTime today = DateTime(now.year, now.month, now.day);
    final int daysLeft = exp.difference(today).inDays;
    return daysLeft <= withinDays;
  }

  Map<String, dynamic> toJson(DateTime now) => <String, dynamic>{
        'id': id,
        'name': name,
        if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
        'total_weight_g': _round(totalWeightG),
        'remaining_weight_g': _round(remainingWeightG),
        'price': _round2(price),
        'price_per_gram': _round4(pricePerGram),
        'macros_per_100g': macrosPer100g.toJson(),
        if (expirationDate != null && expirationDate!.isNotEmpty)
          'expiration_date': expirationDate,
        'expiring_soon': isExpiringSoon(now),
        'date_added': dateAdded,
        'last_price': _round2(lastPrice),
        'updated_at_ms': updatedAtMs,
      };

  factory PantryItem.fromJson(Map<String, dynamic> j) => PantryItem(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        barcode: j['barcode'] as String?,
        totalWeightG: _num(j['total_weight_g']),
        remainingWeightG:
            _num(j['remaining_weight_g'] ?? j['total_weight_g']),
        price: _num(j['price']),
        macrosPer100g:
            Macros.fromJson(j['macros_per_100g'] as Map<String, dynamic>?),
        expirationDate: j['expiration_date'] as String?,
        dateAdded: (j['date_added'] as String?) ?? '',
        lastPrice: _num(j['last_price'] ?? j['price']),
        updatedAtMs: (j['updated_at_ms'] as num?)?.toInt() ?? 0,
      );
}

/// A one-tap re-add for a frequent purchase.
class QuickAddItem {
  String name;
  String? barcode;
  double lastPrice;
  Macros macrosPer100g;
  double? lastTotalWeightG; // remembered so re-add can pre-fill the amount too

  QuickAddItem({
    required this.name,
    this.barcode,
    required this.lastPrice,
    required this.macrosPer100g,
    this.lastTotalWeightG,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
        'last_price': _round2(lastPrice),
        'macros_per_100g': macrosPer100g.toJson(),
        if (lastTotalWeightG != null)
          'last_total_weight_g': _round(lastTotalWeightG!),
      };

  factory QuickAddItem.fromJson(Map<String, dynamic> j) => QuickAddItem(
        name: (j['name'] as String?) ?? '',
        barcode: j['barcode'] as String?,
        lastPrice: _num(j['last_price']),
        macrosPer100g:
            Macros.fromJson(j['macros_per_100g'] as Map<String, dynamic>?),
        lastTotalWeightG: (j['last_total_weight_g'] as num?)?.toDouble(),
      );
}

/// The whole file: `{ "pantry": [...], "quick_add_items": [...] }`.
class PantryData {
  final List<PantryItem> pantry;
  final List<QuickAddItem> quickAdd;

  const PantryData({this.pantry = const [], this.quickAdd = const []});

  /// Pretty-printed so the GitHub diff is human-readable. [now] is used to
  /// stamp the derived `expiring_soon` flag at write time.
  String encode(DateTime now) {
    const JsonEncoder enc = JsonEncoder.withIndent('  ');
    return enc.convert(<String, dynamic>{
      'pantry': pantry.map((PantryItem i) => i.toJson(now)).toList(),
      'quick_add_items':
          quickAdd.map((QuickAddItem q) => q.toJson()).toList(),
    });
  }

  static PantryData decode(String jsonStr) {
    try {
      final dynamic d = jsonDecode(jsonStr);
      if (d is Map<String, dynamic>) {
        final List<PantryItem> items =
            ((d['pantry'] as List<dynamic>?) ?? <dynamic>[])
                .whereType<Map<String, dynamic>>()
                .map(PantryItem.fromJson)
                .toList();
        final List<QuickAddItem> quick =
            ((d['quick_add_items'] as List<dynamic>?) ?? <dynamic>[])
                .whereType<Map<String, dynamic>>()
                .map(QuickAddItem.fromJson)
                .toList();
        return PantryData(pantry: items, quickAdd: quick);
      }
    } catch (_) {}
    return const PantryData();
  }

  /// Last-write-wins merge onto the latest fetched copy (never a blind
  /// overwrite). Pantry items are keyed by id; the higher `updated_at_ms`
  /// wins. Quick-adds are keyed by lower-cased name; the app's copy wins on
  /// ties since it just wrote it.
  static PantryData merge(PantryData remote, PantryData local) {
    final Map<String, PantryItem> items = <String, PantryItem>{};
    for (final PantryItem i in <PantryItem>[...remote.pantry, ...local.pantry]) {
      final PantryItem? cur = items[i.id];
      if (cur == null || i.updatedAtMs >= cur.updatedAtMs) {
        items[i.id] = i;
      }
    }
    final List<PantryItem> mergedItems = items.values.toList()
      ..sort((PantryItem a, PantryItem b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final Map<String, QuickAddItem> quick = <String, QuickAddItem>{};
    for (final QuickAddItem q in remote.quickAdd) {
      quick[q.name.toLowerCase()] = q;
    }
    for (final QuickAddItem q in local.quickAdd) {
      quick[q.name.toLowerCase()] = q; // local wins
    }
    final List<QuickAddItem> mergedQuick = quick.values.toList()
      ..sort((QuickAddItem a, QuickAddItem b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    return PantryData(pantry: mergedItems, quickAdd: mergedQuick);
  }
}

// ── small shared helpers ────────────────────────────────────────────────

double _num(dynamic v) {
  if (v is num) {
    return v.toDouble();
  }
  if (v is String) {
    return double.tryParse(v) ?? 0;
  }
  return 0;
}

DateTime? _parseDate(String? s) {
  if (s == null || s.isEmpty) {
    return null;
  }
  return DateTime.tryParse(s);
}

// Rounding keeps the JSON tidy: whole grams, cents for money, 4 dp for /g.
double _round(double v) => (v * 10).round() / 10;
double _round2(double v) => (v * 100).round() / 100;
double _round4(double v) => (v * 10000).round() / 10000;
