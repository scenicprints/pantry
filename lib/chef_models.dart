import 'dart:convert';

// ═══════════════════════════════════════════════════════════════════════
// CHEF MODELS — the shapes the Claude API returns for the two-call flow:
//   Call 1 → a list of MealOption (kOptionCount, all wildly different)
//   Call 2 → a full Recipe (ingredients + numbered steps w/ timers + notes)
// Plus local meal history so options stay fresh.
// ═══════════════════════════════════════════════════════════════════════

/// How many dinner options the chef proposes each time.
const int kOptionCount = 5;

/// One of the [kOptionCount] options the user picks from.
/// The dish forms the chef must choose from. Every option must use a
/// different one — this is what "genuinely different" means, mechanically.
// Everyday forms only. "braise", "stuffed or rolled" and "flatbread or pizza"
// came out — with different-forms enforced every night, the list itself
// decided how strange dinner got. It has to stay long enough that
// kOptionCount ordinary dinners can each take a different one.
const List<String> kDishForms = <String>[
  'sheet-pan',
  'stir-fry',
  'skillet',
  'bowl',
  'soup or stew',
  'salad-as-a-meal',
  'tacos or wraps',
  'pasta or noodles',
  'roast',
  'grill',
  'air fryer basket',
  'burger or patty',
  'meatballs',
  'casserole or bake',
  'curry',
];

class MealOption {
  final String title;
  final String desc;
  final String protein;
  final String form; // one of kDishForms (free text tolerated)
  final String cuisine; // e.g. "Mexican", "Thai", "American diner"
  final String sides; // the vegetable side (+ optional starch) on the plate
  final String newBuys; // "" or "No new buys" when all from pantry
  final double proteinPerServing;
  final double caloriesPerServing;
  final double estCostTotal; // estimated whole-meal cost (0 = not provided)
  final double estCostPerServing; // estimated cost per serving

  const MealOption({
    required this.title,
    required this.desc,
    required this.protein,
    this.form = '',
    this.cuisine = '',
    this.sides = '',
    required this.newBuys,
    required this.proteinPerServing,
    required this.caloriesPerServing,
    this.estCostTotal = 0,
    this.estCostPerServing = 0,
  });

  factory MealOption.fromJson(Map<String, dynamic> j) => MealOption(
        title: (j['title'] as String?)?.trim() ?? 'Untitled',
        desc: (j['desc'] as String?)?.trim() ?? '',
        protein: (j['protein'] as String?)?.trim() ?? '',
        form: (j['form'] as String?)?.trim() ?? '',
        cuisine: (j['cuisine'] as String?)?.trim() ?? '',
        sides: (j['sides'] as String?)?.trim() ?? '',
        newBuys: (j['newBuys'] as String?)?.trim() ?? '',
        proteinPerServing: _num(j['proteinPerServing']),
        caloriesPerServing: _num(j['caloriesPerServing']),
        estCostTotal: _num(j['estCostTotal']),
        estCostPerServing: _num(j['estCostPerServing']),
      );

  /// A short "form · cuisine" line for the option card ('' if unknown).
  String get shape {
    final List<String> parts = <String>[
      if (form.isNotEmpty) form,
      if (cuisine.isNotEmpty) cuisine,
    ];
    return parts.join(' · ');
  }
}

