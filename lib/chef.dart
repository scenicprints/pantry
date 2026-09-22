import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'avoid.dart';
import 'chef_models.dart';
import 'liver.dart';
import 'models.dart';
import 'pricebook.dart';

// ═══════════════════════════════════════════════════════════════════════
// AI CHEF — talks to the Claude API directly from the phone.
//
// Two-call flow (kept separate on purpose — see the master spec):
//   Call 1  generateOptions() → kOptionCount wildly different options
//   Call 2  generateRecipe()  → the full grams-based recipe
//
// Model default: claude-haiku-4-5 (cheap, plenty for this). Optional
// claude-sonnet-4-6 and claude-opus-5 toggles. Opus 5 replaced opus-4-8 at
// the same price per token, so the top slot got better for nothing.
//
// The fixed rules ride in the cached system block; the live pantry + history
// + servings are the per-call user message.
//
// The API key is entered once in Settings and stored encrypted on-device via
// flutter_secure_storage — never hardcoded, never in the repo. Native apps
// have no CORS restriction, so the direct call just works.
// ═══════════════════════════════════════════════════════════════════════

const String kChefModelHaiku = 'claude-haiku-4-5';
const String kChefModelSonnet = 'claude-sonnet-4-6';
const String kChefModelOpus = 'claude-opus-5';

// ═══════════════════════════════════════════════════════════════════════
// EQUIPMENT — what the user actually cooks with. The chef used to have this
// hard-coded; now it's picked in Settings and injected into every prompt, so
// recipes only ever use appliances that exist in this kitchen.
// ═══════════════════════════════════════════════════════════════════════

/// One appliance. [note] carries capability knowledge worth telling the chef
/// — only for devices where it genuinely changes how a recipe is written.
class CookDevice {
  final String name;
  final String? note;
  const CookDevice(this.name, [this.note]);
}

const List<CookDevice> kKnownDevices = <CookDevice>[
  CookDevice('Air fryer'),
  CookDevice('Stove / cooktop'),
  CookDevice('Oven'),
  CookDevice(
      'Tovala Smart Oven',
      'countertop smart oven with Steam, Bake, Broil, Air Fry, Toast and '
          'Reheat. Its edge is STEAM and multi-mode cycles: up to 3 modes '
          'chained in one automated cook (e.g. Steam → Bake → Broil), each '
          'with its own time and temperature. Steam keeps lean proteins juicy '
          'and revives leftovers without drying them; finish on Broil to '
          'brown. Small capacity — single layer, batch if needed'),
  CookDevice('Toaster oven'),
  CookDevice('Microwave'),
  CookDevice('Outdoor grill'),
  CookDevice('Smoker'),
  CookDevice('Slow cooker (Crock-Pot)'),
  CookDevice('Pressure cooker (Instant Pot)'),
  CookDevice('Sous vide'),
  CookDevice('Rice cooker'),
  CookDevice('Griddle / flat top'),
  CookDevice('Deep fryer'),
  CookDevice('Blender'),
  CookDevice('Immersion blender'),
  CookDevice('Food processor'),
  CookDevice('Stand mixer'),
  CookDevice('Waffle iron'),
  CookDevice('Panini press'),
  CookDevice('Toaster'),
];

/// Sensible starting kitchen — what the user said they have. Only used until
/// they change it in Settings.
const List<String> kDefaultDevices = <String>[
  'Air fryer',
  'Stove / cooktop',
  'Oven',
  'Tovala Smart Oven',
  'Outdoor grill',
];

// ═══════════════════════════════════════════════════════════════════════
// AVOID LIST — foods the chef must never use. Editable in Settings, because
// hardcoding dislikes meant the chef also invented its own (it kept refusing
// yogurt). The list it is given each call is the COMPLETE truth.
// ═══════════════════════════════════════════════════════════════════════

/// The starting list — what the chef used to have hardcoded — so behaviour
/// does not change until the user edits it. There is no preset menu beyond
/// this: the user types in whatever they actually avoid.
const List<String> kDefaultAvoids = <String>[
  'Pork',
  'All seafood',
  'Spicy food',
  'Chili powder',
  'Yogurt',
];

/// Capability note for [name], or null (covers custom devices too).
String? deviceNote(String name) {
  for (final CookDevice d in kKnownDevices) {
    if (d.name == name) {
      return d.note;
    }
  }
  return null;
}

class ChefException implements Exception {
  final String message;

  /// True when the call reached Claude and came back unreadable, rather than
  /// failing for a reason a retry can't mend (a bad key, no network). A
  /// formatting slip is usually transient, so those get one more go.
  final bool unreadable;

  ChefException(this.message, {this.unreadable = false});
  @override
  String toString() => message;
}

/// On-device settings: the API key and which model to use.
class ChefKeys {
  static const FlutterSecureStorage _s = FlutterSecureStorage();
  static const String _kKey = 'chef_api_key';
  static const String _kModel = 'chef_model'; // 'haiku' | 'sonnet' | 'opus'
  static const String _kEquipment = 'chef_equipment'; // JSON list of devices
  static const String _kAvoids = 'chef_avoids'; // JSON list of avoided foods

  /// Key baked in at build time via --dart-define=ANTHROPIC_API_KEY=… (a
  /// GitHub Actions secret; shared with BodyComp). A user-entered key
  /// overrides it. Empty in local/dev builds.
  static const String _bakedKey = String.fromEnvironment('ANTHROPIC_API_KEY');
  static bool get hasBakedKey => _bakedKey.isNotEmpty;

  /// The user's own key (null if they haven't set one).
  static Future<String?> getUserKey() => _s.read(key: _kKey);
  static Future<void> setApiKey(String v) => v.trim().isEmpty
      ? _s.delete(key: _kKey)
      : _s.write(key: _kKey, value: v.trim());
  static Future<bool> hasUserKey() async =>
      (await getUserKey())?.isNotEmpty ?? false;

  /// The key actually used for calls: the user's if set, else the baked one.
  static Future<String> effectiveKey() async {
    final String? u = await getUserKey();
    if (u != null && u.isNotEmpty) {
      return u;
    }
    return _bakedKey;
  }

  static Future<bool> hasUsableKey() async => (await effectiveKey()).isNotEmpty;

  static Future<String> getModelPref() async =>
      (await _s.read(key: _kModel)) ?? 'haiku';
  static Future<void> setModelPref(String p) => _s.write(key: _kModel, value: p);

  /// The appliances the user owns. Falls back to [kDefaultDevices] until they
  /// pick their own in Settings.
  static Future<List<String>> getEquipment() async {
    final String? raw = await _s.read(key: _kEquipment);
    if (raw == null || raw.isEmpty) {
      return List<String>.from(kDefaultDevices);
    }
    try {
      final dynamic d = jsonDecode(raw);
      if (d is List) {
        return d.whereType<String>().toList();
      }
    } catch (_) {}
    return List<String>.from(kDefaultDevices);
  }

  static Future<void> setEquipment(List<String> devices) =>
      _s.write(key: _kEquipment, value: jsonEncode(devices));

  /// Foods the chef must never use. Falls back to [kDefaultAvoids] until the
  /// user edits the list; an explicitly emptied list is respected.
  static Future<List<String>> getAvoids() async {
    final String? raw = await _s.read(key: _kAvoids);
    if (raw == null) {
      return List<String>.from(kDefaultAvoids);
    }
    try {
      final dynamic d = jsonDecode(raw);
      if (d is List) {
        return d.whereType<String>().toList();
      }
    } catch (_) {}
    return List<String>.from(kDefaultAvoids);
  }

  static Future<void> setAvoids(List<String> foods) =>
      _s.write(key: _kAvoids, value: jsonEncode(foods));

  static Future<String> getModelId() async {
    switch (await getModelPref()) {
      case 'opus':
        return kChefModelOpus;
      case 'sonnet':
        return kChefModelSonnet;
      default:
        return kChefModelHaiku;
    }
  }
}

class Chef {
  static const String _endpoint = 'https://api.anthropic.com/v1/messages';

