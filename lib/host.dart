import 'package:flutter/material.dart';

import 'chef.dart';
import 'chef_models.dart';
import 'cook.dart' show money, withSpinner, RecipeScreen;
import 'host_hub.dart';
import 'models.dart';
import 'pricebook.dart';
import 'theme.dart';

// ═══════════════════════════════════════════════════════════════════════
// HOST HUB — planning menus for guests. Dishes are exactly what the user
// names (not chef-invented), scaled to a guest count, written with no diet
// rules attached (see chef.dart's generateHostDish / _hostSystemPrompt).
// Dinners sync across devices the same way "On the menu" does — see
// HostHubSync in host_hub.dart — so a dinner built on the phone is on the
// iPad at the counter.
//
// Three screens: HostHubScreen is the actual hub — upcoming and past
// dinners, one door in. HostSetupScreen starts a new one. HostResultsScreen
// is a built (or reopened) menu.
// ═══════════════════════════════════════════════════════════════════════

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

const List<String> _kWeekdays = <String>[
  'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun',
];
const List<String> _kMonths = <String>[
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
  'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];

/// "Sat, Oct 3" from a 'YYYY-MM-DD' string; '' if unparsable.
String displayDate(String iso) {
  final DateTime? d = DateTime.tryParse(iso);
  if (d == null) {
    return '';
  }
  return '${_kWeekdays[d.weekday - 1]}, ${_kMonths[d.month - 1]} ${d.day}';
}

// ═══════════════════════════════════════════════════════════════════════
// HUB — the landing screen. Upcoming dinners, past dinners, one clear way
// to start a new one. This is the "Hub" the button on Cook promises: a
// place you return to, not just a form you fill in once and forget.
// ═══════════════════════════════════════════════════════════════════════

class HostHubScreen extends StatelessWidget {
  final List<HostEvent> events; // pre-sorted: upcoming first, then past
  final List<PantryItem> items;
  final PriceBook prices;
  final void Function(HostEvent event) onSave;
  final void Function(HostEvent event) onRemove;
  final void Function(Recipe recipe, int servings)? onSaveRecipe;
  final void Function(PantryItem item, double grams)? onUse;

  const HostHubScreen({
    super.key,
    required this.events,
    required this.items,
    required this.prices,
    required this.onSave,
    required this.onRemove,
    this.onSaveRecipe,
    this.onUse,
  });

  void _openSetup(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HostSetupScreen(
        items: items,
        prices: prices,
        onSave: onSave,
        onRemove: onRemove,
        onSaveRecipe: onSaveRecipe,
        onUse: onUse,
      ),
    ));
  }

  void _openEvent(BuildContext context, HostEvent event) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HostResultsScreen(
        event: event,
        items: items,
        onSave: onSave,
        onRemove: onRemove,
        onSaveRecipe: onSaveRecipe,
        onUse: onUse,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final List<HostEvent> upcoming =
        events.where((HostEvent e) => e.isUpcoming(now)).toList();
    final List<HostEvent> past =
        events.where((HostEvent e) => !e.isUpcoming(now)).toList();
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(title: Text('Host Hub', style: serif(size: 20))),
      body: ListView(
        padding: pagePadding(context, top: 4, bottom: bottomPad),
        children: <Widget>[
          Text(
              'Plan a menu for guests — no diet rules attached, just the '
              'dishes you name, shopped, scaled, and on the iPad when you '
              'cook.',
              style: TextStyle(color: kMuted, fontSize: 13.5, height: 1.4)),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: () => _openSetup(context),
              icon: const Icon(Icons.add_rounded),
              label: Text('New dinner',
                  style: serif(
                      size: 17, weight: FontWeight.w600, color: Colors.white)),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
            ),
          ),
          const SizedBox(height: 26),
          if (events.isEmpty) _emptyState(),
          if (upcoming.isNotEmpty) ...<Widget>[
            Text('UPCOMING', style: labelCaps(color: kAccent)),
            const SizedBox(height: 10),
            for (final HostEvent e in upcoming)
              _eventCard(context, e, highlight: true),
            const SizedBox(height: 22),
          ],
          if (past.isNotEmpty) ...<Widget>[
            Text('PAST', style: labelCaps()),
            const SizedBox(height: 10),
            for (final HostEvent e in past) _eventCard(context, e),
          ],
        ],
      ),
    );
  }

  Widget _emptyState() => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('Nothing planned yet', style: serif(size: 17, weight: FontWeight.w600)),
          const SizedBox(height: 6),
          Text(
              'Start a dinner above — pick a guest count, name your dishes, '
              'and get real recipes for them, no diet rules attached.',
              style: TextStyle(color: kMuted, fontSize: 13, height: 1.4)),
        ]),
      );

  Widget _eventCard(BuildContext context, HostEvent e, {bool highlight = false}) {
    final String title = e.name.trim().isEmpty ? 'Unnamed dinner' : e.name.trim();
    final String dateLabel = e.eventDate.isEmpty ? '' : displayDate(e.eventDate);
    final bool built = e.isBuilt;
    return GestureDetector(
      onTap: () => _openEvent(context, e),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: highlight ? kAccent.withValues(alpha: 0.5) : kBorder)),
        child: Row(children: <Widget>[
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text(title, style: serif(size: 16, weight: FontWeight.w600)),
              const SizedBox(height: 3),
              Text(
                  <String>[
                    '${e.guests} guest${e.guests == 1 ? '' : 's'}',
                    if (dateLabel.isNotEmpty) dateLabel,
                    '${e.dishes.length} dish${e.dishes.length == 1 ? '' : 'es'}',
                    if (!built) 'unfinished',
                  ].join(' · '),
                  style: mono(size: 11, color: built ? kMuted : kWarn)),
            ]),
          ),
          const Icon(Icons.chevron_right_rounded, color: kMuted),
        ]),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// SETUP — guest count, dinner date, a free-form dish list, guest dietary
