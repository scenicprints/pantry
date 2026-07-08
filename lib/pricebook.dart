import 'dart:convert';

import 'package:http/http.dart' as http;

import 'github_sync.dart';
import 'models.dart';

// ═══════════════════════════════════════════════════════════════════════
// PRICE BOOK — the last-known unit price for everything the user has ever
// priced, kept even after an item is used up and leaves the pantry. This is
// what lets the chef put a real dollar figure on a "new buy" you've bought
// before, instead of guessing. Keyed by lower-cased name (barcode too when
// present). Synced as `price_book.json`; merges keep the newer price.
// ═══════════════════════════════════════════════════════════════════════

const String kPriceBookPath = 'price_book.json';

class PriceEntry {
  final String name; // display name (original casing)
  final String? barcode;
  final double unitPrice; // per gram (weight) or per unit (count)
  final String unit; // 'g' | 'count'
  final int ts; // when this price was recorded

  const PriceEntry({
    required this.name,
    this.barcode,
    required this.unitPrice,
    required this.unit,
    required this.ts,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
        'unit_price': _round4(unitPrice),
        'unit': unit,
        'ts': ts,
      };

  factory PriceEntry.fromJson(Map<String, dynamic> j) => PriceEntry(
        name: (j['name'] as String?) ?? '',
        barcode: j['barcode'] as String?,
        unitPrice: _num(j['unit_price']),
        unit: (j['unit'] as String?) ?? 'g',
        ts: (j['ts'] as num?)?.round() ?? 0,
      );

  bool get isCount => unit == 'count';
}

class PriceBook {
  final Map<String, PriceEntry> byName; // key = name.toLowerCase()
  const PriceBook([this.byName = const <String, PriceEntry>{}]);

  bool get isEmpty => byName.isEmpty;

  PriceEntry? lookup(String name) => byName[name.trim().toLowerCase()];

  /// A copy with [item]'s current price recorded (skips untracked/priceless
  /// items). Returns the same book unchanged when there's nothing to record.
  PriceBook withItem(PantryItem item, DateTime when) {
    if (item.untracked || item.pricePer <= 0 || item.name.trim().isEmpty) {
      return this;
    }
    final String key = item.name.trim().toLowerCase();
    final Map<String, PriceEntry> next =
        Map<String, PriceEntry>.from(byName);
    next[key] = PriceEntry(
      name: item.name.trim(),
      barcode: item.barcode,
      unitPrice: item.pricePer,
      unit: item.unit,
      ts: when.millisecondsSinceEpoch,
    );
    return PriceBook(next);
  }

  /// Seed/refresh from the current pantry (used at startup so owned items are
  /// always priceable even before any new save).
  PriceBook withPantry(List<PantryItem> items, DateTime when) {
    PriceBook book = this;
    for (final PantryItem it in items) {
      if (!it.deleted) {
        book = book.withItem(it, when);
      }
    }
    return book;
  }

  String encode() {
    const JsonEncoder enc = JsonEncoder.withIndent('  ');
    return enc.convert(<String, dynamic>{
      'prices': byName.values.map((PriceEntry e) => e.toJson()).toList(),
    });
  }

  static PriceBook decode(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) {
      return const PriceBook();
    }
    try {
      final dynamic d = jsonDecode(jsonStr);
      if (d is Map<String, dynamic>) {
        final Map<String, PriceEntry> m = <String, PriceEntry>{};
        for (final dynamic e in (d['prices'] as List<dynamic>?) ?? <dynamic>[]) {
          if (e is Map<String, dynamic>) {
            final PriceEntry pe = PriceEntry.fromJson(e);
            if (pe.name.isNotEmpty) {
              m[pe.name.toLowerCase()] = pe;
            }
          }
        }
        return PriceBook(m);
      }
    } catch (_) {}
    return const PriceBook();
  }

  /// Union of two books, keeping the newer price for each name.
  static PriceBook merge(PriceBook a, PriceBook b) {
    final Map<String, PriceEntry> out = Map<String, PriceEntry>.from(a.byName);
    b.byName.forEach((String k, PriceEntry v) {
      final PriceEntry? cur = out[k];
      if (cur == null || v.ts >= cur.ts) {
        out[k] = v;
      }
    });
    return PriceBook(out);
  }
}

/// GitHub read/write for `price_book.json`. Merge keeps the newer price.
class PriceBookSync {
  static bool get canWrite => PantrySync.canWrite;

  static Uri get _uri => Uri.parse(
      'https://api.github.com/repos/$kDataRepoOwner/$kDataRepoName/contents/$kPriceBookPath');

  static Map<String, String> _headers() => <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Pantry (github.com/scenicprints/pantry)',
        if (PantrySync.canWrite)
          'Authorization': 'Bearer ${const String.fromEnvironment('GITHUB_DATA_TOKEN')}',
      };

  static Future<({PriceBook book, String? sha})?> fetch() async {
    try {
      final http.Response r =
          await http.get(_uri, headers: _headers()).timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) {
        return (book: const PriceBook(), sha: null);
      }
      if (r.statusCode != 200) {
        return null;
      }
      final Map<String, dynamic> j = jsonDecode(r.body) as Map<String, dynamic>;
      final String content = (j['content'] as String? ?? '').replaceAll('\n', '');
      final String? sha = j['sha'] as String?;
      final String decoded =
          content.isEmpty ? '' : utf8.decode(base64.decode(content));
      return (book: PriceBook.decode(decoded), sha: sha);
    } catch (_) {
      return null;
    }
  }

  static Future<PriceBook?> push(PriceBook local) async {
    if (!canWrite) {
      return null;
    }
    for (int attempt = 0; attempt < 2; attempt++) {
      final ({PriceBook book, String? sha})? remote = await fetch();
      if (remote == null) {
        return null;
      }
      final PriceBook merged = PriceBook.merge(remote.book, local);
      if (await _put(merged.encode(), remote.sha)) {
        return merged;
      }
    }
    return null;
  }

  static Future<bool> _put(String contentStr, String? sha) async {
    try {
      final Map<String, dynamic> body = <String, dynamic>{
        'message': 'Update price book',
        'content': base64.encode(utf8.encode(contentStr)),
        'branch': 'main',
        'sha': ?sha,
      };
      final http.Response r = await http
          .put(_uri, headers: _headers(), body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      return r.statusCode == 200 || r.statusCode == 201;
    } catch (_) {
      return false;
    }
  }
}

double _num(dynamic v) {
  if (v is num) {
    return v.toDouble();
  }
  if (v is String) {
    return double.tryParse(v) ?? 0;
  }
  return 0;
}

double _round4(double v) => (v * 10000).round() / 10000;