  // ── Call 1: the options ───────────────────────────────────────────────
  // [request], when given, is a free-text craving/description (e.g. from the
  // wife) — the options are then tailored to it. [justShown] are the titles
  // of options the user just rejected with "five different ideas", so a
  // regenerate can't hand back the same set. [recentForms] is derived from
  // recentMeals so the chef is steered away from what it keeps making.
  static Future<List<MealOption>> generateOptions({
    required List<PantryItem> pantry,
    required int servings,
    required List<String> recentMeals,
    PriceBook prices = const PriceBook(),
    String? request,
    List<String> justShown = const <String>[],
    List<String> recentForms = const <String>[],
  }) async {
    final String req = request?.trim() ?? '';
    final bool hasReq = req.isNotEmpty;
    final List<String> avoids = await ChefKeys.getAvoids();
    // Ask, check, and if they came back as one dinner in five hats — or
    // with a food he doesn't eat — ask again with the specific complaint
    // attached. An avoid violation is a hard failure, so it gets a second
    // retry; variety alone gets one.
    List<MealOption> out = await _askOptions(
        pantry: pantry,
        servings: servings,
        recentMeals: recentMeals,
        prices: prices,
        request: req,
        justShown: justShown,
        recentForms: recentForms);
    String problem = _optionsProblem(out, avoids, requireProteinVariety: !hasReq);
    int attemptsLeft = optionsAvoidHits(out, avoids).isEmpty ? 1 : 2;
    while (problem.isNotEmpty && attemptsLeft > 0) {
      attemptsLeft--;
      try {
        final List<MealOption> retry = await _askOptions(
            pantry: pantry,
            servings: servings,
            recentMeals: recentMeals,
            prices: prices,
            request: req,
            justShown: justShown,
            recentForms: recentForms,
            complaint: problem);
        if (_isBetter(retry, out, avoids, requireProteinVariety: !hasReq)) {
          out = retry;
        }
        final String next =
            _optionsProblem(out, avoids, requireProteinVariety: !hasReq);
        if (optionsAvoidHits(out, avoids).isEmpty) {
          problem = ''; // the hard rule is satisfied; stop spending calls
        } else {
          problem = next;
        }
      } on ChefException {
        break; // keep what we have rather than fail the whole ask
      }
    }
    // Last line of defence: never hand back a meal built on a food he
    // avoids, however many times the model insists on it.
    final List<MealOption> clean = out
        .where((MealOption o) => optionAvoidHits(o, avoids).isEmpty)
        .toList();
    if (clean.isEmpty) {
      final String named =
          optionsAvoidHits(out, avoids).map((AvoidHit h) => h.term).join(', ');
      throw ChefException(named.isEmpty
          ? 'The chef returned no usable options — try again.'
          : 'Every idea the chef came back with used $named, which is on your '
              'avoid list. Try again.');
    }
    return clean;
  }

  /// Everything wrong with a set of options, worst first: a food on the avoid
  /// list is a hard failure; blowing the fatty liver limits and
  /// one-dinner-in-five-hats are the softer ones.
  static String _optionsProblem(List<MealOption> opts, List<String> avoids,
      {required bool requireProteinVariety}) {
    final List<String> parts = <String>[
      avoidComplaint(optionsAvoidHits(opts, avoids)),
      optionsLiverComplaint(opts),
      optionsSimilarity(opts, requireProteinVariety: requireProteinVariety),
    ].where((String s) => s.isNotEmpty).toList();
    return parts.join('; ');
  }

  /// Is [a] a better set than [b]? Fewer avoid violations always wins; then
  /// fewer broken liver limits; ties go to the more varied set.
  static bool _isBetter(List<MealOption> a, List<MealOption> b,
      List<String> avoids,
      {required bool requireProteinVariety}) {
    final int badA = optionsAvoidHits(a, avoids).length;
    final int badB = optionsAvoidHits(b, avoids).length;
    if (badA != badB) {
      return badA < badB;
    }
    final int liverA = optionsLiverFlags(a).length;
    final int liverB = optionsLiverFlags(b).length;
    if (liverA != liverB) {
      return liverA < liverB;
    }
    return optionsSimilarity(a, requireProteinVariety: requireProteinVariety)
            .length <
        optionsSimilarity(b, requireProteinVariety: requireProteinVariety)
            .length;
  }

  static Future<List<MealOption>> _askOptions({
    required List<PantryItem> pantry,
    required int servings,
    required List<String> recentMeals,
    required PriceBook prices,
    required String request,
    required List<String> justShown,
    required List<String> recentForms,
    String complaint = '',
  }) async {
    final String req = request;
    final bool hasReq = req.isNotEmpty;
    final String knownPrices = formatKnownPrices(prices, pantry);
    final String equipment = formatEquipment(await ChefKeys.getEquipment());
    final String formList = kDishForms.join(', ');

    final String task = hasReq
        ? '''
The user has a SPECIFIC REQUEST for this meal:
"$req"

Propose exactly $kOptionCount options that satisfy this request as closely as
possible while still obeying EVERY hard rule (allergy, AVOID list). They must be
$kOptionCount ordinary dinners a home cook would recognise, and wildly different
ones: no two may be the same KIND of dish (a stew and a curry are one kind), and
no two may share a CUISINE. Repeating a protein is fine. Use pantry items where they
fit; new buys are expected and fine to fulfil the request. Only prioritize an
[EXPIRING SOON] item if it suits the request.'''
        : '''
Propose exactly $kOptionCount dinner options. Every one of them must be an
ordinary dinner a home cook would recognise and could name in a few plain words
— the kind of thing that turns up on a weeknight table.

They also have to be $kOptionCount WILDLY different dinners:
  • dish FORM — $kOptionCount different ones, each from: $formList. Judge
    this by what ARRIVES AT THE TABLE, not by the label. A stew, a curry and
    a brothy bowl are three different words for one dinner; so are a burger
    and a meatball, a stir-fry and a skillet, a sheet-pan and a bake. No two
    options may be the same KIND of dinner — and never more than one of them
    eaten with a spoon out of a bowl.
  • CUISINE / flavor family — $kOptionCount different ones, ranging widely
    across the world rather than handing back five neighbours.
  • primary PROTEIN — repeats are FINE here. Two chicken dinners that are
    genuinely different dishes are welcome; just don't put every option on the
    same protein.

Ordinary still outranks different. There are more than enough plain weeknight
dinners to fill $kOptionCount slots — a roast, a soup, tacos, a pasta and a
stir-fry are already five familiar dinners with nothing in common — so never
reach for a fusion, a novelty ingredient or a restaurant dish to fill the last
one. If a slot will only go "different" by going strange, keep it plain and take
the distance from a different axis. Use any [EXPIRING SOON] ingredient in
whichever option it honestly belongs in.''';

    final String avoids = formatAvoids(await ChefKeys.getAvoids());
    final String user = '''
CURRENT PANTRY (what's in stock — use [EXPIRING SOON] items where they fit,
never by forcing them; prices shown are per gram or per unit):
${formatPantry(pantry)}
${knownPrices.isEmpty ? '' : '''

KNOWN PRICES (the user has bought these before — use these exact unit prices if
a meal needs them as new buys):
$knownPrices'''}

EQUIPMENT — the ONLY appliances in this kitchen. Never propose a meal that
needs anything not on this list:
$equipment

AVOID — the COMPLETE list of foods to keep out of these meals. Each entry
covers its whole group, not just the words written: no option may use anything
listed under it. Nothing else is off limits: do NOT refuse or omit any other
ingredient on taste grounds.
$avoids

RECENTLY MADE${hasReq ? ' (context only — you MAY reuse one if it matches the request)' : ' — do NOT repeat any of these'}:
${recentMeals.isEmpty ? '(none yet)' : recentMeals.map((String m) => '- $m').join('\n')}
${recentForms.isEmpty ? '' : '''
The user has been eating a lot of these lately — steer AWAY from them:
${recentForms.map((String f) => '- $f').join('\n')}'''}
${justShown.isEmpty ? '' : '''

The user just REJECTED these and asked for different ideas — none of your
options may resemble them (not the same dish, form, or spin):
${justShown.map((String t) => '- $t').join('\n')}'''}
${complaint.isEmpty ? '' : '''

YOUR LAST ATTEMPT WAS REJECTED: $complaint. Fix that by swapping in a different
ORDINARY dinner, not a stranger one. Nothing on the AVOID list (or in a group it
names) may appear in any option.'''}

Cooking for $servings ${servings == 1 ? 'person' : 'people'}.

$task

LIVER AND WEIGHT: every one of the $kOptionCount options must already sit inside the fatty
liver rules as written — no more than ~7g saturated fat and ~6g added sugar per
serving, at least ~8g fiber, whole grains rather than refined, olive oil as the
fat, nothing deep-fried, no alcohol, no cured or processed meat. Do not offer a
dish you would then have to apologise for. If a familiar dinner needs lightening
to get there, lighten it and say so in one clause of "desc".

SIDES ARE OPTIONAL. Add a simple vegetable side (and a starch) only where the
meal genuinely wants one — a stew, a curry or a loaded bowl is already dinner
and needs nothing bolted on. When you do add one, keep it simple but not bare
— roasted hard, charred, or a sharp dressed salad — built from pantry
vegetables when there are any.
Leave "sides" empty when the dish stands on its own. Nutrition and cost figures
cover whatever is on the plate.

The pantry above is the COMPLETE list of what the user has. Everything else —
including any protein, oil, spice, or staple — is a NEW BUY. Do not claim the
user already has an ingredient that is not listed above; put it in newBuys.

EVERY OPTION HAS TO BE WORTH LOOKING FORWARD TO. He is picking dinner off this
screen after a day at work — if none of the $kOptionCount makes him hungry, the
answer is wrong however sensible it is. Give each one something that makes it
good: a crust, a char, a glaze, a sauce, a crunch against something soft. Plain
ingredients cooked properly, not plain ingredients left plain.

COST: keep each ingredient list to what the dish needs and don't waste money on
things nobody will taste — but do NOT pick the cheaper dinner over the better
one, and don't lean on lentils, beans and cabbage just because they are cheap.
Buy the one or two ordinary things a dish needs (rule 6).
For each option estimate its total cost for $servings ${servings == 1 ? 'serving' : 'servings'}
(estCostTotal) and per serving (estCostPerServing), in US dollars. Use the unit
prices above for pantry/known items; estimate typical grocery prices for the
rest.

Respond with ONLY valid JSON, no markdown, in exactly this shape:
{"options":[{"title":"","desc":"","protein":"","form":"","cuisine":"","sides":"","newBuys":"","proteinPerServing":0,"caloriesPerServing":0,"satFatPerServing":0,"addedSugarPerServing":0,"fiberPerServing":0,"estCostTotal":0,"estCostPerServing":0}]}
"desc" is one plain sentence that makes him want it — say what it looks and
tastes like on the plate (what's crisp, what's saucy, what it's spooned over),
not a list of ingredients and never a sales pitch.
"satFatPerServing", "addedSugarPerServing" and "fiberPerServing" are grams per
serving for everything on the plate — the liver numbers, estimated honestly, not
rounded down to look good.
"form" is one entry from the form list above. "cuisine" is a short label
(e.g. "Thai", "Tex-Mex", "Mediterranean"). "sides" names the vegetable side and
any starch, or is "" when the dish needs none. "newBuys" is a short comma list
(or "No new buys" if all from pantry). Cost fields are numbers in dollars
(e.g. 8.50).''';

    // Roomier than the old three-option budget: five options of JSON, each
    // with sides and cost fields, ran close to the 1800 ceiling.
    final Map<String, dynamic> data = await _post(user: user, maxTokens: 3200);
    final List<dynamic> opts = (data['options'] as List<dynamic>?) ?? <dynamic>[];
    final List<MealOption> out = opts
        .whereType<Map<String, dynamic>>()
        .map(MealOption.fromJson)
        .toList();
    if (out.isEmpty) {
      throw ChefException('The chef returned no options — try again.');
    }
    return out;
  }

