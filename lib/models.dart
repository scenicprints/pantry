import 'dart:convert';

// ═══════════════════════════════════════════════════════════════════════
// DATA MODEL
//
// This is the pantry's schema — and it is the CONTRACT with the AI chef,
// which reads the same JSON from GitHub. Keys are snake_case exactly as the
// master spec defines them.
//
// An item is tracked either by WEIGHT (grams) or by COUNT (e.g. eggs):
//   • weight items keep the original keys — total_weight_g / remaining_weight_g
//     / price_per_gram / macros_per_100g  (chef unchanged)
//   • count items use   unit:"count" + total_count / remaining_count /
//     price_per_unit / (optional) macros_per_unit
// Items with no `unit` are treated as weight — so old files still parse.
//
// `price_per_gram`/`price_per_unit` and `expiring_soon` are DERIVED and
// written out so the chef doesn't recompute them. `updated_at_ms` is extra
// bookkeeping the chef ignores; it drives last-write-wins merges.
// ═══════════════════════════════════════════════════════════════════════

const String kUnitGrams = 'g';
const String kUnitCount = 'count';

/// Nutrition. For weight items these are per 100 g; for count items they are
/// per single unit (and are usually left empty — count items are "pure count").
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

  bool get isEmpty =>
      proteinG == 0 && calories == 0 && carbsG == 0 && fatG == 0;

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

/// One item in the kitchen. `total`/`remaining` are in grams when
/// [unit] == 'g', or whole units when [unit] == 'count'.
class PantryItem {
  final String id;
  String name;
  String? barcode;
  String unit; // 'g' | 'count'
  double total;
  double remaining;
  double price;
  Macros macros; // per 100 g (weight) or per unit (count)
  String? expirationDate; // 'YYYY-MM-DD' or null
  String dateAdded; // 'YYYY-MM-DD'
  double lastPrice;
  int updatedAtMs;

  PantryItem({
    required this.id,
    required this.name,
    this.barcode,
    this.unit = kUnitGrams,
    required this.total,
    required this.remaining,
    required this.price,
    required this.macros,
    this.expirationDate,
    required this.dateAdded,
    required this.lastPrice,
    this.updatedAtMs = 0,
  });

  bool get isCount => unit == kUnitCount;

  /// price ÷ total. This is price-per-gram for weight items and
  /// price-per-unit for count items. Guards divide-by-zero.
  double get pricePer => total > 0 ? price / total : 0;

  /// Short label for the amount: 'g' or 'ct'.
  String get unitLabel => isCount ? 'ct' : 'g';

  /// True when an expiration date is set and within [withinDays] of [now]
  /// (also true once already expired).
  bool isExpiringSoon(DateTime now, {int withinDays = 5}) {
    final DateTime? exp = _parseDate(expirationDate);
    if (exp == null) {
      return false;
    }
    final DateTime today = DateTime(now.year, now.month, now.day);
    return exp.difference(today).inDays <= withinDays;
  }

  Map<String, dynamic> toJson(DateTime now) {
    final Map<String, dynamic> common = <String, dynamic>{
      'id': id,
      'name': name,
      if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
      'price': _round2(price),
      if (expirationDate != null && expirationDate!.isNotEmpty)
        'expiration_date': expirationDate,
      'expiring_soon': isExpiringSoon(now),
      'date_added': dateAdded,
      'last_price': _round2(lastPrice),
      'updated_at_ms': updatedAtMs,
    };
    if (isCount) {
      return <String, dynamic>{
        ...common,
        'unit': kUnitCount,
        'total_count': _round(total),
        'remaining_count': _round(remaining),
        'price_per_unit': _round4(pricePer),
        if (!macros.isEmpty) 'macros_per_unit': macros.toJson(),
      };
    }
    return <String, dynamic>{
      ...common,
      'total_weight_g': _round(total),
      'remaining_weight_g': _round(remaining),
      'price_per_gram': _round4(pricePer),
      'macros_per_100g': macros.toJson(),
    };
  }

