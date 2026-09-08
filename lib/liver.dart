// ════════════════════════════════════════════════════════════════════════
// FATTY LIVER — the app-side half of the liver rules.
//
// The prompt states the limits; this checks the numbers that come back. Same
// shape as the avoid list: the model is told, and then it is measured, because
// a chef told to keep saturated fat down still hands over a cream sauce when
// the dish is famous for one.
//
// This is deliberately SOFTER than the avoid list. An avoid violation is food
// he cannot eat, so the option is thrown out. A liver number is the model's own
// estimate, so a miss buys one re-ask with the specific complaint attached and
// the better of the two sets is kept. Nothing here ever refuses outright.
//
// Numbers are per serving, counting everything on the plate.
// ════════════════════════════════════════════════════════════════════════

import 'chef_models.dart';

/// Saturated fat ceiling, grams per serving.
const double kMaxSatFatPerServing = 7;

/// Added sugar ceiling, grams per serving. Fructose is the one that matters
/// most for a fatty liver, so this is the tightest of the three.
const double kMaxAddedSugarPerServing = 6;

/// Fiber floor, grams per serving.
const double kMinFiberPerServing = 8;

/// Tolerance on each limit, so a 7.2g estimate does not cost an API call.
const double _kSlack = 1.5;

/// One liver limit a meal option missed.
class LiverFlag {
  /// The option it was found on.
  final String title;

  /// What went wrong, in the words the chef gets re-asked with.
  final String problem;

  const LiverFlag({required this.title, required this.problem});

  @override
  String toString() => '"$title" $problem';
}

/// True when the chef reported any of the three liver numbers. All three at
/// zero means it did not answer, not that the dish is a miracle — an
/// unreported meal is left alone rather than burning a re-ask on a guess.
bool reportsLiverNumbers(MealOption o) =>
    o.satFatPerServing > 0 ||
    o.addedSugarPerServing > 0 ||
    o.fiberPerServing > 0;

/// Every liver limit [o] missed — empty when it is inside them, and empty when
/// it reported nothing to judge.
List<LiverFlag> optionLiverFlags(MealOption o) {
  if (!reportsLiverNumbers(o)) {
    return const <LiverFlag>[];
  }
  final List<LiverFlag> out = <LiverFlag>[];
  if (o.satFatPerServing > kMaxSatFatPerServing + _kSlack) {
    out.add(LiverFlag(
        title: o.title,
        problem: 'has ${_g(o.satFatPerServing)} of saturated fat per serving, '
            'over the ${_g(kMaxSatFatPerServing)} limit'));
  }
  if (o.addedSugarPerServing > kMaxAddedSugarPerServing + _kSlack) {
    out.add(LiverFlag(
        title: o.title,
        problem: 'has ${_g(o.addedSugarPerServing)} of added sugar per serving, '
            'over the ${_g(kMaxAddedSugarPerServing)} limit'));
  }
  if (o.fiberPerServing < kMinFiberPerServing - _kSlack) {
    out.add(LiverFlag(
        title: o.title,
        problem: 'has only ${_g(o.fiberPerServing)} of fiber per serving, '
            'under the ${_g(kMinFiberPerServing)} floor'));
  }
  return out;
}

/// Every liver flag across a set of options.
List<LiverFlag> optionsLiverFlags(List<MealOption> opts) =>
    opts.expand(optionLiverFlags).toList();

/// The complaint to re-ask with, or '' when there is nothing wrong.
String liverComplaint(List<LiverFlag> flags) {
  if (flags.isEmpty) {
    return '';
  }
  final String named =
      flags.map((LiverFlag f) => f.toString()).join('; ');
  return 'these break the fatty liver limits: $named';
}

/// Shortcut: the complaint for a whole set of options.
String optionsLiverComplaint(List<MealOption> opts) =>
    liverComplaint(optionsLiverFlags(opts));

/// True when an option reported its numbers and is inside every limit. The
/// option card uses this to decide whether to mark it liver-friendly.
bool isLiverFriendly(MealOption o) =>
    reportsLiverNumbers(o) && optionLiverFlags(o).isEmpty;

String _g(double v) =>
    '${v == v.roundToDouble() ? v.toInt() : v.toStringAsFixed(1)}g';