  // ── Call 2: full recipe ───────────────────────────────────────────────
  // The picked option is already clear of the avoid list, but the recipe can
  // still smuggle a forbidden food into the method (an anchovy in the
  // dressing, butter in the pan). Same deal as the options: check, re-ask
  // once with the complaint, and refuse rather than hand over a recipe he
  // can't eat.
  static Future<Recipe> generateRecipe({
    required MealOption option,
    required int servings,
    required List<PantryItem> pantry,
    PriceBook prices = const PriceBook(),
  }) async {
    final List<String> avoids = await ChefKeys.getAvoids();
    Recipe out = await _askRecipe(
        option: option, servings: servings, pantry: pantry, prices: prices);
    List<AvoidHit> hits = recipeAvoidHits(out, avoids);
    if (hits.isNotEmpty) {
      final Recipe retry = await _askRecipe(
          option: option,
          servings: servings,
          pantry: pantry,
          prices: prices,
          complaint: avoidComplaint(hits));
      final List<AvoidHit> retryHits = recipeAvoidHits(retry, avoids);
      if (retryHits.length < hits.length) {
        out = retry;
        hits = retryHits;
      }
    }
    if (hits.isNotEmpty) {
      throw ChefException(
          'The chef kept putting ${hits.map((AvoidHit h) => h.term).join(', ')} '
          'in this recipe, which is on your avoid list. Pick another option.');
    }
    return out;
  }

  static Future<Recipe> _askRecipe({
    required MealOption option,
    required int servings,
    required List<PantryItem> pantry,
    PriceBook prices = const PriceBook(),
    String complaint = '',
  }) async {
    final String knownPrices = formatKnownPrices(prices, pantry);
    final String equipment = formatEquipment(await ChefKeys.getEquipment());
    final String avoids = formatAvoids(await ChefKeys.getAvoids());
    final String user = '''
Write the full recipe for "${option.title}" (${option.desc}) for $servings
${servings == 1 ? 'person' : 'people'}. Measurements in GRAMS for anything
weighed, counts for count items like eggs, spoons for spices, and "to taste"
for salt and pepper. Cook Miracle Noodles IN the sauce if used. Include heat
levels, timing, and pro tips. Follow every user rule and the recipe format.
Keep it as simple as the dish honestly allows: as few ingredients as the dish
actually needs, and no technique a home cook on a weeknight wouldn't use. Do
not pad the method to look thorough. Simple is not the same as bland — keep
every step that makes the food good (the sear, the browning, the sauce, the
seasoning, the acid at the end) and cut only padding. And it is not the same
as terse: the prep is not padding. Every chop, mince, trim and drain the method
relies on has to be somewhere the cook can see it, in a step or in the
ingredient's amount. Nothing in a step may depend on work you never wrote down.
${option.sides.isEmpty ? '' : '''
The side is part of this recipe: "${option.sides}". Include its ingredients and
its steps, sequenced so everything lands together (start what takes longest
first; say when to start the side). Keep the side simple — it is a side —
but not bare: season it and give it some colour.'''}

PANTRY (the complete list of what the user has on hand; prices are per gram or
per unit):
${formatPantry(pantry)}
${knownPrices.isEmpty ? '' : '''

KNOWN PRICES (bought before — use these exact unit prices for these new buys):
$knownPrices'''}

EQUIPMENT — the ONLY appliances in this kitchen. Every step must be doable
with these; never instruct the user to use anything else:
$equipment

AVOID — the COMPLETE list of foods to keep out of this recipe. Each entry
covers its whole group, not just the words written. Nothing else is off limits
on taste grounds.
$avoids
${complaint.isEmpty ? '' : '''

YOUR LAST ATTEMPT BROKE THE AVOID LIST: $complaint. Rewrite the recipe without
it — swap in something the list allows, or change the dish.'''}

LIVER LIMITS FOR THIS RECIPE (per serving, everything on the plate): at most
~7g saturated fat, at most ~6g added sugar, at least ~8g fiber. Olive oil is the
fat and you state its grams. No butter, cream or coconut milk. No alcohol in any
step. No cured or processed meat. No deep-frying or batter-frying. Whole grains
rather than refined. This is where a lightened dish usually slips back — the
option was approved on these numbers, so the method has to hold them.

For every ingredient NOT in that pantry list, append " (new buy)" to its name in
the ingredients list. Do not imply the user already has anything not listed.

For each step, set "timerSeconds" to the number of seconds for any wait/cook/
rest timer in that step (e.g. 6 minutes = 360). Use 0 when the step has no
time-based action.

COST: estimate estCostTotal (whole recipe), estCostPerServing, and estGroceryCost
(ONLY the new buys — what the user actually spends at the store for this meal),
in US dollars. Use the unit prices above; estimate typical grocery prices for
anything without one.

Respond with ONLY valid JSON, no markdown, in exactly this shape:
{"title":"","description":"","ingredients":[{"item":"","amount":""}],"steps":[{"title":"","content":"","timerSeconds":0}],"notes":"","estCostTotal":0,"estCostPerServing":0,"estGroceryCost":0}
"notes" is one string containing protein per serving, calories per serving,
saturated fat, added sugar and fiber per serving, any new buys, storage/pro
tips, and one short line on how the dish sits with the fatty liver. Cost fields
are numbers in dollars (e.g. 12.75).''';

    final Map<String, dynamic> data = await _post(user: user, maxTokens: 2500);
    return Recipe.fromJson(data, baseServings: servings);
  }

