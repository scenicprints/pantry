import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chef_models.dart';
import 'github_sync.dart';
import 'storage.dart';

// ═══════════════════════════════════════════════════════════════════════
// THE MENU — what is planned, shared across devices.
//
// "On the menu" never synced. It sat in a device-local planned_meals.json
// with nothing in the data repo behind it, so a meal planned on the phone was
// invisible on the iPad and the shopping list you ticked in the shop was not
// the one at home. Everything else in this app already travelled: the pantry,
// the prices, the spend, the chef's settings. This did not.
//
// MERGING. Last-write-wins on the whole document would be wrong here in a way
// it isn't for the chef's settings: two devices genuinely both add meals, and
// losing one is losing a shopping trip. So the merge is a UNION BY MEAL ID
// (createdAtMs, which is already a stable id), and where both sides hold the
// same meal the newer document's copy wins — that is the one whose shopping
// ticks are current.
//
// A meal removed on one device would come back from the other under a plain
// union, so removals are recorded as tombstones and outlive the meal itself.
// ═══════════════════════════════════════════════════════════════════════

const String kMenuPath = 'menu.json';

/// When this device last published or accepted a menu.
const String _kMenuStamp = 'menu_updated_ms';

/// Ids of meals deleted here, so a merge can't resurrect them.
const String _kMenuGone = 'menu_removed';

class MenuSync {
  static String get _token => const String.fromEnvironment('GITHUB_DATA_TOKEN');
  static bool get canWrite => _token.isNotEmpty;

  static Uri get _uri => Uri.parse(
      'https://api.github.com/repos/$kDataRepoOwner/$kDataRepoName/contents/$kMenuPath');

  static Map<String, String> _headers() => <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Pantry (github.com/scenicprints/pantry)',
        if (canWrite) 'Authorization': 'Bearer $_token',
      };

  /// Meals, the removed-ids list, the document's stamp, and the blob sha.
  static Future<(List<PlannedMeal>, Set<int>, int, String?)?> _fetch() async {
    try {
      final http.Response r = await http
          .get(_uri, headers: _headers())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) {
        return (<PlannedMeal>[], <int>{}, 0, null);
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
        return (<PlannedMeal>[], <int>{}, 0, sha);
      }
      final dynamic d = jsonDecode(utf8.decode(base64.decode(content)));
      if (d is! Map<String, dynamic>) {
        return (<PlannedMeal>[], <int>{}, 0, sha);
      }
      final List<PlannedMeal> meals = ((d['meals'] as List<dynamic>?) ??
              <dynamic>[])
          .whereType<Map>()
          .map((Map e) => PlannedMeal.fromJson(e.cast<String, dynamic>()))
          .toList();
      final Set<int> gone = ((d['removed'] as List<dynamic>?) ?? <dynamic>[])
          .whereType<num>()
          .map((num n) => n.round())
          .toSet();
      return (meals, gone, (d['updated_at_ms'] as num?)?.round() ?? 0, sha);
    } catch (_) {
      return null;
    }
  }

  static Set<int> _localGone() =>
      LocalCache.prefIntList(_kMenuGone).toSet();

  static void _rememberGone(Iterable<int> ids) {
    final Set<int> all = _localGone()..addAll(ids);
    // Keep the list from growing without bound; a meal deleted long ago will
    // not be sitting in anyone's menu any more.
    final List<int> kept = all.toList()..sort();
    LocalCache.setPrefIntList(
        _kMenuGone, kept.length > 200 ? kept.sublist(kept.length - 200) : kept);
  }

  /// Record that [ids] were taken off the menu here, so the merge keeps them
  /// off rather than pulling them back from the other device.
  static void noteRemoved(Iterable<int> ids) {
    if (ids.isEmpty) {
      return;
    }
    _rememberGone(ids);
  }

  /// Merge what is on GitHub into what is here. Returns the merged menu when
  /// it differs from [local], else null. A failed fetch changes nothing.
  static Future<List<PlannedMeal>?> pull(List<PlannedMeal> local) async {
    final (List<PlannedMeal>, Set<int>, int, String?)? r = await _fetch();
    if (r == null) {
      return null;
    }
    final Set<int> gone = <int>{..._localGone(), ...r.$2};
    final bool remoteIsNewer = r.$3 > LocalCache.prefInt(_kMenuStamp);

    final Map<int, PlannedMeal> merged = <int, PlannedMeal>{
      for (final PlannedMeal m in local) m.createdAtMs: m,
    };
    for (final PlannedMeal m in r.$1) {
      // The newer document's copy is the one whose shopping ticks are current.
      if (!merged.containsKey(m.createdAtMs) || remoteIsNewer) {
        merged[m.createdAtMs] = m;
      }
    }
    for (final int id in gone) {
      merged.remove(id);
    }

    final List<PlannedMeal> out = merged.values.toList()
      ..sort((PlannedMeal a, PlannedMeal b) =>
          a.createdAtMs.compareTo(b.createdAtMs));
    if (remoteIsNewer) {
      LocalCache.setPrefInt(_kMenuStamp, r.$3);
    }

    // SEED IT. Publishing used to happen only when the menu CHANGED, so a
    // device already holding a menu would open, pull nothing, and never send
    // what it had. Neither side ever wrote the file and nothing ever synced.
    // If anything here is missing from the remote, publish now.
    final Set<int> remoteIds =
        r.$1.map((PlannedMeal m) => m.createdAtMs).toSet();
    if (out.any((PlannedMeal m) => !remoteIds.contains(m.createdAtMs))) {
      pushSoon(out);
    }

    final bool same = out.length == local.length &&
        out.every((PlannedMeal m) =>
            local.any((PlannedMeal l) => l.createdAtMs == m.createdAtMs));
    return same && !remoteIsNewer ? null : out;
  }

  /// Publish the menu as it stands here.
  static Future<bool> push(List<PlannedMeal> meals) async {
    if (!canWrite) {
      return false;
    }
    final (List<PlannedMeal>, Set<int>, int, String?)? current = await _fetch();
    if (current == null) {
      return false;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Set<int> gone = <int>{..._localGone(), ...current.$2};
    _rememberGone(gone);
    final String body =
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'updated_at_ms': now,
      'meals': meals.map((PlannedMeal m) => m.toJson()).toList(),
      'removed': gone.toList()..sort(),
    });
    try {
      final http.Response r = await http
          .put(_uri,
              headers: <String, String>{
                ..._headers(),
                'content-type': 'application/json',
              },
              body: jsonEncode(<String, dynamic>{
                'message': 'Menu',
                'content': base64.encode(utf8.encode(body)),
                if (current.$4 != null) 'sha': current.$4,
              }))
          .timeout(const Duration(seconds: 20));
      final bool ok = r.statusCode == 200 || r.statusCode == 201;
      if (ok) {
        LocalCache.setPrefInt(_kMenuStamp, now);
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Fire-and-forget publish, for callers that shouldn't wait on a round trip
  /// to tick a shopping-list box.
  static void pushSoon(List<PlannedMeal> meals) {
    push(meals).catchError((Object _) => false);
  }
}
