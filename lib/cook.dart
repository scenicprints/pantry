import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'chef.dart';
import 'chef_models.dart';
import 'models.dart';
import 'notifications.dart';
import 'pricebook.dart';
import 'storage.dart';
import 'theme.dart';

// ═══════════════════════════════════════════════════════════════════════
// COOK TAB — the AI chef. Reads the live pantry, asks Claude for 3 options,
// then a full grams-based recipe with a live servings scaler, cooking mode,
// and per-step timers.
// ═══════════════════════════════════════════════════════════════════════

/// "$8.50" — shared money formatter for the cost estimates.
String money(double v) => '\$${v.toStringAsFixed(2)}';

class CookTab extends StatefulWidget {
  final List<PantryItem> items;
  final PriceBook prices;
  const CookTab(
      {super.key, required this.items, this.prices = const PriceBook()});

  @override
  State<CookTab> createState() => _CookTabState();
}

class _CookTabState extends State<CookTab> {
  int _servings = 2;
  MealHistory _history = const MealHistory(kSeedMealHistory);
  List<PlannedMeal> _planned = <PlannedMeal>[];
  RecipeBox _box = const RecipeBox();
  bool _hasKey = false;

  @override
  void initState() {
    super.initState();
    _history = MealHistory.decode(LocalCache.loadHistory());
    _planned = PlannedMenu.decode(LocalCache.loadPlanned()).meals;
    _box = RecipeBox.decode(LocalCache.loadRecipeBox());
    ChefKeys.hasUsableKey().then((bool v) {
      if (mounted) {
        setState(() => _hasKey = v);
      }
    }).catchError((Object _) {});
  }

  void _markCooked(String title) {
    setState(() => _history = _history.withCooked(title));
    LocalCache.saveHistory(_history.encode());
  }

  void _persistPlanned() =>
      LocalCache.savePlanned(PlannedMenu(_planned).encode());

  void _persistBox() => LocalCache.saveRecipeBox(_box.encode());

  /// Keep a recipe on purpose. Saving the same dish twice just bumps its
  /// cooked count instead of duplicating the entry.
  void _saveRecipe(Recipe recipe, int servings) {
    final int i = _box.recipes.indexWhere((SavedRecipe r) =>
        r.recipe.title.trim().toLowerCase() ==
        recipe.title.trim().toLowerCase());
    setState(() {
      if (i >= 0) {
        final List<SavedRecipe> next = List<SavedRecipe>.of(_box.recipes);
        next[i] = next[i]
            .copyWith(timesCooked: next[i].timesCooked + 1, servings: servings);
        _box = RecipeBox(next);
      } else {
        _box = RecipeBox(<SavedRecipe>[
          ..._box.recipes,
          SavedRecipe(
              savedAtMs: DateTime.now().millisecondsSinceEpoch,
              recipe: recipe,
              servings: servings),
        ]);
      }
    });
    _persistBox();
  }

  void _updateSaved(SavedRecipe r) {
    setState(() => _box = RecipeBox(_box.recipes
        .map((SavedRecipe x) => x.id == r.id ? r : x)
        .toList()));
    _persistBox();
  }

  void _removeSaved(SavedRecipe r) {
    setState(() => _box = RecipeBox(
        _box.recipes.where((SavedRecipe x) => x.id != r.id).toList()));
    _persistBox();
  }

