import 'dart:convert';

import 'package:http/http.dart' as http;

import 'github_sync.dart';
import 'models.dart';

// ═══════════════════════════════════════════════════════════════════════
// SPENDING LEDGER — tracks money by CONSUMPTION, not purchase. Something can
// sit in the pantry for months; it only counts as "spent" when it's actually
// used. Each time an item is used (the Use(−) button today; BodyComp's
// confirm-subtract can append here later), one immutable entry is recorded
// with the cost of exactly what was consumed (amount × price-per-unit at that
// moment).
//
// Stored as `usage.json` in the same public pantry-data repo. The log is
// APPEND-ONLY, so syncing is a union by entry id — it can never clobber an
// entry another writer added, which sidesteps the last-write-wins merge that
// governs pantry.json.
// ═══════════════════════════════════════════════════════════════════════

const String kUsagePath = 'usage.json';

/// One consumption event. Immutable — the cost is snapshotted at use time so a
/// later price change never rewrites history.
class UsageEntry {
  final String id; // unique per event (itemId + timestamp)
  final int ts; // event time, ms since epoch
  final String itemId; // pantry item id (may be '' if unknown)
  final String name;
  final double amount; // grams or count actually consumed
  final String unit; // 'g' | 'count'
  final double unitPrice; // price per gram/unit at the time of use
  final double cost; // amount × unitPrice
  final String source; // 'manual' | 'bodycomp'

  const UsageEntry({
    required this.id,
    required this.ts,
    required this.itemId,
    required this.name,
    required this.amount,
    required this.unit,
    required this.unitPrice,
    required this.cost,
    this.source = 'manual',
  });

  /// Build an entry from a pantry item and the amount just used.
  factory UsageEntry.forUse(PantryItem item, double amount, DateTime when,
      {String source = 'manual'}) {
    final int ts = when.millisecondsSinceEpoch;
    final double unitPrice = item.pricePer;
    return UsageEntry(
      id: '${item.id}-$ts',
      ts: ts,
      itemId: item.id,
      name: item.name,
      amount: amount,
      unit: item.unit,
      unitPrice: unitPrice,
      cost: _round2(amount * unitPrice),
      source: source,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'ts': ts,
        'item_id': itemId,
        'name': name,
        'amount': _round(amount),
        'unit': unit,
        'unit_price': _round4(unitPrice),
        'cost': _round2(cost),
        'source': source,
      };

  factory UsageEntry.fromJson(Map<String, dynamic> j) {
    final int ts = (j['ts'] as num?)?.round() ?? 0;
    final String itemId = (j['item_id'] as String?) ?? '';
    return UsageEntry(
      id: (j['id'] as String?) ?? '$itemId-$ts',
      ts: ts,
      itemId: itemId,
      name: (j['name'] as String?) ?? '',
      amount: _num(j['amount']),
      unit: (j['unit'] as String?) ?? 'g',
      unitPrice: _num(j['unit_price']),
      cost: _num(j['cost']),
      source: (j['source'] as String?) ?? 'manual',
    );
  }
}

/// The whole ledger. Append-only; merge is a union keyed by entry id.
class SpendingLog {
  final List<UsageEntry> entries;
  const SpendingLog([this.entries = const <UsageEntry>[]]);

  SpendingLog add(UsageEntry e) =>
      SpendingLog(<UsageEntry>[...entries, e]);

  String encode() {
    const JsonEncoder enc = JsonEncoder.withIndent('  ');
    return enc.convert(<String, dynamic>{
      'usage': entries.map((UsageEntry e) => e.toJson()).toList(),
    });
  }

  static SpendingLog decode(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) {
      return const SpendingLog();
    }
    try {
      final dynamic d = jsonDecode(jsonStr);
      if (d is Map<String, dynamic>) {
        final List<UsageEntry> es =
            ((d['usage'] as List<dynamic>?) ?? <dynamic>[])
                .whereType<Map<String, dynamic>>()
                .map(UsageEntry.fromJson)
                .toList();
        return SpendingLog(es);
      }
    } catch (_) {}
    return const SpendingLog();
  }

  /// Union of two logs by entry id, sorted oldest→newest.
  static SpendingLog merge(SpendingLog a, SpendingLog b) {
    final Map<String, UsageEntry> byId = <String, UsageEntry>{};
    for (final UsageEntry e in <UsageEntry>[...a.entries, ...b.entries]) {
      byId[e.id] = e;
    }
    final List<UsageEntry> out = byId.values.toList()
      ..sort((UsageEntry x, UsageEntry y) => x.ts.compareTo(y.ts));
    return SpendingLog(out);
  }

  // ── windows ───────────────────────────────────────────────────────────

  /// Sunday 00:00 of the week containing [now] (weeks run Sun–Sat).
  static DateTime weekStart(DateTime now) {
    final DateTime midnight = DateTime(now.year, now.month, now.day);
    final int daysSinceSunday = now.weekday % 7; // Mon=1..Sat=6, Sun=7→0
    return midnight.subtract(Duration(days: daysSinceSunday));
  }

  static DateTime monthStart(DateTime now) => DateTime(now.year, now.month, 1);

