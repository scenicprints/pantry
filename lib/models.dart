import 'dart:convert';

// ═══════════════════════════════════════════════════════════════════════
// DATA MODEL  —  the schema is the CONTRACT with the AI chef.
//
// Two independent ideas per item:
//   • TRACKING  — how stock is measured: by weight (grams) or by count.
//       weight → total_weight_g / remaining_weight_g / price_per_gram
//       count  → unit:"count" + total_count / remaining_count / price_per_unit
//   • NUTRITION — entered PER SERVING (straight off the label):
//       serving_size + serving_unit + macros_per_serving
//     When the serving unit is grams we also emit a derived macros_per_100g
//     so older chef logic keeps working.
//
// Backward compatible: old files with macros_per_100g / macros_per_unit are
// migrated to a per-serving representation on read.
//
// `price_per_*`, `expiring_soon`, and the derived `macros_per_100g` are
// written out so the chef needn't recompute them. `updated_at_ms` drives the
// last-write-wins merge; `deleted` is a tombstone. The chef ignores both.
// ═══════════════════════════════════════════════════════════════════════

const String kUnitGrams = 'g';
const String kUnitCount = 'count';

/// Common serving units offered in the UI (plus a free-text "custom").
const List<String> kServingUnits = <String>[
  'g', 'oz', 'ml', 'cup', 'tbsp', 'tsp', 'piece',
];

/// Nutrition for ONE serving.
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

  /// Scale every value by [f] (e.g. to convert a serving to per-100 g).
  Macros scale(double f) => Macros(
        proteinG: proteinG * f,
        calories: calories * f,
        carbsG: carbsG * f,
        fatG: fatG * f,
      );

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
  String unit; // tracking unit: 'g' | 'count'
  double total;
  double remaining;
  double price;
  Macros macros; // PER SERVING
  double servingSize; // amount in one serving (0 = unset)
  String servingUnit; // e.g. 'g', 'oz', 'cup', 'cookie'
  String? expirationDate; // 'YYYY-MM-DD' or null
  String dateAdded; // 'YYYY-MM-DD'
  double lastPrice;
  int updatedAtMs;
  bool deleted;

  PantryItem({
    required this.id,
    required this.name,
    this.barcode,
    this.unit = kUnitGrams,
    required this.total,
    required this.remaining,
    required this.price,
    required this.macros,
    this.servingSize = 0,
    this.servingUnit = 'g',
    this.expirationDate,
    required this.dateAdded,
    required this.lastPrice,
    this.updatedAtMs = 0,
    this.deleted = false,
  });

  bool get isCount => unit == kUnitCount;

  /// price ÷ total — price-per-gram (weight) or price-per-unit (count).
  double get pricePer => total > 0 ? price / total : 0;

  String get unitLabel => isCount ? 'ct' : 'g';

  /// Human serving label, e.g. "30 g" or "2 cookie". Empty if unset.
  String get servingLabel =>
      servingSize > 0 ? '${_trim(servingSize)} $servingUnit' : '';

  bool isExpiringSoon(DateTime now, {int withinDays = 5}) {
    final DateTime? exp = _parseDate(expirationDate);
    if (exp == null) {
      return false;
    }
    final DateTime today = DateTime(now.year, now.month, now.day);
    return exp.difference(today).inDays <= withinDays;
  }

  Map<String, dynamic> toJson(DateTime now) {
    final Map<String, dynamic> m = <String, dynamic>{
      'id': id,
      'name': name,
      if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
      'price': _round2(price),
      if (servingSize > 0) 'serving_size': _round(servingSize),
      if (servingSize > 0) 'serving_unit': servingUnit,
      if (!macros.isEmpty) 'macros_per_serving': macros.toJson(),
      // Derived per-100 g when the serving is in grams — keeps older chef
      // logic (and any per-100 g consumers) working unchanged.
      if (!macros.isEmpty && servingUnit == 'g' && servingSize > 0)
        'macros_per_100g': macros.scale(100 / servingSize).toJson(),
      if (expirationDate != null && expirationDate!.isNotEmpty)
        'expiration_date': expirationDate,
      'expiring_soon': isExpiringSoon(now),
      'date_added': dateAdded,
      'last_price': _round2(lastPrice),
      'updated_at_ms': updatedAtMs,
      if (deleted) 'deleted': true,
    };
    if (isCount) {
      m['unit'] = kUnitCount;
      m['total_count'] = _round(total);
      m['remaining_count'] = _round(remaining);
      m['price_per_unit'] = _round4(pricePer);
    } else {
      m['total_weight_g'] = _round(total);
      m['remaining_weight_g'] = _round(remaining);
      m['price_per_gram'] = _round4(pricePer);
    }
    return m;
  }

  factory PantryItem.fromJson(Map<String, dynamic> j) {
    final bool count = j['unit'] == kUnitCount || j.containsKey('total_count');

    // Nutrition migration: prefer per-serving; fall back to legacy per-100 g
    // (a 100 g serving) or per-unit (a 1-unit serving).
    Macros macros;
    double servingSize;
    String servingUnit;
    if (j['macros_per_serving'] != null) {
      macros = Macros.fromJson(j['macros_per_serving'] as Map<String, dynamic>?);
      servingSize = _num(j['serving_size']);
      servingUnit = (j['serving_unit'] as String?) ?? 'g';
    } else if (j['macros_per_100g'] != null) {
      macros = Macros.fromJson(j['macros_per_100g'] as Map<String, dynamic>?);
      servingSize = 100;
      servingUnit = 'g';
    } else if (j['macros_per_unit'] != null) {
      macros = Macros.fromJson(j['macros_per_unit'] as Map<String, dynamic>?);
      servingSize = 1;
      servingUnit = 'serving';
    } else {
      macros = const Macros();
      servingSize = _num(j['serving_size']);
      servingUnit = (j['serving_unit'] as String?) ?? 'g';
    }

    if (count) {
      return PantryItem(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        barcode: j['barcode'] as String?,
        unit: kUnitCount,
        total: _num(j['total_count']),
        remaining: _num(j['remaining_count'] ?? j['total_count']),
        price: _num(j['price']),
        macros: macros,
        servingSize: servingSize,
        servingUnit: servingUnit,
        expirationDate: j['expiration_date'] as String?,
        dateAdded: (j['date_added'] as String?) ?? '',
        lastPrice: _num(j['last_price'] ?? j['price']),
        updatedAtMs: (j['updated_at_ms'] as num?)?.toInt() ?? 0,
        deleted: j['deleted'] == true,
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
      macros: macros,
      servingSize: servingSize,
      servingUnit: servingUnit,
      expirationDate: j['expiration_date'] as String?,
      dateAdded: (j['date_added'] as String?) ?? '',
      lastPrice: _num(j['last_price'] ?? j['price']),
      updatedAtMs: (j['updated_at_ms'] as num?)?.toInt() ?? 0,
      deleted: j['deleted'] == true,
    );
  }
}

