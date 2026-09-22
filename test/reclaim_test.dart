import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pantry/reclaim.dart';

// The sweep frees gigabytes, so the thing worth proving is not that it
// deletes: it is that it stops. The app's own JSON lives one directory over
// from the installers, and a sweep that took pantry_cache.json with them
// would cost far more than the storage it saved.

File write(Directory d, String name, int bytes) {
  final File f = File('${d.path}/$name')
    ..createSync(recursive: true)
    ..writeAsBytesSync(List<int>.filled(bytes, 0));
  return f;
}

void main() {
  late Directory root;
  late Directory files;
  late Directory cache;

  setUp(() {
    root = Directory.systemTemp.createTempSync('reclaim_test');
    files = Directory('${root.path}/files')..createSync();
    cache = Directory('${root.path}/cache')..createSync();
  });

  tearDown(() {
    try {
      root.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('every downloaded installer goes, whatever it is called', () {
    final Directory ota = Directory('${files.path}/ota_update')..createSync();
    write(ota, 'pantry-0.16.0.apk', 1000);
    write(ota, 'pantry-0.17.1.apk', 1000);
    write(ota, 'pantry-0.18.2.apk', 1000);

    final int freed = Reclaim.sweepTrees(files: files, cache: cache);

    expect(freed, 3000);
    expect(ota.listSync(), isEmpty);
  });

  test("the app's own data is not touched", () {
    write(files, 'pantry_cache.json', 500);
    write(files, 'recipe_box.json', 500);
    write(files, 'cook_notes.json', 500);
    write(Directory('${files.path}/ota_update')..createSync(),
        'pantry-0.18.2.apk', 9000);

    final int freed = Reclaim.sweepTrees(files: files, cache: cache);

    expect(freed, 9000, reason: 'only the installer should be counted');
    expect(File('${files.path}/pantry_cache.json').existsSync(), isTrue);
    expect(File('${files.path}/recipe_box.json').existsSync(), isTrue);
    expect(File('${files.path}/cook_notes.json').existsSync(), isTrue);
  });

  test('label photos go from the cache, and only from the cache', () {
    write(cache, 'image_picker_9482.jpg', 2000);
    write(cache, 'scan.png', 1000);
    // A picture sitting in files/ is not ours to delete: nothing the app
    // writes there is disposable, and guessing by extension there is how a
    // cleanup turns into data loss.
    write(files, 'progress.jpg', 4000);

    final int freed = Reclaim.sweepTrees(files: files, cache: cache);

    expect(freed, 3000);
    expect(File('${files.path}/progress.jpg').existsSync(), isTrue);
  });

  test('an installer that landed outside ota_update still goes', () {
    write(files, 'stray-1.2.3.apk', 700);
    write(cache, 'downloaded.apk', 300);

    expect(Reclaim.sweepTrees(files: files, cache: cache), 1000);
  });

  test('a second sweep finds nothing and frees nothing', () {
    write(Directory('${files.path}/ota_update')..createSync(), 'a.apk', 1000);

    expect(Reclaim.sweepTrees(files: files, cache: cache), 1000);
    expect(Reclaim.sweepTrees(files: files, cache: cache), 0);
  });

  test('missing directories are not an error', () {
    final Directory gone = Directory('${root.path}/nope');
    expect(Reclaim.sweepTrees(files: gone, cache: gone), 0);
  });

  test('sizes read the way a person would say them', () {
    expect(Reclaim.pretty(3435973836), '3.2 GB');
    expect(Reclaim.pretty(104857600), '100 MB');
    expect(Reclaim.pretty(2048), '2 KB');
    expect(Reclaim.pretty(12), '12 bytes');
  });
}