  // ── cook it again, better ─────────────────────────────────────────────

  /// Rewrite [recipe] applying what the cook wrote down after cooking it.
  ///
  /// The app remembers that a meal was cooked, never how it went, so the same
  /// flaw came back every time. This is where a note turns into a change.
  static Future<Recipe> reviseRecipe({
    required Recipe recipe,
    required List<String> notes,
    required int servings,
    required List<PantryItem> pantry,
    PriceBook prices = const PriceBook(),
  }) async {
    final StringBuffer noteList = StringBuffer();
    for (final String n in notes) {
      noteList.writeln('- $n');
    }
    final String knownPrices = formatKnownPrices(prices, pantry);
    final String equipment = formatEquipment(await ChefKeys.getEquipment());
    final String avoids = formatAvoids(await ChefKeys.getAvoids());
    final String servingWord = servings == 1 ? 'person' : 'people';

    final String user = '''
Rewrite this recipe for $servings $servingWord, applying what the cook wrote
down after cooking it.

It is the SAME DISH. Keep the title, keep the character of it. Change what the
notes ask for, and anything that genuinely follows from that change: if a note
says it was too salty, the salt drops AND anything salty that fed into it; if a
note says a step ran long, that step's time and its timerSeconds both change.
Change nothing the notes do not touch.

WHAT THE COOK WROTE (oldest first, so the last line is the most recent):
$noteList
THE RECIPE AS IT STANDS (written for ${recipe.baseServings} ${recipe.baseServings == 1 ? 'person' : 'people'}):
${jsonEncode(recipe.toJson())}

PANTRY (what is on hand now; prices are per gram or per unit):
${formatPantry(pantry)}
${knownPrices.isEmpty ? '' : '''

KNOWN PRICES (use these exact unit prices for these new buys):
$knownPrices'''}
$equipment
$avoids
Measurements in GRAMS for anything weighed, counts for count items like eggs,
spoons for spices, and "to taste" for salt and pepper. Follow every user rule
and the recipe format. Keep it as simple as the dish honestly allows.

COST: estimate estCostTotal (whole recipe), estCostPerServing, and
estGroceryCost (ONLY the new buys), in US dollars.

Respond with ONLY valid JSON, no markdown, in exactly this shape:
{"title":"","description":"","ingredients":[{"item":"","amount":""}],"steps":[{"title":"","content":"","timerSeconds":0}],"notes":"","estCostTotal":0,"estCostPerServing":0,"estGroceryCost":0}
"notes" is one string containing protein per serving, calories per serving,
saturated fat, added sugar and fiber per serving, any new buys, storage/pro
tips, one short line on how the dish sits with the fatty liver, and one short
line saying what you changed and why.''';

    final Map<String, dynamic> data = await _post(user: user, maxTokens: 2500);
    return Recipe.fromJson(data, baseServings: servings);
  }

  // ── mise en place ─────────────────────────────────────────────────────

  /// Plan the measuring: which ingredients can share a bowl because they go
  /// into the pan at the same moment and keep together until then.
  ///
  /// Deliberately a separate pass over a finished recipe rather than a field
  /// on the generation, so anything already in the recipe box can get one.
  static Future<PrepPlan> planPrep(Recipe recipe) async {
    final StringBuffer ing = StringBuffer();
    for (final RecipeIngredient i in recipe.ingredients) {
      ing.writeln('- ${i.item}: ${i.amount}');
    }
    final StringBuffer steps = StringBuffer();
    for (int i = 0; i < recipe.steps.length; i++) {
      final RecipeStep st = recipe.steps[i];
      steps.writeln(
          '${i + 1}. ${st.title.isEmpty ? '' : '${st.title} — '}${st.content}');
    }
    final String servingWord =
        recipe.baseServings == 1 ? 'serving' : 'servings';

    final String user = '''
Plan the mise en place for "${recipe.title}". The cook measures everything into
bowls before starting.

Two ingredients share a bowl ONLY when they go into the pan at the same moment
AND sitting together until then harms neither.

Never put in the same bowl:
- raw meat, poultry, fish or raw egg with anything at all
- salt or sugar with cut vegetables, or with anything that will weep
- an acid (citrus, vinegar, wine, tomato) with dairy
- baking soda or baking powder with any acid or any liquid
- fresh soft herbs with anything hot or acidic
- anything added to taste at the end, or any garnish

Everything else that goes in together can share. An ingredient that shares with
nothing still gets its own bowl: every ingredient below must appear exactly
once across the bowls, none dropped, none repeated.

Name each bowl for what it is ("Aromatics", "Tomato base", "Spice mix"), never
"Bowl 1". Set "step" to the number of the step it goes into, or 0 if it is not
tied to one. Copy each amount EXACTLY as written below. "prep" is the knife
work if the ingredient list or a step calls for any ("diced", "thinly sliced"),
otherwise an empty string.

ALSO say what gets COOKED TOGETHER, in "cookGroups". A cook group is a set of
ingredients that end up as one mass you could still put on a scale: one tray,
one pan, one pot. This is a different question from the bowls. Two things can
share a bowl and end up in different pans, and two things measured separately
can end up stirred into the same sauce.

- One group per vessel. A side cooked on its own tray is its own group, and
  that is the whole point of the question.
- Anything stirred INTO a group belongs to that group, however late it goes in.
- Anything eaten raw or added at the table (a garnish, a dressing spooned over,
  salt to taste) goes in NO group. Leave it out.
- Use the exact ingredient names from the list below, and name each group for
  its vessel or its dish ("Sheet pan", "Rice pot", "Yogurt sauce").

INGREDIENTS (for ${recipe.baseServings} $servingWord):
$ing
STEPS:
$steps
Respond with ONLY valid JSON, no markdown, in exactly this shape:
{"bowls":[{"label":"","step":0,"items":[{"item":"","amount":"","prep":""}]}],"cookGroups":[{"name":"","items":[""]}]}''';

    final Map<String, dynamic> data =
        await _post(user: user, maxTokens: 2500, cheap: true);
    return PrepPlan.fromJson(data, baseServings: recipe.baseServings);
  }

  // ── out of an ingredient ──────────────────────────────────────────────

  /// A swap for [missing], preferring what the pantry already holds.
  static Future<Substitution> substitute({
    required Recipe recipe,
    required RecipeIngredient missing,
    required List<PantryItem> pantry,
    required int servings,
  }) async {
    final String avoids = formatAvoids(await ChefKeys.getAvoids());
    final double factor =
        recipe.baseServings == 0 ? 1 : servings / recipe.baseServings;
    final String servingWord = servings == 1 ? 'serving' : 'servings';
    final String user = '''
The cook is partway through "${recipe.title}" and has run out of
"${missing.item}" (the recipe calls for ${missing.scaled(factor)}).

Give ONE swap. Prefer something in the pantry below; only reach outside it if
the pantry genuinely holds nothing that works. Give the amount for $servings
$servingWord.

"use" is what to use instead, with the amount.
"fromPantry" is true ONLY if the swap is on the pantry list below.
"note" is what changes about the dish and anything to do differently, at most
two short sentences. Empty string if nothing changes.

PANTRY:
${formatPantry(pantry)}
$avoids
Respond with ONLY valid JSON, no markdown, in exactly this shape:
{"use":"","note":"","fromPantry":false}''';

    final Map<String, dynamic> data =
        await _post(user: user, maxTokens: 600, cheap: true);
    return Substitution.fromJson(data);
  }

