import 'package:flutter/material.dart';

import 'chef.dart';
import 'chef_models.dart';
import 'cook.dart' show money, withSpinner, RecipeScreen;
import 'host_brief.dart';
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

/// Build a menu: a recipe per dish, then the prep timeline and the run
/// sheet. Returns the finished dinner and the names of any dishes the chef
/// couldn't write.
///
/// Shared by the form on this device and by a brief written in Claude, so
/// both arrive at the same dinner by the same path — the chef does the
/// cooking either way, and the only difference is how the ask reached it.
///
/// Failures are caught PER DISH. One dish hitting a rate limit used to throw
/// away every recipe that had already come back — minutes of waiting and
/// real money, gone.
Future<(HostEvent, List<String>)> buildHostMenu({
  required List<HostDish> input,
  required int guests,
  required String eventDate,
  required String name,
  required String guestNotes,
  required String dinnerNotes,
  required bool prepTimeline,
  required List<PantryItem> pantry,
  required PriceBook prices,
}) async {
  if (input.isEmpty) {
    throw ChefException('Add at least one dish first.');
  }
  final List<Recipe?> recipes = await Future.wait(input.map((HostDish d) async {
    try {
      return await Chef.generateHostDish(
        dish: d.text,
        course: d.course,
        guests: guests,
        pantry: pantry,
        prices: prices,
        guestNotes: guestNotes,
        dishNotes: d.notes,
        dinnerNotes: dinnerNotes,
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

  final List<HostDish> cookable =
      withRecipes.where((HostDish d) => d.recipe != null).toList();

  // The plan and the run sheet don't depend on each other, so they're asked
  // for together rather than one after the other.
  final List<Object> plans = await Future.wait(<Future<Object>>[
    if (prepTimeline)
      Chef.generateHostTimeline(
          dishes: cookable, guests: guests, eventDate: eventDate)
    else
      Future<List<PrepDay>>.value(const <PrepDay>[]),
    Chef.generateRunSheet(dishes: cookable, guests: guests),
  ]);

  return (
    HostEvent(
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
      name: name,
      guests: guests,
      eventDate: eventDate,
      dishes: withRecipes,
      guestNotes: guestNotes,
      prepDays: plans[0] as List<PrepDay>,
      runSheet: plans[1] as List<ServiceStep>,
    ),
    failed
  );
}

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
  final List<HostBrief> briefs; // waiting to be built, newest first
  final List<PantryItem> items;
  final PriceBook prices;
  final void Function(HostEvent event) onSave;
  final void Function(HostEvent event) onRemove;
  final void Function(HostBrief brief)? onBriefBuilt;
  final void Function(Recipe recipe, int servings)? onSaveRecipe;
  final void Function(PantryItem item, double grams)? onUse;

  const HostHubScreen({
    super.key,
    required this.events,
    this.briefs = const <HostBrief>[],
    required this.items,
    required this.prices,
    required this.onSave,
    required this.onRemove,
    this.onBriefBuilt,
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
  late List<HostBrief> _briefs = widget.briefs;

  /// A `late` field initialises once, so a rebuild carrying a different list
  /// would have gone on showing the first one — the same staleness this
  /// screen exists to avoid, one level up.
  @override
  void didUpdateWidget(HostHubScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.events, widget.events)) {
      _events = widget.events;
    }
    if (!identical(old.briefs, widget.briefs)) {
      _briefs = widget.briefs;
    }
  }

  void _openPaste(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HostPasteScreen(
        onRead: (HostBrief b) {
          setState(() => _briefs = <HostBrief>[b, ..._briefs]);
          _openBrief(context, b);
        },
      ),
    ));
  }

  void _openBrief(BuildContext context, HostBrief b) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => HostBriefScreen(
        brief: b,
        items: widget.items,
        prices: widget.prices,
        onSave: _handleSave,
        onRemove: _handleRemove,
        onBuilt: (HostBrief built) {
          widget.onBriefBuilt?.call(built);
          setState(() =>
              _briefs = _briefs.where((HostBrief x) => x.id != built.id).toList());
        },
        onSaveRecipe: widget.onSaveRecipe,
        onUse: widget.onUse,
      ),
    ));
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
          // A plan that arrived from Claude leads — it's waiting on you, and
          // nothing else on this screen is.
          if (_briefs.isNotEmpty && !cooking) ...<Widget>[
            Text('WAITING TO BE BUILT', style: labelCaps(color: kOlive)),
            const SizedBox(height: 10),
            for (final HostBrief b in _briefs) _briefCard(context, b),
            const SizedBox(height: 18),
          ],
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
          if (!cooking) ...<Widget>[
            const SizedBox(height: 10),
            Center(
              child: TextButton.icon(
                onPressed: () => _openPaste(context),
                icon: const Icon(Icons.content_paste_rounded, size: 16),
                label: const Text('Paste a plan from Claude'),
                style: TextButton.styleFrom(foregroundColor: kMuted),
              ),
            ),
          ],
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

  /// A dinner worked out in Claude, sitting in the app waiting for the chef
  /// to cook from it.
  Widget _briefCard(BuildContext context, HostBrief b) => Material(
        color: kOlive.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openBrief(context, b),
          child: Container(
            margin: const EdgeInsets.only(bottom: 10),
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: kOlive.withValues(alpha: 0.45))),
            child: Row(children: <Widget>[
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
                  Text(b.name.isEmpty ? 'A dinner from Claude' : b.name,
                      style: serif(size: 17, weight: FontWeight.w600, height: 1.2)),
                  const SizedBox(height: 5),
                  Text(
                      <String>[
                        '${b.guests} ${b.guests == 1 ? 'guest' : 'guests'}',
                        if (b.eventDate.isNotEmpty) displayDate(b.eventDate),
                        '${b.dishes.length} dish${b.dishes.length == 1 ? '' : 'es'}',
                      ].join(' · '),
                      style: mono(size: 10.5, color: kMuted)),
                  const SizedBox(height: 7),
                  Text('Tap to have the chef build it',
                      style: mono(
                          size: 10.5, weight: FontWeight.w600, color: kOlive)),
                ]),
              ),
              const Icon(Icons.chevron_right_rounded, color: kMuted),
            ]),
          ),
        ),
      );

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
  // On by default: a plan you have to remember to ask for is a plan you find
  // out you needed on the day.
  bool _prepTimeline = true;

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

  /// This form's dishes, handed to the shared builder.
  Future<(HostEvent, List<String>)> _buildMenu() => buildHostMenu(
        input: <HostDish>[
          for (int i = 0; i < _dishCtrls.length; i++)
            if (_dishCtrls[i].text.trim().isNotEmpty)
              HostDish(
                  text: _dishCtrls[i].text.trim(), course: _dishCourses[i]),
        ],
        guests: _guests,
        eventDate: _eventDate,
        name: '',
        guestNotes: _notesCtrl.text.trim(),
        dinnerNotes: '',
        prepTimeline: _prepTimeline,
        pantry: widget.items,
        prices: widget.prices,
      );

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
// PASTE A PLAN — for a Claude that can't reach the data repo.
//
// A Claude Code session on the desktop can write host_brief.json itself. The
// one on a phone or in a browser can only hand back text, so the app takes
// the text.
// ═══════════════════════════════════════════════════════════════════════