// notes, and an optional prep timeline.
// ═══════════════════════════════════════════════════════════════════════

class HostSetupScreen extends StatefulWidget {
  final List<PantryItem> items;
  final PriceBook prices;
  final void Function(HostEvent event) onSave;
  final void Function(HostEvent event) onRemove;
  final void Function(Recipe recipe, int servings)? onSaveRecipe;
  final void Function(PantryItem item, double grams)? onUse;

  const HostSetupScreen({
    super.key,
    required this.items,
    required this.prices,
    required this.onSave,
    required this.onRemove,
    this.onSaveRecipe,
    this.onUse,
  });

  @override
  State<HostSetupScreen> createState() => _HostSetupScreenState();
}

class _HostSetupScreenState extends State<HostSetupScreen> {
  int _guests = 6;
  String _eventDate = '';
  final List<TextEditingController> _dishCtrls = <TextEditingController>[
    TextEditingController(),
  ];
  final List<String> _dishCourses = <String>['Main'];
  final TextEditingController _notesCtrl = TextEditingController();
  bool _prepTimeline = false;

  @override
  void dispose() {
    for (final TextEditingController c in _dishCtrls) {
      c.dispose();
    }
    _notesCtrl.dispose();
    super.dispose();
  }

  void _addDish() => setState(() {
        _dishCtrls.add(TextEditingController());
        _dishCourses.add('Main');
      });

  void _removeDish(int i) => setState(() {
        _dishCtrls.removeAt(i).dispose();
        _dishCourses.removeAt(i);
      });

  void _setDishCourse(int i, String course) =>
      setState(() => _dishCourses[i] = course);

