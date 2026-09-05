import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'avoid.dart';
import 'chef_models.dart';
import 'liver.dart';
import 'models.dart';
import 'pricebook.dart';
import 'spending.dart';

// ═══════════════════════════════════════════════════════════════════════
// AI CHEF — talks to the Claude API directly from the phone.
//
// Two-call flow (kept separate on purpose — see the master spec):
//   Call 1  generateOptions() → 3 protein-varied meal options
//   Call 2  generateRecipe()  → the full grams-based recipe
//
// Model default: claude-haiku-4-5 (cheap, plenty for this). Optional
// claude-sonnet-4-6 toggle. The fixed rules ride in the cached system block;
// the live pantry + history + servings are the per-call user message.
//
// The API key is entered once in Settings and stored encrypted on-device via
// flutter_secure_storage — never hardcoded, never in the repo. Native apps
// have no CORS restriction, so the direct call just works.
// ═══════════════════════════════════════════════════════════════════════

const String kChefModelHaiku = 'claude-haiku-4-5';
const String kChefModelSonnet = 'claude-sonnet-4-6';
const String kChefModelOpus = 'claude-opus-4-8';

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
  ChefException(this.message);
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

  // ── Call 1: three options ─────────────────────────────────────────────
  // [request], when given, is a free-text craving/description (e.g. from the
  // wife) — the 3 options are then tailored to it. [justShown] are the titles
  // of options the user just rejected with "three different ideas", so a
  // regenerate can't hand back the same three. [recentForms] is derived from
  // recentMeals so the chef is steered away from what it keeps making.
  static Future<List<MealOption>> generateOptions({
    required List<PantryItem> pantry,
    required int servings,
    required List<String> recentMeals,
    PriceBook prices = const PriceBook(),
    SpendProfile spend = SpendProfile.empty,
    String? request,
    List<String> justShown = const <String>[],
    List<String> recentForms = const <String>[],
  }) async {
    final String req = request?.trim() ?? '';
    final bool hasReq = req.isNotEmpty;
    final List<String> avoids = await ChefKeys.getAvoids();
    // Ask, check, and if the three came back as one dinner in three hats — or
    // with a food he doesn't eat — ask again with the specific complaint
    // attached. An avoid violation is a hard failure, so it gets a second
    // retry; variety alone gets one.
    List<MealOption> out = await _askOptions(
        pantry: pantry,
        servings: servings,
        recentMeals: recentMeals,
        prices: prices,
        spend: spend,
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
            spend: spend,
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
  /// three-dinners-in-one-hat are the softer ones.
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
    required SpendProfile spend,
    required String request,
    required List<String> justShown,
    required List<String> recentForms,
    String complaint = '',
  }) async {
    final String req = request;
    final bool hasReq = req.isNotEmpty;
    final String knownPrices = formatKnownPrices(prices, pantry);
    final String spending = formatSpending(spend);
    final String proteinValue = formatProteinValue(prices, pantry);
    final String equipment = formatEquipment(await ChefKeys.getEquipment());
    final String formList = kDishForms.join(', ');

    final String task = hasReq
        ? '''
The user has a SPECIFIC REQUEST for this meal:
"$req"

Propose exactly 3 options that satisfy this request as closely as possible while
still obeying EVERY hard rule (allergy, AVOID list). They must be three ordinary
dinners a home cook would recognise, and three different ones: no two alike on
both dish FORM and cuisine, and not all three on either. They do NOT need
different proteins if the request points to one. Use pantry items where they
fit; new buys are expected and fine to fulfil the request. Only prioritize an
[EXPIRING SOON] item if it suits the request.'''
        : '''
Propose exactly 3 dinner options. Every one of them must be an ordinary dinner
a home cook would recognise and could name in a few plain words — the kind of
thing that turns up on a weeknight table.

They also have to be three different dinners, judged on three axes:
  • dish FORM — pick each from: $formList.
  • CUISINE / flavor family.
  • primary PROTEIN — any protein not on the AVOID list.
The bar is: no two options may match on TWO of those axes, and all three may
not share any single one. Two chicken dinners are fine when they are genuinely
different dishes. Three chicken dinners, or three sheet-pans, are not.

Being different is the lower priority of the two. Never reach for an unusual
dish, a fusion, or an exotic ingredient to make the three look varied — a
plain, familiar third option beats a clever one every time. Use any
[EXPIRING SOON] ingredient in whichever option it honestly belongs in.''';

    final String avoids = formatAvoids(await ChefKeys.getAvoids());
    final String user = '''
CURRENT PANTRY (what's in stock — use [EXPIRING SOON] items where they fit,
never by forcing them; prices shown are per gram or per unit):
${formatPantry(pantry)}
${knownPrices.isEmpty ? '' : '''

KNOWN PRICES (the user has bought these before — use these exact unit prices if
a meal needs them as new buys):
$knownPrices'''}
${proteinValue.isEmpty ? '' : '''

PROTEIN VALUE — what a gram of protein actually costs him, worked out from the
prices above. Protein is the target that costs the most to hit, so this is
where a cheap dinner is won or lost:
$proteinValue'''}
${spending.isEmpty ? '' : '''

WHAT HE ACTUALLY SPENDS (his own ledger — money is counted when food is USED,
not when it is bought). This is not a budget and there is no limit to hit; it
is what the bill really looks like, so you can cook against it:
$spending'''}

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

The user just REJECTED these three and asked for different ideas — none of your
options may resemble them (not the same dish, form, or spin):
${justShown.map((String t) => '- $t').join('\n')}'''}
${complaint.isEmpty ? '' : '''

YOUR LAST ATTEMPT WAS REJECTED: $complaint. Fix that by swapping in a different
ORDINARY dinner, not a stranger one. Nothing on the AVOID list (or in a group it
names) may appear in any option.'''}

