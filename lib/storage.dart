import 'dart:convert';
import 'dart:io';

import 'models.dart';

// ═══════════════════════════════════════════════════════════════════════
// LOCAL CACHE — the pantry is kept in a JSON file in the app's persistent
// storage so the UI is instant and works offline; GitHub is synced on top.
// Uses the same systemTemp→/files trick as BodyComp so data survives app
// updates without pulling in path_provider. iOS has its own persistent
// directory; see init().
// ═══════════════════════════════════════════════════════════════════════

class LocalCache {
  static late File _file;
  static late File _historyFile; // cooked-meal history (chef)
  static late File _plannedFile; // "On the menu" planned meals (chef)
  static late File _usageFile; // spending ledger (consumption events)
  static late File _priceBookFile; // last-known unit prices
  static late File _recipeBoxFile; // saved recipes (the recipe box)
  static late File _prefsFile; // small UI preferences (cooking-mode toggles)
  static late File _prepFile; // cached mise en place plans, keyed by recipe
  static late File _notesFile; // what happened last time, keyed by recipe

  static Map<String, dynamic> _prepPlans = <String, dynamic>{};
  static Map<String, dynamic> _cookNotes = <String, dynamic>{};

  static Map<String, dynamic> _prefs = <String, dynamic>{};

  static Future<void> init() async {
    // systemTemp on Android = /data/user/0/<package>/cache; go up to /files/.
    // On iOS it's <container>/tmp, whose sibling the system keeps across app
    // updates and restores from backup is Library/Application Support. Both
    // are reached from the same parent, so no path_provider either way.
    final String tempPath = Directory.systemTemp.path;
    final String appDir = Directory(tempPath).parent.path;
    final Directory filesDir = Directory(
        Platform.isIOS ? '$appDir/Library/Application Support' : '$appDir/files');
    if (!filesDir.existsSync()) {
      filesDir.createSync(recursive: true);
    }
    _file = File('${filesDir.path}/pantry_cache.json');
    _historyFile = File('${filesDir.path}/meal_history.json');
    _plannedFile = File('${filesDir.path}/planned_meals.json');
    _usageFile = File('${filesDir.path}/usage.json');
    _priceBookFile = File('${filesDir.path}/price_book.json');
    _recipeBoxFile = File('${filesDir.path}/recipe_box.json');
    _prefsFile = File('${filesDir.path}/prefs.json');
    _prepFile = File('${filesDir.path}/prep_plans.json');
    _notesFile = File('${filesDir.path}/cook_notes.json');
    try {
      if (_notesFile.existsSync()) {
        final dynamic d = jsonDecode(_notesFile.readAsStringSync());
        if (d is Map<String, dynamic>) {
          _cookNotes = d;
        }
      }
    } catch (_) {}
    try {
      if (_prepFile.existsSync()) {
        final dynamic d = jsonDecode(_prepFile.readAsStringSync());
        if (d is Map<String, dynamic>) {
          _prepPlans = d;
        }
      }
    } catch (_) {}
    try {
      if (_prefsFile.existsSync()) {
        final dynamic d = jsonDecode(_prefsFile.readAsStringSync());
        if (d is Map<String, dynamic>) {
          _prefs = d;
        }
      }
    } catch (_) {}
  }

  // ── preferences ───────────────────────────────────────────────────────
  // Small UI state that should be remembered but isn't worth syncing: the
  // cooking-mode layout toggles. Kept in memory and written through, so a
  // read is free on the hot path.

  static bool prefBool(String key, {bool fallback = false}) {
    final dynamic v = _prefs[key];
    return v is bool ? v : fallback;
  }

  static void setPrefBool(String key, bool value) {
    _prefs[key] = value;
    try {
      _prefsFile.writeAsStringSync(jsonEncode(_prefs));
    } catch (_) {}
  }

  // ── mise en place ─────────────────────────────────────────────────────
  // A measuring plan costs an API call, so it is kept once it is made. Only
  // the last [_kPrepKeep] recipes are held; Dart maps keep insertion order,
  // so the oldest falls off the front.

  static const int _kPrepKeep = 30;

  static String? loadPrep(String key) {
    final dynamic v = _prepPlans[key];
    return v is String ? v : null;
  }

  static void savePrep(String key, String json) {
    _prepPlans.remove(key); // re-insert so a reused recipe counts as recent
    _prepPlans[key] = json;
    while (_prepPlans.length > _kPrepKeep) {
      _prepPlans.remove(_prepPlans.keys.first);
    }
    try {
      _prepFile.writeAsStringSync(jsonEncode(_prepPlans));
    } catch (_) {}
  }