  void _openBox() {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RecipeBoxScreen(
        box: _box,
        onUpdate: _updateSaved,
        onRemove: _removeSaved,
        onPlan: _addPlanned,
        onOpenPlanned: _openPlanned,
        onCooked: _markCooked,
        onRemovePlanned: _removePlanned,
        onUpdatePlanned: _updatePlanned,
        onSave: _saveRecipe,
      ),
    ));
  }

  /// Save a freshly picked recipe onto the menu and return it (so the caller
  /// can open its shopping list).
  PlannedMeal _addPlanned(Recipe recipe, int servings) {
    final PlannedMeal meal = PlannedMeal(
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      recipe: recipe,
      servings: servings,
      checked: List<bool>.filled(recipe.ingredients.length, false),
    );
    setState(() => _planned = <PlannedMeal>[..._planned, meal]);
    _persistPlanned();
    return meal;
  }

  /// Persist an edit (a ticked ingredient or a servings change).
  void _updatePlanned(PlannedMeal updated) {
    final int i = _planned.indexWhere((PlannedMeal m) => m.id == updated.id);
    if (i < 0) {
      return;
    }
    setState(() {
      _planned = <PlannedMeal>[..._planned];
      _planned[i] = updated;
    });
    _persistPlanned();
  }

  void _removePlanned(PlannedMeal meal) {
    setState(() =>
        _planned = _planned.where((PlannedMeal m) => m.id != meal.id).toList());
    _persistPlanned();
  }

  void _openPlanned(PlannedMeal meal) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlannedMealScreen(
        meal: meal,
        onUpdate: _updatePlanned,
        onCooked: _markCooked,
        onRemove: _removePlanned,
        onSave: _saveRecipe,
      ),
    ));
  }

  int get _expiringCount {
    final DateTime now = DateTime.now();
    return widget.items
        .where((PantryItem i) =>
            !i.deleted && !i.usedUp && i.isExpiringSoon(now))
        .length;
  }

  Future<void> _cook() async {
    final List<MealOption>? options = await withSpinner<List<MealOption>>(
      context,
      'Thinking up 3 options…',
      () => Chef.generateOptions(
        pantry: widget.items,
        servings: _servings,
        recentMeals: _history.recent(),
        prices: widget.prices,
      ),
    );
    if (options == null || !mounted) {
      return;
    }
    _openOptions(options, null);
  }

  /// "Cook a request" — describe a craving, get 3 tailored options.
  Future<void> _cookRequest() async {
    final String? request = await _askRequest();
    if (request == null || request.trim().isEmpty || !mounted) {
      return;
    }
    final List<MealOption>? options = await withSpinner<List<MealOption>>(
      context,
      'Tailoring 3 ideas…',
      () => Chef.generateOptions(
        pantry: widget.items,
        servings: _servings,
        recentMeals: _history.recent(),
        prices: widget.prices,
        request: request,
      ),
    );
    if (options == null || !mounted) {
      return;
    }
    _openOptions(options, request);
  }

  // Shared: open the 3-options screen. [request] carries the craving through
  // so "Three different ideas" regenerates in the same mode.
  void _openOptions(List<MealOption> options, String? request) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => OptionsScreen(
        options: options,
        servings: _servings,
        request: request,
        onRegenerate: () => Chef.generateOptions(
          pantry: widget.items,
          servings: _servings,
          recentMeals: _history.recent(),
          prices: widget.prices,
          request: request,
        ),
        onPick: (MealOption o) => Chef.generateRecipe(
            option: o,
            servings: _servings,
            pantry: widget.items,
            prices: widget.prices),
        onPlan: _addPlanned,
        onSave: _saveRecipe,
        onUpdate: _updatePlanned,
        onCooked: _markCooked,
        onRemove: _removePlanned,
      ),
    ));
  }

  Future<String?> _askRequest() async {
    final TextEditingController c = TextEditingController();
    final String? result = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: kCard,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(18))),
      builder: (BuildContext ctx) => Padding(
        padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 20,
            bottom: MediaQuery.of(ctx).viewInsets.bottom +
                MediaQuery.of(ctx).viewPadding.bottom +
                20),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                      color: kBorder, borderRadius: BorderRadius.circular(2))),
              Text('What are you in the mood for?',
                  style: serif(size: 22, weight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('Describe it however you like — a craving, a cuisine, a '
                  'dish, a vibe. I\'ll tailor three ideas to it.',
                  style: TextStyle(color: kMuted, fontSize: 13, height: 1.4)),
              const SizedBox(height: 16),
              TextField(
                controller: c,
                autofocus: true,
                minLines: 2,
                maxLines: 4,
                textCapitalization: TextCapitalization.sentences,
                style: TextStyle(color: kInk, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'e.g. something cozy with chicken, taco night, '
                      'a light Italian dish…',
                  hintStyle: TextStyle(color: kFaint),
                  filled: true,
                  fillColor: kInset,
                  contentPadding: const EdgeInsets.all(14),
                  border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: kBorder)),
                  enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: kBorder)),
                  focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: kAccent)),
                ),
                onSubmitted: (String v) => Navigator.pop(ctx, v.trim()),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton.icon(
                  onPressed: () => Navigator.pop(ctx, c.text.trim()),
                  icon: const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: Text('Get 3 ideas',
                      style: serif(
                          size: 16,
                          weight: FontWeight.w600,
                          color: Colors.white)),
                  style: ElevatedButton.styleFrom(
                      backgroundColor: kAccent,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12))),
                ),
              ),
            ]),
      ),
    );
    c.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final int itemCount =
        widget.items.where((PantryItem i) => !i.deleted && !i.usedUp).length;
    final double bottomPad = 40 + MediaQuery.of(context).viewPadding.bottom;
    return ListView(
      padding: EdgeInsets.fromLTRB(20, 24, 20, bottomPad),
      children: <Widget>[
        Text('Tonight', style: serif(size: 34, weight: FontWeight.w600)),
        const SizedBox(height: 6),
        Text('Tell me when you\'re ready and I\'ll give you three ideas from '
            'what\'s in the kitchen.',
            style: TextStyle(color: kMuted, fontSize: 14, height: 1.5)),
        const SizedBox(height: 24),
        if (_planned.isNotEmpty) ...<Widget>[
          _menuSection(),
          const SizedBox(height: 24),
        ],
        _statsRow(itemCount),
        if (_box.recipes.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          _recipeBoxTile(),
        ],
        const SizedBox(height: 24),
        _servingsStepper(),
        const SizedBox(height: 24),
        if (!_hasKey) _needKeyCard(),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton.icon(
            onPressed: _hasKey ? _cook : null,
            icon: const Icon(Icons.restaurant_menu_rounded),
            label: Text('Cook something',
                style: serif(
                    size: 17, weight: FontWeight.w600, color: Colors.white)),
            style: ElevatedButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: Colors.white,
                disabledBackgroundColor: kBorder,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14))),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton.icon(
            onPressed: _hasKey ? _cookRequest : null,
            icon: const Icon(Icons.favorite_rounded),
            label: Text('Wife\'s Request',
                style: serif(
                    size: 17, weight: FontWeight.w600, color: Colors.white)),
            style: ElevatedButton.styleFrom(
                backgroundColor: kOlive,
                foregroundColor: Colors.white,
                disabledBackgroundColor: kBorder,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14))),
          ),
        ),
      ],
    );
  }

  /// Quiet doorway to the recipe box. Only appears once something is saved,
  /// so it never sits there empty.
  Widget _recipeBoxTile() {
    final int n = _box.recipes.length;
    final int favs =
        _box.recipes.where((SavedRecipe r) => r.favourite).length;
    return Material(
      color: kCard,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: _openBox,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kBorder)),
          child: Row(children: <Widget>[
            const Text('🔖', style: TextStyle(fontSize: 18)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('Recipe box',
                        style: serif(size: 16, weight: FontWeight.w600)),
                    Text(
                        '$n saved${favs > 0 ? ' · $favs favourite${favs == 1 ? '' : 's'}' : ''}',
                        style: mono(size: 11, color: kMuted)),
                  ]),
            ),
            Icon(Icons.chevron_right_rounded, color: kMuted),
          ]),
        ),
      ),
    );
  }

  Widget _statsRow(int itemCount) {
    return Row(children: <Widget>[
      _stat('$itemCount', 'in stock'),
      const SizedBox(width: 12),
      _stat('${_history.meals.length}', 'meals cooked'),
      const SizedBox(width: 12),
      _stat('$_expiringCount', 'expiring', warn: _expiringCount > 0),
    ]);
  }

  Widget _stat(String value, String label, {bool warn = false}) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: warn ? kWarn : kBorder)),
          child: Column(children: <Widget>[
            Text(value,
                style: serif(
                    size: 24,
                    weight: FontWeight.w600,
                    color: warn ? kWarn : kInk)),
            const SizedBox(height: 2),
            Text(label, style: mono(size: 10, color: kMuted, spacing: 0.5)),
          ]),
        ),
      );

  Widget _menuSection() {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Row(children: <Widget>[
        Text('ON THE MENU', style: labelCaps(color: kAccent)),
        const SizedBox(width: 8),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          decoration: BoxDecoration(
              color: kAccent.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(20)),
          child: Text('${_planned.length}',
              style: mono(size: 11, weight: FontWeight.w600, color: kAccent)),
        ),
      ]),
      const SizedBox(height: 4),
      Text('Saved to shop for and cook later. Tap for the shopping list.',
          style: TextStyle(color: kMuted, fontSize: 12, height: 1.4)),
      const SizedBox(height: 12),
      for (final PlannedMeal m in _planned.reversed) _plannedCard(m),
    ]);
  }

  Widget _plannedCard(PlannedMeal m) {
    final bool ready = m.allGathered;
    return GestureDetector(
      onTap: () => _openPlanned(m),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: ready ? kOlive : kBorder)),
        child: Row(children: <Widget>[
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(m.recipe.title,
                  style: serif(size: 17, weight: FontWeight.w600, height: 1.2)),
              const SizedBox(height: 6),
              Row(children: <Widget>[
                Icon(ready ? Icons.check_circle_rounded : Icons.shopping_cart_rounded,
                    size: 13, color: ready ? kOlive : kMuted),
                const SizedBox(width: 5),
                Text(
                    m.total == 0
                        ? 'Serves ${m.servings}'
                        : ready
                            ? 'Shopping list complete'
                            : '${m.gathered}/${m.total} gathered · serves ${m.servings}',
                    style: mono(
                        size: 11,
                        color: ready ? kOlive : kMuted)),
              ]),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: kMuted),
        ]),
      ),
    );
  }

  Widget _servingsStepper() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Row(children: <Widget>[
        Text('COOKING FOR', style: labelCaps()),
        const Spacer(),
        _roundBtn(Icons.remove_rounded,
            () => setState(() => _servings = (_servings - 1).clamp(1, 12))),
        SizedBox(
          width: 44,
          child: Center(
              child: Text('$_servings',
                  style: serif(size: 22, weight: FontWeight.w600))),
        ),
        _roundBtn(Icons.add_rounded,
            () => setState(() => _servings = (_servings + 1).clamp(1, 12))),
      ]),
    );
  }

  Widget _needKeyCard() => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: kWarn.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: kWarn.withValues(alpha: 0.5))),
        child: Row(children: <Widget>[
          const Icon(Icons.key_rounded, color: kWarn, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text('Add your Claude API key in Settings to start cooking.',
                style: TextStyle(fontSize: 13, color: kInk)),
          ),
        ]),
      );

  Widget _roundBtn(IconData icon, VoidCallback onTap) => Material(
        color: kInset,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
              padding: const EdgeInsets.all(8), child: Icon(icon, size: 20)),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════
