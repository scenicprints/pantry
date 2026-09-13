// The shared timer registry. The countdown itself needs a clock, so what is
// checked here is the bookkeeping that used to be implicit in the widget:
// identity, what reaches the rail, and what a new dish clears.

import 'package:flutter_test/flutter_test.dart';

import 'package:pantry/cook_timers.dart';

void main() {
  final CookTimers timers = CookTimers.instance;

  setUp(timers.clearAll);

  test('ensure returns the same timer for a key, so a step re-attaches', () {
    final CookTimer a =
        timers.ensure(key: 'Chili#0', label: 'Simmer', seconds: 600);
    final CookTimer b =
        timers.ensure(key: 'Chili#0', label: 'ignored', seconds: 1);
    expect(identical(a, b), isTrue);
    expect(b.total, 600);
    expect(b.label, 'Simmer');
  });

  test('an untouched timer stays out of the rail', () {
    timers.ensure(key: 'Chili#0', label: 'Simmer', seconds: 600);
    expect(timers.rail, isEmpty);
  });

  test('a running timer is in the rail, and pausing keeps it there', () {
    final CookTimer t =
        timers.ensure(key: 'Chili#0', label: 'Simmer', seconds: 600);
    timers.toggle(t);
    expect(t.running, isTrue);
    expect(timers.rail, hasLength(1));

    timers.toggle(t);
    expect(t.running, isFalse);
    // Paused mid-count is not idle, so it must not vanish from the rail.
    timers.nudge(t, -60);
    expect(timers.rail, hasLength(1));
  });

  test('several timers run at once', () {
    final CookTimer rice =
        timers.ensure(key: 'Chili#0', label: 'Rice', seconds: 900);
    final CookTimer oven =
        timers.ensure(key: 'Chili#1', label: 'Oven', seconds: 1800);
    timers.toggle(rice);
    timers.toggle(oven);
    expect(timers.anyRunning, isTrue);
    expect(timers.rail, hasLength(2));
  });

  test('reset puts a timer back and out of the rail', () {
    final CookTimer t =
        timers.ensure(key: 'Chili#0', label: 'Simmer', seconds: 600);
    timers.toggle(t);
    timers.nudge(t, -100);
    timers.reset(t);
    expect(t.remaining, 600);
    expect(t.running, isFalse);
    expect(timers.rail, isEmpty);
  });

  test('nudge cannot drive a timer below zero', () {
    final CookTimer t =
        timers.ensure(key: 'Chili#0', label: 'Simmer', seconds: 60);
    timers.nudge(t, -600);
    expect(t.remaining, 0);
    expect(t.done, isTrue);
  });

  test('a finished timer stays in the rail until it is dealt with', () {
    final CookTimer t =
        timers.ensure(key: 'Chili#0', label: 'Simmer', seconds: 60);
    timers.nudge(t, -60);
    expect(t.done, isTrue);
    expect(timers.rail, hasLength(1));

    timers.dismiss(t);
    expect(timers.rail, isEmpty);
  });

  test('starting a new dish clears the last one out of the rail', () {
    final CookTimer old =
        timers.ensure(key: 'Chili#0', label: 'Simmer', seconds: 600);
    timers.toggle(old);
    final CookTimer fresh =
        timers.ensure(key: 'Risotto#2', label: 'Stock', seconds: 300);
    timers.toggle(fresh);
    expect(timers.rail, hasLength(2));

    timers.retainOnly('Risotto#');
    expect(timers.rail, hasLength(1));
    expect(timers.rail.single.label, 'Stock');
  });

  test('display rolls over into hours', () {
    final CookTimer t =
        timers.ensure(key: 'Stew#0', label: 'Braise', seconds: 3661);
    expect(t.display, '1:01:01');
    timers.nudge(t, -3600);
    expect(t.display, '1:01');
  });
}
