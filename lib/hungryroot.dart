import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chef.dart';
import 'chef_models.dart';
import 'cook.dart' show CookingModeScreen, StepTimer, withSpinner;
import 'theme.dart';

// ═══════════════════════════════════════════════════════════════════════
// COOK FOR HUNGRYROOT — the food is already here.
//
// The box has landed, the portions are decided, and the card in it was
// written for a kitchen with one skillet and nothing else. So it runs the
// burgers, then the zucchini, then the buns through that one pan and calls
// the whole thing eight minutes. This kitchen has an air fryer, a Tovala, a
// grill and a stove. The method is the only thing left to get right, and
// that is the entire screen.
//
// What this deliberately does NOT have: a pantry, a shopping list, a cost
// estimate, a servings stepper, a save button, a sync file. He paid for the
// meal and he is cooking it tonight. Paste, cook, done.
// ═══════════════════════════════════════════════════════════════════════

/// The paste box. One field, one button.
class HungryRootScreen extends StatefulWidget {
  const HungryRootScreen({super.key});

  @override
  State<HungryRootScreen> createState() => _HungryRootScreenState();
}

class _HungryRootScreenState extends State<HungryRootScreen> {
  final TextEditingController _c = TextEditingController();

  /// Enough text to be a recipe card rather than a stray tap. The shortest
  /// real card is still a title and a couple of steps.
  bool get _ready => _c.text.trim().length >= 20;

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Future<void> _pasteFromClipboard() async {
    final ClipboardData? d = await Clipboard.getData(Clipboard.kTextPlain);
    final String text = d?.text?.trim() ?? '';
    if (text.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Nothing on the clipboard.')));
      }
      return;
    }
    setState(() {
      _c.text = text;
      _c.selection = TextSelection.collapsed(offset: text.length);
    });
  }

  Future<void> _plan() async {
    final String instructions = _c.text.trim();
    FocusScope.of(context).unfocus();
    final CookPlan? plan = await withSpinner<CookPlan>(
      context,
      'Working out the best way…',
      () => Chef.planHungryRoot(instructions: instructions),
    );
    if (plan == null || !mounted) {
      return;
    }
    if (plan.steps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('That did not come back as a method. Try again, or '
              'check the card pasted in full.')));
      return;
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => CookPlanScreen(plan: plan),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(
          title: Text('Cook for HungryRoot', style: serif(size: 20))),
      body: ListView(
        padding: pagePadding(context, top: 8, bottom: bottomPad),
        children: <Widget>[
          Text('Paste the card',
              style: serif(size: 30, weight: FontWeight.w600, height: 1.1)),
          const SizedBox(height: 8),
          Text('The instructions that came with the meal, however they are '
              'written. Nothing about your pantry comes into this: the food '
              'is already here, so the only question is how to cook it in '
              'your kitchen.',
              style: TextStyle(color: kMuted, fontSize: 14, height: 1.5)),
          const SizedBox(height: 20),
          TextField(
            controller: _c,
            minLines: 8,
            maxLines: 20,
            textCapitalization: TextCapitalization.sentences,
            keyboardType: TextInputType.multiline,
            onChanged: (_) => setState(() {}),
            style: TextStyle(color: kInk, fontSize: 15, height: 1.5),
            decoration: InputDecoration(
              hintText: 'Cook time: 8 minutes\n\n'
                  'Heat lightly oiled skillet over high; cook burgers…',
              hintStyle: TextStyle(color: kFaint, height: 1.5),
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
          ),
          const SizedBox(height: 10),
          Row(children: <Widget>[
            TextButton.icon(
              onPressed: _pasteFromClipboard,
              icon: const Icon(Icons.content_paste_rounded, size: 16),
              label: const Text('Paste',
                  style:
                      TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              style: TextButton.styleFrom(foregroundColor: kOlive),
            ),
            const Spacer(),
            if (_c.text.trim().isNotEmpty)
              TextButton.icon(
                onPressed: () => setState(_c.clear),
                icon: const Icon(Icons.close_rounded, size: 16),
                label: const Text('Clear',
                    style:
                        TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                style: TextButton.styleFrom(foregroundColor: kMuted),
              ),
          ]),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton.icon(
              onPressed: _ready ? _plan : null,
              icon: const Icon(Icons.local_fire_department_rounded),
              label: Text('How should I cook this?',
                  style: serif(
                      size: 17,
                      weight: FontWeight.w600,
                      color: Colors.white)),
              style: ElevatedButton.styleFrom(
                  backgroundColor: kAccent,
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: kBorder,
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14))),
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
// THE PLAN — verdict first, then who is cooking what, then the method.
//
// The verdict leads because it is the answer. Everything under it is the
// working. The time row sits next to it because the number printed on the
// card is the number he already has in his head, and a plan that quietly
// takes twice as long without saying so is a worse plan.
// ═══════════════════════════════════════════════════════════════════════

class CookPlanScreen extends StatelessWidget {
  final CookPlan plan;
  const CookPlanScreen({super.key, required this.plan});

  @override
  Widget build(BuildContext context) {
    final double bottomPad = 32 + MediaQuery.of(context).viewPadding.bottom;
    return Scaffold(
      appBar: AppBar(),
      body: ListView(
        padding: pagePadding(context, bottom: bottomPad),
        children: <Widget>[
          Text(plan.title,
              style: serif(size: 30, weight: FontWeight.w600, height: 1.1)),
          if (plan.verdict.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            _verdictCard(),
          ],
          if (plan.totalMinutes > 0) ...<Widget>[
            const SizedBox(height: 12),
            _timeCard(),
          ],
          if (plan.stations.isNotEmpty) ...<Widget>[
            const SizedBox(height: 20),
            _heading('ALL AT ONCE'),
            const SizedBox(height: 10),
            for (final CookStation s in plan.stations) _stationRow(s),
          ],
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  // factor 1 and no pantry: the box set the portions and
                  // there is nothing here to weigh off a shelf.
                  builder: (_) => CookingModeScreen(
                      recipe: plan.recipe, factor: 1, servings: 0),
                ),
              ),
              icon: const Icon(Icons.local_fire_department_rounded),
              label: Text('Cooking mode',
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
          if (plan.ingredients.isNotEmpty) ...<Widget>[
            const SizedBox(height: 26),
            _heading('WHAT CAME IN THE BOX'),
            const SizedBox(height: 10),
            for (final RecipeIngredient i in plan.ingredients)
              _ingredientRow(i),
          ],
          const SizedBox(height: 26),
          _heading('METHOD'),
          const SizedBox(height: 12),
          for (int i = 0; i < plan.steps.length; i++)
            _stepRow(i + 1, plan.steps[i], i),
          if (plan.notes.isNotEmpty) ...<Widget>[
            const SizedBox(height: 20),
            _heading('NOTES'),
            const SizedBox(height: 10),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                  color: kCard,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: kBorder)),
              child: Text(plan.notes,
                  style: TextStyle(fontSize: 14, color: kInk, height: 1.6)),
            ),
          ],
        ],
      ),
    );
  }

  Widget _verdictCard() => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
            color: kCard,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: kAccent.withValues(alpha: 0.45))),
        child: Text(plan.verdict,
            style: serif(
                size: 16,
                weight: FontWeight.w500,
                color: kInk,
                height: 1.5)),
      );

  /// Total against the card's claim. When the card never said a number this
  /// is just the total, with nothing to compare it to.
  Widget _timeCard() {
    final int? diff = plan.minutesVsCard;
    final bool faster = diff != null && diff > 0;
    final bool slower = diff != null && diff < 0;
    final Color c = slower ? kWarn : kOlive;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
          color: kInset, borderRadius: BorderRadius.circular(14)),
      child: Row(children: <Widget>[
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: <Widget>[
          Text('START TO PLATE', style: labelCaps(color: kAccent)),
          const SizedBox(height: 4),
          Text('${plan.totalMinutes} min',
              style: serif(size: 24, weight: FontWeight.w600)),
        ]),
        const SizedBox(width: 12),
        // Expanded rather than a Spacer and an intrinsic Column: two
        // intrinsically-sized Columns in a Row overflow the moment the text
        // is a little wider than it was guessed to be.
        if (plan.cardMinutes > 0)
          Expanded(
            child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: <Widget>[
                  Text('the card said ${plan.cardMinutes} min',
                      textAlign: TextAlign.end,
                      style: mono(size: 11, color: kMuted)),
                  if (faster || slower) ...<Widget>[
                    const SizedBox(height: 4),
                    Text(
                        faster
                            ? '${diff!} min faster'
                            : '${-diff!} min longer, worth it',
                        textAlign: TextAlign.end,
                        style:
                            mono(size: 12, weight: FontWeight.w600, color: c)),
                  ],
                ]),
          ),
      ]),
    );
  }

  Widget _stationRow(CookStation s) => Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
              color: kCard,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: kBorder)),
          child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 112,
                  child: Text(s.appliance,
                      style: serif(
                          size: 14, weight: FontWeight.w700, height: 1.3)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(s.job,
                      style: mono(size: 12, color: kOlive)),
                ),
              ]),
        ),
      );

  Widget _heading(String s) => Row(children: <Widget>[
        Text(s, style: labelCaps(color: kAccent)),
        const SizedBox(width: 10),
        const Expanded(child: Divider(color: kBorder, height: 1)),
      ]);

  Widget _ingredientRow(RecipeIngredient ing) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                  child: Text(ing.item,
                      style: const TextStyle(fontSize: 15, color: kInk))),
              const SizedBox(width: 12),
              Text(ing.amount,
                  style:
                      mono(size: 14, weight: FontWeight.w600, color: kOlive)),
            ]),
      );

  Widget _stepRow(int n, RecipeStep step, int index) => Padding(
        padding: const EdgeInsets.only(bottom: 18),
        child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: 34,
                child: Text('$n',
                    style: serif(
                        size: 26, weight: FontWeight.w600, color: kAccent)),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      if (step.title.isNotEmpty)
                        Text(step.title,
                            style: const TextStyle(
                                fontSize: 15.5,
                                fontWeight: FontWeight.w700,
                                color: kInk)),
                      if (step.content.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 3),
                        Text(step.content,
                            style: TextStyle(
                                fontSize: 14.5, color: kInk, height: 1.5)),
                      ],
                      if (step.hasTimer) ...<Widget>[
                        const SizedBox(height: 10),
                        StepTimer(
                          timerKey: '${plan.title}#$index',
                          label: step.title.isEmpty ? 'Step $n' : step.title,
                          seconds: step.timerSeconds,
                        ),
                      ],
                    ]),
              ),
            ]),
      );
}
