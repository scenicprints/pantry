import 'chef_models.dart';

// ═══════════════════════════════════════════════════════════════════════
// SPOONS AND PIECES INTO GRAMS.
//
// The scale is the only thing at the counter that tells the truth, and this
// app records what the scale said. So every row that can be weighed has to
// ask for grams, whatever words the recipe used.
//
// The chef is told to write grams for anything that pours or scoops. It has
// been told twice now and still comes back with "1 tbsp olive oil", and a
// recipe saved to the box weeks ago keeps its tablespoons forever however
// well the prompt behaves afterwards. A rule the app depends on but cannot
// enforce is not a rule, so the conversion lives here instead.
//
// WHAT IS NOT CONVERTED. Salt, pepper and dried ground spices stay in spoons,
// because nobody weighs a pinch of cumin and he has said so plainly. Eggs and
// the other things that genuinely come in pieces stay as counts.
//
// These are estimates, and the number in the field is only a starting point:
// he tares, weighs, and what he types replaces it. An estimate he can correct
// beats a blank box he has to guess at. Where there is no honest answer this
// returns null and the box stays blank rather than inventing one.
// ═══════════════════════════════════════════════════════════════════════

/// Grams in one tablespoon, by what the food is. Three teaspoons to the
/// tablespoon, sixteen tablespoons to the cup.
const Map<String, double> _perTbsp = <String, double>{
  'oil': 13.6,
  'butter': 14.2,
  'honey': 21.0,
  'syrup': 20.0,
  'molasses': 20.0,
  'tahini': 15.0,
  'peanut butter': 16.0,
  'almond butter': 16.0,
  'nut butter': 16.0,
  'tomato paste': 16.0,
  'paste': 16.0,
  'soy sauce': 16.0,
  'fish sauce': 18.0,
  'vinegar': 14.9,
  'lemon juice': 15.0,
  'lime juice': 15.0,
  'juice': 15.0,
  'mustard': 15.0,
  'ketchup': 17.0,
  'mayonnaise': 13.8,
  'yogurt': 15.3,
  'sour cream': 14.4,
  'cream': 15.0,
  'milk': 15.3,
  'stock': 15.0,
  'broth': 15.0,
  'water': 14.8,
  'minced garlic': 9.0,
  'garlic': 8.5,
  'ginger': 6.0,
  'flour': 8.0,
  'cornstarch': 8.0,
  'sugar': 12.5,
  'breadcrumb': 6.8,
  'panko': 3.8,
  'oat': 5.0,
  'rice': 11.5,
  'parmesan': 5.0,
  'cheese': 7.0,
};

/// A dried seasoning, which stays in spoons. These are the seasonings
/// themselves, never a food that happens to be sold ground.
const List<String> _seasonings = <String>[
  'salt',
  'pepper',
  'paprika',
  'cumin',
  'coriander',
  'oregano',
  'thyme',
  'rosemary',
  'basil',
  'sage',
  'cinnamon',
  'nutmeg',
  'allspice',
  'cardamom',
  'turmeric',
  'curry powder',
  'cayenne',
  'chilli',
  'chili flake',
  'red pepper flake',
  'garlic powder',
  'onion powder',
  'mustard powder',
  'dried',
  'seasoning',
  'spice',
  'baking powder',
  'baking soda',
  'yeast',
  'extract',
];

/// Grams for one of a thing, where "one" is a sensible medium.
const Map<String, double> _perPiece = <String, double>{
  'garlic clove': 3.0,
  'clove garlic': 3.0,
  'shallot': 40.0,
  'onion': 110.0,
  'scallion': 15.0,
  'green onion': 15.0,
  'spring onion': 15.0,
  'bell pepper': 119.0,
  'carrot': 61.0,
  'celery stalk': 40.0,
  'celery': 40.0,
  'tomato': 123.0,
  'potato': 173.0,
  'sweet potato': 130.0,
  'zucchini': 196.0,
  'courgette': 196.0,
  'cucumber': 200.0,
  'lemon': 58.0,
  'lime': 67.0,
  'orange': 131.0,
  'apple': 182.0,
  'banana': 118.0,
  'avocado': 150.0,
  'jalapeno': 14.0,
  'mushroom': 18.0,
  'chicken breast': 174.0,
  'chicken thigh': 82.0,
};