/// Normalises a free-text form/protein for comparison ("Sheet Pan" ==
/// "sheet-pan"; "chicken breast" and "chicken thighs" both == "chicken").
String _norm(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

const List<String> _kProteinHeads = <String>[
  'chicken', 'turkey', 'beef', 'steak', 'pork', 'lamb', 'salmon', 'tuna',
  'cod', 'tilapia', 'shrimp', 'fish', 'tofu', 'tempeh', 'egg', 'bean',
  'lentil', 'chickpea', 'sausage', 'ham', 'bacon',
];

String proteinFamily(String protein) {
  final String p = _norm(protein);
  for (final String h in _kProteinHeads) {
    if (p.contains(h)) {
      return h == 'steak' ? 'beef' : h;
    }
  }
  return p;
}

/// Dish forms that arrive at the table as the same dinner, however the label
/// differs. Three soups is what the user actually complained about, and the
/// form list alone never caught it: "soup or stew", "curry" and a brothy
/// "bowl" are three different labels and one identical plate. Anything not
/// named here is its own family.
const Map<String, String> _kFormFamilies = <String, String>{
  'soup or stew': 'a bowl of something simmered',
  'curry': 'a bowl of something simmered',
  'burger or patty': 'formed ground meat',
  'meatballs': 'formed ground meat',
  'stir fry': 'a hot pan of chopped things',
  'skillet': 'a hot pan of chopped things',
  'sheet pan': 'a tray in the oven',
  'casserole or bake': 'a tray in the oven',
};

/// The family [form] belongs to — itself, when it shares with nothing.
String formFamily(String form) {
  final String f = _norm(form);
  return _kFormFamilies[f] ?? f;
}

/// Why a set of options fails the "wildly different dinners" bar — '' when
/// the set is fine.
///
/// The axes are not equal, and that is deliberate:
///  • FORM is strict, judged by family: no two options may be the same KIND
///    of dinner. A stew and a curry are one dinner twice.
///  • CUISINE is strict: no two share one.
///  • PROTEIN may repeat — the user's call ("it is okay to share a protein").
///    Two chicken dinners that are genuinely different dishes are fine; all
///    of them on one protein is still one dinner in five hats.
String optionsSimilarity(List<MealOption> opts,
    {bool requireProteinVariety = true}) {
  if (opts.length < 2) {
    return '';
  }
  final List<String> proteins =
      opts.map((MealOption o) => proteinFamily(o.protein)).toList();
  final List<String> problems = <String>[
    _repeats(opts.map((MealOption o) => formFamily(o.form)).toList(), opts,
        'kind of dish'),
    _repeats(opts.map((MealOption o) => _norm(o.cuisine)).toList(), opts,
        'cuisine'),
    if (requireProteinVariety) _allShare(proteins, 'protein'),
  ].where((String s) => s.isNotEmpty).toList();
  return problems.join('; ');
}

/// '' unless EVERY option carries the same value on this axis. The weak bar,
/// used where repeats are allowed but a clean sweep is still one dinner.
String _allShare(List<String> values, String label) {
  if (values.length < 2 || values.any((String v) => v.isEmpty)) {
    return '';
  }
  return values.toSet().length == 1
      ? 'all of them share one $label (${values.first})'
      : '';
}

/// '' unless two or more options carry the same value on this axis — otherwise
/// it names them, so the retry knows exactly which dinner to swap out.
String _repeats(List<String> values, List<MealOption> opts, String label) {
  final Map<String, List<String>> byValue = <String, List<String>>{};
  for (int i = 0; i < values.length && i < opts.length; i++) {
    if (values[i].isEmpty) {
      continue; // an unlabelled axis can't be judged
    }
    byValue.putIfAbsent(values[i], () => <String>[]).add(opts[i].title);
  }
  final List<String> dups = <String>[];
  for (final MapEntry<String, List<String>> e in byValue.entries) {
    if (e.value.length > 1) {
      dups.add('${e.value.map((String t) => '"$t"').join(' and ')} '
          'share one $label (${e.key})');
    }
  }
  return dups.join('; ');
}

/// One ingredient row. [amount] is a display string ("300 g", "2", "1 tbsp");
/// the numeric prefix is what the servings stepper scales.
class RecipeIngredient {
  final String item;
  final String amount;
  const RecipeIngredient({required this.item, required this.amount});

  factory RecipeIngredient.fromJson(Map<String, dynamic> j) => RecipeIngredient(
        item: (j['item'] as String?)?.trim() ?? '',
        amount: (j['amount'] as String?)?.trim() ?? '',
      );

  Map<String, dynamic> toJson() => <String, dynamic>{'item': item, 'amount': amount};

  /// This amount rescaled by [factor], keeping the unit text.
  String scaled(double factor) => _scaleAmount(amount, factor);
}

/// One numbered step. [timerSeconds] > 0 means the step has a countdown.
class RecipeStep {
  final String title;
  final String content;
  final int timerSeconds;
  const RecipeStep({
    required this.title,
    required this.content,
    this.timerSeconds = 0,
  });

  bool get hasTimer => timerSeconds > 0;

  factory RecipeStep.fromJson(Map<String, dynamic> j) => RecipeStep(
        title: (j['title'] as String?)?.trim() ?? '',
        content: (j['content'] as String?)?.trim() ?? '',
        timerSeconds: (j['timerSeconds'] as num?)?.round() ?? 0,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'content': content,
        'timerSeconds': timerSeconds,
      };
}

/// A full recipe. [baseServings] is what the API was asked to write for;
/// the stepper scales everything relative to it.
class Recipe {
  final String title;
  final String description;
  final List<RecipeIngredient> ingredients;
  final List<RecipeStep> steps;
  final String notes;
  final int baseServings;
  final double estCostTotal; // estimated cost of the whole recipe (0 = none)
  final double estCostPerServing; // estimated cost per serving
  final double estGroceryCost; // estimated cost of the NEW BUYS only (the trip)

  const Recipe({
    required this.title,
    required this.description,
    required this.ingredients,
    required this.steps,
    required this.notes,
    required this.baseServings,
    this.estCostTotal = 0,
    this.estCostPerServing = 0,
    this.estGroceryCost = 0,
  });

  factory Recipe.fromJson(Map<String, dynamic> j, {required int baseServings}) =>
      Recipe(
        title: (j['title'] as String?)?.trim() ?? 'Recipe',
        description: (j['description'] as String?)?.trim() ?? '',
        ingredients: ((j['ingredients'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(RecipeIngredient.fromJson)
            .toList(),
        steps: ((j['steps'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(RecipeStep.fromJson)
            .toList(),
        notes: (j['notes'] as String?)?.trim() ?? '',
        baseServings: baseServings,
        estCostTotal: _num(j['estCostTotal']),
        estCostPerServing: _num(j['estCostPerServing']),
        estGroceryCost: _num(j['estGroceryCost']),
      );

  /// Rebuild a Recipe from its own stored JSON (baseServings lives in the map).
  factory Recipe.fromStored(Map<String, dynamic> j) =>
      Recipe.fromJson(j, baseServings: (j['baseServings'] as num?)?.round() ?? 2);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'title': title,
        'description': description,
        'ingredients':
            ingredients.map((RecipeIngredient e) => e.toJson()).toList(),
        'steps': steps.map((RecipeStep e) => e.toJson()).toList(),
        'notes': notes,
        'baseServings': baseServings,
        'estCostTotal': estCostTotal,
        'estCostPerServing': estCostPerServing,
        'estGroceryCost': estGroceryCost,
      };
}

// ── recipe box ────────────────────────────────────────────────────────────

/// A recipe kept on purpose. Saved only when the user taps save, so the box
/// holds the keepers rather than everything the chef ever produced.
class SavedRecipe {
  final int savedAtMs; // stable id
  final Recipe recipe;
  final int servings; // the size it was cooked at
  final bool favourite;
  final int timesCooked;

  const SavedRecipe({
    required this.savedAtMs,
    required this.recipe,
    required this.servings,
    this.favourite = false,
    this.timesCooked = 0,
  });

  String get id => savedAtMs.toString();

  SavedRecipe copyWith({bool? favourite, int? timesCooked, int? servings}) =>
      SavedRecipe(
        savedAtMs: savedAtMs,
        recipe: recipe,
        servings: servings ?? this.servings,
        favourite: favourite ?? this.favourite,
        timesCooked: timesCooked ?? this.timesCooked,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'savedAtMs': savedAtMs,
        'servings': servings,
        if (favourite) 'favourite': true,
        if (timesCooked > 0) 'timesCooked': timesCooked,
        'recipe': recipe.toJson(),
      };

  factory SavedRecipe.fromJson(Map<String, dynamic> j) => SavedRecipe(
        savedAtMs: (j['savedAtMs'] as num?)?.round() ?? 0,
        recipe: Recipe.fromStored((j['recipe'] as Map).cast<String, dynamic>()),
        servings: (j['servings'] as num?)?.round() ?? 2,
        favourite: j['favourite'] == true,
        timesCooked: (j['timesCooked'] as num?)?.round() ?? 0,
      );
}

/// The whole box. Favourites float to the top, then most recently saved.
class RecipeBox {
  final List<SavedRecipe> recipes;
  const RecipeBox([this.recipes = const <SavedRecipe>[]]);

  List<SavedRecipe> get sorted {
    final List<SavedRecipe> out = List<SavedRecipe>.of(recipes);
    out.sort((SavedRecipe a, SavedRecipe b) {
      if (a.favourite != b.favourite) {
        return a.favourite ? -1 : 1;
      }
      return b.savedAtMs.compareTo(a.savedAtMs);
    });
    return out;
  }

  /// Already in the box? Matched on title so re-cooking the same dish doesn't
  /// silently create a duplicate entry.
  bool has(String title) => recipes.any((SavedRecipe r) =>
      r.recipe.title.trim().toLowerCase() == title.trim().toLowerCase());

  String encode() => jsonEncode(<String, dynamic>{
        'recipes': recipes.map((SavedRecipe r) => r.toJson()).toList(),
      });

  static RecipeBox decode(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) {
      return const RecipeBox();
    }
    try {
      final dynamic d = jsonDecode(jsonStr);
      if (d is Map<String, dynamic>) {
        return RecipeBox(((d['recipes'] as List<dynamic>?) ?? <dynamic>[])
            .whereType<Map<String, dynamic>>()
            .map(SavedRecipe.fromJson)
            .toList());
      }
    } catch (_) {}
    return const RecipeBox();
  }
}

// ── planned meals ("On the menu") ─────────────────────────────────────────

/// A recipe the user picked ahead of time and is holding onto so they can
/// shop for it and cook it later. Persists (survives restarts) until cooked.
/// [checked] is parallel to [recipe.ingredients] — the shopping-list ticks.
class PlannedMeal {
  final int createdAtMs; // also the stable id
  final Recipe recipe;
  final int servings;
  final List<bool> checked;

  const PlannedMeal({
    required this.createdAtMs,
    required this.recipe,
    required this.servings,
    required this.checked,
  });

  String get id => createdAtMs.toString();

  double get factor =>
      recipe.baseServings == 0 ? 1 : servings / recipe.baseServings;

  int get total => recipe.ingredients.length;
  int get gathered => checked.where((bool b) => b).length;
  bool get allGathered => total > 0 && gathered == total;

  PlannedMeal copyWith({int? servings, List<bool>? checked}) => PlannedMeal(
        createdAtMs: createdAtMs,
        recipe: recipe,
        servings: servings ?? this.servings,
        checked: checked ?? this.checked,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'createdAtMs': createdAtMs,
        'servings': servings,
        'checked': checked,
        'recipe': recipe.toJson(),
      };

  factory PlannedMeal.fromJson(Map<String, dynamic> j) {
    final Recipe r =
        Recipe.fromStored((j['recipe'] as Map).cast<String, dynamic>());
    final List<dynamic> c = (j['checked'] as List<dynamic>?) ?? const <dynamic>[];
    // Normalise the tick list to the ingredient count so a schema drift or a
    // hand-edited file can't throw or leave a dangling checkbox.
    final List<bool> checked = List<bool>.generate(
        r.ingredients.length, (int i) => i < c.length && c[i] == true);
    return PlannedMeal(
      createdAtMs: (j['createdAtMs'] as num?)?.round() ?? 0,
      recipe: r,
      servings: (j['servings'] as num?)?.round() ?? r.baseServings,
      checked: checked,
    );
  }
}

/// The whole "On the menu" list, newest last. Encodes/decodes defensively so
/// a bad file just yields an empty menu instead of bricking the Cook tab.
class PlannedMenu {
  final List<PlannedMeal> meals;
  const PlannedMenu(this.meals);

  String encode() => jsonEncode(<String, dynamic>{
        'meals': meals.map((PlannedMeal m) => m.toJson()).toList(),
      });

  static PlannedMenu decode(String? s) {
    if (s == null || s.isEmpty) {
      return const PlannedMenu(<PlannedMeal>[]);
    }
    try {
      final dynamic d = jsonDecode(s);
      final List<dynamic> m = (d is Map ? d['meals'] : d) as List<dynamic>;
      return PlannedMenu(m
          .whereType<Map>()
          .map((Map e) => PlannedMeal.fromJson(e.cast<String, dynamic>()))
          .toList());
    } catch (_) {
      return const PlannedMenu(<PlannedMeal>[]);
    }
  }
}

// ── meal history ─────────────────────────────────────────────────────────

/// The seed history from the master spec — meals never to repeat until they
/// age out of the recent window.
const List<String> kSeedMealHistory = <String>[
  'Sesame Cauliflower & Egg Stir-Fry',
  'Egg Drop Soup with Tofu & Green Onions',
  'Korean-Style Beef & Egg Rice Bowl',
  'Turkey Bolognese over Miracle Noodle Spaghetti',
  'Air Fryer Turkey Meatballs with Roasted Potato Wedges',
  'Oven-Baked Turkey Meatloaf Muffins with Garlic Mashed Potatoes',
  'Cheesy Chicken & Veggie Skillet over Miracle Noodle Angel Hair',
  'Cheesy Beef & Veggie Baked Miracle Noodle Fettuccine',
  'Beef Teriyaki Bowl over Miracle Noodle Angel Hair',
  'Glazed Turkey Meatballs with Crispy Smashed Potatoes',
  'Glazed Turkey Burger Patties with Air Fryer Potato Fries',
  'Bunless Beef Smash Burgers with Air Fryer Potato Fries',
  'Beef Stroganoff over Miracle Noodle Fettuccine',
  'Cube Steak & Egg Rice Bowl',
  'Creamy Garlic Chicken & Potatoes',
  'Turkey Meatball Parmesan over Miracle Noodle Spaghetti',
  'Crispy Parmesan Chicken Tenders with Air Fryer Potato Wedges',
  'Air Fryer Breaded Tofu Nuggets with Potato Wedges',
  'Beef & Cream Cheese Stuffed Bell Peppers',
  'Salisbury Steak with Mushroom Gravy & Mashed Potatoes',
  'Turkey Lettuce Wrap Bowls',
  'Breaded Cube Steak with Mashed Potatoes & Roasted Asparagus',
  'Sesame Chicken Egg Drop Ramen',
  'Classic Loaded Beef Stuffed Potatoes',
  'Street-Style Ground Beef Tacos (Buffet)',
  'Egg Foo Young',
  'Ground Beef & Sweet Potato Skillet with Kale',
  'Orange Chicken with Roasted Sweet Potatoes',
  'Beef Carbonara over Miracle Noodle Spaghetti',
  'Everything-Crusted Pigs in a Blanket with 3 Dips',
];

/// Local history store — the most recent [cap] cooked meals feed Call 1.
class MealHistory {
  final List<String> meals; // newest last
  const MealHistory(this.meals);

  static const int cap = 40;

  List<String> recent({int n = 30}) =>
      meals.length <= n ? meals : meals.sublist(meals.length - n);

  /// What he's been eating a LOT of lately, read off the last [n] titles —
  /// "meatballs ×3, sheet-pan ×2, chicken ×5". Anything seen twice or more
  /// is worth steering away from. Ordered most-frequent first.
  List<String> frequentShapes({int n = 12}) {
    final List<String> tail = recent(n: n);
    final Map<String, int> counts = <String, int>{};
    void bump(String k) => counts[k] = (counts[k] ?? 0) + 1;
    for (final String title in tail) {
      final String t = title.toLowerCase();
      for (final String form in kDishForms) {
        final String key = form.split(' ').first.replaceAll('-', ' ');
        // "sheet-pan" → "sheet pan"; "tacos or wraps" → "tacos"; "bowl".
        final List<String> probes = <String>[
          key,
          key.replaceAll(' ', '-'),
          if (key.endsWith('s')) key.substring(0, key.length - 1),
        ];
        if (probes.any((String p) => p.length > 2 && t.contains(p))) {
          bump(form);
        }
      }
      final String fam = proteinFamily(t);
      if (fam.isNotEmpty && fam != t) {
        bump(fam);
      }
    }
    final List<MapEntry<String, int>> hot = counts.entries
        .where((MapEntry<String, int> e) => e.value >= 2)
        .toList()
      ..sort((MapEntry<String, int> a, MapEntry<String, int> b) =>
          b.value.compareTo(a.value));
    return <String>[for (final MapEntry<String, int> e in hot) '${e.key} ×${e.value}'];
  }

  MealHistory withCooked(String title) {
    final List<String> next = <String>[
      ...meals.where((String m) => m.toLowerCase() != title.toLowerCase()),
      title,
    ];
    final List<String> trimmed =
        next.length <= cap ? next : next.sublist(next.length - cap);
    return MealHistory(trimmed);
  }

  String encode() => jsonEncode(<String, dynamic>{'meals': meals});

  static MealHistory decode(String? s) {
    if (s == null || s.isEmpty) {
      return const MealHistory(kSeedMealHistory);
    }
    try {
      final dynamic d = jsonDecode(s);
      final List<dynamic> m = (d is Map ? d['meals'] : d) as List<dynamic>;
      return MealHistory(m.map((dynamic e) => e.toString()).toList());
    } catch (_) {
      return const MealHistory(kSeedMealHistory);
    }
  }
}

// ── helpers ────────────────────────────────────────────────────────────

double _num(dynamic v) {
  if (v is num) {
    return v.toDouble();
  }
  if (v is String) {
    return double.tryParse(v.replaceAll(RegExp(r'[^0-9.]'), '')) ?? 0;
  }
  return 0;
}

/// Scale the leading number in an amount string, keeping the unit text.
/// Weight/volume (g, ml, tbsp…) round to whole; count-like (eggs, cloves)
/// round to the nearest half so you don't get "0.37 egg".
String _scaleAmount(String amount, double factor) {
  final RegExpMatch? m = RegExp(r'^\s*(\d+(?:\.\d+)?)').firstMatch(amount);
  if (m == null) {
    return amount; // "to taste", "a pinch" — leave as-is
  }
  final double base = double.tryParse(m.group(1)!) ?? 0;
  final String rest = amount.substring(m.end); // unit + any extra text
  final double v = base * factor;
  final String unit = rest.toLowerCase();
  final bool weightOrVolume = RegExp(
          r'\b(g|kg|ml|l|gram|tbsp|tsp|cup|oz)\b|^\s*g\b|^\s*ml\b')
      .hasMatch(unit);
  final double rounded = weightOrVolume
      ? v.roundToDouble()
      : (v * 2).roundToDouble() / 2; // nearest 0.5 for counts
  final String num = rounded == rounded.roundToDouble()
      ? rounded.toInt().toString()
      : rounded.toStringAsFixed(1);
  return '$num$rest';
}
