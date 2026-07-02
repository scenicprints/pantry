import 'dart:convert';
import 'package:http/http.dart' as http;

import 'models.dart';

// ═══════════════════════════════════════════════════════════════════════
// GITHUB SYNC — reads/writes pantry.json in the PUBLIC data repo via the
// GitHub Contents API. This file is the handoff point to the AI chef, which
// reads the same JSON.
//
// The data repo is public, so the chef reads it with no auth. WRITING needs
// a token — a fine-grained PAT scoped to ONLY this repo (contents:write),
// injected at build time via --dart-define (a GitHub Actions secret, never
// in source). Mirrors BodyComp's custom-foods sync.
//
// Every push is fetch → merge-onto-latest → PUT with the blob sha, so a
// write is layered onto the newest file rather than blindly overwriting it.
// ═══════════════════════════════════════════════════════════════════════

const String kDataRepoOwner = 'scenicprints';
const String kDataRepoName = 'pantry-data';
const String kPantryPath = 'pantry.json';

class RemotePantry {
  final PantryData data;
  final String? sha; // blob sha needed to update the file (null if absent)
  const RemotePantry(this.data, this.sha);
}

class PantrySync {
  static String get _token =>
      const String.fromEnvironment('GITHUB_DATA_TOKEN');

  /// Whether a write token was baked into this build. Reads work regardless
  /// (public repo); only pushes need the token.
  static bool get canWrite => _token.isNotEmpty;

  static Uri get _contentsUri => Uri.parse(
      'https://api.github.com/repos/$kDataRepoOwner/$kDataRepoName/contents/$kPantryPath');

  static Map<String, String> _headers({bool auth = false}) =>
      <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Pantry (github.com/scenicprints/pantry)',
        if (auth && canWrite) 'Authorization': 'Bearer $_token',
      };

  /// Fetch the remote pantry + blob sha. Returns null on any failure
  /// (offline, etc.) so callers fall back to the local cache. A 404 (file
  /// not created yet) returns empty data with a null sha.
  static Future<RemotePantry?> fetch() async {
    try {
      final http.Response r = await http
          .get(_contentsUri, headers: _headers(auth: true))
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) {
        return const RemotePantry(PantryData(), null);
      }
      if (r.statusCode != 200) {
        return null;
      }
      final Map<String, dynamic> j =
          jsonDecode(r.body) as Map<String, dynamic>;
      final String content =
          (j['content'] as String? ?? '').replaceAll('\n', '');
      final String? sha = j['sha'] as String?;
      final String decoded =
          content.isEmpty ? '' : utf8.decode(base64.decode(content));
      return RemotePantry(PantryData.decode(decoded), sha);
    } catch (_) {
      return null;
    }
  }

  /// Merge [local] onto the newest remote file and write it back. Retries
  /// once if the sha went stale between fetch and PUT (409/422). Returns the
  /// merged data that is now live on GitHub, or null on failure so the
  /// caller can keep the local copy and try again later.
  static Future<PantryData?> push(PantryData local, DateTime now) async {
    if (!canWrite) {
      return null;
    }
    for (int attempt = 0; attempt < 2; attempt++) {
      final RemotePantry? remote = await fetch();
      if (remote == null) {
        return null; // couldn't read → don't risk a bad write
      }
      final PantryData merged = PantryData.merge(remote.data, local);
      final String? newSha =
          await _put(merged.encode(now), remote.sha);
      if (newSha != null) {
        return merged;
      }
      // else: likely a sha race — loop refetches and retries once.
    }
    return null;
  }

  static Future<String?> _put(String contentStr, String? sha) async {
    try {
      final Map<String, dynamic> body = <String, dynamic>{
        'message': 'Update pantry',
        'content': base64.encode(utf8.encode(contentStr)),
        'branch': 'main',
        'sha': ?sha,
      };
      final http.Response r = await http
          .put(_contentsUri,
              headers: _headers(auth: true), body: jsonEncode(body))
          .timeout(const Duration(seconds: 20));
      if (r.statusCode == 200 || r.statusCode == 201) {
        final Map<String, dynamic> j =
            jsonDecode(r.body) as Map<String, dynamic>;
        final Map<String, dynamic>? c = j['content'] as Map<String, dynamic>?;
        return c?['sha'] as String?;
      }
      return null;
    } catch (_) {
      return null;
    }
  }
}
