import 'dart:convert';

import 'package:http/http.dart' as http;

import 'chef_models.dart';
import 'github_sync.dart';
import 'storage.dart';

// ═══════════════════════════════════════════════════════════════════════
// HOST HUB — a dinner planned for guests. A dish here is exactly what the
// user typed (not chef-invented), scaled to a guest count, and written with
// no diet/health rules attached — see chef.dart's generateHostDish and
// _hostSystemPrompt.
//
// SYNCED, the same way "On the menu" is (menu_sync.dart): the whole point of
// a hosting plan is that it has to be there on the iPad at the counter, not
// just on whichever phone built it. `host_hub.json` in pantry-data, union by
// event id, tombstones for deletes — same shape as MenuSync, deliberately,
// so there is one merge policy to reason about in this app, not two.
// ═══════════════════════════════════════════════════════════════════════

/// The course choices offered on the dish list.
const List<String> kHostCourses = <String>[
  'Starter',
  'Main',
  'Side',
  'Dessert',
  'Drink',
  'Other',
];

/// One dish the user is making. [recipe] is null until the menu is built.
class HostDish {
  final String text; // as typed, e.g. "Lasagna"
  final String course; // one of kHostCourses
  final Recipe? recipe;

  const HostDish({required this.text, required this.course, this.recipe});

  HostDish copyWith({Recipe? recipe}) =>
      HostDish(text: text, course: course, recipe: recipe ?? this.recipe);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        'course': course,
        if (recipe != null) 'recipe': recipe!.toJson(),
      };

  factory HostDish.fromJson(Map<String, dynamic> j) => HostDish(
        text: (j['text'] as String?) ?? '',
        course: (j['course'] as String?) ?? 'Main',
        recipe: j['recipe'] is Map
            ? Recipe.fromStored((j['recipe'] as Map).cast<String, dynamic>())
            : null,
      );
}

/// One job on the prep timeline, tied to the dish it belongs to.
///
/// A task is a row on a schedule, not a sentence in a recipe: "what can I do
/// three days out" was buried in step prose, so it had to be read for, dish
/// by dish. [dish] is the dish's title, so a line can be tapped through to
/// the recipe it came from; it is '' for anything that belongs to the dinner
/// rather than to one dish (setting the table, pulling things out to thaw).
class PrepTask {
  final String text;
  final String dish;
  const PrepTask({required this.text, this.dish = ''});

  Map<String, dynamic> toJson() => <String, dynamic>{
        'text': text,
        if (dish.isNotEmpty) 'dish': dish,
      };

  factory PrepTask.fromJson(Map<String, dynamic> j) => PrepTask(
        text: (j['text'] as String?) ?? '',
        dish: (j['dish'] as String?) ?? '',
      );
}

/// One day of the prep timeline. [date] is 'YYYY-MM-DD' where the chef gave
/// one, so the day can be shown against the calendar and counted back from
/// the dinner; [label] is its own wording, kept as a fallback.
class PrepDay {
  final String date;
  final String label;
  final List<PrepTask> tasks;
  const PrepDay({this.date = '', required this.label, required this.tasks});

  Map<String, dynamic> toJson() => <String, dynamic>{
        if (date.isNotEmpty) 'date': date,
        'label': label,
        'tasks': tasks.map((PrepTask t) => t.toJson()).toList(),
      };

  /// Tolerates the old shape, where a day's tasks were plain strings with no
  /// dish attached — dinners planned before this change still read.
  factory PrepDay.fromJson(Map<String, dynamic> j) {
    final List<PrepTask> tasks = <PrepTask>[];
    for (final dynamic t in (j['tasks'] as List<dynamic>?) ?? const <dynamic>[]) {
      if (t is Map) {
        tasks.add(PrepTask.fromJson(t.cast<String, dynamic>()));
      } else {
        tasks.add(PrepTask(text: t.toString()));
      }
    }
    return PrepDay(
      date: (j['date'] as String?) ?? '',
      label: (j['label'] as String?) ?? '',
      tasks: tasks,
    );
  }