  double spentBetween(DateTime start, DateTime end) {
    final int a = start.millisecondsSinceEpoch;
    final int b = end.millisecondsSinceEpoch;
    double sum = 0;
    for (final UsageEntry e in entries) {
      if (e.ts >= a && e.ts < b) {
        sum += e.cost;
      }
    }
    return _round2(sum);
  }

  double weekTotal(DateTime now) =>
      spentBetween(weekStart(now), weekStart(now).add(const Duration(days: 7)));

  double lastWeekTotal(DateTime now) {
    final DateTime start = weekStart(now).subtract(const Duration(days: 7));
    return spentBetween(start, start.add(const Duration(days: 7)));
  }

  double monthTotal(DateTime now) =>
      spentBetween(monthStart(now), DateTime(now.year, now.month + 1, 1));

  double lastMonthTotal(DateTime now) => spentBetween(
      DateTime(now.year, now.month - 1, 1), DateTime(now.year, now.month, 1));

  /// Average spend per ACTIVE week (weeks that had any spend) — a stable
  /// typical figure that isn't diluted by empty weeks before you started.
  double averagePerWeek() =>
      _averageByBucket((DateTime d) => weekStart(d));

  /// Average spend per active month (months that had any spend).
  double averagePerMonth() =>
      _averageByBucket((DateTime d) => DateTime(d.year, d.month));

  double _averageByBucket(DateTime Function(DateTime) bucketOf) {
    final Map<String, double> byBucket = <String, double>{};
    for (final UsageEntry e in entries) {
      if (e.cost <= 0) {
        continue;
      }
      final DateTime b =
          bucketOf(DateTime.fromMillisecondsSinceEpoch(e.ts));
      final String key = '${b.year}-${b.month}-${b.day}';
      byBucket[key] = (byBucket[key] ?? 0) + e.cost;
    }
    if (byBucket.isEmpty) {
      return 0;
    }
    final double total =
        byBucket.values.fold<double>(0, (double a, double b) => a + b);
    return _round2(total / byBucket.length);
  }

  /// Total cost per item name within [start, end), highest first.
  List<MapEntry<String, double>> topItems(DateTime start, DateTime end,
      {int limit = 5}) {
    final int a = start.millisecondsSinceEpoch;
    final int b = end.millisecondsSinceEpoch;
    final Map<String, double> byName = <String, double>{};
    for (final UsageEntry e in entries) {
      if (e.ts >= a && e.ts < b && e.cost > 0) {
        byName[e.name] = (byName[e.name] ?? 0) + e.cost;
      }
    }
    final List<MapEntry<String, double>> out = byName.entries.toList()
      ..sort((MapEntry<String, double> x, MapEntry<String, double> y) =>
          y.value.compareTo(x.value));
    return out.take(limit).toList();
  }
}

/// GitHub read/append for `usage.json`. Mirrors [PantrySync] but append-only.
class SpendingSync {
  static bool get canWrite => PantrySync.canWrite;

  static Uri get _uri => Uri.parse(
      'https://api.github.com/repos/$kDataRepoOwner/$kDataRepoName/contents/$kUsagePath');

  static Map<String, String> _headers() => <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Pantry (github.com/scenicprints/pantry)',
        if (PantrySync.canWrite) 'Authorization': 'Bearer ${_token()}',
      };

  static String _token() => const String.fromEnvironment('GITHUB_DATA_TOKEN');

  /// Fetch the remote log + blob sha (null sha if the file doesn't exist yet).
  static Future<({SpendingLog log, String? sha})?> fetch() async {
    try {
      final http.Response r =
          await http.get(_uri, headers: _headers()).timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) {
        return (log: const SpendingLog(), sha: null);
      }
      if (r.statusCode != 200) {
        return null;
      }
      final Map<String, dynamic> j = jsonDecode(r.body) as Map<String, dynamic>;
      final String content = (j['content'] as String? ?? '').replaceAll('\n', '');
      final String? sha = j['sha'] as String?;
      final String decoded =
          content.isEmpty ? '' : utf8.decode(base64.decode(content));
      return (log: SpendingLog.decode(decoded), sha: sha);
    } catch (_) {
      return null;
    }
  }

  /// Merge [local] onto the remote log (union by id) and write it back.
  /// Returns the merged log now live on GitHub, or null on failure.
  static Future<SpendingLog?> push(SpendingLog local) async {
    if (!canWrite) {
      return null;
    }
    for (int attempt = 0; attempt < 2; attempt++) {
      final ({SpendingLog log, String? sha})? remote = await fetch();
      if (remote == null) {
        return null;
      }
      final SpendingLog merged = SpendingLog.merge(remote.log, local);
      if (await _put(merged.encode(), remote.sha)) {
        return merged;
      }
    }
    return null;
  }

  static Future<bool> _put(String contentStr, String? sha) async {
    try {
      final Map<String, dynamic> body = <String, dynamic>{
        'message': 'Update usage ledger',
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

// ── shared rounding (kept local to avoid touching models.dart helpers) ──
double _num(dynamic v) {
  if (v is num) {
    return v.toDouble();
  }
  if (v is String) {
    return double.tryParse(v) ?? 0;
  }
  return 0;
}

double _round(double v) => (v * 10).round() / 10;
double _round2(double v) => (v * 100).round() / 100;
double _round4(double v) => (v * 10000).round() / 10000;