// OPTIONS — 3 protein-varied cards + "Three different ideas"
// ═══════════════════════════════════════════════════════════════════════

class OptionsScreen extends StatefulWidget {
  final List<MealOption> options;
  final int servings;
  final String? request; // the craving, when these came from "Cook a request"
  final Future<List<MealOption>> Function() onRegenerate;
  final Future<Recipe> Function(MealOption) onPick;
  final PlannedMeal Function(Recipe recipe, int servings) onPlan;
  /// Keep a recipe in the box (threaded down to the recipe screen).
  final void Function(Recipe recipe, int servings)? onSave;
  final void Function(PlannedMeal meal) onUpdate;
  final void Function(String title) onCooked;
  final void Function(PlannedMeal meal) onRemove;

  const OptionsScreen({
    super.key,
    required this.options,
    required this.servings,
    this.request,
    required this.onRegenerate,
    required this.onPick,
    required this.onPlan,
    this.onSave,
    required this.onUpdate,
    required this.onCooked,
    required this.onRemove,
  });

  @override
  State<OptionsScreen> createState() => _OptionsScreenState();
}

class _OptionsScreenState extends State<OptionsScreen> {
  late List<MealOption> _options = widget.options;

  Future<void> _regenerate() async {
    final List<MealOption>? next = await withSpinner<List<MealOption>>(
        context, 'Three different ideas…', widget.onRegenerate);
    if (next != null && mounted) {
      setState(() => _options = next);
    }
  }

  Future<void> _pick(MealOption o) async {
    final Recipe? r = await withSpinner<Recipe>(
        context, 'Writing the recipe…', () => widget.onPick(o));
    if (r == null || !mounted) {
      return;
    }
    // Selecting a meal saves it to the menu so it survives leaving this screen
    // and closing the app — then we open its shopping list first.
    final PlannedMeal meal = widget.onPlan(r, widget.servings);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Saved to your menu — here\'s the shopping list.')));
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PlannedMealScreen(
        meal: meal,
        onUpdate: widget.onUpdate,
        onCooked: widget.onCooked,
        onRemove: widget.onRemove,
        onSave: widget.onSave,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final double bottomPad = 24 + MediaQuery.of(context).viewPadding.bottom;
    final String? request = widget.request?.trim();
    final bool hasReq = request != null && request.isNotEmpty;
    return Scaffold(
      appBar: AppBar(
          title: Text(hasReq ? 'Wife\'s Request' : 'Tonight',
              style: serif(size: 20))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPad),
        children: <Widget>[
          if (hasReq) ...<Widget>[
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                  color: kOlive.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kOlive.withValues(alpha: 0.4))),
              child: Row(children: <Widget>[
                const Icon(Icons.favorite_rounded, color: kOlive, size: 16),
                const SizedBox(width: 10),
                Expanded(
                  child: Text('“$request”',
                      style: serif(
                          size: 14,
                          weight: FontWeight.w400,
                          color: kInk,
                          style: FontStyle.italic,
                          height: 1.3)),
                ),
              ]),
            ),
            const SizedBox(height: 14),
          ],
          Text(
              hasReq
                  ? 'Three takes on what you asked for — pick one.'
                  : 'Pick one — each uses a different protein.',
              style: TextStyle(color: kMuted, fontSize: 13)),
          const SizedBox(height: 14),
          for (final MealOption o in _options) _card(o),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton.icon(
              onPressed: _regenerate,
              icon: const Icon(Icons.refresh_rounded, size: 18),
              label: const Text('Three different ideas'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: kAccent,
                  side: BorderSide(color: kAccent.withValues(alpha: 0.5)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(MealOption o) {
    final bool noBuys = o.newBuys.isEmpty ||
        o.newBuys.toLowerCase().contains('no new buy');
    return GestureDetector(
      onTap: () => _pick(o),
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          if (o.protein.isNotEmpty)
            Text(o.protein.toUpperCase(), style: labelCaps(color: kAccent)),
          const SizedBox(height: 6),
          Text(o.title, style: serif(size: 21, weight: FontWeight.w600)),
          if (o.desc.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(o.desc,
                style: serif(
                    size: 14,
                    weight: FontWeight.w400,
                    color: kMuted,
                    style: FontStyle.italic,
                    height: 1.4)),
          ],
          const SizedBox(height: 12),
          Row(children: <Widget>[
            Text('${_i(o.proteinPerServing)}g protein',
                style: mono(size: 12, color: kOlive)),
            const SizedBox(width: 14),
            Text('${_i(o.caloriesPerServing)} cal',
                style: mono(size: 12, color: kOlive)),
          ]),
          if (o.estCostTotal > 0) ...<Widget>[
            const SizedBox(height: 8),
            Text(
                '≈ ${money(o.estCostTotal)}'
                '${o.estCostPerServing > 0 ? '  ·  ${money(o.estCostPerServing)}/serving' : ''}'
                '  (est.)',
                style: mono(size: 12, weight: FontWeight.w600, color: kAccent)),
          ],
          const SizedBox(height: 6),
          Text(
              noBuys ? 'No new buys — all from your pantry' : 'New buys: ${o.newBuys}',
              style: TextStyle(
                  fontSize: 12,
                  color: noBuys ? kOlive : kMuted,
                  fontStyle: noBuys ? FontStyle.normal : FontStyle.italic)),
        ]),
      ),
    );
  }

  static String _i(double v) => v.round().toString();
}

// ═══════════════════════════════════════════════════════════════════════
// RECIPE BOX — the keepers. Nothing lands here automatically; a recipe is
// saved only when you tap the bookmark, so the box stays a shortlist rather
// than a dumping ground. From here a recipe can be re-read, cooked again, or
// put back on the menu with its shopping list.
// ═══════════════════════════════════════════════════════════════════════

class RecipeBoxScreen extends StatefulWidget {
  final RecipeBox box;
  final void Function(SavedRecipe) onUpdate;
  final void Function(SavedRecipe) onRemove;
  final PlannedMeal Function(Recipe recipe, int servings) onPlan;
  final void Function(PlannedMeal) onOpenPlanned;
  final void Function(String title) onCooked;
  final void Function(PlannedMeal) onRemovePlanned;
  final void Function(PlannedMeal) onUpdatePlanned;
  final void Function(Recipe recipe, int servings) onSave;

  const RecipeBoxScreen({
    super.key,
    required this.box,
    required this.onUpdate,
    required this.onRemove,
    required this.onPlan,
    required this.onOpenPlanned,
    required this.onCooked,
    required this.onRemovePlanned,
    required this.onUpdatePlanned,
    required this.onSave,
  });

  @override
  State<RecipeBoxScreen> createState() => _RecipeBoxScreenState();
}

class _RecipeBoxScreenState extends State<RecipeBoxScreen> {
  late RecipeBox _box = widget.box;
  String _query = '';

