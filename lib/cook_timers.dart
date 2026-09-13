import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import 'notifications.dart';

// ═══════════════════════════════════════════════════════════════════════
// COOK TIMERS — one registry for every timer in a cook, so rice, the oven
// and the pan can all run at once and a timer keeps counting when you move
// off its step.
//
// The countdown used to live inside the StepTimer widget, which meant a
// timer only survived because the step page was kept alive, and only one
// was ever visible. Here a single periodic tick drives them all and the
// alarm fires from the registry, so a timer that ends three steps back
// still rings.
// ═══════════════════════════════════════════════════════════════════════

class CookTimer {
  /// Stable identity, so returning to a step re-attaches to the running
  /// timer instead of starting a second one.
  final String key;
  final String label;
  final int total;
  int remaining;
  bool running;

  CookTimer({
    required this.key,
    required this.label,
    required this.total,
  })  : remaining = total,
        running = false;

  bool get done => remaining <= 0;
  bool get idle => !running && remaining == total;

  /// m:ss, or h:mm:ss once there is an hour on the clock.
  String get display {
    final int s = remaining < 0 ? 0 : remaining;
    final int h = s ~/ 3600;
    final int m = (s % 3600) ~/ 60;
    final int sec = s % 60;
    final String ss = sec.toString().padLeft(2, '0');
    if (h > 0) {
      return '$h:${m.toString().padLeft(2, '0')}:$ss';
    }
    return '$m:$ss';
  }
}

class CookTimers extends ChangeNotifier {
  CookTimers._();
  static final CookTimers instance = CookTimers._();

  final List<CookTimer> _timers = <CookTimer>[];
  Timer? _tick;

  /// Timers worth showing in the rail: running, or finished and not yet
  /// acknowledged. An untouched step timer stays out of the way.
  List<CookTimer> get rail =>
      _timers.where((CookTimer t) => !t.idle).toList(growable: false);

  bool get anyRunning => _timers.any((CookTimer t) => t.running);

  /// The timer for [key], created on first ask. [label] and [seconds] only
  /// apply at creation; an existing timer is returned as it stands.
  CookTimer ensure({
    required String key,
    required String label,
    required int seconds,
  }) {
    for (final CookTimer t in _timers) {
      if (t.key == key) {
        return t;
      }
    }
    final CookTimer t = CookTimer(key: key, label: label, total: seconds);
    _timers.add(t);
    return t;
  }

  void toggle(CookTimer t) {
    if (t.done) {
      reset(t);
      return;
    }
    t.running = !t.running;
    _syncTicking();
    notifyListeners();
  }

  void reset(CookTimer t) {
    t.running = false;
    t.remaining = t.total;
    _syncTicking();
    notifyListeners();
  }

  /// Add or remove time on a running timer. The pan does not care what the
  /// recipe said.
  void nudge(CookTimer t, int seconds) {
    t.remaining = (t.remaining + seconds).clamp(0, 24 * 3600);
    _syncTicking();
    notifyListeners();
  }

  /// Drop a timer out of the rail entirely.
  void dismiss(CookTimer t) {
    _timers.remove(t);
    _syncTicking();
    notifyListeners();
  }

  /// Drop every timer that isn't part of this dish. Called when a cook
  /// starts, so a leftover from the last recipe can't sit in the rail
  /// claiming something is on the stove.
  void retainOnly(String keyPrefix) {
    final int before = _timers.length;
    _timers.removeWhere((CookTimer t) => !t.key.startsWith(keyPrefix));
    if (_timers.length != before) {
      _syncTicking();
      notifyListeners();
    }
  }

  /// Called when cooking mode closes. Nothing should keep ticking once the
  /// cook is over.
  void clearAll() {
    _timers.clear();
    _tick?.cancel();
    _tick = null;
    notifyListeners();
  }

  void _syncTicking() {
    if (anyRunning) {
      _tick ??= Timer.periodic(const Duration(seconds: 1), (_) => _onTick());
    } else {
      _tick?.cancel();
      _tick = null;
    }
  }

  void _onTick() {
    final List<CookTimer> finished = <CookTimer>[];
    for (final CookTimer t in _timers) {
      if (!t.running) {
        continue;
      }
      t.remaining--;
      if (t.remaining <= 0) {
        t.remaining = 0;
        t.running = false;
        finished.add(t);
      }
    }
    for (final CookTimer t in finished) {
      _alert(t);
    }
    _syncTicking();
    notifyListeners();
  }

  Future<void> _alert(CookTimer t) async {
    HapticFeedback.heavyImpact();
    Notifications.alarm(
        'Timer done', t.label.isEmpty ? 'A step timer finished.' : t.label);
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: <int>[0, 500, 250, 500, 250, 800]);
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }
}