/// Things that stay a count, because a count is how anyone would say it.
const List<String> _countedAnyway = <String>[
  'egg',
  'tortilla',
  'bun',
  'roll',
  'slice',
  'sheet',
  'wrap',
  'pita',
  'naan',
  'bay leaf',
  'skewer',
  'can',
  'jar',
  'packet',
];

String _norm(String s) => s.toLowerCase().replaceAll(RegExp('[^a-z ]+'), ' ');

bool _mentions(String item, Iterable<String> words) {
  final String n = ' ${_norm(item)} ';
  return words.any((String w) => n.contains(' $w'));
}

/// True when this ingredient is a dried seasoning, so spoons are right and
/// weighing it would be the wrong thing to ask for.
bool isSeasoning(String item) => _mentions(item, _seasonings);

/// True when a count is the honest way to say it.
bool staysACount(String item) => _mentions(item, _countedAnyway);

/// The longest key that appears in [item] wins, so "minced garlic" beats
/// "garlic" and "tomato paste" beats "paste".
double? _lookup(String item, Map<String, double> table) {
  final String n = _norm(item);
  double? best;
  int longest = -1;
  for (final MapEntry<String, double> e in table.entries) {
    if (n.contains(e.key) && e.key.length > longest) {
      longest = e.key.length;
      best = e.value;
    }
  }
  return best;
}

/// What [amount] of [item] weighs, or null when there is no honest answer.
double? gramsFor(String item, String amount) {
  if (isGramAmount(amount)) {
    return amountValue(amount);
  }
  final double? n = amountValue(amount);
  if (n == null || n <= 0) {
    return null; // "to taste", "a pinch"
  }
  final String unit = _norm(amountUnit(amount)).trim();

  double? spoons;
  if (RegExp('^(tbsp|tablespoon|tablespoons|tbs|tb)').hasMatch(unit)) {
    spoons = n;
  } else if (RegExp('^(tsp|teaspoon|teaspoons)').hasMatch(unit)) {
    spoons = n / 3;
  } else if (RegExp('^(cup|cups)').hasMatch(unit)) {
    spoons = n * 16;
  }
  if (spoons != null) {
    if (isSeasoning(item)) {
      return null; // nobody weighs the cumin
    }
    final double? perTbsp = _lookup(item, _perTbsp);
    return perTbsp == null ? null : _round(spoons * perTbsp);
  }

  // Millilitres, close enough to grams for anything he cooks with.
  if (RegExp('^(ml|millilitre|millilitres|milliliter|milliliters)')
      .hasMatch(unit)) {
    final double? perTbsp = _lookup(item, _perTbsp);
    return _round(n * (perTbsp == null ? 1.0 : perTbsp / 14.8));
  }
  if (RegExp('^(kg|kilo|kilos|kilogram|kilograms)').hasMatch(unit)) {
    return _round(n * 1000);
  }
  if (RegExp('^(oz|ounce|ounces)').hasMatch(unit)) {
    return _round(n * 28.35);
  }
  if (RegExp('^(lb|lbs|pound|pounds)').hasMatch(unit)) {
    return _round(n * 453.6);
  }

  // A bare count, or a piece word like "cloves" or "medium".
  final bool bareOrPiece = unit.isEmpty ||
      RegExp('^(clove|cloves|piece|pieces|medium|large|small|whole|'
              'head|heads|stalk|stalks|sprig|sprigs)')
          .hasMatch(unit);
  if (!bareOrPiece || staysACount(item)) {
    return null;
  }
  final double? each =
      _lookup('$unit $item', _perPiece) ?? _lookup(item, _perPiece);
  return each == null ? null : _round(n * each);
}

double _round(double g) =>
    g >= 100 ? g.roundToDouble() : (g * 10).roundToDouble() / 10;
