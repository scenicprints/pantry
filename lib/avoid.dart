// ═══════════════════════════════════════════════════════════════════════
// AVOID ENFORCEMENT — the app-side half of the avoid list.
//
// The list used to be prompt-only, and the model read it literally: with
// "All seafood" on the list it still offered salmon and cod, because neither
// word was on the list. Categories now expand to their members, both in the
// prompt (so the model is told) and here (so a violation is caught and the
// option is thrown out whatever the model says).
//
// The matching is deliberately narrow. Over-blocking is the other failure
// mode — the chef used to invent its own restrictions — so terms match on
// word boundaries only, and a qualifier in front of a term ("turkey bacon",
// "almond milk", "peanut butter") means it is not that food.
// ═══════════════════════════════════════════════════════════════════════

import 'chef_models.dart';

/// One avoided food found in text the user was about to be shown.
class AvoidHit {
  /// What the user typed, e.g. "All seafood".
  final String entry;

  /// What was actually found, e.g. "salmon".
  final String term;

  const AvoidHit({required this.entry, required this.term});

  @override
  String toString() => term.toLowerCase() == entry.toLowerCase().trim()
      ? term
      : '$term (on the AVOID list as "$entry")';
}

/// A category a user might type as one line, and everything it covers.
class _AvoidCategory {
  /// Words that, in the user's entry, mean they meant this category.
  final List<String> triggers;

  /// The foods the category rules out.
  final List<String> members;

  /// Words that cancel a match when they sit right in front of the term.
  final List<String> qualifiers;

  const _AvoidCategory({
    required this.triggers,
    required this.members,
    this.qualifiers = kStdQualifiers,
  });
}

/// "turkey bacon" is not pork; "almond milk" is not dairy.
const List<String> kStdQualifiers = <String>[
  'turkey', 'chicken', 'beef', 'plant', 'plant based', 'vegan', 'veggie',
  'vegetarian', 'tofu', 'soy', 'almond', 'oat', 'coconut', 'cashew', 'rice',
  'peanut', 'sunflower', 'nut', 'seed', 'mock', 'imitation', 'faux', 'apple',
  'cocoa', 'shea', 'gluten free', 'dairy free', 'meatless',
];

/// Seafood leaves "imitation" out of its qualifiers on purpose — imitation
/// crab is fish.
const List<String> _kPlantQualifiers = <String>[
  'plant', 'plant based', 'vegan', 'vegetarian', 'mock', 'faux', 'meatless',
];