Cooking for $servings ${servings == 1 ? 'person' : 'people'}.

$task

LIVER AND WEIGHT: every one of the 3 options must already sit inside the fatty
liver rules as written — no more than ~7g saturated fat and ~6g added sugar per
serving, at least ~8g fiber, whole grains rather than refined, olive oil as the
fat, nothing deep-fried, no alcohol, no cured or processed meat. Do not offer a
dish you would then have to apologise for. If a familiar dinner needs lightening
to get there, lighten it and say so in one clause of "desc".

SIDES ARE OPTIONAL. Add a simple vegetable side (and a starch) only where the
meal genuinely wants one — a stew, a curry or a loaded bowl is already dinner
and needs nothing bolted on. When you do add one, keep it plain: roasted,
steamed or a quick salad, built from pantry vegetables when there are any.
Leave "sides" empty when the dish stands on its own. Nutrition and cost figures
cover whatever is on the plate.

The pantry above is the COMPLETE list of what the user has. Everything else —
including any protein, oil, spice, or staple — is a NEW BUY. Do not claim the
user already has an ingredient that is not listed above; put it in newBuys.

COST: these are weeknight dinners on a budget. Keep each ingredient list short
and made of everyday groceries — an ingredient earns its place by changing the
dish, not by being authentic. Build on cheap staples and keep the expensive
things to accents. Buy the one or two ordinary things a dish needs (rule 6),
but notice when an option is drifting expensive and pull it back before you
propose it.
For each option estimate its total cost for $servings ${servings == 1 ? 'serving' : 'servings'}
(estCostTotal) and per serving (estCostPerServing), in US dollars. Use the unit
prices above for pantry/known items; estimate typical grocery prices for the
rest.

Respond with ONLY valid JSON, no markdown, in exactly this shape:
{"options":[{"title":"","desc":"","protein":"","form":"","cuisine":"","sides":"","newBuys":"","proteinPerServing":0,"caloriesPerServing":0,"satFatPerServing":0,"addedSugarPerServing":0,"fiberPerServing":0,"estCostTotal":0,"estCostPerServing":0}]}
"satFatPerServing", "addedSugarPerServing" and "fiberPerServing" are grams per
serving for everything on the plate — the liver numbers, estimated honestly, not
rounded down to look good.
"form" is one entry from the form list above. "cuisine" is a short label
(e.g. "Thai", "Tex-Mex", "Mediterranean"). "sides" names the vegetable side and
any starch, or is "" when the dish needs none. "newBuys" is a short comma list
(or "No new buys" if all from pantry). Cost fields are numbers in dollars
(e.g. 8.50).''';

    final Map<String, dynamic> data = await _post(user: user, maxTokens: 1800);
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
    final String proteinValue = formatProteinValue(prices, pantry);
    final String equipment = formatEquipment(await ChefKeys.getEquipment());
    final String avoids = formatAvoids(await ChefKeys.getAvoids());
    final String user = '''
Write the full recipe for "${option.title}" (${option.desc}) for $servings
${servings == 1 ? 'person' : 'people'}. ALL measurements in GRAMS (count items
like eggs as counts). Cook Miracle Noodles IN the sauce if used. Include heat
levels, timing, and pro tips. Follow every user rule and the recipe format.
Keep it as simple as the dish honestly allows: as few steps and as few
ingredients as the dish actually needs, and no technique a home cook on a
weeknight wouldn't use. Do not pad the method to look thorough.
${option.sides.isEmpty ? '' : '''
The side is part of this recipe: "${option.sides}". Include its ingredients and
its steps, sequenced so everything lands together (start what takes longest
first; say when to start the side). Keep the side plain — it is a side.'''}