class HostPasteScreen extends StatefulWidget {
  final void Function(HostBrief brief) onRead;
  const HostPasteScreen({super.key, required this.onRead});

  @override
  State<HostPasteScreen> createState() => _HostPasteScreenState();
}

class _HostPasteScreenState extends State<HostPasteScreen> {
  final TextEditingController _ctrl = TextEditingController();
  String _error = '';

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _read() {
    final HostBrief? b = parseBrief(_ctrl.text);
    if (b == null) {
      setState(() => _error =
          'Couldn\'t read a dinner in that. It needs the JSON Claude gives '
          'you — guests, a date, and a list of dishes.');
      return;
    }
    widget.onRead(b);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(title: Text('Paste a plan', style: serif(size: 20))),
      body: ListView(
        padding: pagePadding(context, top: 4, bottom: bottomPad),
        children: <Widget>[
          Text(
              'Worked a dinner out with Claude somewhere it can\'t reach your '
              'data? Paste what it gave you here.',
              style: TextStyle(color: kMuted, fontSize: 13.5, height: 1.45)),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            minLines: 8,
            maxLines: 20,
            autofocus: true,
            style: mono(size: 12, color: kInk),
            decoration: InputDecoration(
              hintText: '{"name": "Sarah\'s Birthday", "guests": 6, …}',
              hintStyle: mono(size: 12, color: kFaint),
              filled: true,
              fillColor: kInset,
              contentPadding: const EdgeInsets.all(14),
              border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none),
            ),
          ),
          if (_error.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                  color: kWarn.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: kWarn.withValues(alpha: 0.5))),
              child: Text(_error,
                  style: TextStyle(fontSize: 13, color: kInk, height: 1.4)),
            ),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton.icon(
              onPressed: _read,
              icon: const Icon(Icons.content_paste_go_rounded, size: 18),
              label: Text('Read it',
                  style: serif(
                      size: 16, weight: FontWeight.w600, color: Colors.white)),
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
}

