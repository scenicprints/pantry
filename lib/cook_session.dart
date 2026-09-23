import 'package:flutter/material.dart';

import 'chef_models.dart';
import 'models.dart';

// ═══════════════════════════════════════════════════════════════════════
// COOK SESSION — what you actually put in the pan, for one cook.
//
// This used to live inside the measuring screen, which was wrong twice over.
// Weights change WHILE you cook — something bakes longer, you top up the
// stock — so they cannot belong to a screen you have already left. And the
// handoff to BodyComp has to happen at the END of cooking, not when the
// measuring is done, for the same reason.
//
// So the session is owned by the recipe and handed to both screens: the
// measuring screen shows it grouped into bowls, cooking mode shows it as a
// flat panel you can pull up mid-step. Same numbers, two views.
//
// One entry per RECIPE ingredient, not per bowl item: bowls are a way of
// looking at the list, not the list itself.
// ═══════════════════════════════════════════════════════════════════════

/// Strip a food name down to something two spellings of it can agree on.
String foodKey(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\([^)]*\)'), ' ') // "(drained)" says nothing useful
    .replaceAll(RegExp(r'[^a-z]+'), ' ')
    .trim();

/// What the cook can pair an ingredient with, narrowed by [query].
///
/// The rule is "what have I got", and an item whose amount is not tracked is
/// still something he has got. Minced garlic and soy sauce are bought, opened
/// and sitting in the door of the fridge; they carry no gram count because
/// nobody weighs them, and an earlier version read that missing number as
/// missing stock and hid them. Nothing is subtracted for them either way, but
/// pairing is also what tells BodyComp the food was eaten, so hiding them
/// silently dropped them out of the meal.
///
/// [includeEmpty] brings back the tracked items that have run down to zero,
/// because the counts are not always right and he needs a way to reach one.
List<PantryItem> pickablePantry(
  List<PantryItem> pantry, {
  String query = '',
  bool includeEmpty = false,
}) {
  final String q = query.trim().toLowerCase();
  return pantry
      .where((PantryItem p) =>
          !p.deleted &&
          (includeEmpty || p.untracked || p.remaining > 0) &&
          (q.isEmpty || p.name.toLowerCase().contains(q)))
      .toList()
    ..sort((PantryItem a, PantryItem b) =>
        a.name.toLowerCase().compareTo(b.name.toLowerCase()));
}

/// The pantry item an ingredient most likely refers to, or null.
///
/// Exact normalised match first, then containment either way, preferring the
/// shortest hit so "chicken" doesn't win over "chicken thighs".
///
/// Untracked items are matched too. They used to be skipped on the grounds
/// that there is no stock to draw down, which confused two different things:
/// nothing is subtracted for the minced garlic, but the meal still contains
/// it, and leaving it unlinked meant re-pairing it by hand on every single
/// cook. An item that has actually run out is skipped, though, since pairing
/// to it would be wrong.
PantryItem? matchPantryItem(String ingredient, List<PantryItem> pantry) {
  final String want = foodKey(ingredient);
  if (want.isEmpty) {
    return null;
  }
  final List<PantryItem> usable = pantry
      .where((PantryItem p) =>
          !p.deleted && (p.untracked || p.remaining > 0))
      .toList();
  for (final PantryItem p in usable) {
    if (foodKey(p.name) == want) {
      return p;
    }
  }
  PantryItem? best;
  for (final PantryItem p in usable) {
    final String have = foodKey(p.name);
    if (have.isEmpty) {
      continue;
    }
    if (want.contains(have) || have.contains(want)) {
      if (best == null || have.length < foodKey(best.name).length) {
        best = p;
      }
    }
  }
  return best;
}

/// One ingredient, and what really went in.
class CookEntry {
  final String item;

  /// What the recipe asked for, scaled to the servings, e.g. "480 g" or
  /// "2 tsp". Kept so the field can show what it was meant to be.
  final String recipeAmount;

  /// Grams actually weighed out. Always editable, whatever unit the recipe
  /// used: the recipe is not changed by this, it only records what happened,
  /// and a cook weighing his spices should not be told he can't.
  final TextEditingController grams;

  /// The pantry item this draws down. Empty means deliberately nothing.
  String pantryId;

  /// The bowl this portion belongs to, empty when the plan never placed it.
  /// An ingredient used at two different moments becomes two entries with the
  /// same [item] and different bowls, so each gets its own weight.
  String bowl;

  CookEntry({
    required this.item,
    required this.recipeAmount,
    required this.grams,
    this.pantryId = '',
    this.bowl = '',
  });

  /// True when the recipe itself gave a weight, so the field starts filled.
  bool get startedFromRecipe => isGramAmount(recipeAmount);

  double get measuredG => double.tryParse(grams.text.trim()) ?? 0;
}

class CookSession extends ChangeNotifier {
  final Recipe recipe;
  final int servings;
  final double factor;
  final List<PantryItem> pantry;

  /// In recipe order, which is the order everything is displayed in.
  final List<CookEntry> entries = <CookEntry>[];

