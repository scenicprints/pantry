import 'dart:convert';

import 'package:http/http.dart' as http;

import 'github_sync.dart';

// ═══════════════════════════════════════════════════════════════════════
// A BRIEF — a dinner worked out in conversation with Claude, handed to the
// app for its chef to cook from.
//
// WHY THIS EXISTS. Planning a real dinner is a conversation: this dish but
// with short rib instead of mince, no cream in anything, the starter has to
// be cold because the oven is busy. The app's own planner is one box and one
// shot — it cannot be argued with, so a menu arrives with a sauce you don't
// want and there is nowhere to say so.
//
// So the THINKING happens in Claude, where it can go back and forth, and
// what lands here is the finished ask: the guests, the date, each dish with
// whatever was decided about it, and the notes that apply to the whole
// table. The chef still does the cooking — the recipes, the prep timeline
// and the run sheet are all written on this device, from this brief.
//
// It travels as `host_brief.json` in the same pantry-data repo as
// everything else. A brief is CONSUMED, not kept: once its menu is built it
// is stamped and stops showing, so an inbox never fills up with dinners that
// already happened.
// ═══════════════════════════════════════════════════════════════════════

const String kHostBriefPath = 'host_brief.json';

/// One dish as it was asked for — not as the chef will write it.
class BriefDish {
  /// What to cook, in the words it was agreed in ("Lasagna, short rib").
  final String text;

  /// Starter / Main / Side / Dessert / Drink / Other.
  final String course;

  /// Everything decided about THIS dish: what to use instead of what, what
  /// to leave out, how it should turn out. This is the half the app had no
  /// way to accept — "no cream sauce, make it a red sauce" belongs here.
  final String notes;

  const BriefDish({required this.text, required this.course, this.notes = ''});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        'course': course,
        if (notes.isNotEmpty) 'notes': notes,
      };

  factory BriefDish.fromJson(Map<String, dynamic> j) => BriefDish(
        text: (j['text'] as String?)?.trim() ?? '',
        course: (j['course'] as String?)?.trim() ?? 'Main',
        notes: (j['notes'] as String?)?.trim() ?? '',
      );
}

/// A whole dinner, as asked for.
class HostBrief {
  final int createdAtMs; // stable id
  final String name;
  final int guests;
  final String eventDate; // 'YYYY-MM-DD' or ''
  final List<BriefDish> dishes;

  /// Restrictions for the people at this table, this once.
  final String guestNotes;

  /// Anything that applies to the whole dinner rather than one dish — the
  /// occasion, what time people sit down, what the oven is already doing,
  /// how much of it you want done in advance.
  final String notes;

  /// Set once the chef has built this into a menu, so it stops showing.
  final int builtAtMs;

  const HostBrief({
    required this.createdAtMs,
    required this.name,
    required this.guests,
    required this.eventDate,
    required this.dishes,
    this.guestNotes = '',
    this.notes = '',
    this.builtAtMs = 0,
  });

  String get id => createdAtMs.toString();
  bool get isBuilt => builtAtMs > 0;

  HostBrief markBuilt(DateTime when) => HostBrief(
        createdAtMs: createdAtMs,
        name: name,
        guests: guests,
        eventDate: eventDate,
        dishes: dishes,
        guestNotes: guestNotes,
        notes: notes,
        builtAtMs: when.millisecondsSinceEpoch,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'createdAtMs': createdAtMs,
        'name': name,
        'guests': guests,
        'eventDate': eventDate,
        'dishes': dishes.map((BriefDish d) => d.toJson()).toList(),
        if (guestNotes.isNotEmpty) 'guestNotes': guestNotes,
        if (notes.isNotEmpty) 'notes': notes,
        if (builtAtMs > 0) 'builtAtMs': builtAtMs,
      };

