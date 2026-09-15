import 'dart:convert';

import 'package:http/http.dart' as http;

import 'github_sync.dart';

// ═══════════════════════════════════════════════════════════════════════
// COOKED HANDOFF — what actually went in the pan, sent to BodyComp.
//
// The numbers that matter only exist at the counter: you weigh 473 g, not the
// 480 g the recipe asked for. This app is where you are standing when that
// happens, so it captures them and hands the meal over rather than making you
// type it all again on the phone.
//
// It travels through `cooked.json` in the shared pantry-data repo because the
// cooking happens on the iPad and the logging happens on the phone. Both apps
// already hold a write token for that repo.
//
// THE LINE BETWEEN THE TWO APPS:
//   Pantry   records what went IN the pan, subtracts it from the shelf, and
//            books the spend.
//   BodyComp works out what went on the PLATE and logs it, exactly as it
//            always has, and must not subtract a meal that arrives here.
//
// Pantry has no business asking about portions. It does not know what you
// served yourself, and BodyComp already does that job properly.
//
// Every ingredient goes into ONE meal. Each line does carry the pan it was
// cooked in, though, because what was NOT cooked together is the thing to be
// wary of: a side that never got stirred in comes off the tray as its own
// mass, and BodyComp needs to know that to portion it sensibly.
// ═══════════════════════════════════════════════════════════════════════

const String kCookedPath = 'cooked.json';

/// One measured ingredient. [rawG] is what was actually weighed out, which is
/// also what leaves the pantry.
class CookedLine {
  final String pantryId; // '' when nothing in the pantry matched
  final String name;
  final String? barcode;
  final double rawG;

  /// The pan this was cooked in, as the chef grouped them. Empty when it was
  /// never cooked with anything — a garnish, or something added at the table.
  final String group;

  const CookedLine({
    required this.name,
    required this.rawG,
    this.pantryId = '',
    this.barcode,
    this.group = '',
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'pantry_id': pantryId,
        'name': name,
        if (barcode != null && barcode!.isNotEmpty) 'barcode': barcode,
        if (group.isNotEmpty) 'group': group,
        'raw_g': double.parse(rawG.toStringAsFixed(1)),
      };

  factory CookedLine.fromJson(Map<String, dynamic> j) => CookedLine(
        pantryId: (j['pantry_id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        barcode: j['barcode'] as String?,
        group: (j['group'] as String?) ?? '',
        rawG: (j['raw_g'] as num?)?.toDouble() ?? 0,
      );
}

/// One cooked meal waiting for BodyComp to log it.
class CookedMeal {
  final String id;
  final String recipe;
  final int servings;
  final int cookedAtMs;
  final List<CookedLine> lines;

  const CookedMeal({
    required this.id,
    required this.recipe,
    required this.servings,
    required this.cookedAtMs,
    required this.lines,
  });

  /// True once Pantry has taken these amounts off the shelf. BodyComp reads
  /// this and skips the subtraction it would normally do on a new meal.
  bool get pantrySettled => true;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'recipe': recipe,
        'servings': servings,
        'cooked_at_ms': cookedAtMs,
        'pantry_settled': pantrySettled,
        'lines': lines.map((CookedLine l) => l.toJson()).toList(),
      };

  factory CookedMeal.fromJson(Map<String, dynamic> j) => CookedMeal(
        id: (j['id'] as String?) ?? '',
        recipe: (j['recipe'] as String?) ?? '',
        servings: (j['servings'] as num?)?.round() ?? 0,
        cookedAtMs: (j['cooked_at_ms'] as num?)?.round() ?? 0,
        lines: ((j['lines'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(CookedLine.fromJson)
            .toList(),
      );
}

/// Appends a cooked meal to `cooked.json`, a queue BodyComp drains.
///
/// Every write is fetch → merge onto the newest file → PUT with the blob sha,
/// the same shape as PantrySync, so a meal sent from the iPad can't wipe one
/// the phone added a minute earlier. The merge is a union by meal id, which
/// also makes a retry after a half-failed push harmless.
class CookedSync {
  static String get _token => const String.fromEnvironment('GITHUB_DATA_TOKEN');
  static bool get canWrite => _token.isNotEmpty;

  static Uri get _uri => Uri.parse(
      'https://api.github.com/repos/$kDataRepoOwner/$kDataRepoName/contents/$kCookedPath');

  static Map<String, String> _headers({bool auth = false}) => <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Pantry (github.com/scenicprints/pantry)',
        if (auth && canWrite) 'Authorization': 'Bearer $_token',
      };

  /// The pending queue and the blob sha, or null if the fetch failed.
  /// A 404 (nothing cooked yet) is an empty queue, not a failure.
  static Future<(List<CookedMeal>, String?)?> _fetch() async {
    try {
      final http.Response r = await http
          .get(_uri, headers: _headers(auth: true))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) {
        return (<CookedMeal>[], null);
      }
      if (r.statusCode != 200) {
        return null;
      }
      final Map<String, dynamic> j =
          jsonDecode(r.body) as Map<String, dynamic>;
      final String content =
          (j['content'] as String? ?? '').replaceAll('\n', '');
      final String? sha = j['sha'] as String?;
      if (content.isEmpty) {
        return (<CookedMeal>[], sha);
      }
      final dynamic d = jsonDecode(utf8.decode(base64.decode(content)));
      final List<dynamic> meals =
          (d is Map ? d['meals'] as List<dynamic>? : d as List<dynamic>?) ??
              <dynamic>[];
      return (
        meals
            .whereType<Map<String, dynamic>>()
            .map(CookedMeal.fromJson)
            .toList(),
        sha
      );
    } catch (_) {
      return null;
    }
  }

  /// Add [meal] to the queue. Returns false if it didn't reach GitHub, so the
  /// caller can keep it and retry rather than telling the cook it's on the
  /// phone when it isn't.
  static Future<bool> send(CookedMeal meal) async {
    if (!canWrite) {
      return false;
    }
    final (List<CookedMeal>, String?)? current = await _fetch();
    if (current == null) {
      return false;
    }
    final List<CookedMeal> queue = <CookedMeal>[
      ...current.$1.where((CookedMeal m) => m.id != meal.id),
      meal,
    ];
    final String body = const JsonEncoder.withIndent('  ')
        .convert(<String, dynamic>{
      'meals': queue.map((CookedMeal m) => m.toJson()).toList(),
    });
    try {
      final http.Response r = await http
          .put(_uri,
              headers: <String, String>{
                ..._headers(auth: true),
                'content-type': 'application/json',
              },
              body: jsonEncode(<String, dynamic>{
                'message': 'Cooked: ${meal.recipe}',
                'content': base64.encode(utf8.encode(body)),
                if (current.$2 != null) 'sha': current.$2,
              }))
          .timeout(const Duration(seconds: 20));
      return r.statusCode == 200 || r.statusCode == 201;
    } catch (_) {
      return false;
    }
  }
}