  /// The measuring plan, once the chef has been asked for one. Only used to
  /// group the display and to know what shares a pan.
  PrepPlan? plan;

  CookSession({
    required this.recipe,
    required this.servings,
    required this.factor,
    required this.pantry,
  }) {
    for (final RecipeIngredient i in recipe.ingredients) {
      final String amount = i.scaled(factor);
      final PantryItem? match = matchPantryItem(i.item, pantry);
      entries.add(CookEntry(
        item: i.item,
        recipeAmount: amount,
        // Prefilled where the recipe already spoke in grams, so an untouched
        // line still sends something true. Blank otherwise rather than
        // guessing what 2 tsp weighs.
        grams: TextEditingController(text: _prefill(amount)),
        pantryId: match?.id ?? '',
      ));
    }
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  /// What the field starts as for [amount]: the number when the recipe spoke
  /// in grams, blank otherwise rather than guessing what 2 tsp weighs.
  static String _prefill(String amount) =>
      isGramAmount(amount) ? _trim(amountValue(amount) ?? 0) : '';

  CookEntry? byName(String name) {
    final String want = foodKey(name);
    for (final CookEntry e in entries) {
      if (foodKey(e.item) == want) {
        return e;
      }
    }
    for (final CookEntry e in entries) {
      final String k = foodKey(e.item);
      if (k.isNotEmpty && (k.contains(want) || want.contains(k))) {
        return e;
      }
    }
    return null;
  }

  PantryItem? pantryFor(CookEntry e) {
    if (e.pantryId.isEmpty) {
      return null;
    }
    for (final PantryItem p in pantry) {
      if (p.id == e.pantryId) {
        return p;
      }
    }
    return null;
  }

  void setLink(CookEntry e, String pantryId) {
    e.pantryId = pantryId;
    notifyListeners();
  }

  /// Take the plan, and split any ingredient the plan uses in more than one
  /// bowl into one entry per bowl.
  ///
  /// This is the "30 g of oil" problem. The recipe asks for oil once, so
  /// there was one row and one weight, and the plan then put oil in the pan
  /// bowl AND in the vegetable bowl. Whichever he poured first took the whole
  /// 30 g, and there was no way to get it back out of a bowl it was already
  /// mixed into. A shared ingredient has to be weighed once per use, at the
  /// amount that use needs.
  ///
  /// Anything already typed stays put: the first portion keeps his number,
  /// because reading a plan must never wipe a weight he has entered.
  void setPlan(PrepPlan p) {
    plan = p;
    _splitAcrossBowls(p);
    notifyListeners();
  }

  void _splitAcrossBowls(PrepPlan p) {
    final List<CookEntry> out = <CookEntry>[];
    for (final CookEntry e in entries) {
      final List<(PrepBowl, PrepItem)> uses = <(PrepBowl, PrepItem)>[];
      for (final PrepBowl b in p.bowls) {
        for (final PrepItem i in b.items) {
          if (byName(i.item) == e) {
            uses.add((b, i));
          }
        }
      }
      if (uses.isEmpty) {
        out.add(e);
        continue;
      }
      if (uses.length == 1) {
        e.bowl = uses.first.$1.label;
        out.add(e);
        continue;
      }
      // Used in several bowls. One entry each, carrying that bowl's own
      // amount rather than the recipe's total.
      //
      // "Did he type this?" is not the same as "is there a number in it". The
      // field starts prefilled with the recipe's own total, so treating any
      // non-empty field as his would hand the first bowl the whole 30 g and
      // the portions would no longer add up. Only a value that differs from
      // the prefill is his, and only that survives.
      final bool hisOwn = e.grams.text.trim() != _prefill(e.recipeAmount);
      for (int n = 0; n < uses.length; n++) {
        final (PrepBowl b, PrepItem i) = uses[n];
        final String amount = i.amount.isEmpty ? e.recipeAmount : i.amount;
        out.add(CookEntry(
          item: e.item,
          recipeAmount: amount,
          bowl: b.label,
          pantryId: e.pantryId,
          grams: n == 0 && hisOwn
              ? e.grams
              : TextEditingController(text: _prefill(amount)),
        ));
      }
    }
    entries
      ..clear()
      ..addAll(out);
  }

  /// The entry for one line of one bowl. Falls back to the plain name lookup
  /// so a plan that never split anything behaves exactly as before.
  CookEntry? inBowl(String bowlLabel, String name) {
    final String want = foodKey(name);
    for (final CookEntry e in entries) {
      if (e.bowl == bowlLabel && foodKey(e.item) == want) {
        return e;
      }
    }
    for (final CookEntry e in entries) {
      final String k = foodKey(e.item);
      if (e.bowl == bowlLabel &&
          k.isNotEmpty &&
          (k.contains(want) || want.contains(k))) {
        return e;
      }
    }
    return byName(name);
  }

  /// Anything with a weight on it. What gets subtracted and logged.
  List<CookEntry> get weighed =>
      entries.where((CookEntry e) => e.measuredG > 0).toList();

  @override
  void dispose() {
    for (final CookEntry e in entries) {
      e.grams.dispose();
    }
    super.dispose();
  }
}
