import 'dart:async';

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'chef.dart';
import 'chef_models.dart';
import 'chef_sync.dart';
import 'cook_timers.dart';
import 'cooked_handoff.dart';
import 'liver.dart';
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

  /// Take grams off a pantry item. Carried down to the measuring screen,
  /// which is the only place that knows what really went in the pan.
  final void Function(PantryItem item, double grams)? onUse;

  const CookTab(
      {super.key,
      required this.items,
      this.prices = const PriceBook(),
      this.onUse});

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
        pantry: widget.items,
        onUse: widget.onUse,
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
        pantry: widget.items,
        onUse: widget.onUse,
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
        recentForms: _history.frequentShapes(),
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
        recentForms: _history.frequentShapes(),
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
  // so "Five different ideas" regenerates in the same mode.
  void _openOptions(List<MealOption> options, String? request) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => OptionsScreen(
        options: options,
        servings: _servings,
        pantry: widget.items,
        onUse: widget.onUse,
        request: request,
        onRegenerate: (List<MealOption> shown) => Chef.generateOptions(
          pantry: widget.items,
          servings: _servings,
          recentMeals: _history.recent(),
          recentForms: _history.frequentShapes(),
          prices: widget.prices,
          request: request,
          justShown: shown.map((MealOption o) => o.title).toList(),
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
                  'dish, a vibe. I\'ll tailor five ideas to it.',
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
        Text('Tell me when you\'re ready and I\'ll give you five ideas from '
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

/// "Cooked this?" plus the one line that makes the next attempt better.
///
/// Returns null if the cook backed out. Otherwise the note, which may be
/// empty: the box is optional and skipping it is the common case.
Future<String?> confirmCooked(BuildContext context, String title) async {
  final TextEditingController note = TextEditingController();
  final String? result = await showModalBottomSheet<String>(
    context: context,
    backgroundColor: kCard,
    isScrollControlled: true, // the keyboard must not cover the field
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (BuildContext ctx) {
      final double pad = 20 + MediaQuery.of(ctx).viewPadding.bottom;
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Padding(
          padding: EdgeInsets.fromLTRB(22, 22, 22, pad),
          child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Text('Cooked “$title”?',
                textAlign: TextAlign.center,
                style: serif(size: 20, weight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('It comes off the menu and goes into your history.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13.5, color: kMuted, height: 1.4)),
            const SizedBox(height: 18),
            TextField(
              controller: note,
              textCapitalization: TextCapitalization.sentences,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 14.5, color: kInk),
              decoration: InputDecoration(
                hintText: 'How did it go? Too salty, needed longer…',
                hintStyle: TextStyle(color: kFaint, fontSize: 14),
                filled: true,
                fillColor: kInset,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: kBorder)),
                enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: const BorderSide(color: kBorder)),
              ),
            ),
            const SizedBox(height: 6),
            Text('Optional. The chef reads it when you cook this again.',
                style: TextStyle(fontSize: 11.5, color: kFaint)),
            const SizedBox(height: 18),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx, note.text),
                style: ElevatedButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12))),
                child: Text('Yes, cooked',
                    style: serif(
                        size: 16, weight: FontWeight.w600, color: Colors.white)),
              ),
            ),
            const SizedBox(height: 8),
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text('Not yet', style: TextStyle(color: kMuted))),
          ]),
        ),
      );
    },
  );
  note.dispose();
  if (result == null) {
    return null;
  }
  LocalCache.addNote(title, result);
  ChefSync.pushSoon();
  return result;
}

// ═══════════════════════════════════════════════════════════════════════
// OPTIONS — five wildly different dinners + "Five different ideas"
// ═══════════════════════════════════════════════════════════════════════