  Future<void> _pickDate() async {
    final DateTime now = DateTime.now();
    final DateTime initial =
        DateTime.tryParse(_eventDate) ?? now.add(const Duration(days: 3));
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: initial.isBefore(now) ? now : initial,
      firstDate: now,
      lastDate: now.add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() => _eventDate = _iso(picked));
    }
  }

  Future<HostEvent> _buildMenu() async {
    final List<HostDish> input = <HostDish>[
      for (int i = 0; i < _dishCtrls.length; i++)
        if (_dishCtrls[i].text.trim().isNotEmpty)
          HostDish(text: _dishCtrls[i].text.trim(), course: _dishCourses[i]),
    ];
    if (input.isEmpty) {
      throw ChefException('Add at least one dish first.');
    }
    final String guestNotes = _notesCtrl.text.trim();
    final List<Recipe> recipes = await Future.wait(input.map((HostDish d) =>
        Chef.generateHostDish(
          dish: d.text,
          course: d.course,
          guests: _guests,
          pantry: widget.items,
          prices: widget.prices,
          guestNotes: guestNotes,
        )));
    final List<HostDish> withRecipes = <HostDish>[
      for (int i = 0; i < input.length; i++) input[i].copyWith(recipe: recipes[i]),
    ];
    List<PrepDay> prepDays = const <PrepDay>[];
    if (_prepTimeline) {
      prepDays = await Chef.generateHostTimeline(
          dishes: withRecipes, guests: _guests, eventDate: _eventDate);
    }
    return HostEvent(
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      name: '',
      guests: _guests,
      eventDate: _eventDate,
      dishes: withRecipes,
      guestNotes: guestNotes,
      prepDays: prepDays,
    );
  }

  Future<void> _build() async {
    if (_prepTimeline && _eventDate.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Pick a dinner date first, or turn off the prep timeline.')));
      return;
    }
    final HostEvent? event = await withSpinner<HostEvent>(
        context, 'Building your menu…', _buildMenu);
    if (event == null || !mounted) {
      return;
    }
    widget.onSave(event); // saved as soon as it's built, so it's never lost
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => HostResultsScreen(
        event: event,
        items: widget.items,
        onSave: widget.onSave,
        onRemove: widget.onRemove,
        onSaveRecipe: widget.onSaveRecipe,
        onUse: widget.onUse,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(title: Text('New Dinner', style: serif(size: 20))),
      body: ListView(
        padding: pagePadding(context, top: 4, bottom: bottomPad),
        children: <Widget>[
          _guestsCard(),
          const SizedBox(height: 14),
          _dateCard(),
          const SizedBox(height: 22),
          Text('What are you making?',
              style: serif(size: 17, weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('Add as many dishes as you want, tag each one\'s course.',
              style: TextStyle(color: kMuted, fontSize: 12.5, height: 1.4)),
          const SizedBox(height: 10),
          for (int i = 0; i < _dishCtrls.length; i++) _dishCard(i),
          OutlinedButton.icon(
            onPressed: _addDish,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add a dish'),
            style: OutlinedButton.styleFrom(
                foregroundColor: kInk,
                side: const BorderSide(color: kBorder, width: 1.4),
                minimumSize: const Size(double.infinity, 52),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14))),
          ),
          const SizedBox(height: 14),
          _notesCard(),
          const SizedBox(height: 14),
          _prepToggleCard(),
          const SizedBox(height: 22),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _build,
              icon: const Icon(Icons.restaurant_rounded),
              label: Text('Build my menu',
                  style: serif(
                      size: 17, weight: FontWeight.w600, color: Colors.white)),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
            ),
          ),
        ],
      ),
    );
  }

  Widget _guestsCard() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: Row(children: <Widget>[
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              Text('GUESTS', style: labelCaps()),
              const SizedBox(height: 2),
              Text('$_guests', style: serif(size: 30, weight: FontWeight.w600)),
            ]),
          ),
          _roundBtn(Icons.remove_rounded,
              () => setState(() => _guests = (_guests - 1).clamp(1, 30))),
          const SizedBox(width: 8),
          _roundBtn(
              Icons.add_rounded,
              () => setState(() => _guests = (_guests + 1).clamp(1, 30)),
              filled: true),
        ]),
      );

  Widget _dateCard() => Material(
        color: kCard,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: _pickDate,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kBorder)),
            child: Row(children: <Widget>[
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text('WHEN\'S THE DINNER?', style: labelCaps()),
                  const SizedBox(height: 2),
                  Text(_eventDate.isEmpty ? 'Pick a date' : displayDate(_eventDate),
                      style: serif(
                          size: 18,
                          weight: FontWeight.w600,
                          color: _eventDate.isEmpty ? kFaint : kInk)),
                ]),
              ),
              const Icon(Icons.calendar_month_rounded, color: kMuted),
            ]),
          ),
        ),
      );

  Widget _dishCard(int i) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Row(children: <Widget>[
          Expanded(
            child: TextField(
              controller: _dishCtrls[i],
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(fontSize: 15, color: kInk),
              decoration: InputDecoration(
                hintText: 'e.g. Lasagna',
                hintStyle: TextStyle(color: kFaint),
                filled: true,
                fillColor: kInset,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none),
              ),
            ),
          ),
          if (_dishCtrls.length > 1) ...<Widget>[
            const SizedBox(width: 2),
            IconButton(
              tooltip: 'Remove dish',
              onPressed: () => _removeDish(i),
              icon: const Icon(Icons.close_rounded, size: 20, color: kMuted),
            ),
          ],
        ]),
        const SizedBox(height: 8),
        _courseDropdown(i),
      ]),
    );
  }

  Widget _courseDropdown(int i) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: kBorder)),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<String>(
            value: _dishCourses[i],
            isDense: true,
            icon: const Icon(Icons.expand_more_rounded, size: 16, color: kMuted),
            style: mono(size: 12, weight: FontWeight.w600, color: kInk),
            dropdownColor: kCard,
            items: <DropdownMenuItem<String>>[
              for (final String c in kHostCourses)
                DropdownMenuItem<String>(value: c, child: Text(c)),
            ],
            onChanged: (String? v) {
              if (v != null) {
                _setDishCourse(i, v);
              }
            },
          ),
        ),
      );

  Widget _notesCard() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('GUESTS\' DIETARY NOTES', style: labelCaps()),
          const SizedBox(height: 8),
          TextField(
            controller: _notesCtrl,
            textCapitalization: TextCapitalization.sentences,
            style: const TextStyle(fontSize: 14, color: kInk),
            decoration: InputDecoration(
              hintText: 'e.g. one guest is allergic to tree nuts',
              hintStyle: TextStyle(color: kFaint),
              filled: true,
              fillColor: kInset,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 6),
          Text('This event only — your own avoid list always applies.',
              style: TextStyle(fontSize: 11.5, color: kMuted)),
        ]),
      );

  Widget _prepToggleCard() => Container(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: SwitchListTile.adaptive(
          value: _prepTimeline,
          onChanged: (bool v) => setState(() => _prepTimeline = v),
          activeThumbColor: kOlive,
          contentPadding: EdgeInsets.zero,
          title: Text('Plan a prep timeline',
              style: TextStyle(
                  fontSize: 14, fontWeight: FontWeight.w600, color: kInk)),
          subtitle: Text(
              'Optional — a day-by-day plan working back from your dinner date',
              style: TextStyle(fontSize: 11.5, color: kMuted)),
        ),
      );

  Widget _roundBtn(IconData icon, VoidCallback onTap, {bool filled = false}) =>
      Material(
        color: filled ? kAccent : kInset,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onTap,
          child: Padding(
              padding: const EdgeInsets.all(9),
              child: Icon(icon, size: 20, color: filled ? Colors.white : kInk)),
        ),
      );
}

