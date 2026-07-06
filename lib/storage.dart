import 'dart:convert';
import 'dart:io';

import 'models.dart';

// ═══════════════════════════════════════════════════════════════════════
// LOCAL CACHE — the pantry is kept in a JSON file in the app's persistent
// storage so the UI is instant and works offline; GitHub is synced on top.
// Uses the same systemTemp→/files trick as BodyComp so data survives app
// updates without pulling in path_provider.
// ═══════════════════════════════════════════════════════════════════════

class LocalCache {
  static late File _file;
  static late File _historyFile; // cooked-meal history (chef)
  static late File _plannedFile; // "On the menu" planned meals (chef)

  static Future<void> init() async {
    // systemTemp on Android = /data/user/0/<package>/cache; go up to /files/.
    final String tempPath = Directory.systemTemp.path;
    final String appDir = Directory(tempPath).parent.path;
    final Directory filesDir = Directory('$appDir/files');
    if (!filesDir.existsSync()) {
      filesDir.createSync(recursive: true);
    }
    _file = File('${filesDir.path}/pantry_cache.json');
    _historyFile = File('${filesDir.path}/meal_history.json');
    _plannedFile = File('${filesDir.path}/planned_meals.json');
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