class OptionsScreen extends StatefulWidget {
  final List<MealOption> options;
  final int servings;
  /// The live pantry, carried down so the recipe screen can answer
  /// "I'm out of this" against what's actually on the shelf.
  final List<PantryItem> pantry;
  final void Function(PantryItem item, double grams)? onUse;
  final String? request; // the craving, when these came from "Cook a request"
  /// Regenerate, told what was just on screen so it can't hand it back.
  final Future<List<MealOption>> Function(List<MealOption> shown) onRegenerate;
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
    this.pantry = const <PantryItem>[],
    this.onUse,
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
        context, 'Five different ideas…', () => widget.onRegenerate(_options));
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
        pantry: widget.pantry,
        onUse: widget.onUse,
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
        padding: pagePadding(context, top: 8, bottom: bottomPad, side: 16),
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
                  ? 'Five takes on what you asked for — pick one.'
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
              label: const Text('Five different ideas'),
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
          // "CHICKEN · SHEET-PAN · MEDITERRANEAN" — the three axes that make
          // it a different dinner from the other two cards.
          if (o.protein.isNotEmpty || o.shape.isNotEmpty)
            Text(
                <String>[
                  if (o.protein.isNotEmpty) o.protein,
                  if (o.form.isNotEmpty) o.form,
                  if (o.cuisine.isNotEmpty) o.cuisine,
                ].join(' · ').toUpperCase(),
                style: labelCaps(color: kAccent)),
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
          if (o.sides.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              const Icon(Icons.eco_rounded, size: 14, color: kOlive),
              const SizedBox(width: 6),
              Expanded(
                  child: Text('with ${o.sides}',
                      style: TextStyle(fontSize: 12.5, color: kOlive, height: 1.3))),
            ]),
          ],
          const SizedBox(height: 12),
          Row(children: <Widget>[
            Text('${_i(o.proteinPerServing)}g protein',
                style: mono(size: 12, color: kOlive)),
            const SizedBox(width: 14),
            Text('${_i(o.caloriesPerServing)} cal',
                style: mono(size: 12, color: kOlive)),
          ]),
          // The liver line. Each number is olive inside its limit and amber
          // over it, so a dish that slipped is visible before it's picked.
          if (reportsLiverNumbers(o)) ...<Widget>[
            const SizedBox(height: 5),
            Row(children: <Widget>[
              Text('${_i(o.satFatPerServing)}g sat fat',
                  style: mono(
                      size: 12,
                      color: o.satFatPerServing > kMaxSatFatPerServing
                          ? kWarn
                          : kOlive)),
              const SizedBox(width: 14),
              Text('${_i(o.addedSugarPerServing)}g sugar',
                  style: mono(
                      size: 12,
                      color: o.addedSugarPerServing > kMaxAddedSugarPerServing
                          ? kWarn
                          : kOlive)),
              const SizedBox(width: 14),
              Text('${_i(o.fiberPerServing)}g fiber',
                  style: mono(
                      size: 12,
                      color: o.fiberPerServing < kMinFiberPerServing
                          ? kWarn
                          : kOlive)),
            ]),
          ],
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
  final List<PantryItem> pantry;
  final void Function(PantryItem item, double grams)? onUse;

  const RecipeBoxScreen({
    super.key,
    required this.box,
    this.pantry = const <PantryItem>[],
    this.onUse,
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
        pantry: widget.pantry,
        onUse: widget.onUse,
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
  final List<PantryItem> pantry;
  final void Function(PantryItem item, double grams)? onUse;

  const PlannedMealScreen({
    super.key,
    required this.meal,
    this.pantry = const <PantryItem>[],
    this.onUse,
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

  Future<void> _cooked() async {
    // Destructive (clears the menu, writes history) and it sat one thumb-width
    // from "View full recipe" — so it asks first.
    final String? note = await confirmCooked(context, _meal.recipe.title);
    if (note == null || !mounted) {
      return;
    }
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
        padding: pagePadding(context, top: 4, bottom: bottomPad),
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
          // The thing you tap every time is the big one; the thing you tap
          // once per meal is quiet, further down, and confirms.
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => RecipeScreen(
                    recipe: r,
                    pantry: widget.pantry,
                    onUse: widget.onUse,
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
              label: Text('View full recipe',
                  style: serif(size: 16, weight: FontWeight.w600, color: Colors.white)),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
            ),
          ),
          const SizedBox(height: 26),
          Center(
            child: TextButton.icon(
              onPressed: _cooked,
              icon: const Icon(Icons.check_rounded, size: 18),
              label: const Text('I cooked this'),
              style: TextButton.styleFrom(
                  foregroundColor: kMuted,
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12)),
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
  final List<PantryItem> pantry;
  final void Function(PantryItem item, double grams)? onUse;
  const RecipeScreen({
    super.key,
    required this.recipe,
    required this.onCooked,
    this.pantry = const <PantryItem>[],
    this.onUse,
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

  bool _revising = false;

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
        padding: pagePadding(context, bottom: bottomPad),
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
          if (LocalCache.loadNotes(r.title).isNotEmpty) ...<Widget>[
            _cookNotesCard(LocalCache.loadNotes(r.title)),
            const SizedBox(height: 14),
          ],
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
                      CookingModeScreen(
                    recipe: r,
                    factor: _factor,
                    pantry: widget.pantry,
                    servings: _servings,
                  ),
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
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) =>
                      PrepScreen(
                    recipe: r,
                    servings: _servings,
                    pantry: widget.pantry,
                    onUse: widget.onUse,
                    onSent: widget.onCooked,
                  ),
                ),
              ),
              icon: const Icon(Icons.checklist_rounded, size: 18),
              label: Text('Measure everything out',
                  style: serif(size: 15, weight: FontWeight.w600, color: kOlive)),
              style: OutlinedButton.styleFrom(
                  foregroundColor: kOlive,
                  side: BorderSide(color: kOlive.withValues(alpha: 0.5)),
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
          for (int i = 0; i < r.steps.length; i++)
            _stepRow(i + 1, r.steps[i], i),
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
              onPressed: () async {
                if (await confirmCooked(context, r.title) == null ||
                    !context.mounted) {
                  return;
                }
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
          // You don't always know at the moment you tap "I cooked this"
          // whether something was off. This adds one any time after.
          Center(
            child: TextButton.icon(
              onPressed: _addNote,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('Add a note about this recipe',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              style: TextButton.styleFrom(foregroundColor: kMuted),
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

  /// What you wrote down the last time you cooked this, and the offer to have
  /// the chef act on it.
  Widget _cookNotesCard(List<String> notes) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kOlive.withValues(alpha: 0.35))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          const Icon(Icons.edit_note_rounded, size: 18, color: kOlive),
          const SizedBox(width: 8),
          Text('LAST TIME YOU COOKED THIS', style: labelCaps(color: kOlive)),
        ]),
        const SizedBox(height: 10),
        for (int i = 0; i < notes.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('·  ', style: TextStyle(fontSize: 14, color: kFaint)),
                  Expanded(
                      child: Text(notes[i],
                          style: const TextStyle(
                              fontSize: 14, color: kInk, height: 1.45))),
                  InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () {
                      LocalCache.removeNote(widget.recipe.title, i);
                      ChefSync.pushSoon();
                      setState(() {});
                    },
                    child: const Padding(
                      padding: EdgeInsets.all(4),
                      child: Icon(Icons.close_rounded, size: 15, color: kFaint),
                    ),
                  ),
                ]),
          ),
        const SizedBox(height: 6),
        SizedBox(
          width: double.infinity,
          height: 44,
          child: OutlinedButton.icon(
            onPressed: _revising ? null : _reviseWithNotes,
            icon: _revising
                ? const SizedBox(
                    width: 15,
                    height: 15,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: kOlive))
                : const Icon(Icons.auto_fix_high_rounded, size: 17),
            label: Text(_revising ? 'Rewriting…' : 'Cook it again, fixed',
                style: const TextStyle(
                    fontSize: 14, fontWeight: FontWeight.w600)),
            style: OutlinedButton.styleFrom(
                foregroundColor: kOlive,
                side: BorderSide(color: kOlive.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10))),
          ),
        ),
      ]),
    );
  }

  /// Write down what was off, whenever you notice it. The chef reads these
  /// when you ask it to cook the dish again.
  Future<void> _addNote() async {
    final TextEditingController c = TextEditingController();
    final String? entered = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('How did it go?', style: serif(size: 19)),
        content: TextField(
          controller: c,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          minLines: 2,
          maxLines: 4,
          style: const TextStyle(fontSize: 14.5, color: kInk),
          decoration: InputDecoration(
            hintText: 'Too salty. The roast wanted 4 more minutes.',
            hintStyle: TextStyle(color: kFaint, fontSize: 14),
            filled: true,
            fillColor: kInset,
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: const BorderSide(color: kBorder)),
          ),
        ),
        actions: <Widget>[
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text('Cancel', style: TextStyle(color: kMuted))),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, c.text),
            style: ElevatedButton.styleFrom(
                backgroundColor: kAccent, foregroundColor: Colors.white),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    final String note = (entered ?? '').trim();
    c.dispose();
    if (note.isEmpty) {
      return;
    }
    LocalCache.addNote(widget.recipe.title, note);
    ChefSync.pushSoon();
    if (!mounted) {
      return;
    }
    setState(() {});
    ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Noted for next time.')));
  }

  Future<void> _reviseWithNotes() async {
    final List<String> notes = LocalCache.loadNotes(widget.recipe.title);
    if (notes.isEmpty) {
      return;
    }
    setState(() => _revising = true);
    try {
      final Recipe revised = await Chef.reviseRecipe(
        recipe: widget.recipe,
        notes: notes,
        servings: _servings,
        pantry: widget.pantry,
      );
      if (!mounted) {
        return;
      }
      setState(() => _revising = false);
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => RecipeScreen(
          recipe: revised,
          pantry: widget.pantry,
          onUse: widget.onUse,
          initialServings: _servings,
          onSave: widget.onSave,
          onCooked: widget.onCooked,
        ),
      ));
    } on ChefException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() => _revising = false);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() => _revising = false);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Could not rewrite the recipe. Try again.')));
    }
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

  /// Tapping a row is how you say you've run out of it.
  Widget _ingredientRow(RecipeIngredient ing) => InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => showOutOfSheet(
          context: context,
          recipe: widget.recipe,
          ingredient: ing,
          pantry: widget.pantry,
          servings: _servings,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Expanded(
                child: Text(ing.item,
                    style: const TextStyle(fontSize: 15, color: kInk))),
            const SizedBox(width: 12),
            Text(ing.scaled(_factor),
                style: mono(size: 14, weight: FontWeight.w600, color: kOlive)),
          ]),
        ),
      );

  Widget _stepRow(int n, RecipeStep step, int index) {
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
              StepTimer(
                timerKey: '${widget.recipe.title}#$index',
                label: step.title.isEmpty ? 'Step $n' : step.title,
                seconds: step.timerSeconds,
              ),
            ],
          ]),
        ),
      ]),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// COOKING MODE — the counter screen. Screen stays awake.