  factory HostBrief.fromJson(Map<String, dynamic> j) => HostBrief(
        createdAtMs: (j['createdAtMs'] as num?)?.round() ?? 0,
        name: (j['name'] as String?)?.trim() ?? '',
        guests: (j['guests'] as num?)?.round() ?? 2,
        eventDate: (j['eventDate'] as String?)?.trim() ?? '',
        dishes: ((j['dishes'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(BriefDish.fromJson)
            .toList(),
        guestNotes: (j['guestNotes'] as String?)?.trim() ?? '',
        notes: (j['notes'] as String?)?.trim() ?? '',
        builtAtMs: (j['builtAtMs'] as num?)?.round() ?? 0,
      );
}

/// Read a brief out of whatever a Claude that has no tools handed back.
///
/// Not every Claude can write to the data repo — the one on a phone or in a
/// browser can only give you text. So the app accepts the JSON directly:
/// pasted with its code fence still on, wrapped in {"briefs":[…]}, as a bare
/// array, or as one brief on its own. Anything it can't read comes back null
/// rather than half a dinner.
HostBrief? parseBrief(String raw, {DateTime? now}) {
  String s = raw.trim();
  if (s.isEmpty) {
    return null;
  }
  // ```json … ``` — a fence is the normal way a chat hands over JSON.
  if (s.startsWith('```')) {
    final int nl = s.indexOf('\n');
    if (nl > 0) {
      s = s.substring(nl + 1);
    }
    final int fence = s.lastIndexOf('```');
    if (fence > 0) {
      s = s.substring(0, fence);
    }
    s = s.trim();
  }
  dynamic d = _tryDecode(s);
  if (d == null) {
    // Prose around the JSON: take from the first bracket to the last.
    final int start = <int>[s.indexOf('{'), s.indexOf('[')]
        .where((int i) => i >= 0)
        .fold(-1, (int a, int b) => a < 0 ? b : (b < a ? b : a));
    final int end = <int>[s.lastIndexOf('}'), s.lastIndexOf(']')]
        .fold(-1, (int a, int b) => b > a ? b : a);
    if (start < 0 || end <= start) {
      return null;
    }
    d = _tryDecode(s.substring(start, end + 1));
    if (d == null) {
      return null;
    }
  }

  Map<String, dynamic>? one;
  if (d is Map<String, dynamic>) {
    if (d['dishes'] is List) {
      one = d;
    } else if (d['briefs'] is List) {
      one = (d['briefs'] as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .where((Map<String, dynamic> m) =>
              ((m['builtAtMs'] as num?)?.round() ?? 0) == 0)
          .firstOrNull;
    }
  } else if (d is List) {
    one = d.whereType<Map<String, dynamic>>().firstOrNull;
  }
  if (one == null) {
    return null;
  }

  final HostBrief b = HostBrief.fromJson(one);
  if (b.dishes.isEmpty) {
    return null;
  }
  // A pasted brief usually has no id of its own; give it one so it can't
  // collide with another.
  return b.createdAtMs > 0
      ? b
      : HostBrief(
          createdAtMs: (now ?? DateTime.now()).millisecondsSinceEpoch,
          name: b.name,
          guests: b.guests,
          eventDate: b.eventDate,
          dishes: b.dishes,
          guestNotes: b.guestNotes,
          notes: b.notes,
        );
}

dynamic _tryDecode(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    return null;
  }
}

/// Reads and writes `host_brief.json`.
///
/// Simpler than the other syncs on purpose: a brief is written from outside
/// the app and only ever stamped by it, so there is nothing to merge — the
/// app fetches the file, and when it builds one it writes the same file back
/// with that brief stamped, onto the newest copy it just read.
class HostBriefSync {
  static String get _token => const String.fromEnvironment('GITHUB_DATA_TOKEN');
  static bool get canWrite => _token.isNotEmpty;

  static Uri get _uri => Uri.parse(
      'https://api.github.com/repos/$kDataRepoOwner/$kDataRepoName/contents/$kHostBriefPath');

  static Map<String, String> _headers() => <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Pantry (github.com/scenicprints/pantry)',
        if (canWrite) 'Authorization': 'Bearer $_token',
      };

  static Future<(List<HostBrief>, String?)?> _fetch() async {
    try {
      final http.Response r = await http
          .get(_uri, headers: _headers())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) {
        return (<HostBrief>[], null);
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
        return (<HostBrief>[], sha);
      }
      final dynamic d = jsonDecode(utf8.decode(base64.decode(content)));
      // A list at the top level is tolerated, so a brief can be written by
      // hand without remembering the wrapper.
      final List<dynamic> raw =
          (d is Map ? d['briefs'] as List<dynamic>? : d as List<dynamic>?) ??
              <dynamic>[];
      return (
        raw
            .whereType<Map<String, dynamic>>()
            .map(HostBrief.fromJson)
            .where((HostBrief b) => b.dishes.isNotEmpty)
            .toList(),
        sha
      );
    } catch (_) {
      return null;
    }
  }

  /// Everything waiting to be built. Null when the fetch failed, so the
  /// caller can leave what it already has alone.
  static Future<List<HostBrief>?> pull() async {
    final (List<HostBrief>, String?)? r = await _fetch();
    return r?.$1;
  }

  /// Stamp [brief] as built, onto the newest copy of the file.
  static Future<bool> markBuilt(HostBrief brief) async {
    if (!canWrite) {
      return false;
    }
    final (List<HostBrief>, String?)? current = await _fetch();
    if (current == null) {
      return false;
    }
    final List<HostBrief> out = current.$1
        .map((HostBrief b) =>
            b.id == brief.id ? b.markBuilt(DateTime.now()) : b)
        .toList();
    final String body =
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'briefs': out.map((HostBrief b) => b.toJson()).toList(),
    });
    try {
      final http.Response r = await http
          .put(_uri,
              headers: <String, String>{
                ..._headers(),
                'content-type': 'application/json',
              },
              body: jsonEncode(<String, dynamic>{
                'message': 'Built: ${brief.name.isEmpty ? 'dinner' : brief.name}',
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