const List<_AvoidCategory> _kAvoidCategories = <_AvoidCategory>[
  _AvoidCategory(
    triggers: <String>['seafood', 'fish', 'shellfish'],
    qualifiers: _kPlantQualifiers,
    members: <String>[
      'seafood', 'fish', 'shellfish', 'salmon', 'tuna', 'cod', 'halibut',
      'tilapia', 'trout', 'sea bass', 'snapper', 'mahi mahi', 'mahi',
      'grouper', 'flounder', 'pollock', 'haddock', 'catfish', 'swordfish',
      'mackerel', 'herring', 'sardine', 'anchovy', 'anchovies', 'shrimp',
      'prawn', 'crab', 'lobster', 'crawfish', 'crayfish', 'scallop', 'clam',
      'mussel', 'oyster', 'squid', 'calamari', 'octopus', 'surimi', 'roe',
      'caviar', 'bonito', 'dashi', 'lox',
    ],
  ),
  _AvoidCategory(
    triggers: <String>['pork', 'pig'],
    members: <String>[
      'pork', 'bacon', 'ham', 'prosciutto', 'pancetta', 'guanciale', 'chorizo',
      'salami', 'pepperoni', 'capicola', 'speck', 'lardon', 'lard',
      'bratwurst', 'andouille', 'mortadella', 'carnitas', 'chicharron',
    ],
  ),
  _AvoidCategory(
    triggers: <String>['red meat'],
    members: <String>[
      'red meat', 'beef', 'steak', 'brisket', 'lamb', 'mutton', 'veal',
      'venison', 'bison', 'goat', 'oxtail', 'short rib', 'pork', 'bacon',
      'ham', 'prosciutto', 'chorizo', 'salami', 'pepperoni',
    ],
  ),
  _AvoidCategory(
    triggers: <String>['poultry'],
    members: <String>[
      'poultry', 'chicken', 'turkey', 'duck', 'goose', 'quail', 'cornish hen',
    ],
  ),
  _AvoidCategory(
    triggers: <String>['dairy', 'lactose'],
    members: <String>[
      'dairy', 'milk', 'cream', 'creme fraiche', 'half and half', 'butter',
      'buttermilk', 'ghee', 'cheese', 'cheddar', 'mozzarella', 'parmesan',
      'feta', 'gouda', 'brie', 'ricotta', 'mascarpone', 'provolone', 'gruyere',
      'yogurt', 'yoghurt', 'sour cream', 'custard', 'ice cream', 'whey',
      'casein', 'queso',
    ],
  ),
  _AvoidCategory(
    triggers: <String>['spicy', 'spice', 'hot food', 'chili', 'chile'],
    qualifiers: <String>['bell', 'sweet', 'black', 'white', 'mild'],
    members: <String>[
      'spicy', 'hot sauce', 'chili', 'chile', 'chilli', 'chili powder',
      'chili flake', 'chili oil', 'chili paste', 'cayenne', 'jalapeno',
      'habanero', 'serrano', 'chipotle', 'sriracha', 'gochujang', 'gochugaru',
      'harissa', 'sambal', 'togarashi', 'peri peri', 'piri piri',
      'ghost pepper', 'scotch bonnet', 'crushed red pepper', 'pepper flake',
      'red pepper flake', 'hot pepper', 'arbol', 'guajillo',
    ],
  ),
  _AvoidCategory(
    triggers: <String>['nut', 'nuts', 'tree nut'],
    qualifiers: <String>['water', 'butter', 'pine', 'nut'],
    members: <String>[
      'nut', 'almond', 'cashew', 'walnut', 'pecan', 'pistachio', 'hazelnut',
      'macadamia', 'brazil nut', 'peanut', 'pine nut', 'nutella', 'praline',
      'marzipan',
    ],
  ),
  _AvoidCategory(
    triggers: <String>['gluten', 'wheat'],
    qualifiers: <String>[
      'rice', 'almond', 'corn', 'coconut', 'chickpea', 'cassava', 'oat',
      'gluten free', 'buckwheat', 'shirataki', 'miracle',
    ],
    members: <String>[
      'gluten', 'wheat', 'flour', 'bread', 'breadcrumb', 'panko', 'pasta',
      'noodle', 'orzo', 'couscous', 'barley', 'rye', 'farro', 'bulgur',
      'semolina', 'seitan', 'tortilla', 'pita', 'naan', 'cracker', 'crouton',
    ],
  ),
  _AvoidCategory(
    triggers: <String>['mushroom', 'fungi'],
    members: <String>[
      'mushroom', 'shiitake', 'portobello', 'portabella', 'cremini', 'porcini',
      'enoki', 'chanterelle', 'truffle',
    ],
  ),
  _AvoidCategory(
    triggers: <String>['egg', 'eggs'],
    qualifiers: <String>['flax', 'chia', 'plant', 'vegan'],
    members: <String>[
      'egg', 'omelet', 'omelette', 'frittata', 'mayonnaise', 'mayo',
      'meringue', 'aioli',
    ],
  ),
  _AvoidCategory(
    triggers: <String>['alcohol', 'booze'],
    members: <String>[
      'alcohol', 'wine', 'beer', 'rum', 'whiskey', 'whisky', 'bourbon',
      'vodka', 'brandy', 'sherry', 'sake', 'mirin', 'vermouth', 'tequila',
      'liqueur',
    ],
  ),
  _AvoidCategory(
    triggers: <String>['soy'],
    members: <String>[
      'soy', 'soy sauce', 'soybean', 'tofu', 'tempeh', 'edamame', 'miso',
      'tamari', 'ponzu', 'hoisin',
    ],
  ),
];

/// Lowercase, letters and spaces only — the form everything is matched in.
String _flat(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z]+'), ' ')
    .trim()
    .replaceAll(RegExp(r'\s+'), ' ');

/// Everything one avoid entry rules out, the entry itself included. "All
/// seafood" comes back as the whole seafood list; "Yogurt" comes back as
/// just yogurt.
List<String> expandAvoid(String entry) {
  final String flat = _flat(entry);
  if (flat.isEmpty) {
    return const <String>[];
  }
  final List<String> out = <String>[flat];
  for (final _AvoidCategory c in _kAvoidCategories) {
    if (c.triggers.any((String t) => _hasWord(flat, t))) {
      for (final String m in c.members) {
        if (!out.contains(m)) {
          out.add(m);
        }
      }
    }
  }
  // "All seafood" is not itself a food — once the category it names has
  // supplied real terms, the raw entry only ever matches itself.
  if (out.length > 1 && RegExp(r'^(all|any|no|non|every)\b').hasMatch(flat)) {
    out.removeAt(0);
  }
  return out;
}

/// The qualifiers that apply to [entry] — per category, so "imitation crab"
/// still counts as seafood while "turkey bacon" does not count as pork.
List<String> _qualifiersFor(String entry) {
  final String flat = _flat(entry);
  for (final _AvoidCategory c in _kAvoidCategories) {
    if (c.triggers.any((String t) => _hasWord(flat, t))) {
      return c.qualifiers;
    }
  }
  return kStdQualifiers;
}

/// [term] appears in [text] as a whole word (plural tolerated).
bool _hasWord(String text, String term) => _wordMatches(text, term).isNotEmpty;

