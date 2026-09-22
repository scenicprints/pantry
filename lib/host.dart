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

/// The iPad is a cooking surface, not a second copy of the app (IOS.md).
/// Planning a dinner and running the shop stay on the phone; here Host Hub
/// shows only what you need standing at the counter — the menu, the prep
/// timeline, and the recipes.
bool _cookingSurface(BuildContext context) =>
    MediaQuery.sizeOf(context).shortestSide >= 600;

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

class HostHubScreen extends StatefulWidget {
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

  @override
  State<HostHubScreen> createState() => _HostHubScreenState();
}

/// Holds its own copy of the list. The screens it opens save and delete
/// through here as well as up to the Cook tab, because a route that captured
/// the list when it opened would still be showing the old one when you came
/// back — a dinner you just built missing from the hub that built it.
class _HostHubScreenState extends State<HostHubScreen> {
  late List<HostEvent> _events = widget.events;

  /// A `late` field initialises once, so a rebuild carrying a different list
  /// would have gone on showing the first one — the same staleness this
  /// screen exists to avoid, one level up.
  @override
  void didUpdateWidget(HostHubScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.events, widget.events)) {
      _events = widget.events;
    }
  }

  void _handleSave(HostEvent e) {
    widget.onSave(e);
    final List<HostEvent> next = List<HostEvent>.of(_events);
    final int i = next.indexWhere((HostEvent x) => x.id == e.id);
    if (i >= 0) {
      next[i] = e;
    } else {
      next.add(e);
    }
    setState(() => _events = HostHubBox(next).sorted);
  }

  void _handleRemove(HostEvent e) {
    widget.onRemove(e);
    setState(() =>
        _events = _events.where((HostEvent x) => x.id != e.id).toList());
  }

  void _openSetup(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HostSetupScreen(
        items: widget.items,
        prices: widget.prices,
        onSave: _handleSave,
        onRemove: _handleRemove,
        onSaveRecipe: widget.onSaveRecipe,
        onUse: widget.onUse,
      ),
    ));
  }

  void _openEvent(BuildContext context, HostEvent event) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HostResultsScreen(
        event: event,
        items: widget.items,
        onSave: _handleSave,
        onRemove: _handleRemove,
        onSaveRecipe: widget.onSaveRecipe,
        onUse: widget.onUse,
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final List<HostEvent> events = _events;
    final List<HostEvent> upcoming =
        events.where((HostEvent e) => e.isUpcoming(now)).toList();
    final List<HostEvent> past =
        events.where((HostEvent e) => !e.isUpcoming(now)).toList();
    final HostEvent? next = upcoming.isEmpty ? null : upcoming.first;
    final List<HostEvent> rest =
        upcoming.length > 1 ? upcoming.sublist(1) : const <HostEvent>[];
    final int guestsFed = past.fold(0, (int s, HostEvent e) => s + e.guests);
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    final bool cooking = _cookingSurface(context);

    return Scaffold(
      appBar: AppBar(title: Text('Host Hub', style: serif(size: 20))),
      body: ListView(
        padding: pagePadding(context, top: 4, bottom: bottomPad),
        children: <Widget>[
          if (next != null) ...<Widget>[
            _nextCard(context, next, now, cooking),
            const SizedBox(height: 18),
          ],
          if (events.isNotEmpty && !cooking) ...<Widget>[
            _statsRow(upcoming.length, past.length, guestsFed),
            const SizedBox(height: 18),
          ],
          if (events.isEmpty) ...<Widget>[
            _emptyState(cooking),
            const SizedBox(height: 18),
          ],
          // Planning happens on the phone; the iPad is where you cook it.
          if (!cooking)
            SizedBox(
              width: double.infinity,
              height: 56,
              child: ElevatedButton.icon(
                onPressed: () => _openSetup(context),
                icon: const Icon(Icons.add_rounded),
                label: Text(
                    next == null ? 'Plan a dinner' : 'Plan another dinner',
                    style: serif(
                        size: 17, weight: FontWeight.w600, color: Colors.white)),
                style: ElevatedButton.styleFrom(
                    backgroundColor: kAccent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14))),
              ),
            ),
          if (rest.isNotEmpty) ...<Widget>[
            const SizedBox(height: 26),
            Text('ALSO COMING UP', style: labelCaps(color: kAccent)),
            const SizedBox(height: 10),
            for (final HostEvent e in rest) _eventRow(context, e, now),
          ],
          if (past.isNotEmpty) ...<Widget>[
            const SizedBox(height: 26),
            Text('ALREADY HOSTED', style: labelCaps()),
            const SizedBox(height: 10),
            for (final HostEvent e in past) _eventRow(context, e, now),
          ],
        ],
      ),
    );
  }

  /// The hero: the dinner you're actually cooking next, with everything you'd
  /// want to know at a glance — how long you've got, what's on the menu, what
  /// it costs, and how far through the shopping you are.
  Widget _nextCard(
      BuildContext context, HostEvent e, DateTime now, bool cooking) {
    final String title = e.name.trim().isEmpty ? 'Unnamed dinner' : e.name.trim();
    final int total = e.ingredientCount;
    final int got = e.gatheredCount;
    final double progress = total == 0 ? 0 : got / total;
    final List<HostDish> built =
        e.dishes.where((HostDish d) => d.recipe != null).toList();
    final int missing = e.dishes.length - built.length;

    return GestureDetector(
      onTap: () => _openEvent(context, e),
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: kCard,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: kAccent.withValues(alpha: 0.55), width: 1.6),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Row(children: <Widget>[
            Flexible(child: _countdownPill(e, now)),
            const Spacer(),
            Text('${e.guests} ${e.guests == 1 ? 'guest' : 'guests'}',
                style: mono(size: 11, weight: FontWeight.w600, color: kMuted)),
          ]),
          const SizedBox(height: 12),
          Text(title,
              style: serif(size: 27, weight: FontWeight.w600, height: 1.1)),
          if (e.eventDate.isNotEmpty) ...<Widget>[
            const SizedBox(height: 4),
            Text(displayDate(e.eventDate),
                style: mono(size: 12, color: kMuted)),
          ],
          if (built.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            for (final HostDish d in built) _menuLine(d),
          ],
          if (missing > 0) ...<Widget>[
            const SizedBox(height: 10),
            Row(children: <Widget>[
              const Icon(Icons.error_outline_rounded, size: 14, color: kWarn),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                    '$missing dish${missing == 1 ? '' : 'es'} still to build',
                    style:
                        mono(size: 11, weight: FontWeight.w600, color: kWarn)),
              ),
            ]),
          ],
          // The shopping run is a phone job — on the counter it's noise.
          if (total > 0 && !cooking) ...<Widget>[
            const SizedBox(height: 18),
            Row(children: <Widget>[
              Text('SHOPPING', style: labelCaps()),
              const Spacer(),
              Text('$got / $total',
                  style: mono(
                      size: 12,
                      weight: FontWeight.w600,
                      color: got == total ? kOlive : kMuted)),
            ]),
            const SizedBox(height: 7),
            ClipRRect(
              borderRadius: BorderRadius.circular(999),
              child: LinearProgressIndicator(
                value: progress,
                minHeight: 7,
                backgroundColor: kInset,
                valueColor: AlwaysStoppedAnimation<Color>(
                    got == total ? kOlive : kAccent),
              ),
            ),
          ],
          if (e.estCostTotal > 0 && !cooking) ...<Widget>[
            const SizedBox(height: 14),
            Row(children: <Widget>[
              Text('≈ ${money(e.estCostTotal)}',
                  style: serif(size: 18, weight: FontWeight.w600, color: kAccent)),
              const SizedBox(width: 8),
              Flexible(
                child: Text('for the table',
                    overflow: TextOverflow.ellipsis,
                    style: mono(size: 11, color: kMuted)),
              ),
              const Spacer(),
              const Icon(Icons.chevron_right_rounded, color: kMuted),
            ]),
          ],
          if (cooking) ...<Widget>[
            const SizedBox(height: 16),
            Row(children: <Widget>[
              const Icon(Icons.local_fire_department_rounded,
                  size: 16, color: kAccent),
              const SizedBox(width: 6),
              Flexible(
                child: Text('Open to prep and cook',
                    overflow: TextOverflow.ellipsis,
                    style:
                        mono(size: 11, weight: FontWeight.w600, color: kAccent)),
              ),
              const Spacer(),
              const Icon(Icons.chevron_right_rounded, color: kMuted),
            ]),
          ],
        ]),
      ),
    );
  }

  /// "TONIGHT" / "TOMORROW" / "IN 5 DAYS" — the thing that makes the hub feel
  /// live rather than a list of records.
  Widget _countdownPill(HostEvent e, DateTime now) {
    final DateTime? d = DateTime.tryParse(e.eventDate);
    late final String label;
    late final Color color;
    if (d == null) {
      label = 'NO DATE YET';
      color = kMuted;
    } else {
      final DateTime today = DateTime(now.year, now.month, now.day);
      final int days = DateTime(d.year, d.month, d.day).difference(today).inDays;
      if (days <= 0) {
        label = 'TONIGHT';
        color = kAccent;
      } else if (days == 1) {
        label = 'TOMORROW';
        color = kAccent;
      } else if (days <= 7) {
        label = 'IN $days DAYS';
        color = kOlive;
      } else {
        label = 'IN $days DAYS';
        color = kMuted;
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(999)),
      child: Text(label,
          style: mono(size: 10.5, weight: FontWeight.w700, color: color, spacing: 1.0)),
    );
  }

  /// One line of the menu: the course, then the dish as the chef titled it.
  Widget _menuLine(HostDish d) => Padding(
        padding: const EdgeInsets.only(bottom: 7),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          SizedBox(
              width: 64,
              child: Text(d.course.toUpperCase(),
                  style: mono(size: 9.5, weight: FontWeight.w600, color: kOlive))),
          Expanded(
            child: Text(d.recipe?.title ?? d.text,
                style: serif(
                    size: 14.5, weight: FontWeight.w500, height: 1.25)),
          ),
        ]),
      );

  Widget _statsRow(int upcoming, int hosted, int guestsFed) => Row(children: <Widget>[
        _stat('$upcoming', upcoming == 1 ? 'coming up' : 'coming up'),
        const SizedBox(width: 10),
        _stat('$hosted', 'hosted'),
        const SizedBox(width: 10),
        _stat('$guestsFed', 'guests fed'),
      ]);

  Widget _stat(String value, String label) => Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 13),
          decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kBorder)),
          child: Column(children: <Widget>[
            Text(value, style: serif(size: 22, weight: FontWeight.w600)),
            const SizedBox(height: 2),
            Text(label, style: mono(size: 9.5, color: kMuted, spacing: 0.4)),
          ]),
        ),
      );

  Widget _emptyState(bool cooking) => Container(
        padding: const EdgeInsets.all(22),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('WHEN COMPANY\'S COMING', style: labelCaps(color: kAccent)),
          const SizedBox(height: 10),
          Text(
              cooking
                  ? 'No dinner planned yet'
                  : 'Nothing on the table yet',
              style: serif(size: 24, weight: FontWeight.w600, height: 1.15)),
          const SizedBox(height: 14),
          if (cooking)
            _emptyLine(Icons.phone_iphone_rounded,
                'Plan one on your phone and it turns up here — the menu, the '
                'prep timeline and every recipe, ready to cook.')
          else ...<Widget>[
            _emptyLine(Icons.groups_rounded, 'Name the dishes you want to make — '
                'the chef writes them properly, scaled to your guest count.'),
            _emptyLine(Icons.receipt_long_rounded, 'One shopping list across the '
                'whole menu, priced, checked against your pantry.'),
            _emptyLine(Icons.tablet_mac_rounded, 'The menu, the prep timeline '
                'and the recipes are on the iPad when you cook.'),
          ],
        ]),
      );

  Widget _emptyLine(IconData icon, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Icon(icon, size: 16, color: kOlive),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: TextStyle(fontSize: 13, color: kMuted, height: 1.45)),
          ),
        ]),
      );

  /// A compact row for everything that isn't the next dinner.
  Widget _eventRow(BuildContext context, HostEvent e, DateTime now) {
    final String title = e.name.trim().isEmpty ? 'Unnamed dinner' : e.name.trim();
    final String dateLabel = e.eventDate.isEmpty ? 'No date' : displayDate(e.eventDate);
    final bool built = e.isBuilt;
    final int total = e.ingredientCount;
    final int got = e.gatheredCount;
    return Material(
      color: kCard,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openEvent(context, e),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: kBorder)),
          child: Row(children: <Widget>[
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                Text(title, style: serif(size: 16, weight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(
                    <String>[
                      dateLabel,
                      '${e.guests} ${e.guests == 1 ? 'guest' : 'guests'}',
                      '${e.dishes.length} dish${e.dishes.length == 1 ? '' : 'es'}',
                      if (!built) 'unfinished',
                      if (built && total > 0 && got == total) 'shopped',
                    ].join(' · '),
                    style: mono(size: 10.5, color: built ? kMuted : kWarn)),
              ]),
            ),
            const Icon(Icons.chevron_right_rounded, color: kMuted),
          ]),
        ),
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

  /// The built menu, plus the names of any dishes the chef couldn't write.
  ///
  /// Each dish is asked for separately and a failure is CAUGHT PER DISH. One
  /// dish hitting a rate limit used to throw away every recipe that had
  /// already come back — minutes of waiting and real money, gone, for a
  /// snackbar. Now what worked is kept, the dish that didn't comes back
  /// without a recipe (the hub shows that dinner as unfinished), and the cook
  /// is told which one to retry.
  Future<(HostEvent, List<String>)> _buildMenu() async {
    final List<HostDish> input = <HostDish>[
      for (int i = 0; i < _dishCtrls.length; i++)
        if (_dishCtrls[i].text.trim().isNotEmpty)
          HostDish(text: _dishCtrls[i].text.trim(), course: _dishCourses[i]),
    ];
    if (input.isEmpty) {
      throw ChefException('Add at least one dish first.');
    }
    final String guestNotes = _notesCtrl.text.trim();
    final List<Recipe?> recipes =
        await Future.wait(input.map((HostDish d) async {
      try {
        return await Chef.generateHostDish(
          dish: d.text,
          course: d.course,
          guests: _guests,
          pantry: widget.items,
          prices: widget.prices,
          guestNotes: guestNotes,
        );
      } on ChefException {
        return null;
      }
    }));

    final List<HostDish> withRecipes = <HostDish>[];
    final List<String> failed = <String>[];
    for (int i = 0; i < input.length; i++) {
      final Recipe? r = recipes[i];
      withRecipes.add(r == null ? input[i] : input[i].copyWith(recipe: r));
      if (r == null) {
        failed.add(input[i].text);
      }
    }
    if (failed.length == input.length) {
      throw ChefException(input.length == 1
          ? 'The chef couldn\'t write that one — try again.'
          : 'The chef couldn\'t write any of those — try again.');
    }

    List<PrepDay> prepDays = const <PrepDay>[];
    if (_prepTimeline) {
      // Only the dishes that actually have a recipe can be planned around.
      prepDays = await Chef.generateHostTimeline(
          dishes: withRecipes
              .where((HostDish d) => d.recipe != null)
              .toList(),
          guests: _guests,
          eventDate: _eventDate);
    }
    return (
      HostEvent(
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
        name: '',
        guests: _guests,
        eventDate: _eventDate,
        dishes: withRecipes,
        guestNotes: guestNotes,
        prepDays: prepDays,
      ),
      failed
    );
  }

  Future<void> _build() async {
    if (_prepTimeline && _eventDate.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content:
              Text('Pick a dinner date first, or turn off the prep timeline.')));
      return;
    }
    final (HostEvent, List<String>)? built =
        await withSpinner<(HostEvent, List<String>)>(
            context, 'Building your menu…', _buildMenu);
    if (built == null || !mounted) {
      return;
    }
    final HostEvent event = built.$1;
    final List<String> failed = built.$2;
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
    if (failed.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'The rest are ready. ${failed.join(', ')} didn\'t come back — '
              'open the dinner and build ${failed.length == 1 ? 'it' : 'them'} again.')));
    }
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
  final PriceBook prices;
  final void Function(HostEvent event) onSave;
  final void Function(HostEvent event) onRemove;
  final void Function(Recipe recipe, int servings)? onSaveRecipe;
  final void Function(PantryItem item, double grams)? onUse;

  const HostResultsScreen({
    super.key,
    required this.event,
    required this.items,
    this.prices = const PriceBook(),
    required this.onSave,
    required this.onRemove,
    this.onSaveRecipe,
    this.onUse,
  });

  @override
  State<HostResultsScreen> createState() => _HostResultsScreenState();
}