  List<SavedRecipe> get _visible {
    final String q = _query.trim().toLowerCase();
    final List<SavedRecipe> all = _box.sorted;
    if (q.isEmpty) {
      return all;
    }
    return all
        .where((SavedRecipe r) =>
            r.recipe.title.toLowerCase().contains(q) ||
            r.recipe.description.toLowerCase().contains(q))
        .toList();
  }

  void _toggleFav(SavedRecipe r) {
    final SavedRecipe next = r.copyWith(favourite: !r.favourite);
    setState(() => _box = RecipeBox(_box.recipes
        .map((SavedRecipe x) => x.id == r.id ? next : x)
        .toList()));
    widget.onUpdate(next);
  }

  Future<void> _remove(SavedRecipe r) async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('Remove from box?', style: serif(size: 18)),
        content: Text('“${r.recipe.title}” will be deleted from your recipe '
            'box. Your history is untouched.',
            style: TextStyle(fontSize: 13.5, color: kMuted, height: 1.4)),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Keep', style: TextStyle(color: kMuted))),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove',
                  style: TextStyle(
                      color: kDanger, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (yes == true) {
      setState(() => _box = RecipeBox(
          _box.recipes.where((SavedRecipe x) => x.id != r.id).toList()));
      widget.onRemove(r);
    }
  }

  void _open(SavedRecipe r) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RecipeScreen(
        recipe: r.recipe,
        initialServings: r.servings,
        alreadySaved: true,
        onCooked: (String title) {
          widget.onCooked(title);
          widget.onUpdate(r.copyWith(timesCooked: r.timesCooked + 1));
        },
      ),
    ));
  }

  /// Put it back on the menu so the shopping list comes with it.
  void _toMenu(SavedRecipe r) {
    final PlannedMeal meal = widget.onPlan(r.recipe, r.servings);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('“${r.recipe.title}” is back on your menu.')));
    widget.onOpenPlanned(meal);
  }

  @override
  Widget build(BuildContext context) {
    final List<SavedRecipe> items = _visible;
    final double bottomPad = 28 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(title: Text('Recipe box', style: serif(size: 20))),
      body: _box.recipes.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(34),
                child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      const Text('🔖', style: TextStyle(fontSize: 40)),
                      const SizedBox(height: 14),
                      Text('Nothing saved yet',
                          style: serif(size: 20, weight: FontWeight.w600)),
                      const SizedBox(height: 8),
                      Text('Open any recipe and tap the bookmark to keep it '
                          'here. Saved recipes can be re-read, cooked again, '
                          'or put back on your menu with a shopping list.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                              fontSize: 13.5, color: kMuted, height: 1.5)),
                    ]),
              ),
            )
          : Column(children: <Widget>[
              if (_box.recipes.length > 4)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  child: TextField(
                    onChanged: (String v) => setState(() => _query = v),
                    decoration: InputDecoration(
                      hintText: 'Search your recipes',
                      hintStyle: TextStyle(color: kFaint),
                      prefixIcon: Icon(Icons.search_rounded, color: kMuted),
                      isDense: true,
                      filled: true,
                      fillColor: kInset,
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: kBorder)),
                      enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(color: kBorder)),
                    ),
                  ),
                ),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Text('No matches.',
                            style: TextStyle(color: kMuted, fontSize: 13.5)))
                    : ListView(
                        padding: EdgeInsets.fromLTRB(16, 4, 16, bottomPad),
                        children: <Widget>[
                          for (final SavedRecipe r in items) _card(r),
                        ],
                      ),
              ),
            ]),
    );
  }

  Widget _card(SavedRecipe r) {
    final Recipe rec = r.recipe;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
              color: r.favourite
                  ? kAccent.withValues(alpha: 0.5)
                  : kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        InkWell(
          onTap: () => _open(r),
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 8, 10),
            child: Row(children: <Widget>[
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(rec.title,
                          style: serif(size: 18, weight: FontWeight.w600)),
                      if (rec.description.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 4),
                        Text(rec.description,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: serif(
                                size: 13,
                                weight: FontWeight.w400,
                                color: kMuted,
                                style: FontStyle.italic,
                                height: 1.35)),
                      ],
                      const SizedBox(height: 8),
                      Row(children: <Widget>[
                        Text('serves ${r.servings}',
                            style: mono(size: 11, color: kOlive)),
                        if (rec.estCostPerServing > 0) ...<Widget>[
                          const SizedBox(width: 12),
                          Text('${money(rec.estCostPerServing)}/serving',
                              style: mono(size: 11, color: kAccent)),
                        ],
                        if (r.timesCooked > 0) ...<Widget>[
                          const SizedBox(width: 12),
                          Text('cooked ${r.timesCooked}×',
                              style: mono(size: 11, color: kMuted)),
                        ],
                      ]),
                    ]),
              ),
              IconButton(
                tooltip: r.favourite ? 'Unfavourite' : 'Favourite',
                onPressed: () => _toggleFav(r),
                icon: Icon(
                    r.favourite ? Icons.star_rounded : Icons.star_border_rounded,
                    size: 20,
                    color: r.favourite ? kAccent : kMuted),
              ),
            ]),
          ),
        ),
        Divider(height: 1, color: kBorder),
        Row(children: <Widget>[
          Expanded(
            child: TextButton.icon(
              onPressed: () => _open(r),
              icon: const Icon(Icons.menu_book_rounded, size: 17),
              label: const Text('Recipe'),
              style: TextButton.styleFrom(foregroundColor: kInk),
            ),
          ),
          Container(width: 1, height: 26, color: kBorder),
          Expanded(
            child: TextButton.icon(
              onPressed: () => _toMenu(r),
              icon: const Icon(Icons.playlist_add_rounded, size: 17),
              label: const Text('To menu'),
              style: TextButton.styleFrom(foregroundColor: kOlive),
            ),
          ),
          Container(width: 1, height: 26, color: kBorder),
          IconButton(
            tooltip: 'Remove',
            onPressed: () => _remove(r),
            icon: const Icon(Icons.delete_outline_rounded,
                size: 18, color: kDanger),
          ),
        ]),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// PLANNED MEAL — a saved meal on the menu. Shows a checkable shopping list
// (every ingredient) so you can shop ahead, then cook it whenever. Ticks and
// the serving count persist; cooking (or removing) clears it from the menu.
// ═══════════════════════════════════════════════════════════════════════

class PlannedMealScreen extends StatefulWidget {
  final PlannedMeal meal;
  final void Function(PlannedMeal meal) onUpdate;
  final void Function(String title) onCooked;
  final void Function(PlannedMeal meal) onRemove;
  /// Keep a recipe in the box (threaded down to the recipe screen).
  final void Function(Recipe recipe, int servings)? onSave;

  const PlannedMealScreen({
    super.key,
    required this.meal,
    required this.onUpdate,
    required this.onCooked,
    required this.onRemove,
    this.onSave,
  });

  @override
  State<PlannedMealScreen> createState() => _PlannedMealScreenState();
}

class _PlannedMealScreenState extends State<PlannedMealScreen> {
  late PlannedMeal _meal = widget.meal;

  void _toggle(int i) {
    final List<bool> checked = <bool>[..._meal.checked];
    checked[i] = !checked[i];
    setState(() => _meal = _meal.copyWith(checked: checked));
    widget.onUpdate(_meal);
  }

