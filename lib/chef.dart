import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import 'chef_models.dart';
import 'models.dart';

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
  static const String _kModel = 'chef_model'; // 'haiku' | 'sonnet'

  static Future<String?> getApiKey() => _s.read(key: _kKey);
  static Future<void> setApiKey(String v) =>
      v.trim().isEmpty ? _s.delete(key: _kKey) : _s.write(key: _kKey, value: v.trim());
  static Future<bool> hasApiKey() async =>
      (await getApiKey())?.isNotEmpty ?? false;

  static Future<String> getModelId() async {
    final String? m = await _s.read(key: _kModel);
    return m == 'sonnet' ? kChefModelSonnet : kChefModelHaiku;
  }

  static Future<bool> isSonnet() async =>
      (await _s.read(key: _kModel)) == 'sonnet';
  static Future<void> setSonnet(bool on) =>
      _s.write(key: _kModel, value: on ? 'sonnet' : 'haiku');
}

class Chef {
  static const String _endpoint = 'https://api.anthropic.com/v1/messages';

  // ── Call 1: three options ─────────────────────────────────────────────
  static Future<List<MealOption>> generateOptions({
    required List<PantryItem> pantry,
    required int servings,
    required List<String> recentMeals,
  }) async {
    final String user = '''
CURRENT PANTRY (what's in stock — [EXPIRING SOON] items must be prioritized):
${formatPantry(pantry)}

RECENTLY MADE — do NOT repeat any of these:
${recentMeals.isEmpty ? '(none yet)' : recentMeals.map((String m) => '- $m').join('\n')}

Cooking for $servings ${servings == 1 ? 'person' : 'people'}.

Propose exactly 3 dinner options. Each option MUST use a DIFFERENT protein from
the accepted list. Prioritize any [EXPIRING SOON] ingredient. Options must be
genuinely different from each other. Follow every hard rule.

Respond with ONLY valid JSON, no markdown, in exactly this shape:
{"options":[{"title":"","desc":"","protein":"","newBuys":"","proteinPerServing":0,"caloriesPerServing":0}]}
"newBuys" is a short comma list (or "No new buys" if all from pantry).''';

    final Map<String, dynamic> data = await _post(user: user, maxTokens: 1500);
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
  static Future<Recipe> generateRecipe({
    required MealOption option,
    required int servings,
  }) async {
    final String user = '''
Write the full recipe for "${option.title}" (${option.desc}) for $servings
${servings == 1 ? 'person' : 'people'}. ALL measurements in GRAMS (count items
like eggs as counts). Cook Miracle Noodles IN the sauce if used. Include heat
levels, timing, and pro tips. Follow every user rule and the recipe format.

For each step, set "timerSeconds" to the number of seconds for any wait/cook/
rest timer in that step (e.g. 6 minutes = 360). Use 0 when the step has no
time-based action.

Respond with ONLY valid JSON, no markdown, in exactly this shape:
{"title":"","description":"","ingredients":[{"item":"","amount":""}],"steps":[{"title":"","content":"","timerSeconds":0}],"notes":""}
"notes" is one string containing protein per serving, calories per serving, any
new buys, and storage/pro tips.''';

    final Map<String, dynamic> data = await _post(user: user, maxTokens: 2500);
    return Recipe.fromJson(data, baseServings: servings);
  }

  // ── shared request ────────────────────────────────────────────────────
  static Future<Map<String, dynamic>> _post({
    required String user,
    required int maxTokens,
  }) async {
    final String? key = await ChefKeys.getApiKey();
    if (key == null || key.isEmpty) {
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
    final List<PantryItem> live = pantry
        .where((PantryItem i) => !i.deleted && i.remaining > 0)
        .toList()
      ..sort((PantryItem a, PantryItem b) {
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
      final String amt = it.isCount
          ? '${_fmt(it.remaining)} ct'
          : '${_fmt(it.remaining)} g';
      sb.write('- ${it.name}: $amt');
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
- DISLIKES (never use): pork, ALL seafood, yogurt-based dips, chili powder,
  spicy food of any kind.
- ACCEPTED PROTEINS ONLY:
  * Chicken — ground, or breast. Breast MUST be chopped into pieces if pan-
    cooked (he hates cooking a whole breast on a pan). Whole breast is fine in
    the air fryer.
  * Beef — ground, cube steak, flank/skirt steak.
  * Ground turkey.
  * Firm tofu.
- Equipment: air fryer, oven, stove, toaster oven.
- Goals: weight loss, high protein, low calorie, superfoods, more energy.
- Measurements: ALWAYS grams (never oz). Count items like eggs stay as counts.

MEAL GENERATION RULES:
1. Present exactly 3 options; the user picks one.
2. Each of the 3 options uses a DIFFERENT protein.
3. Never repeat a meal from the recent history you are given.
4. Never suggest steak & eggs (he's sick of it).
5. The 3 options must be genuinely different dishes — not 3 versions of one.
6. Don't shoehorn the same ingredient into everything (he's called this out re:
   squash, carrots, cream cheese, soy sauce). Vary it.
7. Don't force pantry items where they don't belong (no squash in egg foo
   young). If a dish traditionally needs something he lacks, list it as a new buy.
8. Prioritize [EXPIRING SOON] ingredients — build meals around them.
9. High protein, low calorie — target ~28-40g protein and ~200-420 cal/serving.
10. Minimize new purchases; prefer long-lasting new buys (spices, oils, sauces)
    over perishables. Label new buys clearly.
11. Don't ask whether he can go to the store — he can. Just include new buys.
12. Respect all dislikes/allergies even if the pantry contains a forbidden item.

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
- Notes: protein per serving, calories per serving, new buys, storage/leftover
  tips, and pro tips.
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

STANDARD BREADING STATION: flour (seasoned) -> beaten egg -> breadcrumb +
parmesan mix.

BEHAVIOR: Behave like a personal chef, not a recipe database. Own mistakes.
Don't repeat rejected options. Don't ask unnecessary questions. The pantry is
the source of truth — never assume he ran out of something he didn't mention.
Honor the wife's known favorites (ketchup-brown sugar glaze, turkey meatballs,
breaded meats) and build complementary sides. Support multi-person events and
breakfast-for-dinner on request, same health rules, unless he says to indulge.
''';