  /// "3 days before" / "The day before" / "Dinner day", worked out against
  /// [eventDate] so it is right however the chef worded it. Falls back to
  /// [label] when there are no dates to count between.
  String relativeTo(String eventDate) {
    final DateTime? d = DateTime.tryParse(date);
    final DateTime? e = DateTime.tryParse(eventDate);
    if (d == null || e == null) {
      return label;
    }
    final int days = DateTime(e.year, e.month, e.day)
        .difference(DateTime(d.year, d.month, d.day))
        .inDays;
    if (days <= 0) {
      return 'Dinner day';
    }
    if (days == 1) {
      return 'The day before';
    }
    return '$days days before';
  }
}

/// One step of the dinner-day run sheet: every dish's method merged into a
/// single order, so the whole menu can be cooked at once and land together.
/// [offset] is minutes before serving that the step starts.
class ServiceStep {
  final String dish;
  final String title;
  final String content;
  final int timerSeconds;
  final int offset;

  const ServiceStep({
    required this.dish,
    required this.title,
    required this.content,
    this.timerSeconds = 0,
    this.offset = 0,
  });

  bool get hasTimer => timerSeconds > 0;

  /// "2h 30m before" / "25m before" / "To serve".
  String get whenLabel {
    if (offset <= 0) {
      return 'To serve';
    }
    if (offset < 60) {
      return '${offset}m before';
    }
    final int h = offset ~/ 60;
    final int m = offset % 60;
    return m == 0 ? '${h}h before' : '${h}h ${m}m before';
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'dish': dish,
        'title': title,
        'content': content,
        'timerSeconds': timerSeconds,
        'offset': offset,
      };

  factory ServiceStep.fromJson(Map<String, dynamic> j) => ServiceStep(
        dish: (j['dish'] as String?)?.trim() ?? '',
        title: (j['title'] as String?)?.trim() ?? '',
        content: (j['content'] as String?)?.trim() ?? '',
        timerSeconds: (j['timerSeconds'] as num?)?.round() ?? 0,
        offset: (j['offset'] as num?)?.round() ?? 0,
      );
}

/// A planned or saved dinner. [createdAtMs] is the stable id.
class HostEvent {
  final int createdAtMs;
  final String name; // may be '' (unnamed)
  final int guests;
  final String eventDate; // 'YYYY-MM-DD' or ''
  final List<HostDish> dishes;
  final String guestNotes; // this event only — never the permanent avoid list
  final List<PrepDay> prepDays; // empty when no timeline was requested

  /// The dinner-day run sheet — the whole menu as one ordered cook. Empty
  /// for a single-dish dinner, where the dish's own recipe is the run sheet.
  final List<ServiceStep> runSheet;

  /// Ticked shopping-list rows, keyed "dishIndex:ingredientIndex". Keys
  /// rather than positions because building a missing dish inserts its
  /// ingredients mid-list. Travels with the event for the same reason the
  /// menu's ticks do: the list you tick in the shop is the one waiting at
  /// home.
  final List<String> checked;

  const HostEvent({
    required this.createdAtMs,
    required this.name,
    required this.guests,
    required this.eventDate,
    required this.dishes,
    required this.guestNotes,
    this.prepDays = const <PrepDay>[],
    this.runSheet = const <ServiceStep>[],
    this.checked = const <String>[],
  });

  String get id => createdAtMs.toString();

  /// Total shopping-list rows across every built dish.
  int get ingredientCount => allIngredients.length;

  /// How many of them are ticked, ignoring keys left over from a dish that
  /// no longer exists.
  int get gatheredCount {
    int n = 0;
    for (int d = 0; d < dishes.length; d++) {
      final Recipe? r = dishes[d].recipe;
      if (r == null) {
        continue;
      }
      for (int i = 0; i < r.ingredients.length; i++) {
        if (checked.contains('$d:$i')) {
          n++;
        }
      }
    }
    return n;
  }

  List<Recipe> get recipes =>
      dishes.map((HostDish d) => d.recipe).whereType<Recipe>().toList();