//
// On a phone it is one step at a time. On a tablet in landscape it splits:
// the whole method down the left, the step you are on down the right, so
// you stop swiping back to check what is coming. Counter mode blows the
// type up and lets you tap anywhere to advance, for wet hands three feet
// away.
//
// Timers live in CookTimers, not in the step widget, so the rice, the oven
// and the pan all run at once and none of them stops when you move on.
// ═══════════════════════════════════════════════════════════════════════

/// Remembered layout choices. Both are per-device, neither is worth syncing.
const String kPrefTwoPane = 'cook_two_pane';
const String kPrefCounter = 'cook_counter';

/// Below this the split has nowhere to go, so the toggle stays hidden.
const double kSplitMinWidth = 860;

class CookingModeScreen extends StatefulWidget {
  final Recipe recipe;
  final double factor;
  final List<PantryItem> pantry;
  final int servings;
  const CookingModeScreen({
    super.key,
    required this.recipe,
    required this.factor,
    this.pantry = const <PantryItem>[],
    this.servings = 0,
  });

  @override
  State<CookingModeScreen> createState() => _CookingModeScreenState();
}

class _CookingModeScreenState extends State<CookingModeScreen> {
  final PageController _pc = PageController();
  int _page = 0;
  late bool _twoPane = LocalCache.prefBool(kPrefTwoPane, fallback: true);
  late bool _counter = LocalCache.prefBool(kPrefCounter);

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    Notifications.requestPermission();
    // Anything left over from an earlier dish would sit in the rail lying
    // about what is on the stove.
    CookTimers.instance.retainOnly(_timerPrefix);
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    _pc.dispose();
    super.dispose();
  }

  String get _timerPrefix => '${widget.recipe.title}#';
  String _timerKey(int i) => '$_timerPrefix$i';

  List<RecipeStep> get _steps => widget.recipe.steps;

  /// Type scale. Counter mode is meant to be readable from across the
  /// kitchen, not merely bigger.
  double get _ts => _counter ? 1.35 : 1.0;

  void _go(int i) {
    if (_steps.isEmpty) {
      return;
    }
    final int next = i.clamp(0, _steps.length - 1);
    if (next == _page) {
      return;
    }
    if (_pc.hasClients) {
      _pc.animateToPage(next,
          duration: const Duration(milliseconds: 250), curve: Curves.easeOut);
    }
    setState(() => _page = next);
  }

  void _setTwoPane(bool v) {
    setState(() => _twoPane = v);
    LocalCache.setPrefBool(kPrefTwoPane, v);
  }

  void _setCounter(bool v) {
    setState(() => _counter = v);
    LocalCache.setPrefBool(kPrefCounter, v);
  }

  @override
  Widget build(BuildContext context) {
    final bool wide = MediaQuery.sizeOf(context).width >= kSplitMinWidth;
    final bool split = wide && _twoPane && _steps.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Text('Cooking', style: serif(size: 18)),
        actions: <Widget>[
          IconButton(
            tooltip: 'Ingredients',
            onPressed: _showIngredients,
            icon: const Icon(Icons.receipt_long_rounded),
          ),
          if (wide)
            IconButton(
              tooltip: _twoPane ? 'One step at a time' : 'Show the method',
              onPressed: () => _setTwoPane(!_twoPane),
              icon: Icon(_twoPane
                  ? Icons.crop_portrait_rounded
                  : Icons.vertical_split_rounded),
              color: _twoPane ? kAccent : kInk,
            ),
          IconButton(
            tooltip: _counter ? 'Normal size' : 'Counter mode',
            onPressed: () => _setCounter(!_counter),
            icon: const Icon(Icons.format_size_rounded),
            color: _counter ? kAccent : kInk,
          ),
          Center(
              child: Padding(
            padding: const EdgeInsets.only(right: 16, left: 4),
            child: Text('${_page + 1} / ${_steps.length}',
                style: mono(size: 13, color: kMuted)),
          )),
        ],
      ),
      body: Column(children: <Widget>[
        LinearProgressIndicator(
          value: _steps.isEmpty ? 0 : (_page + 1) / _steps.length,
          minHeight: 3,
          backgroundColor: kInset,
          valueColor: const AlwaysStoppedAnimation<Color>(kAccent),
        ),
        Expanded(
            child: _steps.isEmpty
                ? Center(
                    child: Text('This recipe has no steps.',
                        style: TextStyle(fontSize: 14, color: kMuted)))
                : (split ? _splitBody() : _pagedBody())),
        const TimerRail(),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Row(children: <Widget>[
              if (_page > 0) _navBtn('Back', () => _go(_page - 1)),
              const Spacer(),
              if (_page < _steps.length - 1)
                _navBtn('Next', () => _go(_page + 1), primary: true)
              else
                _navBtn('Done', () {
                  CookTimers.instance.clearAll();
                  Navigator.pop(context);
                }, primary: true),
            ]),
          ),
        ),
      ]),
    );
  }

  // ── layouts ───────────────────────────────────────────────────────────

  Widget _pagedBody() {
    return PageView.builder(
      controller: _pc,
      itemCount: _steps.length,
      onPageChanged: (int i) => setState(() => _page = i),
      itemBuilder: (_, int i) => _KeepAlive(child: _stepPage(i)),
    );
  }

  Widget _splitBody() {
    return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[
      SizedBox(width: 320, child: _methodList()),
      const VerticalDivider(width: 1, color: kBorder),
      Expanded(child: _stepPage(_page)),
    ]);
  }

  /// The whole method down the side. Done steps go quiet, the live one is
  /// marked, and any step is one tap away.
  Widget _methodList() {
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 20),
      itemCount: _steps.length,
      itemBuilder: (_, int i) {
        final RecipeStep st = _steps[i];
        final bool current = i == _page;
        final bool past = i < _page;
        final String text =
            st.title.isNotEmpty ? st.title : st.content;
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Material(
            color: current ? kAccent.withValues(alpha: 0.12) : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              onTap: () => _go(i),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
                child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      SizedBox(
                        width: 26,
                        child: Text('${i + 1}',
                            style: serif(
                                size: 17,
                                weight: FontWeight.w600,
                                color: current
                                    ? kAccent
                                    : (past ? kFaint : kMuted))),
                      ),
                      Expanded(
                        child: Text(
                          text,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 1.35,
                            color: current ? kInk : (past ? kFaint : kMuted),
                            fontWeight:
                                current ? FontWeight.w700 : FontWeight.w400,
                          ),
                        ),
                      ),
                      if (st.hasTimer) ...<Widget>[
                        const SizedBox(width: 6),
                        Icon(Icons.timer_outlined,
                            size: 15, color: past ? kFaint : kMuted),
                      ],
                    ]),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _stepPage(int i) {
    final RecipeStep step = _steps[i];
    final Widget body = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text('STEP ${i + 1}', style: labelCaps(color: kAccent)),
        const SizedBox(height: 10),
        if (step.title.isNotEmpty)
          Text(step.title,
              style: serif(
                  size: 30 * _ts, weight: FontWeight.w600, height: 1.15)),
        const SizedBox(height: 16),
        if (step.content.isNotEmpty)
          Text(step.content,
              style: TextStyle(
                  fontSize: 20 * _ts, color: kInk, height: 1.55)),
        if (step.hasTimer) ...<Widget>[
          const SizedBox(height: 24),
          StepTimer(
            timerKey: _timerKey(i),
            label: step.title.isEmpty ? 'Step ${i + 1}' : step.title,
            seconds: step.timerSeconds,
            large: true,
          ),
        ],
        if (_counter) ...<Widget>[
          const SizedBox(height: 28),
          Text('Tap anywhere to go on.', style: mono(size: 12, color: kFaint)),
        ],
      ]),
    );
    if (!_counter) {
      return body;
    }
    // Counter mode: greasy hands, so the whole page is the Next button.
    // Behind the scroll view, so a long step can still be read.
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onTap: () => _go(_page + 1),
      child: body,
    );
  }

  // ── ingredients + running out ─────────────────────────────────────────

  void _showIngredients() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(ctx).height * 0.8),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 24),
            children: <Widget>[
              Row(children: <Widget>[
                Text('INGREDIENTS', style: labelCaps(color: kAccent)),
                const Spacer(),
                Text('tap one if you are out',
                    style: mono(size: 11, color: kFaint)),
              ]),
              const SizedBox(height: 12),
              for (final RecipeIngredient ing in widget.recipe.ingredients)
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () {
                    Navigator.pop(ctx);
                    showOutOfSheet(
                      context: context,
                      recipe: widget.recipe,
                      ingredient: ing,
                      pantry: widget.pantry,
                      servings: widget.servings > 0
                          ? widget.servings
                          : widget.recipe.baseServings,
                    );
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(children: <Widget>[
                      Expanded(
                          child: Text(ing.item,
                              style:
                                  const TextStyle(fontSize: 15, color: kInk))),
                      const SizedBox(width: 12),
                      Text(ing.scaled(widget.factor),
                          style: mono(
                              size: 14,
                              weight: FontWeight.w600,
                              color: kOlive)),
                    ]),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navBtn(String label, VoidCallback onTap, {bool primary = false}) {
    return SizedBox(
      height: _counter ? 64 : 52,
      width: _counter ? 170 : 130,
      child: primary
          ? ElevatedButton(
              onPressed: onTap,
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: Text(label,
                  style: serif(
                      size: 16 * _ts,
                      weight: FontWeight.w600,
                      color: Colors.white)))
          : OutlinedButton(
              onPressed: onTap,
              style: OutlinedButton.styleFrom(
                  foregroundColor: kInk,
                  side: const BorderSide(color: kBorder),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
              child: Text(label, style: TextStyle(fontSize: 14 * _ts))),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// TIMER RAIL — every timer that is running or has just gone off, in one
// strip that stays put while you move through the steps.
// ═══════════════════════════════════════════════════════════════════════

class TimerRail extends StatelessWidget {
  const TimerRail({super.key});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: CookTimers.instance,
      builder: (BuildContext context, _) {
        final List<CookTimer> timers = CookTimers.instance.rail;
        if (timers.isEmpty) {
          return const SizedBox.shrink();
        }
        return Container(
          height: 64,
          decoration: const BoxDecoration(
            color: kCard,
            border: Border(top: BorderSide(color: kBorder)),
          ),
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            itemCount: timers.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (_, int i) => _chip(timers[i]),
          ),
        );
      },
    );
  }

  Widget _chip(CookTimer t) {
    final Color c = t.done ? kWarn : kAccent;
    return Material(
      color: c.withValues(alpha: t.done ? 0.18 : 0.10),
      borderRadius: BorderRadius.circular(22),
      child: InkWell(
        borderRadius: BorderRadius.circular(22),
        onTap: () => CookTimers.instance.toggle(t),
        onLongPress: () => CookTimers.instance.dismiss(t),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(22),
              border: Border.all(color: c.withValues(alpha: 0.5))),
          child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Icon(
                t.done
                    ? Icons.notifications_active_rounded
                    : (t.running
                        ? Icons.pause_rounded
                        : Icons.play_arrow_rounded),
                size: 18,
                color: c),
            const SizedBox(width: 8),
            Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(t.done ? 'Time!' : t.display,
                      style:
                          mono(size: 15, weight: FontWeight.w700, color: c)),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 130),
                    child: Text(t.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: kMuted)),
                  ),
                ]),
          ]),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// STEP TIMER — a view onto the shared registry. The countdown itself lives