  void _setServings(int s) {
    setState(() => _meal = _meal.copyWith(servings: s.clamp(1, 20)));
    widget.onUpdate(_meal);
  }

  Future<void> _remove() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('Remove from menu?', style: serif(size: 18)),
        content: Text('“${_meal.recipe.title}” will be taken off your menu.',
            style: TextStyle(color: kInk)),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove', style: TextStyle(color: kDanger))),
        ],
      ),
    );
    if (yes == true && mounted) {
      widget.onRemove(_meal);
      Navigator.pop(context);
    }
  }

  void _cooked() {
    widget.onCooked(_meal.recipe.title);
    widget.onRemove(_meal);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Nice — “${_meal.recipe.title}” cooked and cleared '
            'from your menu.')));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final Recipe r = _meal.recipe;
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(
        title: Text('On the menu', style: serif(size: 20)),
        actions: <Widget>[
          IconButton(
            tooltip: 'Remove from menu',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _remove,
          ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 4, 20, bottomPad),
        children: <Widget>[
          Text(r.title,
              style: serif(size: 28, weight: FontWeight.w600, height: 1.15)),
          if (r.description.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(r.description,
                style: serif(
                    size: 15,
                    weight: FontWeight.w400,
                    color: kMuted,
                    style: FontStyle.italic,
                    height: 1.5)),
          ],
          const SizedBox(height: 18),
          _servingsStepper(),
          const SizedBox(height: 22),
          Row(children: <Widget>[
            Text('SHOPPING LIST', style: labelCaps(color: kAccent)),
            const Spacer(),
            if (_meal.total > 0)
              Text('${_meal.gathered}/${_meal.total}',
                  style: mono(
                      size: 12,
                      weight: FontWeight.w600,
                      color: _meal.allGathered ? kOlive : kMuted)),
          ]),
          if (r.estGroceryCost > 0) ...<Widget>[
            const SizedBox(height: 6),
            Row(children: <Widget>[
              const Icon(Icons.shopping_cart_rounded, size: 15, color: kOlive),
              const SizedBox(width: 6),
              Text('This trip ≈ ${money(r.estGroceryCost * _meal.factor)} (est.)',
                  style: mono(size: 12, weight: FontWeight.w600, color: kOlive)),
            ]),
          ],
          const SizedBox(height: 6),
          if (r.ingredients.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text('No ingredients listed.',
                  style: TextStyle(color: kMuted, fontSize: 14)),
            )
          else
            for (int i = 0; i < r.ingredients.length; i++)
              _shoppingRow(i, r.ingredients[i]),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RecipeScreen(
                    recipe: r,
                    initialServings: _meal.servings,
                    onSave: widget.onSave,
                    onCooked: (String title) {
                      widget.onCooked(title);
                      widget.onRemove(_meal);
                    },
                  ),
                ),
              ),
              icon: const Icon(Icons.menu_book_rounded, size: 18),
              label: const Text('View full recipe'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: kInk,
                  side: const BorderSide(color: kBorder),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _cooked,
              icon: const Icon(Icons.check_rounded),
              label: Text('I cooked this',
                  style: serif(size: 16, weight: FontWeight.w600, color: Colors.white)),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _servingsStepper() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
          color: kInset, borderRadius: BorderRadius.circular(14)),
      child: Row(children: <Widget>[
        Text('SERVINGS', style: labelCaps()),
        const Spacer(),
        _roundBtn(Icons.remove_rounded, () => _setServings(_meal.servings - 1)),
        SizedBox(
            width: 44,
            child: Center(
                child: Text('${_meal.servings}',
                    style: serif(size: 22, weight: FontWeight.w600)))),
        _roundBtn(Icons.add_rounded, () => _setServings(_meal.servings + 1)),
      ]),
    );
  }

  Widget _shoppingRow(int i, RecipeIngredient ing) {
    final bool got = _meal.checked[i];
    return InkWell(
      onTap: () => _toggle(i),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Icon(
              got
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 22,
              color: got ? kOlive : kMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Text(ing.item,
                style: TextStyle(
                    fontSize: 15,
                    color: got ? kMuted : kInk,
                    decoration:
                        got ? TextDecoration.lineThrough : TextDecoration.none,
                    decorationColor: kMuted)),
          ),
          const SizedBox(width: 12),
          Text(ing.scaled(_meal.factor),
              style: mono(
                  size: 14,
                  weight: FontWeight.w600,
                  color: got ? kFaint : kOlive)),
        ]),
      ),
    );
  }

  Widget _roundBtn(IconData icon, VoidCallback onTap) => Material(
        color: kCard,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
              padding: const EdgeInsets.all(8), child: Icon(icon, size: 20)),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════
// RECIPE CARD — the hero screen. Live servings scaler, cooking mode,
// ingredients, numbered steps with per-step timers, notes.
// ═══════════════════════════════════════════════════════════════════════

class RecipeScreen extends StatefulWidget {
  final Recipe recipe;
  final void Function(String title) onCooked;
  final int? initialServings;
  /// Keep this recipe in the box. Null hides the save action (e.g. when the
  /// recipe is already being viewed from the box itself).
  final void Function(Recipe recipe, int servings)? onSave;
  final bool alreadySaved;
  const RecipeScreen({
    super.key,
    required this.recipe,
    required this.onCooked,
    this.initialServings,
    this.onSave,
    this.alreadySaved = false,
  });

  @override
  State<RecipeScreen> createState() => _RecipeScreenState();
}

class _RecipeScreenState extends State<RecipeScreen> {
  late int _servings = widget.initialServings ?? widget.recipe.baseServings;
  late bool _saved = widget.alreadySaved;