// ═══════════════════════════════════════════════════════════════════════
// RESULTS — a built (or reopened) menu: cost, each dish, an optional prep
// timeline, a combined checkable shopping list, name/save, and delete.
// ═══════════════════════════════════════════════════════════════════════

class HostResultsScreen extends StatefulWidget {
  final HostEvent event;
  final List<PantryItem> items;
  final void Function(HostEvent event) onSave;
  final void Function(HostEvent event) onRemove;
  final void Function(Recipe recipe, int servings)? onSaveRecipe;
  final void Function(PantryItem item, double grams)? onUse;

  const HostResultsScreen({
    super.key,
    required this.event,
    required this.items,
    required this.onSave,
    required this.onRemove,
    this.onSaveRecipe,
    this.onUse,
  });

  @override
  State<HostResultsScreen> createState() => _HostResultsScreenState();
}

class _HostResultsScreenState extends State<HostResultsScreen> {
  late final List<bool> _checked =
      List<bool>.filled(widget.event.allIngredients.length, false);
  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.event.name);
  bool _saved = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  void _toggle(int i) => setState(() => _checked[i] = !_checked[i]);

  void _save() {
    final HostEvent named = widget.event.copyWith(name: _nameCtrl.text.trim());
    widget.onSave(named);
    setState(() => _saved = true);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(named.name.isEmpty
            ? 'Saved to Host Hub.'
            : '“${named.name}” saved to Host Hub.')));
  }

  Future<void> _delete() async {
    final bool? yes = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        backgroundColor: kCard,
        title: Text('Remove this dinner?', style: serif(size: 18)),
        content: const Text('This takes it off every device.'),
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
      widget.onRemove(widget.event);
      Navigator.pop(context);
    }
  }

  void _openRecipe(Recipe r) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RecipeScreen(
        recipe: r,
        initialServings: widget.event.guests,
        pantry: widget.items,
        onUse: widget.onUse,
        onSave: widget.onSaveRecipe,
        onCooked: (String _) {},
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final HostEvent e = widget.event;
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    final double total = e.estCostTotal;
    final double grocery = e.estGroceryCost;
    final List<RecipeIngredient> ingredients = e.allIngredients;
    return Scaffold(
      appBar: AppBar(
        title: Text(e.name.trim().isEmpty ? 'Your Menu' : e.name.trim(),
            style: serif(size: 20)),
        actions: <Widget>[
          IconButton(
            tooltip: 'Remove this dinner',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: _delete,
          ),
        ],
      ),
      body: ListView(
        padding: pagePadding(context, top: 4, bottom: bottomPad),
        children: <Widget>[
          Text(
              <String>[
                '${e.guests} guest${e.guests == 1 ? '' : 's'}',
                if (e.eventDate.isNotEmpty) displayDate(e.eventDate),
              ].join(' · '),
              style: mono(size: 12, color: kMuted)),
          const SizedBox(height: 14),
          if (e.guestNotes.trim().isNotEmpty) ...<Widget>[
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: kOlive.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kOlive.withValues(alpha: 0.4))),
              child: Text.rich(
                  TextSpan(children: <InlineSpan>[
                    const TextSpan(text: 'Built around: '),
                    TextSpan(
                        text: e.guestNotes.trim(),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                  style: TextStyle(fontSize: 13, color: kInk, height: 1.4)),
            ),
            const SizedBox(height: 14),
          ],
          if (total > 0) ...<Widget>[
            _costCard(total, grocery),
            const SizedBox(height: 14),
          ],
          for (final HostDish d in e.dishes.where((HostDish d) => d.recipe != null))
            _dishCard(d),
          if (e.prepDays.isNotEmpty) ...<Widget>[
            _timelineCard(e.prepDays),
            const SizedBox(height: 14),
          ],
          if (ingredients.isNotEmpty) ...<Widget>[
            _shoppingCard(ingredients),
            const SizedBox(height: 14),
          ],
          _saveCard(),
        ],
      ),
    );
  }

  Widget _costCard(double total, double grocery) {
    final double already = (total - grocery).clamp(0, total);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
          color: kAccent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(14)),
      child: Row(children: <Widget>[
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text('ESTIMATED COST', style: labelCaps(color: kAccent)),
            const SizedBox(height: 2),
            Text('≈ ${money(total)}', style: serif(size: 22, weight: FontWeight.w600)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: <Widget>[
          Text('${money(grocery)} to buy', style: mono(size: 11, color: kMuted)),
          Text('${money(already)} already have', style: mono(size: 11, color: kMuted)),
        ]),
      ]),
    );
  }

  Widget _dishCard(HostDish d) {
    final Recipe r = d.recipe!;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: kBorder)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        Text(d.course.toUpperCase(), style: labelCaps(color: kOlive)),
        const SizedBox(height: 6),
        Text(r.title, style: serif(size: 20, weight: FontWeight.w600, height: 1.2)),
        if (r.description.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(r.description,
              style: serif(
                  size: 14,
                  weight: FontWeight.w400,
                  color: kMuted,
                  style: FontStyle.italic,
                  height: 1.4)),
        ],
        const SizedBox(height: 10),
        Text('Serves ${widget.event.guests}', style: mono(size: 12, color: kMuted)),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: () => _openRecipe(r),
          icon: const Icon(Icons.menu_book_rounded, size: 16),
          label: const Text('View full recipe'),
          style: OutlinedButton.styleFrom(
              foregroundColor: kAccent,
              side: BorderSide(color: kAccent.withValues(alpha: 0.5)),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10))),
        ),
      ]),
    );
  }

  Widget _timelineCard(List<PrepDay> days) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('Prep Timeline', style: serif(size: 17, weight: FontWeight.w600)),
          const SizedBox(height: 10),
          for (final PrepDay day in days) _timelineDay(day),
        ]),
      );

  Widget _timelineDay(PrepDay day) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          SizedBox(
              width: 104,
              child: Text(day.label.toUpperCase(),
                  style: mono(size: 10.5, weight: FontWeight.w600, color: kOlive))),
          Expanded(
            child: Text(day.tasks.join(' · '),
                style: TextStyle(fontSize: 13, color: kInk, height: 1.4)),
          ),
        ]),
      );

  Widget _shoppingCard(List<RecipeIngredient> ingredients) => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('Shopping List', style: serif(size: 17, weight: FontWeight.w600)),
          const SizedBox(height: 10),
          for (int i = 0; i < ingredients.length; i++) _shoppingRow(i, ingredients[i]),
        ]),
      );

  Widget _shoppingRow(int i, RecipeIngredient ing) {
    final bool got = _checked[i];
    final bool newBuy = ing.item.toLowerCase().contains('(new buy)');
    final String label =
        ing.item.replaceAll(RegExp(r'\s*\(new buy\)', caseSensitive: false), '');
    return InkWell(
      onTap: () => _toggle(i),
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(children: <Widget>[
          Icon(got ? Icons.check_box_rounded : Icons.check_box_outline_blank_rounded,
              size: 21, color: got ? kOlive : kMuted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(label,
                style: TextStyle(
                    fontSize: 14.5,
                    color: got ? kMuted : kInk,
                    decoration:
                        got ? TextDecoration.lineThrough : TextDecoration.none)),
          ),
          const SizedBox(width: 8),
          Text(ing.amount,
              style: mono(size: 12.5, weight: FontWeight.w600, color: got ? kFaint : kOlive)),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
                color: (newBuy ? kAccent : kOlive).withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(999)),
            child: Text(newBuy ? 'Buy' : 'Have it',
                style: mono(size: 10, weight: FontWeight.w600, color: newBuy ? kAccent : kOlive)),
          ),
        ]),
      ),
    );
  }

  Widget _saveCard() => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('NAME THIS DINNER', style: labelCaps()),
          const SizedBox(height: 8),
          TextField(
            controller: _nameCtrl,
            textCapitalization: TextCapitalization.words,
            style: const TextStyle(fontSize: 15, color: kInk),
            decoration: InputDecoration(
              hintText: 'e.g. Sarah\'s Birthday',
              hintStyle: TextStyle(color: kFaint),
              filled: true,
              fillColor: kInset,
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: _save,
              icon: Icon(_saved ? Icons.check_rounded : Icons.bookmark_add_rounded,
                  size: 18),
              label: Text(_saved ? 'Saved' : 'Save to Host Hub',
                  style: serif(
                      size: 15, weight: FontWeight.w600, color: Colors.white)),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12))),
            ),
          ),
        ]),
      );
}