/// A one-tap re-add for a frequent purchase.
class QuickAddItem {
  String name;
  String? barcode;
  String unit;
  double lastPrice;
  Macros macros; // per serving
  double servingSize;
  String servingUnit;
  double? lastTotal;
  bool deleted;

  QuickAddItem({
    required this.name,
    this.barcode,
    this.unit = kUnitGrams,
    required this.lastPrice,
    required this.macros,
    this.servingSize = 0,
    this.servingUnit = 'g',
    this.lastTotal,
    this.deleted = false,
  });

  bool get isCount => unit == kUnitCount;

  Map<String, dynamic> toJson() {
    final Map<String, dynamic> m = <String, dynamic>{
      'name': name,
      if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
      'last_price': _round2(lastPrice),
      if (servingSize > 0) 'serving_size': _round(servingSize),
      if (servingSize > 0) 'serving_unit': servingUnit,
      if (!macros.isEmpty) 'macros_per_serving': macros.toJson(),
      if (deleted) 'deleted': true,
    };
    if (isCount) {
      m['unit'] = kUnitCount;
      if (lastTotal != null) {
        m['last_total_count'] = _round(lastTotal!);
      }
    } else if (lastTotal != null) {
      m['last_total_weight_g'] = _round(lastTotal!);
    }
    return m;
  }

  factory QuickAddItem.fromJson(Map<String, dynamic> j) {
    final bool count =
        j['unit'] == kUnitCount || j.containsKey('last_total_count');
    Macros macros;
    double servingSize;
    String servingUnit;
    if (j['macros_per_serving'] != null) {
      macros = Macros.fromJson(j['macros_per_serving'] as Map<String, dynamic>?);
      servingSize = _num(j['serving_size']);
      servingUnit = (j['serving_unit'] as String?) ?? 'g';
    } else if (j['macros_per_100g'] != null) {
      macros = Macros.fromJson(j['macros_per_100g'] as Map<String, dynamic>?);
      servingSize = 100;
      servingUnit = 'g';
    } else if (j['macros_per_unit'] != null) {
      macros = Macros.fromJson(j['macros_per_unit'] as Map<String, dynamic>?);
      servingSize = 1;
      servingUnit = 'serving';
    } else {
      macros = const Macros();
      servingSize = _num(j['serving_size']);
      servingUnit = (j['serving_unit'] as String?) ?? 'g';
    }
    return QuickAddItem(
      name: (j['name'] as String?) ?? '',
      barcode: j['barcode'] as String?,
      unit: count ? kUnitCount : kUnitGrams,
      lastPrice: _num(j['last_price']),
      macros: macros,
      servingSize: servingSize,
      servingUnit: servingUnit,
      lastTotal: (count
              ? (j['last_total_count'] as num?)
              : (j['last_total_weight_g'] as num?))
          ?.toDouble(),
      deleted: j['deleted'] == true,
    );
  }
}

/// The whole file: `{ "pantry": [...], "quick_add_items": [...] }`.
class PantryData {
  final List<PantryItem> pantry;
  final List<QuickAddItem> quickAdd;

  const PantryData({this.pantry = const [], this.quickAdd = const []});

  /// [keepDeleted] retains tombstones — true for the local cache (a delete
  /// survives a restart), false for the GitHub file the chef reads.
  String encode(DateTime now, {bool keepDeleted = false}) {
    const JsonEncoder enc = JsonEncoder.withIndent('  ');
    final Iterable<PantryItem> items =
        keepDeleted ? pantry : pantry.where((PantryItem i) => !i.deleted);
    final Iterable<QuickAddItem> quick =
        keepDeleted ? quickAdd : quickAdd.where((QuickAddItem q) => !q.deleted);
    return enc.convert(<String, dynamic>{
      'pantry': items.map((PantryItem i) => i.toJson(now)).toList(),
      'quick_add_items': quick.map((QuickAddItem q) => q.toJson()).toList(),
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

  /// Last-write-wins merge onto the latest fetched copy. Pantry items keyed
  /// by id (higher `updated_at_ms` wins); quick-adds keyed by lower-cased
  /// name (local wins).
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

String _trim(double v) =>
    v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

double _round(double v) => (v * 10).round() / 10;
double _round2(double v) => (v * 100).round() / 100;
double _round4(double v) => (v * 10000).round() / 10000;