  void _save() {
    widget.onSave?.call(widget.recipe, _servings);
    setState(() => _saved = true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('“${widget.recipe.title}” saved to your recipe box.')));
  }

  double get _factor =>
      widget.recipe.baseServings == 0 ? 1 : _servings / widget.recipe.baseServings;

  /// Cost estimate scaled to the chosen servings. Per-serving is unchanged by
  /// scaling; the whole-meal and grocery totals scale with servings.
  Widget _costCard(Recipe r) {
    final double total = r.estCostTotal * _factor;
    final double grocery = r.estGroceryCost * _factor;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kInset, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Text('ESTIMATED COST', style: labelCaps(color: kAccent)),
          const Spacer(),
          Text(money(total),
              style: mono(size: 18, weight: FontWeight.w700, color: kAccent)),
        ]),
        if (r.estCostPerServing > 0) ...<Widget>[
          const SizedBox(height: 4),
          Text('${money(r.estCostPerServing)} per serving',
              style: mono(size: 12, color: kMuted)),
        ],
        if (grocery > 0) ...<Widget>[
          const SizedBox(height: 8),
          Row(children: <Widget>[
            const Icon(Icons.shopping_cart_rounded, size: 15, color: kOlive),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Groceries to buy for this meal ≈ ${money(grocery)}',
                  style: mono(size: 12, weight: FontWeight.w600, color: kOlive)),
            ),
          ]),
        ],
        const SizedBox(height: 6),
        Text('Estimates from your prices + typical grocery costs.',
            style: TextStyle(fontSize: 11, color: kFaint)),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Recipe r = widget.recipe;
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(
        actions: <Widget>[
          if (widget.onSave != null)
            IconButton(
              tooltip: _saved ? 'In your recipe box' : 'Save to recipe box',
              onPressed: _saved ? null : _save,
              icon: Icon(
                  _saved
                      ? Icons.bookmark_rounded
                      : Icons.bookmark_border_rounded,
                  color: _saved ? kAccent : kInk),
            ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(20, 0, 20, bottomPad),
        children: <Widget>[
          Text(r.title, style: serif(size: 30, weight: FontWeight.w600, height: 1.1)),
          if (r.description.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(r.description,
                style: serif(
                    size: 16,
                    weight: FontWeight.w400,
                    color: kMuted,
                    style: FontStyle.italic,
                    height: 1.5)),
          ],
          const SizedBox(height: 20),
          _servingsStepper(),
          const SizedBox(height: 14),
          if (r.estCostTotal > 0) ...<Widget>[
            _costCard(r),
            const SizedBox(height: 14),
          ],
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      CookingModeScreen(recipe: r, factor: _factor),
                ),
              ),
              icon: const Icon(Icons.local_fire_department_rounded),
              label: Text('Cooking mode',
                  style: serif(size: 16, weight: FontWeight.w600, color: Colors.white)),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
            ),
          ),
          const SizedBox(height: 26),
          _sectionHeading('INGREDIENTS'),
          const SizedBox(height: 10),
          for (final RecipeIngredient ing in r.ingredients) _ingredientRow(ing),
          const SizedBox(height: 26),
          _sectionHeading('STEPS'),
          const SizedBox(height: 12),
          for (int i = 0; i < r.steps.length; i++) _stepRow(i + 1, r.steps[i]),
          if (r.notes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 20),
            _sectionHeading('NOTES'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder)),
              child: Text(r.notes,
                  style: TextStyle(fontSize: 14, color: kInk, height: 1.6)),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton.icon(
              onPressed: () {
                widget.onCooked(r.title);
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text('Added "${r.title}" to your meal history.')));
                Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
              },
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('I cooked this'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: kOlive,
                  side: BorderSide(color: kOlive.withValues(alpha: 0.5)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _servingsStepper() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
          color: kInset, borderRadius: BorderRadius.circular(14)),
      child: Row(children: <Widget>[
        Text('SERVINGS', style: labelCaps()),
        const Spacer(),
        _roundBtn(Icons.remove_rounded,
            () => setState(() => _servings = (_servings - 1).clamp(1, 20))),
        SizedBox(
            width: 44,
            child: Center(
                child: Text('$_servings',
                    style: serif(size: 22, weight: FontWeight.w600)))),
        _roundBtn(Icons.add_rounded,
            () => setState(() => _servings = (_servings + 1).clamp(1, 20))),
      ]),
    );
  }

  Widget _roundBtn(IconData icon, VoidCallback onTap) => Material(
        color: kCard,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
              padding: const EdgeInsets.all(8), child: Icon(icon, size: 20)),
        ),
      );

  Widget _sectionHeading(String s) => Row(children: <Widget>[
        Text(s, style: labelCaps(color: kAccent)),
        const SizedBox(width: 10),
        const Expanded(child: Divider(color: kBorder, height: 1)),
      ]);

  Widget _ingredientRow(RecipeIngredient ing) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Expanded(
              child: Text(ing.item,
                  style: const TextStyle(fontSize: 15, color: kInk))),
          const SizedBox(width: 12),
          Text(ing.scaled(_factor),
              style: mono(size: 14, weight: FontWeight.w600, color: kOlive)),
        ]),
      );

  Widget _stepRow(int n, RecipeStep step) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        SizedBox(
          width: 34,
          child: Text('$n',
              style: serif(size: 26, weight: FontWeight.w600, color: kAccent)),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            if (step.title.isNotEmpty)
              Text(step.title,
                  style: const TextStyle(
                      fontSize: 15.5, fontWeight: FontWeight.w700, color: kInk)),
            if (step.content.isNotEmpty) ...<Widget>[
              const SizedBox(height: 3),
              Text(step.content,
                  style: TextStyle(fontSize: 14.5, color: kInk, height: 1.5)),
            ],
            if (step.hasTimer) ...<Widget>[
              const SizedBox(height: 10),
              StepTimer(seconds: step.timerSeconds),
            ],
          ]),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// COOKING MODE — full-screen, one step at a time, screen stays awake.
// ═══════════════════════════════════════════════════════════════════════

class CookingModeScreen extends StatefulWidget {
  final Recipe recipe;
  final double factor;
  const CookingModeScreen({super.key, required this.recipe, required this.factor});

  @override
  State<CookingModeScreen> createState() => _CookingModeScreenState();
}

