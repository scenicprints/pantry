import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'chef.dart';
import 'chef_models.dart';
import 'models.dart';
import 'notifications.dart';
import 'storage.dart';
import 'theme.dart';

// ═══════════════════════════════════════════════════════════════════════
// COOK TAB — the AI chef. Reads the live pantry, asks Claude for 3 options,
// then a full grams-based recipe with a live servings scaler, cooking mode,
// and per-step timers.
// ═══════════════════════════════════════════════════════════════════════

class CookTab extends StatefulWidget {
  final List<PantryItem> items;
  const CookTab({super.key, required this.items});

  @override
  State<CookTab> createState() => _CookTabState();
}

class _CookTabState extends State<CookTab> {
  int _servings = 2;
  MealHistory _history = const MealHistory(kSeedMealHistory);
  bool _hasKey = false;

  @override
  void initState() {
    super.initState();
    _history = MealHistory.decode(LocalCache.loadHistory());
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

  int get _expiringCount {
    final DateTime now = DateTime.now();
    return widget.items
        .where((PantryItem i) => !i.deleted && i.isExpiringSoon(now))
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
      ),
    );
    if (options == null || !mounted) {
      return;
    }
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => OptionsScreen(
        options: options,
        servings: _servings,
        onRegenerate: () => Chef.generateOptions(
          pantry: widget.items,
          servings: _servings,
          recentMeals: _history.recent(),
        ),
        onPick: (MealOption o) =>
            Chef.generateRecipe(option: o, servings: _servings),
        onCooked: _markCooked,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final int itemCount =
        widget.items.where((PantryItem i) => !i.deleted).length;
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
        _statsRow(itemCount),
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
      ],
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
  final Future<List<MealOption>> Function() onRegenerate;
  final Future<Recipe> Function(MealOption) onPick;
  final void Function(String title) onCooked;

  const OptionsScreen({
    super.key,
    required this.options,
    required this.servings,
    required this.onRegenerate,
    required this.onPick,
    required this.onCooked,
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
    if (r != null && mounted) {
      Navigator.of(context).push(MaterialPageRoute<void>(
        builder: (_) => RecipeScreen(recipe: r, onCooked: widget.onCooked),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final double bottomPad = 24 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(title: Text('Tonight', style: serif(size: 20))),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 8, 16, bottomPad),
        children: <Widget>[
          Text('Pick one — each uses a different protein.',
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
// RECIPE CARD — the hero screen. Live servings scaler, cooking mode,
// ingredients, numbered steps with per-step timers, notes.
// ═══════════════════════════════════════════════════════════════════════

class RecipeScreen extends StatefulWidget {
  final Recipe recipe;
  final void Function(String title) onCooked;
  const RecipeScreen({super.key, required this.recipe, required this.onCooked});

  @override
  State<RecipeScreen> createState() => _RecipeScreenState();
}

class _RecipeScreenState extends State<RecipeScreen> {
  late int _servings = widget.recipe.baseServings;

  double get _factor =>
      widget.recipe.baseServings == 0 ? 1 : _servings / widget.recipe.baseServings;

  @override
  Widget build(BuildContext context) {
    final Recipe r = widget.recipe;
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(),
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
        const SizedBox(height: 10),
        Text('Calls the Claude API directly. Billing is pay-as-you-go and '
            'separate from any Claude.ai subscription.',
            style: TextStyle(fontSize: 11, color: kFaint, height: 1.4)),
      ]),
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