/// Every whole-word occurrence of [term] in [text]. Both must already be
/// flattened.
List<RegExpMatch> _wordMatches(String text, String term) {
  final String t = _flat(term);
  if (t.isEmpty) {
    return const <RegExpMatch>[];
  }
  final RegExp re = RegExp(r'\b' + RegExp.escape(t) + r'(e?s)?\b');
  return re.allMatches(text).toList();
}

/// Words that cancel a term whatever the category, because they mean the
/// food is absent rather than present ("no salmon", "shellfish free").
const List<String> _kNegatedBefore = <String>[
  'no', 'not', 'without', 'skip', 'hold', 'free', 'sub', 'instead of',
  'replaces', 'replacing', 'avoid', 'avoids', 'avoiding',
];
const List<String> _kNegatedAfter = <String>['free', 'alternative',
  'substitute', 'allergy'];

/// Is [m] cancelled by the words around it — a qualifier in front
/// ("turkey bacon", "almond milk", "peanut butter") or a negation on either
/// side ("no salmon", "shellfish free")?
bool _isCancelled(String text, RegExpMatch m, List<String> qualifiers) {
  final String before = text.substring(0, m.start).trimRight();
  for (final String q in <String>[...qualifiers, ..._kNegatedBefore]) {
    if (before == q || before.endsWith(' $q')) {
      return true;
    }
  }
  final String after = text.substring(m.end).trimLeft();
  for (final String q in _kNegatedAfter) {
    if (after == q || after.startsWith('$q ')) {
      return true;
    }
  }
  return false;
}

/// Every avoided food named in [text]. Empty means clean.
List<AvoidHit> textAvoidHits(String text, List<String> avoids) {
  final String flat = _flat(text);
  if (flat.isEmpty) {
    return const <AvoidHit>[];
  }
  final List<AvoidHit> hits = <AvoidHit>[];
  for (final String entry in avoids) {
    if (entry.trim().isEmpty) {
      continue;
    }
    final List<String> qualifiers = _qualifiersFor(entry);
    for (final String term in expandAvoid(entry)) {
      final bool real = _wordMatches(flat, term)
          .any((RegExpMatch m) => !_isCancelled(flat, m, qualifiers));
      if (real && !hits.any((AvoidHit h) => h.term == term)) {
        hits.add(AvoidHit(entry: entry.trim(), term: term));
      }
    }
  }
  return hits;
}

/// Everything on an option card the user would read — a hit anywhere in it
/// is the chef offering an avoided food.
List<AvoidHit> optionAvoidHits(MealOption o, List<String> avoids) =>
    textAvoidHits(
      <String>[o.title, o.desc, o.protein, o.sides, o.newBuys].join(' . '),
      avoids,
    );

/// The same check across a whole set of options.
List<AvoidHit> optionsAvoidHits(List<MealOption> opts, List<String> avoids) {
  final List<AvoidHit> all = <AvoidHit>[];
  for (final MealOption o in opts) {
    for (final AvoidHit h in optionAvoidHits(o, avoids)) {
      if (!all.any((AvoidHit x) => x.term == h.term)) {
        all.add(h);
      }
    }
  }
  return all;
}

/// A recipe's ingredients and method — checked because call 2 can smuggle in
/// what call 1 kept out (an anchovy in the dressing).
List<AvoidHit> recipeAvoidHits(Recipe r, List<String> avoids) => textAvoidHits(
      <String>[
        r.title,
        r.description,
        ...r.ingredients.map((RecipeIngredient i) => i.item),
        ...r.steps.map((RecipeStep s) => '${s.title} ${s.content}'),
        r.notes,
      ].join(' . '),
      avoids,
    );

/// The line handed back to the model when it broke the list.
String avoidComplaint(List<AvoidHit> hits) {
  if (hits.isEmpty) {
    return '';
  }
  return 'you used ${hits.map((AvoidHit h) => h.toString()).join(', ')}, '
      'which the user avoids';
}

/// The avoid list as the prompt should carry it: each entry with the terms
/// its category covers, so the model cannot read "All seafood" as a phrase
/// that happens not to include salmon.
String formatAvoidsForPrompt(List<String> avoids) {
  final List<String> live =
      avoids.where((String a) => a.trim().isNotEmpty).toList();
  if (live.isEmpty) {
    return '(nothing — no food is off limits beyond the allergy above)';
  }
  final StringBuffer sb = StringBuffer();
  for (final String entry in live) {
    final String name = entry.trim();
    final List<String> terms = expandAvoid(entry)
        .where((String t) => t != _flat(entry))
        .toList();
    if (terms.isEmpty) {
      sb.writeln('- $name');
    } else {
      sb.writeln('- $name — covers every member of that group, including: '
          '${terms.join(', ')}');
    }
  }
  return sb.toString().trimRight();
}