class _CookingModeScreenState extends State<CookingModeScreen> {
  final PageController _pc = PageController();
  int _page = 0;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    Notifications.requestPermission();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _pc.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<RecipeStep> steps = widget.recipe.steps;
    return Scaffold(
      appBar: AppBar(
        title: Text('Cooking', style: serif(size: 18)),
        actions: <Widget>[
          Center(
              child: Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Text('${_page + 1} / ${steps.length}',
                style: mono(size: 13, color: kMuted)),
          )),
        ],
      ),
      body: Column(children: <Widget>[
        LinearProgressIndicator(
          value: steps.isEmpty ? 0 : (_page + 1) / steps.length,
          minHeight: 3,
          backgroundColor: kInset,
          valueColor: const AlwaysStoppedAnimation<Color>(kAccent),
        ),
        Expanded(
          child: PageView.builder(
            controller: _pc,
            itemCount: steps.length,
            onPageChanged: (int i) => setState(() => _page = i),
            // Keep each step alive so a running timer isn't destroyed (and
            // silenced) when you swipe to another step.
            itemBuilder: (_, int i) =>
                _KeepAlive(child: _stepPage(i + 1, steps[i])),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(children: <Widget>[
              if (_page > 0)
                _navBtn('Back', () => _pc.previousPage(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut)),
              const Spacer(),
              if (_page < steps.length - 1)
                _navBtn('Next', () => _pc.nextPage(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOut), primary: true)
              else
                _navBtn('Done', () => Navigator.pop(context), primary: true),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _stepPage(int n, RecipeStep step) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('STEP $n', style: labelCaps(color: kAccent)),
        const SizedBox(height: 10),
        if (step.title.isNotEmpty)
          Text(step.title,
              style: serif(size: 30, weight: FontWeight.w600, height: 1.15)),
        const SizedBox(height: 16),
        if (step.content.isNotEmpty)
          Text(step.content,
              style: const TextStyle(fontSize: 20, color: kInk, height: 1.55)),
        if (step.hasTimer) ...<Widget>[
          const SizedBox(height: 24),
          StepTimer(seconds: step.timerSeconds, large: true),
        ],
      ]),
    );
  }

  Widget _navBtn(String label, VoidCallback onTap, {bool primary = false}) {
    return SizedBox(
      height: 52,
      width: 130,
      child: primary
          ? ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: Text(label,
                  style: serif(size: 16, weight: FontWeight.w600, color: Colors.white)))
          : OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                  foregroundColor: kInk,
                  side: const BorderSide(color: kBorder),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: Text(label)),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// STEP TIMER — a live countdown; buzzes + flashes at zero.
// ═══════════════════════════════════════════════════════════════════════

class StepTimer extends StatefulWidget {
  final int seconds;
  final bool large;
  const StepTimer({super.key, required this.seconds, this.large = false});

  @override
  State<StepTimer> createState() => _StepTimerState();
}

class _StepTimerState extends State<StepTimer> {
  late int _remaining = widget.seconds;
  Timer? _timer;
  bool _running = false;
  bool _done = false;

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _toggle() {
    if (_done) {
      _reset();
      return;
    }
    if (_running) {
      _timer?.cancel();
      setState(() => _running = false);
      return;
    }
    setState(() => _running = true);
    _timer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      if (_remaining <= 1) {
        t.cancel();
        setState(() {
          _remaining = 0;
          _running = false;
          _done = true;
        });
        _alert();
      } else {
        setState(() => _remaining--);
      }
    });
  }

  void _reset() {
    _timer?.cancel();
    setState(() {
      _remaining = widget.seconds;
      _running = false;
      _done = false;
    });
  }

  Future<void> _alert() async {
    HapticFeedback.heavyImpact();
    Notifications.alarm('Timer done', 'A cooking step timer just finished.');
    try {
      if (await Vibration.hasVibrator()) {
        Vibration.vibrate(pattern: <int>[0, 500, 250, 500, 250, 800]);
      }
    } catch (_) {}
  }

  String get _label {
    final int m = _remaining ~/ 60;
    final int s = _remaining % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final Color c = _done ? kWarn : kAccent;
    final double h = widget.large ? 60 : 44;
    return GestureDetector(
      onTap: _toggle,
      child: Container(
        height: h,
        padding: const EdgeInsets.symmetric(horizontal: 18),
        decoration: BoxDecoration(
            color: c.withValues(alpha: _done ? 0.16 : 0.10),
            borderRadius: BorderRadius.circular(h / 2),
            border: Border.all(color: c.withValues(alpha: 0.5))),
        child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Icon(
              _done
                  ? Icons.notifications_active_rounded
                  : (_running
                      ? Icons.pause_rounded
                      : Icons.play_arrow_rounded),
              color: c,
              size: widget.large ? 28 : 20),
          const SizedBox(width: 10),
          Text(_done ? 'Time!' : _label,
              style: mono(
                  size: widget.large ? 26 : 17,
                  weight: FontWeight.w600,
                  color: c)),
          if (_done) ...<Widget>[
            const SizedBox(width: 10),
            Text('tap to reset', style: mono(size: 11, color: kMuted)),
          ],
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// CHEF SETTINGS — API key entry + model toggle, for the Settings tab.
// ═══════════════════════════════════════════════════════════════════════

class ChefSettingsCard extends StatefulWidget {
  const ChefSettingsCard({super.key});
  @override
  State<ChefSettingsCard> createState() => _ChefSettingsCardState();
}

class _ChefSettingsCardState extends State<ChefSettingsCard> {
  final TextEditingController _key = TextEditingController();
  bool _obscure = true;
  bool _hasUserKey = false;
  String _model = 'haiku';
  List<String> _equipment = <String>[];
  List<String> _avoids = <String>[];

  static const Map<String, String> _modelCost = <String, String>{
    'haiku': 'Fast & cheap — under \$0.01 per meal. Recommended.',
    'sonnet': 'More creative — a few cents per meal.',
    'opus': 'Most capable — ~15-25¢ per meal. For special occasions.',
  };

  @override
  void initState() {
    super.initState();
    ChefKeys.hasUserKey().then((bool v) {
      if (mounted) {
        setState(() => _hasUserKey = v);
      }
    }).catchError((Object _) {});
    ChefKeys.getModelPref().then((String p) {
      if (mounted) {
        setState(() => _model = p);
      }
    }).catchError((Object _) {});
    ChefKeys.getEquipment().then((List<String> v) {
      if (mounted) {
        setState(() => _equipment = v);
      }
    }).catchError((Object _) {});
    ChefKeys.getAvoids().then((List<String> v) {
      if (mounted) {
        setState(() => _avoids = v);
      }
    }).catchError((Object _) {});
  }

  // ── equipment ─────────────────────────────────────────────────────────

  /// Devices the user typed in themselves (anything not in the catalog).
  List<String> get _customDevices {
    final Set<String> known =
        kKnownDevices.map((CookDevice d) => d.name).toSet();
    return _equipment.where((String s) => !known.contains(s)).toList();
  }

  void _toggleDevice(String name) {
    setState(() {
      _equipment = _equipment.contains(name)
          ? _equipment.where((String s) => s != name).toList()
          : <String>[..._equipment, name];
    });
    ChefKeys.setEquipment(_equipment);
  }

  Future<void> _addCustomDevice() async {
    final TextEditingController c = TextEditingController();
    final String? entered = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('Add equipment', style: serif(size: 19)),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'e.g. Pizza oven',
            hintStyle: TextStyle(color: kFaint),
            filled: true,
            fillColor: kInset,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: kBorder)),
          ),
          onSubmitted: (String v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: kMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            style: ElevatedButton.styleFrom(
                backgroundColor: kAccent, foregroundColor: Colors.white),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    final String name = (entered ?? '').trim();
    if (name.isEmpty || _equipment.contains(name)) {
      return;
    }
    setState(() => _equipment = <String>[..._equipment, name]);
    ChefKeys.setEquipment(_equipment);
  }

  // ── avoid list ────────────────────────────────────────────────────────

  Future<void> _addCustomAvoid() async {
    final TextEditingController c = TextEditingController();
    final String? entered = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('Avoid a food', style: serif(size: 19)),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          decoration: InputDecoration(
            hintText: 'e.g. Bell peppers',
            hintStyle: TextStyle(color: kFaint),
            filled: true,
            fillColor: kInset,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: kBorder)),
          ),
          onSubmitted: (String v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: kMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            style: ElevatedButton.styleFrom(
                backgroundColor: kAccent, foregroundColor: Colors.white),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    final String name = (entered ?? '').trim();
    if (name.isEmpty || _avoids.contains(name)) {
      return;
    }
    setState(() => _avoids = <String>[..._avoids, name]);
    ChefKeys.setAvoids(_avoids);
  }

  void _removeAvoid(String name) {
    setState(() => _avoids = _avoids.where((String s) => s != name).toList());
    ChefKeys.setAvoids(_avoids);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('No longer avoiding $name.')));
  }

