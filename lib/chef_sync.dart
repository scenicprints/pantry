import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chef.dart';
import 'github_sync.dart';
import 'storage.dart';

// ═══════════════════════════════════════════════════════════════════════
// CHEF PROFILE — one chef across every device.
//
// The chef's RULES are compiled in, so they are identical wherever the app
// runs. Its SETTINGS were not: the model, the equipment list and the avoid
// list all lived in flutter_secure_storage, which is per-device. That meant
// picking Opus 5 on the iPad left the phone on Haiku, and — the one that
// actually mattered — a fresh install started with an EMPTY AVOID LIST while
// the prompt was still being told to respect it.
//
// So they travel in `chef.json` beside pantry.json. A separate file on
// purpose: pantry.json's shape is a contract with BodyComp and with the chef
// that reads it raw, and nothing here belongs in it.
//
// The API key NEVER goes in. That repo is public. It stays in secure storage
// with the build-time key as the fallback, exactly as before.
//
// Conflict rule is last-write-wins on the whole document by timestamp. One
// person cooking in one kitchen is not two writers, and a per-field merge
// would resurrect an avoid he had just deleted.
// ═══════════════════════════════════════════════════════════════════════

const String kChefPath = 'chef.json';

/// When this device last accepted or published a profile.
const String _kProfileStamp = 'chef_profile_ms';

class ChefProfile {
  final int updatedAtMs;
  final String model; // 'haiku' | 'sonnet' | 'opus'
  final List<String> equipment;
  final List<String> avoids;
  final Map<String, List<String>> notes; // recipe title -> cook notes

  const ChefProfile({
    required this.updatedAtMs,
    required this.model,
    required this.equipment,
    required this.avoids,
    required this.notes,
  });

  Map<String, dynamic> toJson() => <String, dynamic>{
        'updated_at_ms': updatedAtMs,
        'model': model,
        'equipment': equipment,
        'avoids': avoids,
        'notes': notes,
      };

  factory ChefProfile.fromJson(Map<String, dynamic> j) => ChefProfile(
        updatedAtMs: (j['updated_at_ms'] as num?)?.round() ?? 0,
        model: (j['model'] as String?) ?? 'haiku',
        equipment: ((j['equipment'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<String>()
            .toList(),
        avoids: ((j['avoids'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<String>()
            .toList(),
        notes: <String, List<String>>{
          for (final MapEntry<String, dynamic> e
              in ((j['notes'] as Map<String, dynamic>?) ??
                      <String, dynamic>{})
                  .entries)
            if (e.value is List)
              e.key: (e.value as List<dynamic>).whereType<String>().toList(),
        },
      );
}

class ChefSync {
  static String get _token => const String.fromEnvironment('GITHUB_DATA_TOKEN');
  static bool get canWrite => _token.isNotEmpty;

  static Uri get _uri => Uri.parse(
      'https://api.github.com/repos/$kDataRepoOwner/$kDataRepoName/contents/$kChefPath');

  static Map<String, String> _headers() => <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Pantry (github.com/scenicprints/pantry)',
        if (canWrite) 'Authorization': 'Bearer $_token',
      };

  static Future<(ChefProfile?, String?)?> _fetch() async {
    try {
      final http.Response r = await http
          .get(_uri, headers: _headers())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) {
        return (null, null); // nothing published yet
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
        return (null, sha);
      }
      final dynamic d = jsonDecode(utf8.decode(base64.decode(content)));
      if (d is! Map<String, dynamic>) {
        return (null, sha);
      }
      return (ChefProfile.fromJson(d), sha);
    } catch (_) {
      return null;
    }
  }

  /// This device's chef, as it stands.
  static Future<ChefProfile> local() async => ChefProfile(
        updatedAtMs: LocalCache.prefInt(_kProfileStamp),
        model: await ChefKeys.getModelPref(),
        equipment: await ChefKeys.getEquipment(),
        avoids: await ChefKeys.getAvoids(),
        notes: LocalCache.allNotes(),
      );

  /// Take a profile on board. Everything it carries replaces what is here.
  static Future<void> _apply(ChefProfile p) async {
    await ChefKeys.setModelPref(p.model);
    await ChefKeys.setEquipment(p.equipment);
    await ChefKeys.setAvoids(p.avoids);
    LocalCache.replaceNotes(p.notes);
    LocalCache.setPrefInt(_kProfileStamp, p.updatedAtMs);
  }

  /// Pull on startup. Returns true when something changed here, so the UI can
  /// rebuild. Silent on failure: an unreachable GitHub must never wipe the
  /// avoid list this device already holds.
  static Future<bool> pull() async {
    final (ChefProfile?, String?)? r = await _fetch();
    if (r == null || r.$1 == null) {
      return false;
    }
    final ChefProfile remote = r.$1!;
    if (remote.updatedAtMs <= LocalCache.prefInt(_kProfileStamp)) {
      return false;
    }
    await _apply(remote);
    return true;
  }

  /// Publish what this device holds. Call it after any change to the model,
  /// the equipment, the avoid list or the cook notes.
  static Future<bool> push() async {
    if (!canWrite) {
      return false;
    }
    final (ChefProfile?, String?)? current = await _fetch();
    if (current == null) {
      return false;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final ChefProfile me = await local();
    final ChefProfile out = ChefProfile(
      updatedAtMs: now,
      model: me.model,
      equipment: me.equipment,
      avoids: me.avoids,
      notes: me.notes,
    );
    final String body =
        const JsonEncoder.withIndent('  ').convert(out.toJson());
    try {
      final http.Response r = await http
          .put(_uri,
              headers: <String, String>{
                ..._headers(),
                'content-type': 'application/json',
              },
              body: jsonEncode(<String, dynamic>{
                'message': 'Chef settings',
                'content': base64.encode(utf8.encode(body)),
                if (current.$2 != null) 'sha': current.$2,
              }))
          .timeout(const Duration(seconds: 20));
      final bool ok = r.statusCode == 200 || r.statusCode == 201;
      if (ok) {
        LocalCache.setPrefInt(_kProfileStamp, now);
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Fire-and-forget publish, for UI callers that shouldn't wait on a network
  /// round trip to change a toggle.
  static void pushSoon() {
    push().catchError((Object _) => false);
  }
}