  /// Ingredients across every dish, in dish order — the combined shopping
  /// list. Each dish's recipe was already written for [guests], so nothing
  /// here needs scaling.
  List<RecipeIngredient> get allIngredients =>
      recipes.expand((Recipe r) => r.ingredients).toList();

  double get estCostTotal =>
      recipes.fold(0.0, (double s, Recipe r) => s + r.estCostTotal);
  double get estGroceryCost =>
      recipes.fold(0.0, (double s, Recipe r) => s + r.estGroceryCost);

  /// True once every dish has its recipe — a finished, cookable menu rather
  /// than a plan still being built.
  bool get isBuilt => dishes.isNotEmpty && recipes.length == dishes.length;

  /// The prep day that is due next: today's if there is one, else the
  /// soonest still ahead. Null when the timeline is empty or entirely past.
  /// This is what the hub shows, so "what am I meant to be doing" is on the
  /// screen rather than several taps into a recipe.
  PrepDay? nextPrepDay(DateTime now) {
    final DateTime today = DateTime(now.year, now.month, now.day);
    PrepDay? best;
    DateTime? bestDate;
    for (final PrepDay p in prepDays) {
      final DateTime? d = DateTime.tryParse(p.date);
      if (d == null) {
        continue;
      }
      final DateTime day = DateTime(d.year, d.month, d.day);
      if (day.isBefore(today)) {
        continue;
      }
      if (bestDate == null || day.isBefore(bestDate)) {
        best = p;
        bestDate = day;
      }
    }
    // No dates at all (an older plan, or one the chef didn't date): fall back
    // to the first day so the hub still shows something rather than nothing.
    if (best == null && prepDays.isNotEmpty &&
        prepDays.every((PrepDay p) => p.date.isEmpty)) {
      return prepDays.first;
    }
    return best;
  }

  /// [today]-relative bucket for the Hub's Upcoming/Past split. No date set
  /// counts as upcoming — it's still a live plan, just not scheduled yet.
  bool isUpcoming(DateTime today) {
    final DateTime? d = DateTime.tryParse(eventDate);
    if (d == null) {
      return true;
    }
    final DateTime day = DateTime(today.year, today.month, today.day);
    return !d.isBefore(day);
  }

  HostEvent copyWith({
    String? name,
    List<HostDish>? dishes,
    List<String>? checked,
    List<PrepDay>? prepDays,
    List<ServiceStep>? runSheet,
  }) =>
      HostEvent(
        createdAtMs: createdAtMs,
        name: name ?? this.name,
        guests: guests,
        eventDate: eventDate,
        dishes: dishes ?? this.dishes,
        guestNotes: guestNotes,
        prepDays: prepDays ?? this.prepDays,
        runSheet: runSheet ?? this.runSheet,
        checked: checked ?? this.checked,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'createdAtMs': createdAtMs,
        'name': name,
        'guests': guests,
        'eventDate': eventDate,
        'dishes': dishes.map((HostDish d) => d.toJson()).toList(),
        'guestNotes': guestNotes,
        'prepDays': prepDays.map((PrepDay p) => p.toJson()).toList(),
        'runSheet': runSheet.map((ServiceStep s) => s.toJson()).toList(),
        'checked': checked,
      };