PANTRY (the complete list of what the user has on hand; prices are per gram or
per unit):
${formatPantry(pantry)}
${knownPrices.isEmpty ? '' : '''

KNOWN PRICES (bought before — use these exact unit prices for these new buys):
$knownPrices'''}
${proteinValue.isEmpty ? '' : '''

PROTEIN VALUE — what a gram of protein costs him from each source. The gram
amounts you write are where the money in this recipe is actually spent: hit the
protein target, don't overshoot it, and let the cheaper sources carry the load
wherever the dish allows it:
$proteinValue'''}

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

  // ── shared request ────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> _post({
    required String user,
    required int maxTokens,
  }) async {
    final String key = await ChefKeys.effectiveKey();
    if (key.isEmpty) {
      throw ChefException('Add your Claude API key in Settings first.');
    }
    final String model = await ChefKeys.getModelId();

    final Map<String, dynamic> body = <String, dynamic>{
      'model': model,
      'max_tokens': maxTokens,
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
          .timeout(const Duration(seconds: 60));
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
      throw ChefException("Couldn't read the chef's reply — try again.");
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

  /// Pull the first JSON object out of the reply, tolerating stray markdown
  /// fences or prose around it.
  static Map<String, dynamic> _extractJson(String text) {
    final int start = text.indexOf('{');
    final int end = text.lastIndexOf('}');
    if (start < 0 || end <= start) {
      throw ChefException("The chef's reply wasn't valid — try again.");
    }
    final dynamic d = jsonDecode(text.substring(start, end + 1));
    if (d is Map<String, dynamic>) {
      return d;
    }
    throw ChefException("The chef's reply wasn't valid — try again.");
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
  static String formatKnownPrices(PriceBook prices, List<PantryItem> pantry) {
    if (prices.isEmpty) {
      return '';
    }
    final Set<String> inStock = pantry
        .where((PantryItem i) => !i.deleted && (i.remaining > 0 || i.untracked))
        .map((PantryItem i) => i.name.trim().toLowerCase())
        .toSet();
    final List<PriceEntry> known = prices.byName.values
        .where((PriceEntry e) =>
            e.unitPrice > 0 && !inStock.contains(e.name.trim().toLowerCase()))
        .toList()
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

  /// What he actually spends, from his own ledger. Not a budget and not a
  /// limit — there is nothing here to pass or fail. It is context, so the chef
  /// cooks against the real bill instead of a vague sense that food costs
  /// money. Empty until there are enough complete weeks to call anything
  /// typical.
  static String formatSpending(SpendProfile p) {
    if (!p.hasHistory) {
      return '';
    }
    final StringBuffer sb = StringBuffer();
    sb.writeln('- A normal week for him: ${_money(p.typicalWeek)}');
    if (p.lastWeek > 0) {
      sb.writeln('- Last week: ${_money(p.lastWeek)}');
    }
    if (p.weekToDate > 0) {
      sb.writeln('- Already spent this week: ${_money(p.weekToDate)}');
    }
    if (p.isClimbing) {
      sb.writeln('- His grocery spend is CLIMBING: the last few weeks run '
          '${_money(p.recentAvgPerWeek)} a week against '
          '${_money(p.priorAvgPerWeek)} before that '
          '(+${p.trendPct.round()}%). Pulling that back matters to him right '
          'now.');
    }
    if (p.drivers.isNotEmpty && p.recentTotal > 0) {
      sb.writeln('- Where the money has been going lately '
          '(${_money(p.recentTotal)} in total):');
      for (final MapEntry<String, double> d in p.drivers) {
        final int share = ((d.value / p.recentTotal) * 100).round();
        sb.writeln('  • ${d.key}: ${_money(d.value)}'
            '${share >= 5 ? ' — $share% of it' : ''}');
      }
    }
    return sb.toString().trimRight();
  }

  /// Is this food worth ranking as a PROTEIN at all? Cost per gram of protein
  /// is a meaningless number for oregano — a spice with a trace of protein and
  /// a high price per gram lands at the top of the "dearest protein" list and
  /// says nothing. Only foods carrying real protein for their weight qualify:
  /// 10 g per 100 g, or 3 g in a countable unit (an egg has about 6).
  static bool isProteinSource(double proteinPerUnit, bool isCount) =>
      isCount ? proteinPerUnit >= 3 : proteinPerUnit >= 0.10;

  /// Cost per gram of PROTEIN, worked out from his own prices and his own
  /// scanned macros. Protein is the target that costs the most to hit, so this
  /// is the list that decides whether a cheap dinner is possible at all.
  /// Only foods with both a price and macros can appear.
  static String formatProteinValue(PriceBook prices, List<PantryItem> pantry) {
    final Map<String, ({double perProtein, bool inStock})> byName =
        <String, ({double perProtein, bool inStock})>{};
    for (final PantryItem it in pantry) {
      if (it.deleted ||
          it.costPerProteinGram <= 0 ||
          !isProteinSource(it.proteinPerUnit, it.isCount)) {
        continue;
      }
      byName[it.name.trim()] =
          (perProtein: it.costPerProteinGram, inStock: true);
    }
    for (final PriceEntry e in prices.byName.values) {
      final String key = e.name.trim();
      if (e.costPerProteinGram <= 0 ||
          byName.containsKey(key) ||
          !isProteinSource(e.proteinPerUnit, e.isCount)) {
        continue;
      }
      byName[key] = (perProtein: e.costPerProteinGram, inStock: false);
    }
    if (byName.length < 3) {
      return '';
    }
    final List<MapEntry<String, ({double perProtein, bool inStock})>> sorted =
        byName.entries.toList()
          ..sort((MapEntry<String, ({double perProtein, bool inStock})> a,
                  MapEntry<String, ({double perProtein, bool inStock})> b) =>
              a.value.perProtein.compareTo(b.value.perProtein));

    String line(MapEntry<String, ({double perProtein, bool inStock})> e) =>
        '  • ${e.key}: ${_perProtein(e.value.perProtein)}'
        '${e.value.inStock ? ' (in the pantry)' : ''}';

    final int cheapCount = sorted.length < 8 ? sorted.length : 8;
    final StringBuffer sb = StringBuffer();
    sb.writeln('CHEAPEST protein he has prices for:');
    for (final MapEntry<String, ({double perProtein, bool inStock})> e
        in sorted.take(cheapCount)) {
      sb.writeln(line(e));
    }
    // The dear end only when there is one left to show — with a short list,
    // repeating the same foods under a second heading says nothing.
    final List<MapEntry<String, ({double perProtein, bool inStock})>> rest =
        sorted.skip(cheapCount).toList();
    if (rest.isNotEmpty) {
      final int dearCount = rest.length < 4 ? rest.length : 4;
      sb.writeln('DEAREST protein he has prices for:');
      for (final MapEntry<String, ({double perProtein, bool inStock})> e
          in rest.skip(rest.length - dearCount)) {
        sb.writeln(line(e));
      }
    }
    return sb.toString().trimRight();
  }

  static String _money(double v) => '\$${v.toStringAsFixed(2)}';

  /// "$0.04 per g of protein" — the unit that makes proteins comparable.
  static String _perProtein(double v) =>
      '\$${v.toStringAsFixed(v < 0.1 ? 3 : 2)} per g of protein';

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
  preferences.
- HOW HE COOKS: weeknight dinners for two, on a tight budget, after work. Cheap
  is a goal in its own right here, sitting alongside the protein and calorie
  targets rather than below them. Money is tighter than it was and he is
  actively trying to bring the grocery bill down, so a dinner that costs less
  is worth real something to him. Where cost and the liver rules pull against
  each other, the liver wins — beans, lentils and cabbage are cheap, so this is
  rarely the trade it looks like.
- Measurements: ALWAYS grams (never oz). Count items like eggs stay as counts.

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
1. Present exactly 3 options; the user picks one.
2. REGULAR FOOD. This is the rule that outranks the rest. Every option is an
   ordinary dinner a home cook would recognise and could name in a few plain
   words — the sort of thing that turns up on a weeknight table. Cook a dish
   as its own cuisine; never invent a fusion, never mash two cuisines onto one
   plate, never build a dish around a novelty ingredient. If the title needs a
   clause to explain itself, it is the wrong dish. Simple beats clever, and a
   familiar dinner beats an interesting one every single time.
3. THREE DIFFERENT DINNERS, but never at the cost of rule 2. Judge it on dish
   FORM, cuisine, and protein: no two options alike on two of those three, and
   not all three sharing any one of them — no three meatball dishes, no three
   sheet-pans. Two chicken dinners that are actually different dishes are fine.
   If the only way to make a third option "different" is to make it strange,
   make it ordinary instead.
4. Never repeat a meal from the recent history you are given, and steer away
   from forms/dishes the history shows he's been eating a lot of.
5. Sides are optional. Add a simple vegetable side, and a starch, only when the
   meal actually wants one — a stew or a curry is already dinner. Keep any side
   plain, and build it from pantry vegetables when there are any.
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
   ~200-500 cal/serving, at least ~8g fiber, no more than ~7g saturated fat,
   and no more than ~6g added sugar. The protein and calorie numbers are the
   weight-loss half; the fiber, saturated fat and sugar numbers are the liver
   half, and they are not negotiable.
10. COST IS PART OF THE DISH. Every ingredient is money he spends and a thing
    he has to shop for, measure and wash up after — so each one has to earn its
    place. Add it if it genuinely changes the dish; leave it out if it is only
    there to be authentic or thorough. Let a main and its side share an
    aromatic, an oil, a sauce rather than each pulling its own. Lean on salt,
    heat and technique before another jar. Prefer long-lasting new buys
    (spices, oils, sauces) over perishables and one-use specialty items that
    will rot in the fridge; label new buys clearly. None of this outranks rule
    2 — a strange dinner is not a saving, and neither is a bland one. Getting
    a lot out of a few ordinary ingredients is the skill being asked for.
11. Don't ask whether he can go to the store — he can. Just include new buys.
12. Respect the allergy and the AVOID list even if the pantry contains a
    forbidden item — but never invent extra restrictions beyond them.

COST AWARENESS (money is genuinely tight for him right now — the grocery bill
matters more than it used to, and you treat it as if it were coming out of your
own pocket):
- You are given unit prices: pantry items show a price per gram (e.g. "\$0.012/g")
  or per unit (e.g. "\$0.25 each"), and a KNOWN PRICES list gives prices for
  things the user has bought before. USE THOSE EXACT PRICES when the meal needs
  those ingredients.
- For any ingredient with no given price, estimate a realistic US grocery price.
- YOU ARE GIVEN HIS REAL SPENDING, not a guess: what a normal week costs him,
  what the last one cost, whether it is climbing, and the items the money has
  actually been going to. Read those numbers and cook against them.
  * The named cost drivers are the specific foods draining his budget. Anything
    at the top of that list has to earn its place all over again — propose it
    only when the dish genuinely needs it, in a smaller amount, or not at all.
    Do not build two of the three options on the same expensive driver.
  * When his spend is marked as CLIMBING, that is the week to lean cheaper
    across all three options, not to offer two dear ones and one saver.
  * These figures are context, not a budget. There is no number you must come
    in under and nothing is rejected on price. What is asked is that the money
    shows in the choices you make.
- PROTEIN IS WHERE THE MONEY GOES. His targets need 28-40 g of protein a
  serving, and protein is the dearest thing on the plate — so the cost of a
  dinner is mostly decided by which protein you reach for and how much of it
  you use.
  * You are given cost PER GRAM OF PROTEIN for the foods he has prices for.
    That, not the price per pound, is what makes proteins comparable: a cheap
    cut that is half water can cost more per gram of protein than a dear one.
  * Favour the cheap end of that list. Eggs, tinned fish, chicken thigh, lean
    ground turkey, cottage cheese, lentils, dried beans and tofu are the usual
    winners, and every one of them suits the liver rules.
  * Let legumes carry part of the protein where the dish honestly allows it —
    beans in the chilli, lentils in the sauce. That is the single biggest
    saving available, and it raises the fiber at the same time.
  * Hit the protein target; do not overshoot it. 200 g of meat a serving where
    150 g makes the number is money spent for nothing.
- Cost is not a tiebreaker you apply at the end — it shapes the dish from the
  start. Ordinary weeknight food is mostly cheap food, and the cheap version is
  usually the liver-friendly one too. Build the dish on the plain everyday form
  of whatever it needs, and let the expensive things be accents rather than the
  centre of the plate. Do not reach for a particular ingredient because it is on
  some list of good ones — pick what the dish wants.
- Notice when a meal is drifting expensive — a long shopping list, out-of-season
  produce, a cut or an ingredient bought for one dish — and pull it back before
  you propose it. If one of the three is dearer because it is genuinely worth
  it, fine; not all three.
- NEVER LECTURE HIM ABOUT MONEY. He knows what things cost; that is why you
  have his ledger. Do not mention his budget, his spending, savings made, or
  how thrifty a dish is, in any title, description or note. The saving shows up
  in what you propose, never in what you say about it.
- This never overrides rule 2, rule 6, the allergy, the AVOID list or the
  nutrition targets. A dinner he won't eat is not a saving. Buy the one or two
  ordinary things a good dinner needs.
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
- All measurements in grams (counts for count items).
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