  // ── shared request ────────────────────────────────────────────────────
  /// One call, with a single retry when the reply comes back unreadable.
  ///
  /// A model that answers in prose or fumbles its JSON almost always gets it
  /// right the second time, and the alternative was a dead end: the cook is
  /// told the reply was invalid and has to start over by hand. Only unreadable
  /// replies are retried — a bad key or a dead connection is not worth a
  /// second call.
  ///
  /// [cheap] is for the calls that only rearrange what a previous call already
  /// decided. Nothing a person cooks from is cheap.
  static Future<Map<String, dynamic>> _post({
    required String user,
    required int maxTokens,
    bool cheap = false,
  }) async {
    try {
      return await _postOnce(user: user, maxTokens: maxTokens, cheap: cheap);
    } on ChefException catch (e) {
      if (!e.unreadable) {
        rethrow;
      }
    }
    return _postOnce(user: user, maxTokens: maxTokens, cheap: cheap);
  }

  static Future<Map<String, dynamic>> _postOnce({
    required String user,
    required int maxTokens,
    bool cheap = false,
  }) async {
    final String key = await ChefKeys.effectiveKey();
    if (key.isEmpty) {
      throw ChefException('Add your Claude API key in Settings first.');
    }
    final String model = await ChefKeys.getModelId();

    // Opus 5 THINKS BY DEFAULT; opus-4-8, which it replaced, did not. Thinking
    // tokens are spent out of max_tokens, so a budget that comfortably held
    // five options before now has to cover the reasoning as well, and when it
    // runs out the JSON is truncated mid-object and the reply is unreadable.
    //
    // THAT IS NOT A REASON TO CAP THE THINKING. Pinning every call to low
    // effort fixed the truncation and quietly wrecked the cooking: a recipe
    // came back with its prep folded away and steps that assumed work the
    // method never told you to do. Writing a method someone can actually cook
    // from IS the hard think. Only the two mechanical shape-fills below run
    // cheap. Everything else gets the model's own judgement and a budget wide
    // enough to hold it.
    final bool thinks = _thinksByDefault(model);
    final Map<String, dynamic> body = <String, dynamic>{
      'model': model,
      'max_tokens': thinks ? maxTokens * (cheap ? 3 : 4) : maxTokens,
      if (thinks && cheap) 'output_config': <String, dynamic>{'effort': 'low'},
      // Fixed rules ride in a cached system block; only the user turn varies.
      'system': <Map<String, dynamic>>[
        <String, dynamic>{
          'type': 'text',
          'text': _systemPrompt,
          'cache_control': <String, String>{'type': 'ephemeral'},
        }
      ],
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'content': user},
      ],
    };

    http.Response resp;
    try {
      resp = await http
          .post(
            Uri.parse(_endpoint),
            headers: <String, String>{
              'content-type': 'application/json',
              'x-api-key': key,
              'anthropic-version': '2023-06-01',
            },
            body: jsonEncode(body),
          )
          .timeout(Duration(seconds: thinks ? (cheap ? 150 : 240) : 60));
    } catch (_) {
      throw ChefException('Network error — check your connection and retry.');
    }

    if (resp.statusCode != 200) {
      throw ChefException(_errorFor(resp));
    }

    try {
      final Map<String, dynamic> j =
          jsonDecode(resp.body) as Map<String, dynamic>;
      final List<dynamic> content = (j['content'] as List<dynamic>?) ?? <dynamic>[];
      final String text = content
          .whereType<Map<String, dynamic>>()
          .where((Map<String, dynamic> b) => b['type'] == 'text')
          .map((Map<String, dynamic> b) => b['text'] as String? ?? '')
          .join('\n');
      return _extractJson(text);
    } catch (e) {
      if (e is ChefException) {
        rethrow;
      }
      throw ChefException("Couldn't read the chef's reply — try again.",
          unreadable: true);
    }
  }

  static String _errorFor(http.Response resp) {
    String detail = '';
    try {
      final Map<String, dynamic> j =
          jsonDecode(resp.body) as Map<String, dynamic>;
      detail = (j['error'] as Map<String, dynamic>?)?['message'] as String? ?? '';
    } catch (_) {}
    switch (resp.statusCode) {
      case 401:
        return 'API key rejected — check it in Settings.';
      case 400:
        return 'Bad request${detail.isEmpty ? '' : ': $detail'}';
      case 429:
        return 'Rate limited — wait a moment and retry.';
      case 529:
        return 'Claude is overloaded right now — retry shortly.';
      default:
        if (resp.statusCode >= 500) {
          return 'Claude had a server error — retry shortly.';
        }
        return 'Request failed (${resp.statusCode})${detail.isEmpty ? '' : ': $detail'}';
    }
  }

  /// Models that reason before answering unless told otherwise. Opus 5 and
  /// Sonnet 5 do; the 4.x models this app used before did not, which is why
  /// the token budgets here were sized without it.
  static bool _thinksByDefault(String model) =>
      model.startsWith('claude-opus-5') || model.startsWith('claude-sonnet-5');

  /// Test hook for [_extractJson]. Reading a model's reply is the one piece
  /// of this file that can be checked without spending a call, and it is the
  /// piece that failed in the field.
  @visibleForTesting
  static Map<String, dynamic> debugExtractJson(String text) =>
      _extractJson(text);

  /// Pull the JSON object out of the reply, tolerating markdown fences and
  /// prose around it.
  ///
  /// The old version took everything between the first "{" and the last "}",
  /// which breaks the moment a stray brace appears in prose before the JSON,
  /// or the reply is two objects. It also gave the same message whether the
  /// chef answered in words or returned broken JSON, so a report of it was
  /// impossible to act on. Now it tries the BALANCED object at every brace
  /// in turn and keeps the first that decodes to an object, so a "{curly}" in
  /// the prose no longer hides the real reply. When the chef answered in
  /// plain words it says so and quotes him.
  static Map<String, dynamic> _extractJson(String text) {
    final String s = _stripFences(text).trim();
    if (!s.contains('{')) {
      throw ChefException(_plainAnswer(s), unreadable: true);
    }
    for (final String candidate in _jsonCandidates(s)) {
      try {
        final dynamic d = jsonDecode(candidate);
        if (d is Map<String, dynamic>) {
          return d;
        }
      } catch (_) {
        // try the next shape
      }
    }
    throw ChefException("The chef's reply came back garbled.", unreadable: true);
  }

  /// Every balanced object in the reply, in order, then the greedy
  /// first-to-last span as a last resort.
  ///
  /// Each brace gets its own attempt because the first one is not always the
  /// real one: a reply opening with "Note: use {curly} quotes." would
  /// otherwise hide the JSON that follows it. Capped, so a pathological reply
  /// can't turn this quadratic.
  static List<String> _jsonCandidates(String s) {
    const int maxTries = 24;
    final List<String> out = <String>[];
    int tries = 0;
    for (int i = 0; i < s.length && tries < maxTries; i++) {
      if (s[i] != '{') {
        continue;
      }
      tries++;
      final String? obj = _balancedFrom(s, i);
      if (obj != null && !out.contains(obj)) {
        out.add(obj);
      }
    }
    final int first = s.indexOf('{');
    final int last = s.lastIndexOf('}');
    if (first >= 0 && last > first) {
      final String greedy = s.substring(first, last + 1);
      if (!out.contains(greedy)) {
        out.add(greedy);
      }
    }
    return out;
  }

  /// The balanced object beginning at [start], or null if it never closes.
  /// String-aware, so a brace or a quote inside a description is just text.
  static String? _balancedFrom(String s, int start) {
    int depth = 0;
    bool inString = false;
    bool escaped = false;
    for (int i = start; i < s.length; i++) {
      final String c = s[i];
      if (inString) {
        if (escaped) {
          escaped = false;
        } else if (c == r'\') {
          escaped = true;
        } else if (c == '"') {
          inString = false;
        }
        continue;
      }
      if (c == '"') {
        inString = true;
      } else if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) {
          return s.substring(start, i + 1);
        }
      }
    }
    return null;
  }

  /// Strip a ```json fence if the reply came wrapped in one.
  static String _stripFences(String text) {
    final RegExp fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```', multiLine: true);
    final RegExpMatch? m = fence.firstMatch(text);
    return m != null ? (m.group(1) ?? text) : text;
  }

  /// The chef said something in words rather than handing back a dish. Quote
  /// him: "I can't do that without X" is worth reading, and infinitely more
  /// use than being told the reply was invalid.
  static String _plainAnswer(String s) {
    final String line = s.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (line.isEmpty) {
      return 'The chef sent an empty reply. Try again.';
    }
    final String quote = line.length > 200 ? '${line.substring(0, 200)}…' : line;
    return 'The chef answered in words instead of a dish: "$quote"';
  }

  /// One line per in-stock item for the prompt.
  static String formatPantry(List<PantryItem> pantry) {
    final DateTime now = DateTime.now();
    // Include tracked items with stock left, plus spices / on-hand items
    // (their amount isn't tracked but they ARE available).
    final List<PantryItem> live = pantry
        .where((PantryItem i) =>
            !i.deleted && (i.remaining > 0 || i.untracked))
        .toList()
      ..sort((PantryItem a, PantryItem b) {
        // Spices last; expiring first; then alphabetical.
        if (a.spice != b.spice) {
          return a.spice ? 1 : -1;
        }
        final bool ea = a.isExpiringSoon(now), eb = b.isExpiringSoon(now);
        if (ea != eb) {
          return ea ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
    if (live.isEmpty) {
      return '(pantry is empty — suggest meals with common cheap new buys)';
    }
    final StringBuffer sb = StringBuffer();
    for (final PantryItem it in live) {
      if (it.untracked) {
        sb.writeln('- ${it.name}: ${it.spice ? '(spice — always on hand)' : '(on hand, amount unknown)'}');
        continue;
      }
      final String amt = it.isCount
          ? '${_fmt(it.remaining)} ct'
          : '${_fmt(it.remaining)} g';
      sb.write('- ${it.name}: $amt');
      final String price = _priceLabel(it.pricePer, it.isCount);
      if (price.isNotEmpty) {
        sb.write('  ($price)');
      }
      if (it.isExpiringSoon(now)) {
        sb.write('  [EXPIRING SOON]');
      }
      if (!it.macros.isEmpty && it.servingSize > 0) {
        sb.write(
            '  (${_fmt(it.macros.proteinG)}g P / ${_fmt(it.macros.calories)} cal per ${_fmt(it.servingSize)}${it.servingUnit})');
      }
      sb.writeln();
    }
    return sb.toString().trimRight();
  }

  /// Prices for things the user has bought before but does NOT currently have
  /// in the pantry — so the chef can price familiar new buys accurately. Skips
  /// anything already listed as in-stock.
  /// A food's name with the brand and packaging stripped, so "Chicken Breast
  /// Fillets (Co-op)" and "Boneless, Skinless Chicken Breast Fillet (Just
  /// BARE)" are recognised as the same thing to be priced.
  static String _foodKey(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'\([^)]*\)'), ' ')
      .replaceAll(
          RegExp(r'\b(boneless|skinless|fresh|organic|raw|frozen|fillets?|'
              r'extra|lean|style|whole|large|small)\b'),
          ' ')
      .replaceAll(RegExp(r'[^a-z]+'), ' ')
      .trim();

  /// A price no grocery shop charges, which means the pack weight was
  /// mistyped when it was scanned. Spices are exempt: they genuinely cost a
  /// fortune per pound and a recipe uses a gram of them.
  static bool _absurdPrice(PriceEntry e) {
    if (e.isCount) {
      return e.unitPrice > 25; // $25 for one of a thing
    }
    return e.unitPrice > 0.11; // about $50/lb
  }

  static String formatKnownPrices(PriceBook prices, List<PantryItem> pantry) {
    if (prices.isEmpty) {
      return '';
    }
    final Set<String> inStock = pantry
        .where((PantryItem i) => !i.deleted && (i.remaining > 0 || i.untracked))
        .map((PantryItem i) => i.name.trim().toLowerCase())
        .toSet();
    // The chef is told to quote these EXACTLY, so anything wrong here lands
    // straight in the cost of dinner. Two things go wrong in a real price
    // book, and both did:
    //
    //  * The same food appears several times at different prices, because it
    //    was bought at different shops under different brand names. Chicken
    //    breast sat at both $5.67 and $22.68 a pound. Quoting the dear one
    //    made an ordinary dinner look like a night out.
    //  * A pack weight gets mistyped once and the unit price is nonsense
    //    forever after — orange juice at $226 a pound.
    //
    // So: collapse each food to the CHEAPEST price recorded for it, and drop
    // the impossible ones entirely. Dropping is better than quoting them,
    // because the chef falls back to estimating an ordinary grocery price,
    // which is far closer to the truth than the bad number.
    final Map<String, PriceEntry> best = <String, PriceEntry>{};
    for (final PriceEntry e in prices.byName.values) {
      if (e.unitPrice <= 0 ||
          inStock.contains(e.name.trim().toLowerCase()) ||
          _absurdPrice(e)) {
        continue;
      }
      final String key = '${e.isCount ? 'n' : 'g'}:${_foodKey(e.name)}';
      final PriceEntry? had = best[key];
      if (had == null || e.unitPrice < had.unitPrice) {
        best[key] = e;
      }
    }
    final List<PriceEntry> known = best.values.toList()
      ..sort((PriceEntry a, PriceEntry b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    if (known.isEmpty) {
      return '';
    }
    final StringBuffer sb = StringBuffer();
    for (final PriceEntry e in known) {
      sb.writeln('- ${e.name}: ${_priceLabel(e.unitPrice, e.isCount)}');
    }
    return sb.toString().trimRight();
  }

  /// The complete avoid list for the prompt, one per line, each category
  /// spelled out into the foods it covers. "All seafood" on its own read as
  /// a phrase, and the chef offered salmon.
  static String formatAvoids(List<String> avoid) => formatAvoidsForPrompt(avoid);

  /// The user's appliances, one per line, with a capability note where it
  /// changes how the dish should be cooked (e.g. the Tovala's steam cycles).
  static String formatEquipment(List<String> owned) {
    final List<String> live =
        owned.where((String s) => s.trim().isNotEmpty).toList();
    if (live.isEmpty) {
      return '- Stove / cooktop\n- Oven  (nothing else specified)';
    }
    final StringBuffer sb = StringBuffer();
    for (final String name in live) {
      final String? note = deviceNote(name);
      sb.writeln(note == null ? '- $name' : '- $name — $note');
    }
    return sb.toString().trimRight();
  }

  /// "$0.012/g" or "$0.25 each"; empty when there's no price.
  static String _priceLabel(double unitPrice, bool isCount) {
    if (unitPrice <= 0) {
      return '';
    }
    return isCount
        ? '\$${unitPrice.toStringAsFixed(2)} each'
        : '\$${unitPrice.toStringAsFixed(unitPrice < 0.1 ? 4 : 3)}/g';
  }

  static String _fmt(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);
}

// ═══════════════════════════════════════════════════════════════════════
// FIXED RULES — the chef's brain. Static, so it can be prompt-cached.
// ═══════════════════════════════════════════════════════════════════════

const String _systemPrompt = '''
You are the user's personal chef. You invent meals for them like a real chef —
you do not pull generic recipes. You always obey the profile and rules below.

USER PROFILE (hard rules — never violate):
- Cooking for 2 people (user + wife) unless told a different number.
- ALLERGY: shrimp. Never use it.
- AVOID LIST: the user message carries an AVOID list. That list is the COMPLETE
  set of foods to keep out — treat it as exhaustive. Never avoid, refuse or
  quietly omit an ingredient that is NOT on it because you assume the user
  dislikes it. If something is not listed, it is fair game.
- AVOID LIST ENTRIES ARE CATEGORIES, NOT WORDS. An entry rules out every food
  in that group, not just dishes that spell the entry out. "All seafood" rules
  out salmon, cod, tuna, crab, anchovy, fish sauce and every other fish or
  shellfish. "Dairy" rules out butter, cheese and cream. The entries in the
  user message name the members they cover — read them and obey the whole
  group. An ingredient being unnamed there is not a loophole.
- PROTEINS: any protein is fair game unless it appears on the AVOID list, or
  belongs to a group on it. There is NO fixed short list; roam widely across
  meat, poultry, seafood, dairy, legumes and eggs — minus whatever the AVOID
  list takes off the table. Two prep preferences that still hold:
  * Chicken breast MUST be chopped into pieces if pan-cooked (he hates cooking a
    whole breast on a pan). Whole breast is fine in the air fryer.
  * Never suggest steak & eggs (he's sick of it).
- EQUIPMENT: the user message lists the appliances this kitchen actually has.
  That list is the complete truth — treat anything not on it as unavailable.
  Never write a step that requires a missing appliance; adapt the method to
  what IS available (or pick a different dish). Where a listed device has a
  capability note, use it — it's there because it changes how to cook.
- HEALTH (the reason this chef exists): the user is losing weight AND has a
  FATTY LIVER. Every meal is cooked for both at once. Goals: steady weight
  loss, high protein, high fiber, low saturated fat, low added sugar, plenty of
  vegetables, more energy. The FATTY LIVER RULES below are hard rules, not
  preferences. Lean is not the same as meagre — he is eating well within them,
  not dieting his way through dinner.
- HOW HE COOKS: weeknight dinners for two, after work. He wants real food he
  looks forward to at the end of the day — not a diet plate, and not a budget
  exercise. He notices the grocery bill, so don't be wasteful; but a dinner
  worth eating is worth paying the ordinary price for. Where cost and the liver
  rules pull against each other, the liver wins.
- Measurements: grams (never oz) for anything that gets weighed — proteins,
  vegetables, grains, legumes, dairy, oil. Count items like eggs stay as counts.
  Salt, pepper and dried spices do NOT go in grams; nobody weighs them. Use
  teaspoons and tablespoons for spices, and "to taste" for salt and pepper. The
  exception is where the amount genuinely has to be exact — a brine, a cure, or
  anything baked — and there grams are right.

FATTY LIVER RULES (hard rules — they outrank taste, cost and the pantry):
Cooking for this liver is a Mediterranean pattern: vegetables and legumes in
volume, whole grains instead of refined ones, olive oil as the fat, lean
protein, and very little sugar or saturated fat. Every meal you write obeys all
of the following.
- ADDED SUGAR: about 6 g per serving, maximum, from every source combined.
  Fructose is the worst thing for this liver. No honey, agave, maple syrup,
  brown sugar, corn syrup, fruit juice or concentrate, and no sweetened bottled
  sauce (teriyaki, barbecue, sweet chili, hoisin, glaze) unless you rebuild it
  with a no-sugar-added base and say so in the ingredient name. Whole fruit is
  fine and welcome.
- SATURATED FAT: about 7 g per serving, maximum. Butter, cream, coconut milk,
  palm oil, and cheese as a main ingredient are out. So are fatty cuts and
  poultry skin. Take the lean form of whatever protein the dish uses: skinless
  poultry, a lean cut, 93 percent or leaner ground meat. Trim visible fat and
  drain rendered fat. A small amount of hard cheese used as seasoning (10 to
  15 g) is fine.
- FAT SOURCE: extra virgin olive oil is the default cooking and finishing fat.
  NEVER deep-fry and never batter-and-fry. Air fry, roast, grill, steam, poach,
  braise, or sauté in a measured amount of oil, and always say the grams of
  oil.
- NO ALCOHOL, in the pan or beside the plate. No wine, beer, sherry, mirin or
  spirits in a sauce, however much of it would cook off. Use stock, vinegar or
  citrus instead.
- NO PROCESSED OR CURED MEAT: no bacon, sausage, salami, pepperoni, deli meat,
  hot dogs, jerky, or anything cured or smoked. This includes the turkey and
  chicken versions.
- CARBS ARE WHOLE, NOT REFINED: whatever starch the dish calls for, use the
  whole grain form of it. Keep white rice, white pasta, white bread and buns,
  pastry and plain breadcrumb coatings out of the body of a dish. Keep the
  starch portion modest, roughly 60 to 90 g cooked per serving, and let the
  vegetables and protein carry the plate.
- FIBER: at least about 8 g per serving. Every meal has real vegetables in it,
  aiming at half the plate, and legumes wherever they honestly fit.
- SODIUM: moderate. Season with herbs, spices, citrus, vinegar, garlic and
  onion rather than reaching for salt, soy sauce or bouillon by the spoon.
- SKIP THE ULTRA-PROCESSED SHORTCUTS: jarred sauces, packet seasonings and
  bottled dressings are sugar, oil and salt. Build the sauce or dressing from
  scratch; it is two lines of the method.
- None of this makes dinner unusual. A Mediterranean weeknight meal is an
  ordinary weeknight meal, so rule 2 (REGULAR FOOD) still stands. If a classic
  dish cannot be made inside these limits, choose a different classic dish
  rather than writing a strange one. Say plainly when you have lightened a
  familiar dish, and how.

THE PANTRY LIST IS THE COMPLETE, LITERAL TRUTH (most important rule):
- The pantry list you are given each time is EXHAUSTIVE. Treat ONLY those exact
  items as in-stock.
- EVERYTHING else is a NEW BUY — including basics like salt, pepper, oil,
  garlic, onion, eggs, rice, flour, spices, sauces, butter, cheese. If an
  ingredient is not in the list, the user does NOT have it. Never state or imply
  they already have it.
- `newBuys` for each option must name EVERY ingredient the meal needs that is
  not in the pantry list. Only say "No new buys" if the meal truly uses nothing
  but pantry items.
- When the pantry is nearly empty, it is expected and correct for options to
  need several new buys — be honest about it, don't pretend items are on hand.
- Items shown as "(spice — always on hand)" or "(on hand, amount unknown)" ARE
  available — never list them as new buys. Just don't rely on a specific gram
  amount for them; assume enough.
- In recipes, append " (new buy)" to any ingredient name that is not in the
  pantry.

MEAL GENERATION RULES:
1. Present exactly $kOptionCount options; the user picks one.
2. REGULAR FOOD HE ACTUALLY WANTS TO EAT. This is the rule that outranks the
   rest, and it has two halves that only work together.
   ORDINARY: every option is a dinner a home cook would recognise and could
   name in a few plain words — the sort of thing that turns up on a weeknight
   table. Cook a dish as its own cuisine; never invent a fusion, never mash two
   cuisines onto one plate, never build a dish around a novelty ingredient. If
   the title needs a clause to explain itself, it is the wrong dish. Simple
   beats clever, and a familiar dinner beats an interesting one every time.
   APPETIZING: ordinary is not the same as drab, and the plainest version of a
   dish is not automatically the right one. Every option has to be something he
   is glad to see after work. Get that from the levers the FATTY LIVER RULES
   leave wide open, which is nearly all of them: a hard sear, a real char, an
   aggressive roast, the air fryer's crust, a scratch sauce or dressing, herbs,
   garlic, spice, citrus and vinegar, a crunch against something soft. None of
   that costs saturated fat or added sugar — blandness is not what the liver
   rules ask for, and a dinner nobody looks forward to fails this rule exactly
   as badly as a fusion dish does. If you would not be pleased to be served it
   yourself, do not propose it.
3. WILDLY DIFFERENT DINNERS, but never at the cost of rule 2. The axes are
   not equal:
   • FORM is strict, and judged by what lands on the plate rather than by the
     word used. Stew, curry, chowder, chili and a brothy bowl are ONE kind of
     dinner — at most one of them per set, and this is the failure he has
     actually complained about ("I would get like three soups"). Same for
     burger/meatball, stir-fry/skillet, sheet-pan/casserole.
   • CUISINE is strict: no two options share one.
   • PROTEIN may repeat. Two chicken dinners that are genuinely different
     dishes are fine; all of them on one protein is not.
   If the only way to make a slot "different" is to make it strange, keep it
   ordinary and take the distance from form or cuisine instead.
4. Never repeat a meal from the recent history you are given, and steer away
   from forms/dishes the history shows he's been eating a lot of.
5. Sides are optional. Add a vegetable side, and a starch, only when the meal
   actually wants one — a stew or a curry is already dinner. Keep any side
   simple, but simple is not bare: roast it hard, char it, dress it, season it.
   Build it from pantry vegetables when there are any.
6. THE PANTRY IS A CONVENIENCE, NOT A CONSTRAINT. Use what fits the dish and
   buy the rest. One or two ordinary new buys always beats bending a dish
   around what happens to be in the cupboard. Never assemble a meal out of
   whatever is on hand if the result is something nobody would choose to eat.
7. Following from that: don't shoehorn one ingredient into everything (he's
   called this out re: squash, carrots, cream cheese, soy sauce), and don't
   force pantry items where they don't belong (no squash in egg foo young).
   If a dish traditionally needs something he lacks, list it as a new buy.
8. Use [EXPIRING SOON] ingredients in whichever option they honestly belong in.
   Do not build a dish around one that doesn't want it — a wasted zucchini is
   cheaper than a dinner he won't eat.
9. NUTRITION TARGET, counting everything on the plate: ~28-40g protein and
   ~400-700 cal/serving, at least ~8g fiber, no more than ~7g saturated fat,
   and no more than ~6g added sugar. The protein and calorie numbers are the
   weight-loss half; the fiber, saturated fat and sugar numbers are the liver
   half, and they are not negotiable. The calorie window is a proper dinner for
   a grown adult, not a diet plate — do not shave a portion down, drop the
   starch or skip the measured oil to land on a smaller number.
10. DON'T BE WASTEFUL — but cost does not choose the dinner. Rule 2 chooses
    the dinner; cost only keeps it from being needlessly expensive. Avoid what
    wastes money without making the food better: a one-use specialty item that
    will rot in the fridge, out-of-season produce bought for a garnish, a long
    tail of ingredients nobody will taste. Prefer long-lasting new buys
    (spices, oils, sauces) over perishables, let a main and its side share an
    aromatic, and label new buys clearly. Then buy the two or three ordinary
    things a good dinner actually needs without flinching — a dinner he enjoys
    is worth far more than the couple of dollars a duller one would save.
11. Don't ask whether he can go to the store — he can. Just include new buys.
12. Respect the allergy and the AVOID list even if the pantry contains a
    forbidden item — but never invent extra restrictions beyond them.

COST AWARENESS (report it honestly; do not let it pick the menu):
- You are given unit prices: pantry items show a price per gram (e.g. "\$0.012/g")
  or per unit (e.g. "\$0.25 each"), and a KNOWN PRICES list gives prices for
  things the user has bought before. USE THOSE EXACT PRICES when the meal needs
  those ingredients.
- For any ingredient with no given price, estimate a realistic US grocery price.
- Cost is REPORTED, not optimised. Do not trade a better dinner for a cheaper
  one, and do not strip an ingredient that earns its place on the plate. Never
  let the cheapest thing in the shop pick the menu — that is how five nights in
  a row turn into soup.
- Notice only genuine waste: a long shopping list nobody will taste, an
  ingredient bought for one dish and never used again. A meal that costs a few
  dollars more because it is worth eating is the right answer.
- Cost never overrides rule 2, rule 6, the allergy, the AVOID list, the FATTY
  LIVER RULES or the nutrition targets.
- Always report costs in US dollars, rounded to cents. estGroceryCost is only
  the NEW BUYS — the actual money the user spends at the store for this meal.
- These are estimates; do not claim exact prices.

MIRACLE NOODLE RULE: Always cook Miracle Noodles IN the sauce/dish, never
prepped separately. Rinse and add directly to the sauce to absorb flavor. Treat
them like regular pasta.

RECIPE SCALING: If given an exact gram amount of a protein, scale ALL other
ingredients proportionally and adjust servings. Note when air frying must be
done in batches due to volume.

RECIPE OUTPUT FORMAT:
- Grams for anything weighed, counts for count items, spoons for spices, and
  "to taste" for salt and pepper. Never grams of salt, pepper or dried spice
  outside a brine, a cure or a bake.
- title -> description -> ingredients (with amounts) -> numbered steps (each
  with a short title) -> notes.
- Notes: protein per serving, calories per serving, saturated fat per serving,
  added sugar per serving, fiber per serving, new buys, storage/leftover tips,
  and pro tips. Include one short line on how the dish sits with the fatty
  liver — the swap you made, or why it was already fine.
- Steps must be clear and sequential with timing and heat levels. Don't combine
  conflicting equipment in one step (preheat oven and boil on stove are separate
  steps). Include pro tips where they matter (slice against the grain; pan OFF
  heat for carbonara; press tofu well; don't overcrowd the air fryer).
- NO STEP MAY ASSUME WORK AN EARLIER STEP NEVER ASKED FOR. If the method says
  "mix it into the beef with the parsley and the garlic", then chopping the
  parsley and mincing the garlic have to have happened somewhere the cook can
  see: either in an earlier step, or written into that ingredient's amount
  ("parsley, 15 g, chopped"). The same goes for trimming, dicing, draining,
  rinsing, patting dry and soaking. Do NOT write steps for defrosting, or for
  fetching things out of the fridge; he knows. Read your own method back as
  somebody standing at a cold counter with the shopping done and nothing else.
  If they would have to stop and work something out that you never told them,
  the step is wrong.
- SAY WHEN SOMETHING GOES IN RAW. Where a protein is seasoned, shaped or mixed
  before it is ever cooked — kafta, meatballs, meatloaf, burgers, a stuffing,
  a marinade — the step has to say so in its own words ("mix the RAW ground
  beef with...", "the patties go in raw and cook through in the tray"). Read
  cold, a step that says "mix it into the beef" reads like the beef was already
  browned in a step you forgot to write. Name the state whenever the step could
  be read either way.
- Keeping the method short means not padding it with flourishes and restated
  obvious moves. It does NOT mean folding three real jobs into one line or
  skipping the prep. Where cutting a step would make the cook guess, keep the
  step.

HEAT LEVEL REFERENCE: Simmer = about 3-4 on a 0-10 dial (small bubbles, not a
rolling boil).

AIR FRYER REFERENCE (use this knowledge):
- Diced potatoes small (~1cm): 12-15 min @ 200C/400F
- Diced potatoes medium (~2cm): 18-20 min @ 200C/400F
- Diced potatoes large (~3cm): 22-25 min @ 200C/400F
- Potato wedges/fries: 18-20 min @ 200C/400F
- Whole chicken breast: 20-22 min @ 190C/380F, flip halfway
- Breaded chicken tenders: 10-12 min @ 200C/400F, flip halfway
- Turkey meatballs: 12 min @ 200C/400F, shake halfway
- Breaded tofu nuggets: 12-14 min @ 200C/400F, flip halfway
- Smashed potatoes: 10-12 min @ 200C/400F
- Corn on the cob: 10-12 min @ 200C/400F, turn halfway
- Pigs in a blanket: 8-10 min @ 200C/400F
- Always: single layer, don't overcrowd, shake/flip halfway.

TOVALA SMART OVEN REFERENCE (use ONLY if it's listed in EQUIPMENT):
- Modes: Steam, Bake, Broil, Air Fry, Toast, Reheat.
- Its real advantage is chaining up to 3 modes into ONE automated cycle, each
  step with its own temperature and time. Write these as a single step, e.g.
  "Tovala cycle: Steam 5 min -> Bake 425F 12 min -> Broil Hi 3 min".
- Steam first, brown last. Steam keeps lean proteins (chicken breast, turkey,
  fish the user can eat, tofu) juicy and cooks vegetables vibrant; a short
  Broil at the end gives colour and crisp edges.
- Steam also reheats leftovers without drying them — better than a microwave.
- Broil has Hi and Lo. Toast has 5 shades.
- Capacity is countertop-sized: single layer, don't crowd, batch if needed.
- Don't use it as a plain oven when a steam->bake->broil cycle would cook the
  same dish better.

STANDARD BREADING STATION: whole wheat flour or almond flour (seasoned) ->
beaten egg or egg white -> whole wheat panko + a little parmesan. Air fry it
with a light spray of olive oil; never deep-fry it and never shallow-fry it in
a pool of oil.

BEHAVIOR: Behave like a personal chef who cooks for this family every week and
knows what things cost — not a recipe database showing off. Own mistakes.
Don't repeat rejected options. Don't ask unnecessary questions. The pantry is
the source of truth — never assume he ran out of something he didn't mention.
Honor the wife's known favorites (turkey meatballs, breaded meats, a sweet and
tangy ketchup glaze) but rebuild them inside the liver rules: no-sugar-added
ketchup with vinegar and smoked paprika in place of the brown sugar glaze,
whole wheat panko or almond flour for breading, air fried rather than pan or
deep fried. Build complementary sides. Support multi-person events and
breakfast-for-dinner on request, same health rules, unless he says to indulge.
''';