class _HostResultsScreenState extends State<HostResultsScreen> {
  /// Held locally because a dish can be built here (one that failed first
  /// time round), which changes the menu under the screen.
  late HostEvent _event = widget.event;

  late final TextEditingController _nameCtrl =
      TextEditingController(text: widget.event.name);
  bool _saved = false;

  @override
  void dispose() {
    _nameCtrl.dispose();
    super.dispose();
  }

  Set<String> get _checked => _event.checked.toSet();

  /// Ticks persist and travel — the list you tick in the shop is the one
  /// waiting on the iPad at home, same as "On the menu".
  void _toggle(String key) {
    final Set<String> next = _checked;
    if (!next.remove(key)) {
      next.add(key);
    }
    final HostEvent updated = _event.copyWith(checked: next.toList()..sort());
    setState(() => _event = updated);
    widget.onSave(updated);
  }

  void _save() {
    final HostEvent named = _event.copyWith(name: _nameCtrl.text.trim());
    widget.onSave(named);
    setState(() {
      _event = named;
      _saved = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(named.name.isEmpty
            ? 'Saved to Host Hub.'
            : '“${named.name}” saved to Host Hub.')));
  }

  /// Build a dish the chef didn't manage first time. Keeps the rest of the
  /// menu exactly as it is.
  Future<void> _buildDish(int index) async {
    final HostDish dish = _event.dishes[index];
    final Recipe? r = await withSpinner<Recipe>(
      context,
      'Writing ${dish.text}…',
      () => Chef.generateHostDish(
        dish: dish.text,
        course: dish.course,
        guests: _event.guests,
        pantry: widget.items,
        prices: widget.prices,
        guestNotes: _event.guestNotes,
      ),
    );
    if (r == null || !mounted) {
      return;
    }
    final List<HostDish> dishes = List<HostDish>.of(_event.dishes);
    dishes[index] = dish.copyWith(recipe: r);
    final HostEvent updated = _event.copyWith(dishes: dishes);
    setState(() => _event = updated);
    widget.onSave(updated);
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
      widget.onRemove(_event);
      Navigator.pop(context);
    }
  }

  void _openRecipe(Recipe r) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => RecipeScreen(
        recipe: r,
        initialServings: _event.guests,
        pantry: widget.items,
        onUse: widget.onUse,
        onSave: widget.onSaveRecipe,
        onCooked: (String _) {},
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final HostEvent e = _event;
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    final double total = e.estCostTotal;
    final double grocery = e.estGroceryCost;
    final List<RecipeIngredient> ingredients = e.allIngredients;
    // On the iPad this is a cooking surface: the menu, the timeline and the
    // recipes. Shopping, naming and deleting are the phone's job.
    final bool cooking = _cookingSurface(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(e.name.trim().isEmpty ? 'Your Menu' : e.name.trim(),
            style: serif(size: 20)),
        actions: <Widget>[
          if (!cooking)
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
          if (total > 0 && !cooking) ...<Widget>[
            _costCard(total, grocery),
            const SizedBox(height: 14),
          ],
          // The timeline leads on the counter: it's what you're following.
          if (cooking && e.prepDays.isNotEmpty) _timelineCard(e.prepDays),
          for (int i = 0; i < e.dishes.length; i++)
            e.dishes[i].recipe == null
                ? _unbuiltDishCard(i, e.dishes[i], cooking)
                : _dishCard(e.dishes[i]),
          if (!cooking && e.prepDays.isNotEmpty) ...<Widget>[
            _timelineCard(e.prepDays),
            const SizedBox(height: 14),
          ],
          if (ingredients.isNotEmpty && !cooking) ...<Widget>[
            _shoppingCard(),
            const SizedBox(height: 14),
          ],
          if (!cooking) _saveCard(),
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

  /// A dish the chef didn't manage — kept on the menu with a way to try it
  /// again, rather than silently dropped.
  Widget _unbuiltDishCard(int index, HostDish d, bool cooking) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kWarn.withValues(alpha: 0.6))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(d.course.toUpperCase(), style: labelCaps(color: kWarn)),
          const SizedBox(height: 6),
          Text(d.text, style: serif(size: 20, weight: FontWeight.w600, height: 1.2)),
          const SizedBox(height: 6),
          Text(
              cooking
                  ? 'No recipe for this one yet — build it on your phone.'
                  : 'No recipe yet — the chef didn\'t get to this one.',
              style: TextStyle(fontSize: 13, color: kMuted, height: 1.4)),
          if (!cooking) ...<Widget>[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () => _buildDish(index),
              icon: const Icon(Icons.refresh_rounded, size: 16),
              label: const Text('Build this dish'),
              style: OutlinedButton.styleFrom(
                  foregroundColor: kWarn,
                  side: BorderSide(color: kWarn.withValues(alpha: 0.6)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10))),
            ),
          ],
        ]),
      );

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

  Widget _shoppingCard() => Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('Shopping List', style: serif(size: 17, weight: FontWeight.w600)),
          const SizedBox(height: 10),
          for (int d = 0; d < _event.dishes.length; d++)
            if (_event.dishes[d].recipe != null)
              for (int i = 0; i < _event.dishes[d].recipe!.ingredients.length; i++)
                _shoppingRow('$d:$i', _event.dishes[d].recipe!.ingredients[i]),
        ]),
      );

  Widget _shoppingRow(String key, RecipeIngredient ing) {
    final bool got = _checked.contains(key);
    final bool newBuy = ing.item.toLowerCase().contains('(new buy)');
    final String label =
        ing.item.replaceAll(RegExp(r'\s*\(new buy\)', caseSensitive: false), '');
    return InkWell(
      onTap: () => _toggle(key),
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