// in CookTimers, so leaving the step does not stop the pan.
// ═══════════════════════════════════════════════════════════════════════

class StepTimer extends StatelessWidget {
  final String timerKey;
  final String label;
  final int seconds;
  final bool large;
  const StepTimer({
    super.key,
    required this.timerKey,
    required this.seconds,
    this.label = '',
    this.large = false,
  });

  @override
  Widget build(BuildContext context) {
    final CookTimer t = CookTimers.instance
        .ensure(key: timerKey, label: label, seconds: seconds);
    return AnimatedBuilder(
      animation: CookTimers.instance,
      builder: (BuildContext context, _) {
        final Color c = t.done ? kWarn : kAccent;
        final double h = large ? 60 : 44;
        return Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          GestureDetector(
            onTap: () => CookTimers.instance.toggle(t),
            child: Container(
              height: h,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                  color: c.withValues(alpha: t.done ? 0.16 : 0.10),
                  borderRadius: BorderRadius.circular(h / 2),
                  border: Border.all(color: c.withValues(alpha: 0.5))),
              child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
                Icon(
                    t.done
                        ? Icons.notifications_active_rounded
                        : (t.running
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded),
                    color: c,
                    size: large ? 28 : 20),
                const SizedBox(width: 10),
                Text(t.done ? 'Time!' : t.display,
                    style: mono(
                        size: large ? 26 : 17,
                        weight: FontWeight.w600,
                        color: c)),
                if (t.done) ...<Widget>[
                  const SizedBox(width: 10),
                  Text('tap to reset', style: mono(size: 11, color: kMuted)),
                ],
              ]),
            ),
          ),
          if (large && t.running) ...<Widget>[
            const SizedBox(width: 10),
            _nudge(t, 60, '+1'),
            const SizedBox(width: 6),
            _nudge(t, -60, '-1'),
          ],
        ]);
      },
    );
  }

  /// The pan does not care what the recipe said.
  Widget _nudge(CookTimer t, int secs, String label) => Material(
        color: kInset,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => CookTimers.instance.nudge(t, secs),
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
                child: Text(label,
                    style:
                        mono(size: 13, weight: FontWeight.w700, color: kOlive))),
          ),
        ),
      );
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
    ChefSync.pushSoon();
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
    ChefSync.pushSoon();
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
    ChefSync.pushSoon();
  }

  void _removeAvoid(String name) {
    setState(() => _avoids = _avoids.where((String s) => s != name).toList());
    ChefKeys.setAvoids(_avoids);
    ChefSync.pushSoon();
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('No longer avoiding $name.')));
  }

  void _removeCustomDevice(String name) {
    setState(() =>
        _equipment = _equipment.where((String s) => s != name).toList());
    ChefKeys.setEquipment(_equipment);
    ChefSync.pushSoon();
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
            ButtonSegment<String>(value: 'opus', label: Text('Opus 5')),
          ],
          selected: <String>{_model},
          showSelectedIcon: false,
          onSelectionChanged: (Set<String> s) {
            setState(() => _model = s.first);
            ChefKeys.setModelPref(s.first);
            ChefSync.pushSoon();
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

// ═══════════════════════════════════════════════════════════════════════
// MISE EN PLACE — measure everything out before the pan gets hot, and record
// what actually went in.
//
// The bowls come from the chef, because the grouping is a judgement call: two
// things can go in at the same moment and still have to be kept apart until
// then. A bowl is only a hint about washing up; every ingredient is weighed
// on its own regardless.
//
// The number beside each ingredient is editable, because 480 g is what the
// recipe asked for and 473 g is what went in. That number is what leaves the
// pantry and what BodyComp logs, so this screen is the only place it is ever
// true.
// ═══════════════════════════════════════════════════════════════════════

/// Strip a food name down to something two spellings of it can agree on.
String _foodKey(String s) => s
    .toLowerCase()
    .replaceAll(RegExp(r'\([^)]*\)'), ' ') // "(drained)" says nothing useful
    .replaceAll(RegExp(r'[^a-z]+'), ' ')
    .trim();

/// The pantry item an ingredient most likely refers to, or null.
///
/// Exact normalised match first, then containment either way, preferring the
/// shortest hit so "chicken" doesn't win over "chicken thighs" when both are
/// on the shelf. Spices and quantity-unknown items are skipped: they carry no
/// weight or price, so there is nothing to take off them.
PantryItem? matchPantryItem(String ingredient, List<PantryItem> pantry) {
  final String want = _foodKey(ingredient);
  if (want.isEmpty) {
    return null;
  }
  final List<PantryItem> usable = pantry
      .where((PantryItem p) => !p.deleted && !p.spice && !p.quantityUnknown)
      .toList();
  for (final PantryItem p in usable) {
    if (_foodKey(p.name) == want) {
      return p;
    }
  }
  PantryItem? best;
  for (final PantryItem p in usable) {
    final String have = _foodKey(p.name);
    if (have.isEmpty) {
      continue;
    }
    if (want.contains(have) || have.contains(want)) {
      if (best == null || have.length < _foodKey(best.name).length) {
        best = p;
      }
    }
  }
  return best;
}

class PrepScreen extends StatefulWidget {
  final Recipe recipe;
  final int servings;
  final List<PantryItem> pantry;

  /// Take [grams] off a pantry item. Wired to the same path the Use(−) button
  /// uses, so the spending ledger and the GitHub push come along for free.
  final void Function(PantryItem item, double grams)? onUse;

  /// The meal reached BodyComp. Used to mark it cooked in one move.
  final void Function(String title)? onSent;

  const PrepScreen({
    super.key,
    required this.recipe,
    required this.servings,
    this.pantry = const <PantryItem>[],
    this.onUse,
    this.onSent,
  });

  @override
  State<PrepScreen> createState() => _PrepScreenState();
}

class _PrepScreenState extends State<PrepScreen> {
  PrepPlan? _plan;
  bool _loading = true;
  bool _sending = false;
  String _error = '';

  /// One tick per item, in bowl-then-item order.
  Set<String> _done = <String>{};

  /// Keyed by ingredient name, because that is what the cook groups refer to.
  final Map<String, TextEditingController> _measured =
      <String, TextEditingController>{};
  final Map<String, String> _link = <String, String>{}; // '' = deliberately none

  String get _cacheKey => widget.recipe.title;

  double get _factor => widget.recipe.baseServings == 0
      ? 1
      : widget.servings / widget.recipe.baseServings;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final TextEditingController c in _measured.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    if (!force) {
      final PrepPlan? cached = PrepPlan.decode(LocalCache.loadPrep(_cacheKey),
          baseServings: widget.recipe.baseServings);
      if (cached != null && !cached.isEmpty) {
        setState(() {
          _plan = cached;
          _loading = false;
        });
        _seed(cached);
        return;
      }
    }
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final PrepPlan plan = await Chef.planPrep(widget.recipe);
      if (!mounted) {
        return;
      }
      LocalCache.savePrep(_cacheKey, plan.encode());
      setState(() {
        _plan = plan;
        _done = <String>{};
        _loading = false;
      });
      _seed(plan);
    } on ChefException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Could not plan the measuring. Try again.';
        _loading = false;
      });
    }
  }

  /// Prefill every weighable line with the recipe's amount and its best guess
  /// at the pantry item, so an untouched line still sends something true.
  void _seed(PrepPlan plan) {
    for (final PrepBowl b in plan.bowls) {
      for (final PrepItem i in b.items) {
        final String scaled = i.scaled(_factor);
        if (!isGramAmount(scaled)) {
          continue;
        }
        _measured.putIfAbsent(
            i.item,
            () => TextEditingController(
                text: _trim(amountValue(scaled) ?? 0)));
        if (!_link.containsKey(i.item)) {
          final PantryItem? m = matchPantryItem(i.item, widget.pantry);
          if (m != null) {
            _link[i.item] = m.id;
          }
        }
      }
    }
    if (mounted) {
      setState(() {});
    }
  }

  static String _trim(double v) =>
      v == v.roundToDouble() ? v.toInt().toString() : v.toStringAsFixed(1);

  PantryItem? _linked(String ingredient) {
    final String? id = _link[ingredient];
    if (id == null || id.isEmpty) {
      return null;
    }
    for (final PantryItem p in widget.pantry) {
      if (p.id == id) {
        return p;
      }
    }
    return null;
  }

  String _id(int bowl, int item) => '$bowl:$item';

  void _toggle(int bowl, int item) {
    final String id = _id(bowl, item);
    setState(() {
      if (!_done.remove(id)) {
        _done.add(id);
      }
    });
  }

  /// Ticking the header does the whole bowl, either way.
  void _toggleBowl(int bowl, PrepBowl b) {
    final List<String> ids = <String>[
      for (int i = 0; i < b.items.length; i++) _id(bowl, i)
    ];
    final bool allDone = ids.every(_done.contains);
    setState(() {
      if (allDone) {
        _done.removeAll(ids);
      } else {
        _done.addAll(ids);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final PrepPlan? plan = _plan;
    final int total = plan?.itemCount ?? 0;
    return Scaffold(
      appBar: AppBar(
        title: Text('Measure', style: serif(size: 18)),
        actions: <Widget>[
          if (plan != null)
            IconButton(
              tooltip: 'Plan it again',
              onPressed: _loading ? null : () => _load(force: true),
              icon: const Icon(Icons.refresh_rounded),
            ),
          if (total > 0)
            Center(
                child: Padding(
              padding: const EdgeInsets.only(right: 16, left: 4),
              child: Text('${_done.length} / $total',
                  style: mono(size: 13, color: kMuted)),
            )),
        ],
      ),
      body: _body(),
      bottomNavigationBar: (plan == null || plan.isEmpty) ? null : _sendBar(),
    );
  }

  Widget _sendBar() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: SizedBox(
          height: 52,
          child: ElevatedButton.icon(
            onPressed: _sending ? null : _send,
            icon: _sending
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.send_rounded, size: 18),
            label: Text(_sending ? 'Sending…' : 'Done, send to BodyComp',
                style: serif(
                    size: 16, weight: FontWeight.w600, color: Colors.white)),
            style: ElevatedButton.styleFrom(
                backgroundColor: kOlive,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12))),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          const CircularProgressIndicator(color: kAccent),
          const SizedBox(height: 16),
          Text('Working out what can share a bowl…',
              style: TextStyle(fontSize: 13, color: kMuted)),
        ]),
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
            Text(_error,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, color: kWarn)),
            const SizedBox(height: 16),
            OutlinedButton(
                onPressed: () => _load(force: true),
                style: OutlinedButton.styleFrom(
                    foregroundColor: kAccent,
                    side: BorderSide(color: kAccent.withValues(alpha: 0.5))),
                child: const Text('Retry')),
          ]),
        ),
      );
    }
    final PrepPlan? plan = _plan;
    if (plan == null || plan.isEmpty) {
      return Center(
          child: Text('Nothing to measure.',
              style: TextStyle(fontSize: 14, color: kMuted)));
    }

    final bool wide = MediaQuery.sizeOf(context).width >= kSplitMinWidth;
    final List<Widget> cards = <Widget>[
      for (int b = 0; b < plan.bowls.length; b++) _bowlCard(b, plan.bowls[b]),
    ];

    return ListView(
      padding: pagePadding(context,
          top: 16, bottom: 24, maxWidth: wide ? 1000 : 640),
      children: <Widget>[
        Text(widget.recipe.title,
            style: serif(size: 22, weight: FontWeight.w600, height: 1.15)),
        const SizedBox(height: 4),
        Text(
            '${plan.bowls.length} ${plan.bowls.length == 1 ? 'bowl' : 'bowls'}'
            ' for ${widget.servings} '
            '${widget.servings == 1 ? 'serving' : 'servings'}'
            ' · edit a weight if it came out different',
            style: mono(size: 12, color: kMuted)),
        const SizedBox(height: 18),
        if (wide) _twoColumns(cards) else ...cards,
      ],
    );
  }

  Widget _twoColumns(List<Widget> cards) {
    final List<Widget> left = <Widget>[];
    final List<Widget> right = <Widget>[];
    for (int i = 0; i < cards.length; i++) {
      (i.isEven ? left : right).add(cards[i]);
    }
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
      Expanded(child: Column(children: left)),
      const SizedBox(width: 14),
      Expanded(child: Column(children: right)),
    ]);
  }

  Widget _bowlCard(int bowl, PrepBowl b) {
    final List<String> ids = <String>[
      for (int i = 0; i < b.items.length; i++) _id(bowl, i)
    ];
    final bool allDone = ids.isNotEmpty && ids.every(_done.contains);
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: allDone ? kInset : kCard,
        borderRadius: BorderRadius.circular(14),
        border:
            Border.all(color: allDone ? kOlive.withValues(alpha: 0.45) : kBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        InkWell(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(14)),
          onTap: () => _toggleBowl(bowl, b),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 10),
            child: Row(children: <Widget>[
              Icon(
                  allDone
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: allDone ? kOlive : kFaint),
              const SizedBox(width: 10),
              Expanded(
                child: Text(b.label,
                    style: serif(
                        size: 17,
                        weight: FontWeight.w600,
                        color: allDone ? kMuted : kInk)),
              ),
              if (b.step > 0)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                      color: kAccent.withValues(alpha: 0.10),
                      borderRadius: BorderRadius.circular(20)),
                  child: Text('STEP ${b.step}',
                      style: mono(
                          size: 10, weight: FontWeight.w700, color: kAccent)),
                ),
            ]),
          ),
        ),
        const Divider(height: 1, color: kBorder),
        for (int i = 0; i < b.items.length; i++) _itemRow(bowl, i, b.items[i]),
        const SizedBox(height: 6),
      ]),
    );
  }

  Widget _itemRow(int bowl, int i, PrepItem item) {
    final bool done = _done.contains(_id(bowl, i));
    final String scaled = item.scaled(_factor);
    final TextEditingController? ctl = _measured[item.item];
    final PantryItem? link = _linked(item.item);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 9, 16, 9),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => _toggle(bowl, i),
          child: Padding(
            padding: const EdgeInsets.only(top: 2, right: 12),
            child: Icon(
                done
                    ? Icons.check_box_rounded
                    : Icons.check_box_outline_blank_rounded,
                size: 22,
                color: done ? kOlive : kFaint),
          ),
        ),
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                GestureDetector(
                  onTap: () => _toggle(bowl, i),
                  child: Text(item.item,
                      style: TextStyle(
                        fontSize: 15.5,
                        color: done ? kFaint : kInk,
                        decoration: done
                            ? TextDecoration.lineThrough
                            : TextDecoration.none,
                        decorationColor: kFaint,
                      )),
                ),
                if (item.prep.isNotEmpty)
                  Text(item.prep,
                      style: TextStyle(fontSize: 12.5, color: kMuted)),
                if (ctl != null) _linkLine(item.item, link),
              ]),
        ),
        const SizedBox(width: 10),
        if (ctl == null)
          // Spoons and "to taste" are cooked with but never weighed, so they
          // are shown and nothing more.
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(scaled,
                style: mono(
                    size: 15,
                    weight: FontWeight.w700,
                    color: done ? kFaint : kOlive)),
          )
        else
          _gramsField(ctl, done),
      ]),
    );
  }

  Widget _gramsField(TextEditingController ctl, bool done) {
    return SizedBox(
      width: 92,
      height: 40,
      child: TextField(
        controller: ctl,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        textAlign: TextAlign.right,
        style: mono(
            size: 15, weight: FontWeight.w700, color: done ? kFaint : kOlive),
        decoration: InputDecoration(
          isDense: true,
          suffixText: 'g',
          suffixStyle: mono(size: 12, color: kMuted),
          filled: true,
          fillColor: kInset,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: kBorder)),
          enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(color: kBorder)),
        ),
      ),
    );
  }

  /// Which pantry item this line draws down. Tap to change or clear it.
  Widget _linkLine(String ingredient, PantryItem? link) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: () => _pickPantryItem(ingredient),
      child: Padding(
        padding: const EdgeInsets.only(top: 3, bottom: 1),
        child: Row(mainAxisSize: MainAxisSize.min, children: <Widget>[
          Icon(link == null ? Icons.link_off_rounded : Icons.link_rounded,
              size: 12, color: link == null ? kWarn : kFaint),
          const SizedBox(width: 5),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 220),
            child: Text(link == null ? 'not in your pantry' : link.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5, color: link == null ? kWarn : kMuted)),
          ),
        ]),
      ),
    );
  }

  Future<void> _pickPantryItem(String ingredient) async {
    final List<PantryItem> usable = widget.pantry
        .where((PantryItem p) => !p.deleted && !p.spice && !p.quantityUnknown)
        .toList()
      ..sort((PantryItem a, PantryItem b) =>
          a.name.toLowerCase().compareTo(b.name.toLowerCase()));

    final String? picked = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (BuildContext ctx) => SafeArea(
        child: ConstrainedBox(
          constraints:
              BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.75),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
            children: <Widget>[
              Text('WHAT IS THIS?', style: labelCaps(color: kAccent)),
              const SizedBox(height: 4),
              Text(ingredient, style: serif(size: 19, weight: FontWeight.w600)),
              const SizedBox(height: 6),
              Text('Pick what it comes out of, so the right thing is taken '
                  'off the shelf.',
                  style: TextStyle(fontSize: 12.5, color: kMuted)),
              const SizedBox(height: 14),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.link_off_rounded, color: kWarn),
                title: const Text('Not from my pantry',
                    style: TextStyle(fontSize: 14.5)),
                subtitle: Text('Nothing is subtracted for this one.',
                    style: TextStyle(fontSize: 11.5, color: kFaint)),
                onTap: () => Navigator.pop(ctx, ''),
              ),
              const Divider(color: kBorder),
              for (final PantryItem p in usable)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title:
                      Text(p.name, style: const TextStyle(fontSize: 14.5)),
                  subtitle: Text('${_trim(p.remaining)} g left',
                      style: mono(size: 11.5, color: kFaint)),
                  onTap: () => Navigator.pop(ctx, p.id),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked == null || !mounted) {
      return;
    }
    setState(() => _link[ingredient] = picked);
  }

  // ── sending ───────────────────────────────────────────────────────────

  /// Every weighed line, grouped the way it was cooked. Anything the chef did
  /// not put in a pan (a garnish, something spooned over at the table) lands
  /// in a trailing group of its own so it is still logged and still leaves the
  /// pantry.
  List<(String, List<CookedLine>)> _groupedLines() {
    final PrepPlan plan = _plan!;
    final Map<String, CookedLine> lines = <String, CookedLine>{};
    for (final MapEntry<String, TextEditingController> e in _measured.entries) {
      final double g = double.tryParse(e.value.text.trim()) ?? 0;
      if (g <= 0) {
        continue;
      }
      final PantryItem? p = _linked(e.key);
      lines[e.key] = CookedLine(
        name: e.key,
        rawG: g,
        pantryId: p?.id ?? '',
        barcode: p?.barcode,
      );
    }

    final List<(String, List<CookedLine>)> out = <(String, List<CookedLine>)>[];
    final Set<String> claimed = <String>{};
    for (final CookGroup g in plan.cookGroups) {
      final List<CookedLine> mine = <CookedLine>[];
      for (final String name in g.items) {
        final String? hit = lines.keys.firstWhereOrNullKey(name);
        if (hit != null && !claimed.contains(hit)) {
          claimed.add(hit);
          mine.add(lines[hit]!);
        }
      }
      if (mine.isNotEmpty) {
        out.add((g.name, mine));
      }
    }
    final List<CookedLine> rest = <CookedLine>[
      for (final String k in lines.keys)
        if (!claimed.contains(k)) lines[k]!
    ];
    if (rest.isNotEmpty) {
      out.add(('Added at the table', rest));
    }
    return out;
  }

  Future<void> _send() async {
    final List<(String, List<CookedLine>)> groups = _groupedLines();
    if (groups.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nothing weighed yet.')));
      return;
    }
    if (!CookedSync.canWrite) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('This build has no write token, so it can only read.')));
      return;
    }

    final List<CookedGroup>? plated = await showModalBottomSheet<List<CookedGroup>>(
      context: context,
      backgroundColor: kCard,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _PlateSheet(groups: groups),
    );
    if (plated == null || !mounted) {
      return;
    }

    setState(() => _sending = true);
    final CookedMeal meal = CookedMeal(
      id: '${DateTime.now().millisecondsSinceEpoch}',
      recipe: widget.recipe.title,
      servings: widget.servings,
      cookedAtMs: DateTime.now().millisecondsSinceEpoch,
      groups: plated,
    );
    final bool ok = await CookedSync.send(meal);
    if (!mounted) {
      return;
    }
    setState(() => _sending = false);
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text(
              "Couldn't reach GitHub. Nothing was subtracted — try again.")));
      return;
    }

    // Only now does the pantry move. If the handoff failed, the shelf is
    // untouched and the cook can retry without double-subtracting.
    int taken = 0;
    for (final CookedGroup g in plated) {
      for (final CookedLine l in g.lines) {
        if (l.pantryId.isEmpty) {
          continue;
        }
        for (final PantryItem p in widget.pantry) {
          if (p.id == l.pantryId) {
            widget.onUse?.call(p, l.rawG);
            taken++;
            break;
          }
        }
      }
    }
    widget.onSent?.call(widget.recipe.title);
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Sent to BodyComp. '
            '$taken ${taken == 1 ? 'item' : 'items'} came off the shelf.')));
    Navigator.of(context).popUntil((Route<dynamic> route) => route.isFirst);
  }
}

