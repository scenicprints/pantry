# Pantry — Roadmap / Backlog

## Host Hub — removed

Gone, not deprecated. It was built, it was used a little, and it was a bust:
planning a dinner party is not a thing that happens often enough to earn a
whole screen, a sync file and its own chef. Deleted outright rather than left
dark, because a dead door on the Cook tab is worse than no door.

Removed: `lib/host.dart`, `lib/host_hub.dart`, `lib/host_brief.dart`, their
three test files, the `generateHostDish` / `generateHostTimeline` /
`generateRunSheet` calls and both host system prompts in `lib/chef.dart`, the
`loadHostHub` / `saveHostHub` pair in `lib/storage.dart`, and the Cook tab's
HOSTING section and Host Hub button.

`host_hub.json` and `host_briefs.json` are left sitting in pantry-data and in
the app's files dir. Nothing reads them now; they are harmless and can be
deleted by hand whenever.

Its slot on the Cook tab is taken by **Cook for HungryRoot** below.

## Cook for HungryRoot — landed, unreleased

A third button on the Cook tab, where Host Hub used to be. Paste the card
that came in the delivery, get the best way to cook exactly that food in
this kitchen. One screen in, one screen out.

The card is the reason this exists. HungryRoot writes for a kitchen with one
skillet, so it runs the burgers, then the zucchini, then the buns through the
same pan and calls the whole thing eight minutes, which is not possible. He
owns an air fryer, a Tovala, a grill and a stove. The feature is reassigning
those jobs to the appliances that are here, running them at once, and being
honest about the clock.

### The shape of it, decided and not open

- **Paste only.** No photo, no vision call. He copies the text.
- **Method and fat.** It picks the appliance, the order, the temperature, the
  timing and the technique, and it says how much cooking fat and which one.
  It does NOT drop, add, swap or reduce a component, and it does not touch a
  seasoning the card names. The food is bought; it is not being edited.
- **One-shot.** Nothing saved, no history, no recipe box entry, no sync file.
  Paste, cook, gone.
- **No pantry, no cost, no servings scaler.** The box decided the portions,
  so `CookPlan.recipe` is baseServings 1 and the factor is always 1.

### Where it lives

- `lib/hungryroot.dart` — `HungryRootScreen` (the paste box) and
  `CookPlanScreen` (verdict, time row, stations, method). Cooking mode, the
  step timers, the two-pane counter view and the screen wakelock are all
  reused from `cook.dart` as-is.
- `lib/chef_models.dart` — `CookPlan` and `CookStation`. `CookPlan` is not
  a `Recipe` because a Recipe carries a cost, a shopping list and a scaler,
  none of which mean anything here. It exposes `.recipe` so the counter
  screens, which all speak Recipe, work unchanged.
- `lib/chef.dart` — `Chef.planHungryRoot` plus `_hungryRootSystemPrompt`.
  A separate system prompt, for the same reason Host Hub had one: the cached
  prompt is written for a chef inventing a meal out of a pantry under liver
  rules that outrank it, and here there is no pantry and the meal is not up
  for a verdict. The health rules survive as TECHNIQUE only.
- `lib/measures.dart` — `gramsOnly`, applied inside `planHungryRoot`. The
  prompt asks for grams and the model still returns "1 tsp oil", so the
  conversion is enforced in code like every other amount in this app. A
  piece keeps its count and gains the weight ("1 medium (196 g)"); salt,
  pepper and dried seasonings keep their spoons.

### One change outside the feature

`CookingModeScreen` only shows its **Weights** action when it has a
`CookSession`. It used to show it always and answer a tap with advice about a
measuring screen that this cook never had. Every existing caller passes a
non-null session, so nothing else moves.

### Not verified by a compiler

There is no Flutter SDK on the Windows machine, so `flutter analyze` and
`flutter test` have not run against any of this. Delimiter balance and every
app symbol were checked by script; `test/hungryroot_test.dart` covers the
parse, the time comparison in both directions, the grams conversion and both
screens building. CI is the first real gate.

## Chef health direction — weight loss + fatty liver (landed, unreleased)

The chef now cooks for a fatty liver as well as for weight loss. This is the
standing contract, not a one-off tweak:

- `lib/chef.dart` — a FATTY LIVER RULES block in the cached system prompt
  (Mediterranean pattern; caps on added sugar and saturated fat; a fiber floor;
  olive oil as the fat; whole grains over refined; no alcohol, no cured or
  processed meat, no deep-frying; moderate sodium). Both call prompts restate
  the numbers, and the recipe notes now report sat fat / added sugar / fiber.
- `lib/liver.dart` — the app-side half, same shape as `avoid.dart`. It measures
  the numbers the chef reports and re-asks once with the specific miss named.
  Deliberately softer than the avoid list: it never refuses a set outright,
  because these are the model's own estimates.
- Limits, all per serving: sat fat <= 7 g, added sugar <= 6 g, fiber >= 8 g,
  with 1.5 g of slack before a re-ask is spent.
- The option card shows the three numbers, amber when one is over its limit.

Open decision: the calorie window is still the old `~200-500 cal/serving`. A
liver-friendly dinner with olive oil, whole grains and legumes lands closer to
400-550, so the floor may want raising. Left alone until he says.

## Batch v0.2 (in progress — branch `feature/batch-v0.2`)

Coordinated batch across **pantry** and **bodycomp** repos. Nothing ships until
reviewed; both apps release together.

### Pantry app (this repo)
- [ ] **Nav-bar overlap fix** — content + Add button must clear the bottom
      NavigationBar and the phone's gesture area. (Move FAB to the outer
      Scaffold so it's positioned above the nav bar; add inset-aware padding.)
- [ ] **± adjuster** — replace the single "Subtract" with **Use (−)** and
      **Add (+)** on each item. "Add" is for "bought more, don't re-scan"; it
      raises both remaining and total so the fill bar stays correct. Price is
      left as the last purchase cost (no cost-blending yet).
- [ ] **Count units** — items can be tracked as a **pure count** (e.g. eggs)
      instead of grams. Unit is `g` or `count`.
      - Weight item JSON (unchanged): `total_weight_g`, `remaining_weight_g`,
        `price_per_gram`, `macros_per_100g`.
      - Count item JSON: `unit:"count"`, `total_count`, `remaining_count`,
        `price_per_unit`, optional `macros_per_unit`.
      - Backward compatible: items with no `unit` are treated as `g`.

### BodyComp integration (bodycomp repo, separate branch)
- [ ] **"Subtract from Pantry" button** on the Cook screen — manual trigger.
- [ ] **Always-confirm review screen** before writing:
      - Weight pantry item ← subtract the ingredient's raw grams directly.
      - Count pantry item (eggs) ← show a count field (default 1) the user
        sets; the ingredient's grams are ignored for that line.
      - Matching: **barcode first**, then normalized name; unmatched items are
        shown to map or skip.
- [ ] **Two-repo write token** — BodyComp needs contents:write on
      `pantry-data` as well as `bodycomp-data` (one fine-grained PAT scoped to
      both, injected as a build secret).

### Chef contract note
Once count items exist, `pantry.json` can contain items measured in count
rather than grams. The `pantry-data` README documents the exact schema; the
chef must be told to treat `unit:"count"` items as whole units.

### Explicitly out of scope (for now)
- Two-way sync (Pantry stays the source of truth; BodyComp only subtracts).
- Auto-subtracting leftovers (would double-count; only the raw cook subtracts).
- Cost-blending across restocks.
