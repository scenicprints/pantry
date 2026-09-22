import 'dart:convert';
import 'dart:io';

// ═══════════════════════════════════════════════════════════════════════
// RECLAIM — delete what the app downloaded and then never let go of.
//
// The in-app updater writes each new release to files/ota_update/ under a
// version-specific name, hands it to the system installer, and that is the
// last anyone thinks about it. Nothing ever deleted one. Thirty-odd releases
// at about 100 MB each is several gigabytes of dead installers sitting in
// internal storage, which the user cannot clear himself: it is in files/, not
// cache/, so Android's "Clear cache" does not touch it and only "Clear
// storage" would, which would take the real data with it.
//
// The captured Nutrition Facts photos are the same story on a smaller scale.
// image_picker drops each one in the cache tree and nobody collects them.
//
// WHAT THIS WILL AND WILL NOT DELETE. It removes the contents of the
// ota_update folder, any stray .apk, and image files in the CACHE tree. It
// never deletes by extension inside files/, because that is where the app's
// own JSON lives. Running at launch is what makes it safe: an install that
// needed its APK has already happened, and no photo is in flight.
//
// Everything is best effort. A sweep that fails frees nothing and is silent;
// it must never be the reason the app does not start.
// ═══════════════════════════════════════════════════════════════════════

class Reclaim {
  static const Set<String> _imageExt = <String>{
    '.jpg',
    '.jpeg',
    '.png',
    '.heic',
    '.heif',
    '.webp',
    '.bmp',
  };

  /// Freed by this launch's sweep.
  static int freedNow = 0;

  /// Freed since the app was installed, so Settings can still show the number
  /// after the big first sweep has already happened.
  static int freedEver = 0;

  static Directory? _cache;
  static Directory? _files;
  static File? _ledger;

  /// The same two directories the stores work out, plus the external
  /// app-private tree when the platform has one.
  static void _locate() {
    final Directory cache = Directory.systemTemp;
    _cache = cache;
    _files = Directory(Platform.isIOS
        ? '${cache.parent.path}/Library/Application Support'
        : '${cache.parent.path}/files');
    _ledger = File('${_files!.path}/reclaimed.json');
  }

  /// The app-private folders on the shared volume, which is where older
  /// versions of these plugins sometimes wrote instead. Derived from the
  /// internal path rather than guessed, and skipped when it is not there.
  static List<Directory> _external() {
    if (!Platform.isAndroid) {
      return <Directory>[];
    }
    final String pkg = _cache!.parent.path.split('/').last;
    if (pkg.isEmpty) {
      return <Directory>[];
    }
    final Directory base =
        Directory('/storage/emulated/0/Android/data/$pkg');
    if (!base.existsSync()) {
      return <Directory>[];
    }
    return <Directory>[base];
  }

  /// Delete [f], returning the bytes it held.
  static int _remove(File f) {
    try {
      final int n = f.lengthSync();
      f.deleteSync();
      return n;
    } catch (_) {
      return 0;
    }
  }

  static int _sweepDir(Directory d, bool Function(File) wanted) {
    int freed = 0;
    if (!d.existsSync()) {
      return 0;
    }
    try {
      for (final FileSystemEntity e in d.listSync(recursive: true)) {
        if (e is File && wanted(e)) {
          freed += _remove(e);
        }
      }
    } catch (_) {}
    return freed;
  }

  static bool _isApk(File f) => f.path.toLowerCase().endsWith('.apk');

  static bool _isImage(File f) {
    final String p = f.path.toLowerCase();
    final int dot = p.lastIndexOf('.');
    return dot > 0 && _imageExt.contains(p.substring(dot));
  }

  /// The sweep itself, over directories it is handed rather than ones it
  /// finds, so a test can point it at a sandbox instead of the real phone.
  static int sweepTrees({
    required Directory files,
    required Directory cache,
    List<Directory> external = const <Directory>[],
  }) {
    int freed = 0;

    // 1. Every downloaded installer. The whole folder, not just the older
    //    ones: at launch there is no install still waiting on a file here.
    freed += _sweepDir(Directory('${files.path}/ota_update'), (File _) => true);

    // 2. Any .apk that landed somewhere else, in either tree.
    freed += _sweepDir(files, _isApk);
    freed += _sweepDir(cache, _isApk);

    // 3. Captured label photos. Cache only, never files/, which is where the
    //    app's own JSON lives.
    freed += _sweepDir(cache, _isImage);

    for (final Directory d in external) {
      freed += _sweepDir(d, (File f) => _isApk(f) || _isImage(f));
    }
    return freed;
  }

  /// Clear out the installers and the stale photos. Returns bytes freed.
  static Future<int> sweep() async {
    try {
      _locate();
      _readLedger();
      final int freed = sweepTrees(
          files: _files!, cache: _cache!, external: _external());
      freedNow = freed;
      freedEver += freed;
      if (freed > 0) {
        _writeLedger();
      }
      return freed;
    } catch (_) {
      return 0;
    }
  }

  /// Drop the previous installer before pulling a new one, so the phone never
  /// has to hold two at once.
  static void beforeDownload() {
    try {
      _locate();
      _readLedger();
      final int freed =
          _sweepDir(Directory('${_files!.path}/ota_update'), (File _) => true);
      if (freed > 0) {
        freedEver += freed;
        _writeLedger();
      }
    } catch (_) {}
  }

  static void _readLedger() {
    try {
      final File? l = _ledger;
      if (l != null && l.existsSync()) {
        final dynamic d = jsonDecode(l.readAsStringSync());
        if (d is Map<String, dynamic>) {
          freedEver = (d['freed_ever'] as num?)?.round() ?? 0;
        }
      }
    } catch (_) {}
  }

  static void _writeLedger() {
    try {
      _ledger?.writeAsStringSync(
          jsonEncode(<String, dynamic>{'freed_ever': freedEver}));
    } catch (_) {}
  }

  /// "3.2 GB", for the one line Settings shows.
  static String pretty(int bytes) {
    if (bytes >= 1073741824) {
      return '${(bytes / 1073741824).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1048576) {
      return '${(bytes / 1048576).round()} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).round()} KB';
    }
    return '$bytes bytes';
  }
}