/// Helper for the name join: cook groups name ingredients the way the recipe
/// does, but a stray "(drained)" or a plural shouldn't break the match.
extension _KeyLookup on Iterable<String> {
  String? firstWhereOrNullKey(String wanted) {
    final String w = _foodKey(wanted);
    for (final String k in this) {
      if (_foodKey(k) == w) {
        return k;
      }
    }
    for (final String k in this) {
      final String kk = _foodKey(k);
      if (kk.isNotEmpty && (kk.contains(w) || w.contains(kk))) {
        return k;
      }
    }
    return null;
  }
}

// ═══════════════════════════════════════════════════════════════════════
// PLATE SHEET — the last thing before it goes: how much of each pan ended up
// on your plate. BodyComp divides by what the pan is reckoned to have made.
// ═══════════════════════════════════════════════════════════════════════

class _PlateSheet extends StatefulWidget {
  final List<(String, List<CookedLine>)> groups;
  const _PlateSheet({required this.groups});

  @override
  State<_PlateSheet> createState() => _PlateSheetState();
}

class _PlateSheetState extends State<_PlateSheet> {
  late final List<TextEditingController> _ctl = <TextEditingController>[
    for (int i = 0; i < widget.groups.length; i++) TextEditingController()
  ];

  @override
  void dispose() {
    for (final TextEditingController c in _ctl) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(22, 20, 22, 24),
          child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('ON YOUR PLATE', style: labelCaps(color: kAccent)),
                const SizedBox(height: 6),
                Text('Weigh what you took from each pan.',
                    style: serif(size: 19, weight: FontWeight.w600)),
                const SizedBox(height: 6),
                Text('Leave one blank if you did not have any of it.',
                    style: TextStyle(fontSize: 12.5, color: kMuted)),
                const SizedBox(height: 18),
                for (int i = 0; i < widget.groups.length; i++) _row(i),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: ElevatedButton(
                    onPressed: _submit,
                    style: ElevatedButton.styleFrom(
                        backgroundColor: kOlive,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12))),
                    child: Text('Send',
                        style: serif(
                            size: 16,
                            weight: FontWeight.w600,
                            color: Colors.white)),
                  ),
                ),
              ]),
        ),
      ),
    );
  }

  Widget _row(int i) {
    final (String, List<CookedLine>) g = widget.groups[i];
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(children: <Widget>[
        Expanded(
          child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(g.$1,
                    style: const TextStyle(
                        fontSize: 15, fontWeight: FontWeight.w600, color: kInk)),
                Text(
                    g.$2.map((CookedLine l) => l.name).join(', '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: kFaint)),
              ]),
        ),
        const SizedBox(width: 12),
        SizedBox(
          width: 100,
          height: 44,
          child: TextField(
            controller: _ctl[i],
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            textAlign: TextAlign.right,
            style: mono(size: 15, weight: FontWeight.w700, color: kOlive),
            decoration: InputDecoration(
              isDense: true,
              hintText: '0',
              hintStyle: mono(size: 15, color: kFaint),
              suffixText: 'g',
              suffixStyle: mono(size: 12, color: kMuted),
              filled: true,
              fillColor: kInset,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: kBorder)),
              enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: kBorder)),
            ),
          ),
        ),
      ]),
    );
  }

  void _submit() {
    final List<CookedGroup> out = <CookedGroup>[
      for (int i = 0; i < widget.groups.length; i++)
        CookedGroup(
          name: widget.groups[i].$1,
          plateG: double.tryParse(_ctl[i].text.trim()) ?? 0,
          lines: widget.groups[i].$2,
        ),
    ];
    Navigator.pop(context, out);
  }
}