// ═══════════════════════════════════════════════════════════════════════
// BRIEF — a dinner worked out in conversation with Claude, waiting to be
// built. The thinking happened there, where it could be argued with; the
// cooking happens here.
// ═══════════════════════════════════════════════════════════════════════

class HostBriefScreen extends StatefulWidget {
  final HostBrief brief;
  final List<PantryItem> items;
  final PriceBook prices;
  final void Function(HostEvent event) onSave;
  final void Function(HostEvent event) onRemove;
  final void Function(HostBrief brief) onBuilt;
  final void Function(Recipe recipe, int servings)? onSaveRecipe;
  final void Function(PantryItem item, double grams)? onUse;

  const HostBriefScreen({
    super.key,
    required this.brief,
    required this.items,
    required this.prices,
    required this.onSave,
    required this.onRemove,
    required this.onBuilt,
    this.onSaveRecipe,
    this.onUse,
  });

  @override
  State<HostBriefScreen> createState() => _HostBriefScreenState();
}

class _HostBriefScreenState extends State<HostBriefScreen> {
  Future<void> _build() async {
    final HostBrief b = widget.brief;
    final (HostEvent, List<String>)? built =
        await withSpinner<(HostEvent, List<String>)>(
      context,
      'Cooking up ${b.name.isEmpty ? 'the menu' : b.name}…',
      () => buildHostMenu(
        input: b.dishes
            .map((BriefDish d) =>
                HostDish(text: d.text, course: d.course, notes: d.notes))
            .toList(),
        guests: b.guests,
        eventDate: b.eventDate,
        name: b.name,
        guestNotes: b.guestNotes,
        dinnerNotes: b.notes,
        prepTimeline: true,
        pantry: widget.items,
        prices: widget.prices,
      ),
    );
    if (built == null || !mounted) {
      return;
    }
    widget.onSave(built.$1);
    widget.onBuilt(b);
    Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
      builder: (_) => HostResultsScreen(
        event: built.$1,
        items: widget.items,
        prices: widget.prices,
        onSave: widget.onSave,
        onRemove: widget.onRemove,
        onSaveRecipe: widget.onSaveRecipe,
        onUse: widget.onUse,
      ),
    ));
    if (built.$2.isNotEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('The rest are ready. ${built.$2.join(', ')} didn\'t '
              'come back — open the dinner and build '
              '${built.$2.length == 1 ? 'it' : 'them'} again.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final HostBrief b = widget.brief;
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(
          title: Text(b.name.isEmpty ? 'From Claude' : b.name,
              style: serif(size: 20))),
      body: ListView(
        padding: pagePadding(context, top: 4, bottom: bottomPad),
        children: <Widget>[
          Text('FROM CLAUDE', style: labelCaps(color: kOlive)),
          const SizedBox(height: 8),
          Text(
              <String>[
                '${b.guests} ${b.guests == 1 ? 'guest' : 'guests'}',
                if (b.eventDate.isNotEmpty) displayDate(b.eventDate),
                '${b.dishes.length} dish${b.dishes.length == 1 ? '' : 'es'}',
              ].join(' · '),
              style: mono(size: 12, color: kMuted)),
          const SizedBox(height: 16),
          if (b.notes.isNotEmpty) ...<Widget>[
            _noteCard('ABOUT THE DINNER', b.notes, kOlive),
            const SizedBox(height: 12),
          ],
          if (b.guestNotes.isNotEmpty) ...<Widget>[
            _noteCard('GUESTS', b.guestNotes, kWarn),
            const SizedBox(height: 12),
          ],
          for (final BriefDish d in b.dishes) _dishCard(d),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _build,
              icon: const Icon(Icons.restaurant_rounded),
              label: Text('Build this menu',
                  style: serif(
                      size: 17, weight: FontWeight.w600, color: Colors.white)),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
            ),
          ),
          const SizedBox(height: 10),
          Text(
              'The chef writes the recipes, the prep timeline and the run '
              'sheet from this, using your pantry and your prices.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: kFaint, height: 1.4)),
        ],
      ),
    );
  }

  Widget _noteCard(String label, String text, Color tint) => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
            color: tint.withValues(alpha: 0.10),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: tint.withValues(alpha: 0.4))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(label, style: labelCaps(color: tint)),
          const SizedBox(height: 6),
          Text(text, style: TextStyle(fontSize: 13.5, color: kInk, height: 1.45)),
        ]),
      );

  Widget _dishCard(BriefDish d) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text(d.course.toUpperCase(), style: labelCaps(color: kOlive)),
          const SizedBox(height: 5),
          Text(d.text, style: serif(size: 18, weight: FontWeight.w600, height: 1.2)),
          if (d.notes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 7),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
              const Icon(Icons.subdirectory_arrow_right_rounded,
                  size: 14, color: kMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(d.notes,
                    style:
                        TextStyle(fontSize: 13, color: kMuted, height: 1.45)),
              ),
            ]),
          ],
        ]),
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

  /// The whole menu as one recipe, in run-sheet order.
  ///
  /// A dinner is not cooked one dish at a time, but that was all this screen
  /// offered: a recipe per dish and no way to run them together. Merging the
  /// run sheet into a single Recipe hands the cook the existing cooking mode
  /// — its shared timer rail already runs the oven, the pan and the rice at
  /// once — with every step saying which dish it belongs to and how long
  /// before serving it happens.
  Recipe _wholeMenuRecipe() {
    final HostEvent e = _event;
    final String title =
        e.name.trim().isEmpty ? 'The whole menu' : '${e.name.trim()} — the whole menu';
    return Recipe(
      title: title,
      description: 'Every dish, in the order it happens, so it all lands '
          'together.',
      ingredients: e.allIngredients,
      steps: <RecipeStep>[
        for (final ServiceStep s in e.runSheet)
          RecipeStep(
            title: <String>[
              s.whenLabel,
              if (s.dish.isNotEmpty) s.dish,
            ].join(' · '),
            content: <String>[
              if (s.title.isNotEmpty) s.title,
              s.content,
            ].join(' — '),
            timerSeconds: s.timerSeconds,
          ),
      ],
      notes: '',
      baseServings: e.guests,
    );
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
          // On the counter, the two things you actually follow lead: the run
          // sheet for the whole menu, then the day plan.
          if (e.runSheet.isNotEmpty) _runSheetCard(e),
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

  /// "Cook the whole menu" — the one thing that makes several dishes a
  /// dinner instead of a pile of recipes.
  Widget _runSheetCard(HostEvent e) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: kAccent.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kAccent.withValues(alpha: 0.45))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('DINNER DAY', style: labelCaps(color: kAccent)),
          const SizedBox(height: 6),
          Text('Cook the whole menu',
              style: serif(size: 20, weight: FontWeight.w600, height: 1.2)),
          const SizedBox(height: 4),
          Text(
              'All ${e.dishes.where((HostDish d) => d.recipe != null).length} '
              'dishes as one run, ordered so everything lands together. '
              'Starts ${e.runSheet.first.whenLabel.toLowerCase()}.',
              style: TextStyle(fontSize: 13, color: kMuted, height: 1.4)),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton.icon(
              onPressed: () => _openRecipe(_wholeMenuRecipe()),
              icon: const Icon(Icons.local_fire_department_rounded, size: 18),
              label: Text('Cook it all',
                  style: serif(
                      size: 16, weight: FontWeight.w600, color: Colors.white)),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12))),
            ),
          ),
        ]),
      );

  /// The prep plan as a schedule: a day per block, each job saying which
  /// dish it belongs to and tapping through to that recipe. This is the
  /// answer to "what can I do three days ahead" — it should never have to be
  /// read out of a method.
  Widget _timelineCard(List<PrepDay> days) => Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: kBorder)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('Prep Timeline', style: serif(size: 17, weight: FontWeight.w600)),
          const SizedBox(height: 4),
          Text('What to do when, so dinner day isn\'t all of it.',
              style: TextStyle(fontSize: 12.5, color: kMuted, height: 1.4)),
          const SizedBox(height: 14),
          for (int i = 0; i < days.length; i++)
            _timelineDay(days[i], last: i == days.length - 1),
        ]),
      );

  Widget _timelineDay(PrepDay day, {bool last = false}) {
    final String when = day.relativeTo(_event.eventDate);
    final bool isDinnerDay = when.toLowerCase().startsWith('dinner');
    final Color tint = isDinnerDay ? kAccent : kOlive;
    return Padding(
      padding: EdgeInsets.only(bottom: last ? 0 : 18),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
        // The date rail: the calendar side of the schedule.
        SizedBox(
          width: 86,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            Text(when.toUpperCase(),
                style: mono(size: 10, weight: FontWeight.w700, color: tint)),
            if (day.date.isNotEmpty) ...<Widget>[
              const SizedBox(height: 3),
              Text(displayDate(day.date),
                  style: mono(size: 10.5, color: kFaint)),
            ],
          ]),
        ),
        Container(
          width: 2,
          margin: const EdgeInsets.only(right: 14, top: 3),
          height: (day.tasks.length * 30).toDouble().clamp(24, 400),
          color: tint.withValues(alpha: 0.28),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
            for (final PrepTask t in day.tasks) _timelineTask(t),
          ]),
        ),
      ]),
    );
  }

  Widget _timelineTask(PrepTask t) {
    final Recipe? r = _recipeFor(t.dish);
    final Widget body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(t.text,
              style: TextStyle(fontSize: 13.5, color: kInk, height: 1.4)),
          if (t.dish.isNotEmpty)
            Text(t.dish,
                style: mono(size: 10, color: r == null ? kFaint : kAccent)),
        ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: r == null
          ? body
          : InkWell(
              onTap: () => _openRecipe(r),
              borderRadius: BorderRadius.circular(8),
              child: body,
            ),
    );
  }

  /// The recipe a timeline task belongs to, matched on the dish title the
  /// chef used. Null when it named something that isn't on the menu.
  Recipe? _recipeFor(String dish) {
    if (dish.trim().isEmpty) {
      return null;
    }
    final String want = dish.trim().toLowerCase();
    for (final HostDish d in _event.dishes) {
      final Recipe? r = d.recipe;
      if (r == null) {
        continue;
      }
      if (r.title.trim().toLowerCase() == want ||
          d.text.trim().toLowerCase() == want) {
        return r;
      }
    }
    return null;
  }

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