  void _removeCustomDevice(String name) {
    setState(() =>
        _equipment = _equipment.where((String s) => s != name).toList());
    ChefKeys.setEquipment(_equipment);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('Removed $name.')));
  }

  @override
  void dispose() {
    _key.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final String v = _key.text.trim();
    if (v.isEmpty) {
      return;
    }
    await ChefKeys.setApiKey(v);
    _key.clear();
    if (!mounted) {
      return;
    }
    setState(() => _hasUserKey = true);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('API key saved.')));
  }

  Future<void> _clear() async {
    await ChefKeys.setApiKey('');
    if (mounted) {
      setState(() => _hasUserKey = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool usingBuiltIn = !_hasUserKey && ChefKeys.hasBakedKey;
    final bool ok = _hasUserKey || ChefKeys.hasBakedKey;
    final String status = _hasUserKey
        ? 'Your own Claude API key is saved on this device.'
        : usingBuiltIn
            ? 'Using the built-in key — no setup needed. Paste your own to override.'
            : 'No API key yet — paste one below to enable the chef.';
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('AI CHEF', style: labelCaps(color: kMuted)),
        const SizedBox(height: 12),
        Row(children: <Widget>[
          Icon(ok ? Icons.check_circle_rounded : Icons.key_off_rounded,
              size: 18, color: ok ? kOlive : kWarn),
          const SizedBox(width: 10),
          Expanded(child: Text(status, style: TextStyle(fontSize: 13, color: kInk))),
          if (_hasUserKey)
            TextButton(
                onPressed: _clear,
                child: const Text('Clear', style: TextStyle(color: kDanger))),
        ]),
        const SizedBox(height: 10),
        Row(children: <Widget>[
          Expanded(
            child: TextField(
              controller: _key,
              obscureText: _obscure,
              autocorrect: false,
              enableSuggestions: false,
              style: mono(size: 13),
              decoration: InputDecoration(
                hintText: _hasUserKey ? 'Replace key (sk-ant-…)' : 'sk-ant-…',
                hintStyle: TextStyle(color: kFaint),
                isDense: true,
                filled: true,
                fillColor: kInset,
                suffixIcon: IconButton(
                  icon: Icon(
                      _obscure
                          ? Icons.visibility_rounded
                          : Icons.visibility_off_rounded,
                      size: 18),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: kBorder)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: kBorder)),
              ),
            ),
          ),
          const SizedBox(width: 10),
          ElevatedButton(
            onPressed: _save,
            style: ElevatedButton.styleFrom(
                backgroundColor: kAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
            child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ]),
        const SizedBox(height: 16),
        Text('MODEL', style: labelCaps(color: kMuted)),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const <ButtonSegment<String>>[
            ButtonSegment<String>(value: 'haiku', label: Text('Haiku')),
            ButtonSegment<String>(value: 'sonnet', label: Text('Sonnet')),
            ButtonSegment<String>(value: 'opus', label: Text('Opus 4.8')),
          ],
          selected: <String>{_model},
          showSelectedIcon: false,
          onSelectionChanged: (Set<String> s) {
            setState(() => _model = s.first);
            ChefKeys.setModelPref(s.first);
          },
          style: ButtonStyle(
            backgroundColor: WidgetStateProperty.resolveWith((Set<WidgetState> st) =>
                st.contains(WidgetState.selected)
                    ? kAccent.withValues(alpha: 0.16)
                    : kCard),
            foregroundColor: WidgetStateProperty.all(kInk),
            side: WidgetStateProperty.all(const BorderSide(color: kBorder)),
          ),
        ),
        const SizedBox(height: 6),
        Text(_modelCost[_model] ?? '',
            style: TextStyle(fontSize: 12, color: kMuted)),
        const SizedBox(height: 18),
        Text('MY KITCHEN', style: labelCaps(color: kMuted)),
        const SizedBox(height: 4),
        Text('Tap what you own. The chef only cooks with these.',
            style: TextStyle(fontSize: 11, color: kFaint)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final CookDevice d in kKnownDevices) _deviceChip(d.name),
            for (final String c in _customDevices)
              _deviceChip(c, custom: true),
            _addChip(),
          ],
        ),
        if (_customDevices.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text('Long-press one you added to remove it.',
              style: TextStyle(fontSize: 11, color: kFaint)),
        ],
        const SizedBox(height: 18),
        Text('AVOID', style: labelCaps(color: kMuted)),
        const SizedBox(height: 4),
        Text('Foods the chef must never use — tap to remove one. Anything not '
            'listed is fair game.',
            style: TextStyle(fontSize: 11, color: kFaint, height: 1.35)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            for (final String a in _avoids) _avoidChip(a),
            _addAvoidChip(),
          ],
        ),
        if (_avoids.isEmpty) ...<Widget>[
          const SizedBox(height: 8),
          Text('Nothing avoided — only your shrimp allergy still applies.',
              style: TextStyle(fontSize: 11, color: kFaint)),
        ],
        const SizedBox(height: 16),
        Text('Calls the Claude API directly. Billing is pay-as-you-go and '
            'separate from any Claude.ai subscription.',
            style: TextStyle(fontSize: 11, color: kFaint, height: 1.4)),
      ]),
    );
  }

  /// Self-sizing pill (not a Material ChoiceChip — those clip their label in a
  /// constrained row; see the v0.6.1 filter-chip fix).
  Widget _deviceChip(String name, {bool custom = false}) {
    final bool on = _equipment.contains(name);
    return Material(
      color: on ? kAccent.withValues(alpha: 0.14) : kCard,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _toggleDevice(name),
        onLongPress: custom ? () => _removeCustomDevice(name) : null,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
                color: on ? kAccent.withValues(alpha: 0.55) : kBorder),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            if (on) ...<Widget>[
              const Icon(Icons.check_rounded, size: 14, color: kAccent),
              const SizedBox(width: 6),
            ],
            Text(name,
                style: TextStyle(
                    fontSize: 13,
                    color: on ? kAccent : kInk,
                    fontWeight: on ? FontWeight.w600 : FontWeight.w400)),
          ]),
        ),
      ),
    );
  }

  /// Everything in the list IS avoided, so a pill only needs a way out.
  Widget _avoidChip(String name) {
    return Material(
      color: kDanger.withValues(alpha: 0.13),
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _removeAvoid(name),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 9, 10, 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: kDanger.withValues(alpha: 0.55)),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Text(name,
                style: const TextStyle(
                    fontSize: 13,
                    color: kDanger,
                    fontWeight: FontWeight.w600)),
            const SizedBox(width: 7),
            const Icon(Icons.close_rounded, size: 14, color: kDanger),
          ]),
        ),
      ),
    );
  }

  Widget _addAvoidChip() {
    return Material(
      color: kCard,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _addCustomAvoid,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: kBorder),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Icon(Icons.add_rounded, size: 15, color: kMuted),
            const SizedBox(width: 5),
            Text('Add', style: TextStyle(fontSize: 13, color: kMuted)),
          ]),
        ),
      ),
    );
  }

  Widget _addChip() {
    return Material(
      color: kCard,
      borderRadius: BorderRadius.circular(20),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: _addCustomDevice,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: kBorder, style: BorderStyle.solid),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Icon(Icons.add_rounded, size: 15, color: kMuted),
            const SizedBox(width: 5),
            Text('Add',
                style: TextStyle(fontSize: 13, color: kMuted)),
          ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// Shared: run an async task under a modal spinner; show errors as a snackbar.
// ═══════════════════════════════════════════════════════════════════════

/// Keeps a PageView child (and its running step timer) alive when off-screen.
class _KeepAlive extends StatefulWidget {
  final Widget child;
  const _KeepAlive({required this.child});
  @override
  State<_KeepAlive> createState() => _KeepAliveState();
}

class _KeepAliveState extends State<_KeepAlive>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;
  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

Future<T?> withSpinner<T>(
    BuildContext context, String message, Future<T> Function() task) async {
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => Center(
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration:
            BoxDecoration(color: kCard, borderRadius: BorderRadius.circular(16)),
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          const CircularProgressIndicator(color: kAccent),
          const SizedBox(height: 16),
          Text(message, style: TextStyle(color: kInk, fontSize: 14)),
        ]),
      ),
    ),
  );
  try {
    final T result = await task();
    if (context.mounted) {
      Navigator.of(context).pop();
    }
    return result;
  } catch (e) {
    if (context.mounted) {
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
    return null;
  }
}