  // ── cook notes ────────────────────────────────────────────────────────
  // What happened last time you cooked this: "too salty", "the roast wanted
  // four more minutes". Kept by recipe title, oldest first, so the recipe
  // screen can show them and the chef can be handed them on a revise.

  static const int _kNotesPerRecipe = 6;

  static List<String> loadNotes(String title) {
    final dynamic v = _cookNotes[title];
    if (v is List) {
      return v.whereType<String>().toList();
    }
    return <String>[];
  }

  static void addNote(String title, String note) {
    final String trimmed = note.trim();
    if (trimmed.isEmpty) {
      return;
    }
    final List<String> notes = loadNotes(title)..add(trimmed);
    while (notes.length > _kNotesPerRecipe) {
      notes.removeAt(0);
    }
    _writeNotes(title, notes);
  }

  static void removeNote(String title, int index) {
    final List<String> notes = loadNotes(title);
    if (index < 0 || index >= notes.length) {
      return;
    }
    notes.removeAt(index);
    _writeNotes(title, notes);
  }

  static void _writeNotes(String title, List<String> notes) {
    if (notes.isEmpty) {
      _cookNotes.remove(title);
    } else {
      _cookNotes[title] = notes;
    }
    try {
      _notesFile.writeAsStringSync(jsonEncode(_cookNotes));
    } catch (_) {}
  }

  /// Spending-ledger JSON, or null if none saved yet.
  static String? loadUsage() {
    try {
      if (_usageFile.existsSync()) {
        return _usageFile.readAsStringSync();
      }
    } catch (_) {}
    return null;
  }

  static void saveUsage(String json) {
    try {
      _usageFile.writeAsStringSync(json);
    } catch (_) {}
  }

  /// Price-book JSON, or null if none saved yet.
  static String? loadPriceBook() {
    try {
      if (_priceBookFile.existsSync()) {
        return _priceBookFile.readAsStringSync();
      }
    } catch (_) {}
    return null;
  }

  static void savePriceBook(String json) {
    try {
      _priceBookFile.writeAsStringSync(json);
    } catch (_) {}
  }

  /// Planned-meal ("On the menu") JSON, or null if none saved yet.
  static String? loadPlanned() {
    try {
      if (_plannedFile.existsSync()) {
        return _plannedFile.readAsStringSync();
      }
    } catch (_) {}
    return null;
  }

  static void savePlanned(String json) {
    try {
      _plannedFile.writeAsStringSync(json);
    } catch (_) {}
  }

  /// Recipe-box JSON — the recipes the user chose to keep.
  static String? loadRecipeBox() {
    try {
      if (_recipeBoxFile.existsSync()) {
        return _recipeBoxFile.readAsStringSync();
      }
    } catch (_) {}
    return null;
  }

  static void saveRecipeBox(String json) {
    try {
      _recipeBoxFile.writeAsStringSync(json);
    } catch (_) {}
  }

  /// Cooked-meal history JSON (null when the chef hasn't saved one yet).
  static String? loadHistory() {
    try {
      if (_historyFile.existsSync()) {
        return _historyFile.readAsStringSync();
      }
    } catch (_) {}
    return null;
  }

  static void saveHistory(String json) {
    try {
      _historyFile.writeAsStringSync(json);
    } catch (_) {}
  }

  static PantryData load() {
    try {
      if (_file.existsSync()) {
        return PantryData.decode(_file.readAsStringSync());
      }
    } catch (_) {}
    return const PantryData();
  }

  /// Save the cache. Uses a compact encoding with the derived flags stamped
  /// for [now] (same format as the remote file).
  static void save(PantryData data, DateTime now) {
    try {
      // Keep tombstones locally so a delete survives an app restart even if
      // the push to GitHub hasn't landed yet.
      _file.writeAsStringSync(data.encode(now, keepDeleted: true));
    } catch (_) {}
  }

  /// Timestamp of the last successful local write, or null if none.
  static DateTime? lastSaved() {
    try {
      if (_file.existsSync()) {
        return _file.lastModifiedSync();
      }
    } catch (_) {}
    return null;
  }
}

// A tiny helper the UI uses to build compact JSON for a share/export button.
String prettyJson(Object o) =>
    const JsonEncoder.withIndent('  ').convert(o);
