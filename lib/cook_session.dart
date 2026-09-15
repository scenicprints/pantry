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

/// The pantry item an ingredient most likely refers to, or null.
///
/// Exact normalised match first, then containment either way, preferring the
/// shortest hit so "chicken" doesn't win over "chicken thighs". Spices and
/// quantity-unknown items are skipped: they carry no weight or price, so
/// there is nothing to take off them.
PantryItem? matchPantryItem(String ingredient, List<PantryItem> pantry) {
  final String want = foodKey(ingredient);
  if (want.isEmpty) {
    return null;
  }
  final List<PantryItem> usable = pantry
      .where((PantryItem p) => !p.deleted && !p.spice && !p.quantityUnknown)
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

  CookEntry({
    required this.item,
    required this.recipeAmount,
    required this.grams,
    this.pantryId = '',
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
        grams: TextEditingController(
            text: isGramAmount(amount)
                ? _trim(amountValue(amount) ?? 0)
                : ''),
        pantryId: match?.id ?? '',
      ));
    }
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

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

  void setPlan(PrepPlan p) {
    plan = p;
    notifyListeners();
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