// ═══════════════════════════════════════════════════════════════════════
// OUT OF AN INGREDIENT — asked mid-cook, answered against the pantry.
// ═══════════════════════════════════════════════════════════════════════

void showOutOfSheet({
  required BuildContext context,
  required Recipe recipe,
  required RecipeIngredient ingredient,
  required List<PantryItem> pantry,
  required int servings,
}) {
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: kCard,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _OutOfSheet(
      recipe: recipe,
      ingredient: ingredient,
      pantry: pantry,
      servings: servings,
    ),
  );
}

class _OutOfSheet extends StatefulWidget {
  final Recipe recipe;
  final RecipeIngredient ingredient;
  final List<PantryItem> pantry;
  final int servings;
  const _OutOfSheet({
    required this.recipe,
    required this.ingredient,
    required this.pantry,
    required this.servings,
  });

  @override
  State<_OutOfSheet> createState() => _OutOfSheetState();
}

class _OutOfSheetState extends State<_OutOfSheet> {
  Substitution? _sub;
  bool _loading = true;
  String _error = '';

  @override
  void initState() {
    super.initState();
    _ask();
  }

  Future<void> _ask() async {
    setState(() {
      _loading = true;
      _error = '';
    });
    try {
      final Substitution s = await Chef.substitute(
        recipe: widget.recipe,
        missing: widget.ingredient,
        pantry: widget.pantry,
        servings: widget.servings,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _sub = s;
        _loading = false;
      });
    } on ChefException catch (e) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = e.message;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = 'Could not find a swap. Try again.';
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Substitution? s = _sub;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(22, 18, 22, 26),
        child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('OUT OF', style: labelCaps(color: kAccent)),
              const SizedBox(height: 6),
              Text(widget.ingredient.item,
                  style: serif(size: 22, weight: FontWeight.w600)),
              const SizedBox(height: 18),
              if (_loading)
                Row(children: <Widget>[
                  const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: kAccent)),
                  const SizedBox(width: 12),
                  Text('Looking at what you have…',
                      style: TextStyle(fontSize: 13, color: kMuted)),
                ])
              else if (_error.isNotEmpty)
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(_error,
                      style: const TextStyle(fontSize: 14, color: kWarn)),
                  const SizedBox(height: 14),
                  OutlinedButton(
                      onPressed: _ask,
                      style: OutlinedButton.styleFrom(
                          foregroundColor: kAccent,
                          side:
                              BorderSide(color: kAccent.withValues(alpha: 0.5))),
                      child: const Text('Retry')),
                ])
              else if (s != null) ...<Widget>[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                      color: kInset, borderRadius: BorderRadius.circular(14)),
                  child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(children: <Widget>[
                          Icon(
                              s.fromPantry
                                  ? Icons.kitchen_rounded
                                  : Icons.shopping_cart_rounded,
                              size: 15,
                              color: s.fromPantry ? kOlive : kWarn),
                          const SizedBox(width: 6),
                          Text(s.fromPantry ? 'FROM YOUR PANTRY' : 'NOT ON YOUR SHELF',
                              style: mono(
                                  size: 10,
                                  weight: FontWeight.w700,
                                  color: s.fromPantry ? kOlive : kWarn)),
                        ]),
                        const SizedBox(height: 10),
                        Text(s.use,
                            style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: kInk,
                                height: 1.4)),
                      ]),
                ),
                if (s.note.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 14),
                  Text(s.note,
                      style: TextStyle(fontSize: 14, color: kInk, height: 1.55)),
                ],
                const SizedBox(height: 18),
                Row(children: <Widget>[
                  OutlinedButton.icon(
                      onPressed: _ask,
                      icon: const Icon(Icons.refresh_rounded, size: 16),
                      label: const Text('Another'),
                      style: OutlinedButton.styleFrom(
                          foregroundColor: kMuted,
                          side: const BorderSide(color: kBorder))),
                  const Spacer(),
                  ElevatedButton(
                      onPressed: () => Navigator.pop(context),
                      style: ElevatedButton.styleFrom(
                          backgroundColor: kAccent,
                          foregroundColor: Colors.white),
                      child: const Text('Got it')),
                ]),
              ],
            ]),
      ),
    );
  }
}