  factory PantryItem.fromJson(Map<String, dynamic> j) {
    final bool count =
        j['unit'] == kUnitCount || j.containsKey('total_count');
    if (count) {
      return PantryItem(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        barcode: j['barcode'] as String?,
        unit: kUnitCount,
        total: _num(j['total_count']),
        remaining: _num(j['remaining_count'] ?? j['total_count']),
        price: _num(j['price']),
        macros: Macros.fromJson(j['macros_per_unit'] as Map<String, dynamic>?),
        expirationDate: j['expiration_date'] as String?,
        dateAdded: (j['date_added'] as String?) ?? '',
        lastPrice: _num(j['last_price'] ?? j['price']),
        updatedAtMs: (j['updated_at_ms'] as num?)?.toInt() ?? 0,
      );
    }
    return PantryItem(
      id: (j['id'] as String?) ?? '',
      name: (j['name'] as String?) ?? '',
      barcode: j['barcode'] as String?,
      unit: kUnitGrams,
      total: _num(j['total_weight_g']),
      remaining: _num(j['remaining_weight_g'] ?? j['total_weight_g']),
      price: _num(j['price']),
      macros: Macros.fromJson(j['macros_per_100g'] as Map<String, dynamic>?),
      expirationDate: j['expiration_date'] as String?,
      dateAdded: (j['date_added'] as String?) ?? '',
      lastPrice: _num(j['last_price'] ?? j['price']),
      updatedAtMs: (j['updated_at_ms'] as num?)?.toInt() ?? 0,
    );
  }
}

/// A one-tap re-add for a frequent purchase.
class QuickAddItem {
  String name;
  String? barcode;
  String unit;
  double lastPrice;
  Macros macros;
  double? lastTotal; // remembered amount (grams or count) to pre-fill

  QuickAddItem({
    required this.name,
    this.barcode,
    this.unit = kUnitGrams,
    required this.lastPrice,
    required this.macros,
    this.lastTotal,
  });

  bool get isCount => unit == kUnitCount;

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> m = <String, dynamic>{
      'name': name,
      if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
      'last_price': _round2(lastPrice),
    };
    if (isCount) {
      m['unit'] = kUnitCount;
      if (!macros.isEmpty) {
        m['macros_per_unit'] = macros.toJson();
      }
      if (lastTotal != null) {
        m['last_total_count'] = _round(lastTotal!);
      }
    } else {
      m['macros_per_100g'] = macros.toJson();
      if (lastTotal != null) {
        m['last_total_weight_g'] = _round(lastTotal!);
      }
    }
    return m;
  }

  factory QuickAddItem.fromJson(Map<String, dynamic> j) {
    final bool count =
        j['unit'] == kUnitCount || j.containsKey('last_total_count');
    return QuickAddItem(
      name: (j['name'] as String?) ?? '',
      barcode: j['barcode'] as String?,
      unit: count ? kUnitCount : kUnitGrams,
      lastPrice: _num(j['last_price']),
      macros: Macros.fromJson((count
          ? j['macros_per_unit']
          : j['macros_per_100g']) as Map<String, dynamic>?),
      lastTotal: (count
              ? (j['last_total_count'] as num?)
              : (j['last_total_weight_g'] as num?))
          ?.toDouble(),
    );
  }
}

/// The whole file: `{ "pantry": [...], "quick_add_items": [...] }`.
class PantryData {
  final List<PantryItem> pantry;
  final List<QuickAddItem> quickAdd;

  const PantryData({this.pantry = const [], this.quickAdd = const []});

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
  /// overwrite). Pantry items keyed by id; higher `updated_at_ms` wins.
  /// Quick-adds keyed by lower-cased name; the local copy wins.
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
      quick[q.name.toLowerCase()] = q;
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

double _round(double v) => (v * 10).round() / 10;
double _round2(double v) => (v * 100).round() / 100;
double _round4(double v) => (v * 10000).round() / 10000;