  factory HostEvent.fromJson(Map<String, dynamic> j) => HostEvent(
        createdAtMs: (j['createdAtMs'] as num?)?.round() ?? 0,
        name: (j['name'] as String?) ?? '',
        guests: (j['guests'] as num?)?.round() ?? 2,
        eventDate: (j['eventDate'] as String?) ?? '',
        dishes: ((j['dishes'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(HostDish.fromJson)
            .toList(),
        guestNotes: (j['guestNotes'] as String?) ?? '',
        prepDays: ((j['prepDays'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(PrepDay.fromJson)
            .toList(),
        runSheet: ((j['runSheet'] as List<dynamic>?) ?? const <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(ServiceStep.fromJson)
            .toList(),
        checked: ((j['checked'] as List<dynamic>?) ?? const <dynamic>[])
            .map((dynamic e) => e.toString())
            .toList(),
      );
}

/// The saved dinners, kept locally (host_hub.json via LocalCache) and
/// mirrored to GitHub by [HostHubSync]. Encodes/decodes defensively, same as
/// the recipe box.
class HostHubBox {
  final List<HostEvent> events;
  const HostHubBox([this.events = const <HostEvent>[]]);

  /// Upcoming first (soonest date first, undated plans first of all since
  /// they're still open), then past, newest-created first within each.
  List<HostEvent> get sorted {
    final DateTime today = DateTime.now();
    final List<HostEvent> upcoming =
        events.where((HostEvent e) => e.isUpcoming(today)).toList()
          ..sort((HostEvent a, HostEvent b) {
            final DateTime? da = DateTime.tryParse(a.eventDate);
            final DateTime? db = DateTime.tryParse(b.eventDate);
            if (da == null && db == null) {
              return b.createdAtMs.compareTo(a.createdAtMs);
            }
            if (da == null) {
              return -1;
            }
            if (db == null) {
              return 1;
            }
            return da.compareTo(db);
          });
    final List<HostEvent> past =
        events.where((HostEvent e) => !e.isUpcoming(today)).toList()
          ..sort((HostEvent a, HostEvent b) =>
              b.createdAtMs.compareTo(a.createdAtMs));
    return <HostEvent>[...upcoming, ...past];
  }

  String encode() => jsonEncode(<String, dynamic>{
        'events': events.map((HostEvent e) => e.toJson()).toList(),
      });

  static HostHubBox decode(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) {
      return const HostHubBox();
    }
    try {
      final dynamic d = jsonDecode(jsonStr);
      if (d is Map<String, dynamic>) {
        return HostHubBox(((d['events'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(HostEvent.fromJson)
            .toList());
      }
    } catch (_) {}
    return const HostHubBox();
  }
}

// ═══════════════════════════════════════════════════════════════════════
// SYNC — same shape as MenuSync (menu_sync.dart), on purpose: one merge
// policy in this app, not two. Union by event id; the newer whole-document
// wins where both sides hold the same id; removals are tombstoned so a
// plain union can't resurrect a deleted dinner; a device that already had
// dinners before this existed seeds them onto the remote on first pull.
// ═══════════════════════════════════════════════════════════════════════

const String kHostHubPath = 'host_hub.json';
const String _kHostHubStamp = 'host_hub_updated_ms';
const String _kHostHubGone = 'host_hub_removed';

class HostHubSync {
  static String get _token => const String.fromEnvironment('GITHUB_DATA_TOKEN');
  static bool get canWrite => _token.isNotEmpty;

  static Uri get _uri => Uri.parse(
      'https://api.github.com/repos/$kDataRepoOwner/$kDataRepoName/contents/$kHostHubPath');

  static Map<String, String> _headers() => <String, String>{
        'Accept': 'application/vnd.github+json',
        'X-GitHub-Api-Version': '2022-11-28',
        'User-Agent': 'Pantry (github.com/scenicprints/pantry)',
        if (canWrite) 'Authorization': 'Bearer $_token',
      };

  static Future<(List<HostEvent>, Set<int>, int, String?)?> _fetch() async {
    try {
      final http.Response r = await http
          .get(_uri, headers: _headers())
          .timeout(const Duration(seconds: 15));
      if (r.statusCode == 404) {
        return (<HostEvent>[], <int>{}, 0, null);
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
        return (<HostEvent>[], <int>{}, 0, sha);
      }
      final dynamic d = jsonDecode(utf8.decode(base64.decode(content)));
      if (d is! Map<String, dynamic>) {
        return (<HostEvent>[], <int>{}, 0, sha);
      }
      final List<HostEvent> events = ((d['events'] as List<dynamic>?) ??
              <dynamic>[])
          .whereType<Map>()
          .map((Map e) => HostEvent.fromJson(e.cast<String, dynamic>()))
          .toList();
      final Set<int> gone = ((d['removed'] as List<dynamic>?) ?? <dynamic>[])
          .whereType<num>()
          .map((num n) => n.round())
          .toSet();
      return (events, gone, (d['updated_at_ms'] as num?)?.round() ?? 0, sha);
    } catch (_) {
      return null;
    }
  }

  static Set<int> _localGone() => LocalCache.prefIntList(_kHostHubGone).toSet();

  static void _rememberGone(Iterable<int> ids) {
    final Set<int> all = _localGone()..addAll(ids);
    final List<int> kept = all.toList()..sort();
    LocalCache.setPrefIntList(_kHostHubGone,
        kept.length > 200 ? kept.sublist(kept.length - 200) : kept);
  }

  /// Record that [ids] were removed here, so the merge keeps them off rather
  /// than pulling them back from the other device.
  static void noteRemoved(Iterable<int> ids) {
    if (ids.isEmpty) {
      return;
    }
    _rememberGone(ids);
  }

  /// Merge what is on GitHub into what is here. Returns the merged list when
  /// it differs from [local], else null. A failed fetch changes nothing.
  static Future<List<HostEvent>?> pull(List<HostEvent> local) async {
    final (List<HostEvent>, Set<int>, int, String?)? r = await _fetch();
    if (r == null) {
      return null;
    }
    final Set<int> gone = <int>{..._localGone(), ...r.$2};
    final bool remoteIsNewer = r.$3 > LocalCache.prefInt(_kHostHubStamp);

    final Map<int, HostEvent> merged = <int, HostEvent>{
      for (final HostEvent e in local) e.createdAtMs: e,
    };
    for (final HostEvent e in r.$1) {
      if (!merged.containsKey(e.createdAtMs) || remoteIsNewer) {
        merged[e.createdAtMs] = e;
      }
    }
    for (final int id in gone) {
      merged.remove(id);
    }

    final List<HostEvent> out = merged.values.toList()
      ..sort((HostEvent a, HostEvent b) =>
          a.createdAtMs.compareTo(b.createdAtMs));
    if (remoteIsNewer) {
      LocalCache.setPrefInt(_kHostHubStamp, r.$3);
    }

    // A device already holding dinners before this file existed would pull
    // nothing and never send what it had. Seed the remote if anything local
    // is missing from it.
    final Set<int> remoteIds = r.$1.map((HostEvent e) => e.createdAtMs).toSet();
    if (out.any((HostEvent e) => !remoteIds.contains(e.createdAtMs))) {
      pushSoon(out);
    }

    final bool same = out.length == local.length &&
        out.every((HostEvent e) =>
            local.any((HostEvent l) => l.createdAtMs == e.createdAtMs));
    return same && !remoteIsNewer ? null : out;
  }

  /// Publish the dinners as they stand here.
  static Future<bool> push(List<HostEvent> events) async {
    if (!canWrite) {
      return false;
    }
    final (List<HostEvent>, Set<int>, int, String?)? current = await _fetch();
    if (current == null) {
      return false;
    }
    final int now = DateTime.now().millisecondsSinceEpoch;
    final Set<int> gone = <int>{..._localGone(), ...current.$2};
    _rememberGone(gone);
    final String body =
        const JsonEncoder.withIndent('  ').convert(<String, dynamic>{
      'updated_at_ms': now,
      'events': events.map((HostEvent e) => e.toJson()).toList(),
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
                'message': 'Host Hub',
                'content': base64.encode(utf8.encode(body)),
                if (current.$4 != null) 'sha': current.$4,
              }))
          .timeout(const Duration(seconds: 20));
      final bool ok = r.statusCode == 200 || r.statusCode == 201;
      if (ok) {
        LocalCache.setPrefInt(_kHostHubStamp, now);
      }
      return ok;
    } catch (_) {
      return false;
    }
  }

  /// Fire-and-forget publish, for callers that shouldn't wait on a round trip.
  static void pushSoon(List<HostEvent> events) {
    push(events).catchError((Object _) => false);
  }
}
