# Pantry — Roadmap / Backlog

## HungryRoot mode (released in v0.27.0)

He has been eating HungryRoot, so the food in the delivery is now a thing the
app knows about and can cook from. Three parts, and they only make sense
together.

**An item can say it came in the box.** A `From HungryRoot` switch on the
add/edit screen, a `hungryroot` flag on `PantryItem` (and on `QuickAddItem`,
so a re-add keeps its source), and a HUNGRYROOT badge in the pantry list. It
is pure provenance: nothing about weighing, costing or expiry changes, and
the flag is absent rather than false on everything else.

**A switch on the Cook tab.** It sits between the stats row and COOKING FOR,
because it changes what "Cook something" means and he should see which way
it is set before he presses it. It is dead with nothing tagged and says so
instead of pretending. It rides in `chef.json` with the model and the avoid
list, so phone and iPad agree, and it is re-read on resume.

**It cooks from their cookbook, not from memory.** HungryRoot publishes the
whole catalogue at `api.hungryroot.com/api/v3/pairings/` with no key and no
login: real title, servings, cook time, the method as written, the nutrition
panel. That endpoint is the only reason "replicate one of their meals" is a
feature instead of the chef guessing at a brand it half remembers.

### How the catalogue is read

- **v3, not v2.** The same recipes are served twice. v2 carries the component
  list with brands and gram amounts but costs 53 KB PER RECIPE; v3 is about
  1.5 KB with the method text intact, and the method names the components
  anyway. Nothing calls v2 today.
- **There is no ingredient filter.** `tag` and `limit` work; `search`,
  `product`, `ingredient`, `ordering` and `dish_type` are all accepted and
  all ignored. So the matching is ours: three pages of a hundred featured
  pairings, cached seven days in `hungryroot_catalog.json`, scored locally
  against his tagged stock. A word in the TITLE counts double, and using two
  of his things beats naming one of them three times.
- **Failing is quiet.** Every path returns an empty list rather than
  throwing. A dead network means the mode cooks his delivery food without
  reproducing anything, which is still most of what the switch is for. A
  refresh that fails keeps last week's cache.
- **Near-duplicates are dropped before the chef sees them**, and the prompt
  tells it that if a recipe would repeat one it has already taken, it must
  invent its own dinner from the same food and leave `hungryroot` empty. His
  call: three off the catalogue, but never the same dinner twice.

### Measured against the live catalogue, not guessed

Nothing compiles on the Windows machine, so the matcher was ported to Python
and run against the real endpoint before any of this was called done. With a
box of cilantro lime chicken, bok choy mix, ground turkey, egg tagliatelle
and shredded brussels, out of 300 pulled pairings 163 scored above zero and
the ten handed over led with:

```
 16.0  Balsamic Chicken Sausage + Veggie Chiocciole Pasta   (serves 2, 12 min)
 15.0  Vodka Sauce Egg Tagliatelle Pasta with Turkey Meatballs (serves 2, 6 min)
 13.0  Saucy Green Chicken + Bok Choy Veggies               (serves 2, 10 min)
 12.0  Juicy Chicken with Roasted Potatoes + Brussels       (serves 2, 25 min)
```

The tagliatelle and the turkey found their own recipe, the chicken and the
bok choy found theirs, and the dedupe dropped five more chicken dinners that
were the same plate under other names.

The costs, also measured: **464 KB over the wire** for the three pages,
**277 KB** for the trimmed cache on disk, and about **1,300 tokens** added to
the options prompt by the ten recipes. Once a week, and the options call is
the one that does not think, so the latency is a fetch and not a reasoning
pass.

**The API filters by user agent.** `Python-urllib` is refused with a 403,
which is how this was found. The app's own
`Pantry (github.com/scenicprints/pantry)` is accepted, as are curl's and
Dart's defaults. Worth remembering if the mode ever goes quiet: a 403 looks
exactly like an empty catalogue from inside the app.

### What the mode changes about the chef, and why

| | Normally | HungryRoot mode |
|---|---|---|
| Liver limits | a gate: break them and the options are re-asked | **technique only** — how it's cooked, which fat, how much. A pairing is never rejected for arriving at 9g of saturated fat |
| Avoid list | hard, on everything | hard on anything the CHEF reaches for; a component that came in the box is cooked without comment |
| Variety | different form, cuisine and not-all-one-protein | **form only.** Three recipes out of one delivery will share a cuisine and often a protein |

The liver call is his, asked directly, and matches the paste-a-card screen:
the food is bought and portioned and he is eating it tonight, so the rules
survive as method and nothing else.

Forgiving the avoid list is deliberately narrow. A hit is dropped only when
the term the list caught is ITSELF in the box, matched as a whole phrase with
plurals tolerated on either side. The loose version — forgive a term because
one of its words appears somewhere in the delivery — waves "blue cheese"
through on a box of cheese tortellini. Where this is wrong it is wrong in the
safe direction. `Chef.forgivenHits` is the rule and it is tested.

### The edges, decided

- **Replication is for "Cook something" only.** Wife's Request keeps the
  mode's other half — his delivery food comes first — but is handed no
  catalogue. A craving and a cookbook to copy from are two instructions that
  fight, and the craving wins.
- **Picking a replicated option hands the recipe call their actual card**, so
  the full grams recipe reproduces that meal rather than a dish with the same
  name. It may fix the amounts, the prep and the appliance; it may not change
  the dish.
- **The option card says which ideas are really theirs** and names the
  recipe, so the one the chef had to invent is not disguised as HungryRoot's.

### What shipping it looked like

Green on the FIRST CI run this time, which is new: analyze clean, 256 tests.
What bought that was a throwaway Dart string lexer, written before the push
and not kept: a scanner that tracks string state instead of balancing
delimiters, so it catches the two faults that cost runs before — a
single-quoted string crossing a newline, and a possessive apostrophe closing
a string mid-word, which balances perfectly and does not parse. It found one
of each here. If this keeps paying off it belongs in the repo as a tool
rather than being rewritten each time.

v0.27.0: APK released, and iOS build 222 shipped to TestFlight from the
manual `ios.yml` dispatch — App Store Connect reports it VALID and
unexpired, so the iPad has it. Pushing code still never ships to TestFlight
on its own.

Checking that a build actually became installable, rather than merely
uploading, is worth doing every time: the upload step succeeds long before
Apple finishes ingesting, and the two are a good ten minutes apart. The
read-only `asc-status` workflow in `scenicprints/mediaserver` answers it
without a Mac. The App Store Connect key is account-wide, so that workflow
lists Pantry's builds (3-digit) alongside Marquee's, and no equivalent is
needed here.

### Still open

- The catalogue slice is the first 300 featured pairings, not his actual
  weekly menu, which needs a login. If matches come back thin, the lever is
  the `tag` filter (it works: `tag=25` is high protein), narrowing by the
  primary-protein tags before scoring.
- `hungryroot_catalog.json` is never pruned. It is one 277 KB file of 300
  trimmed entries, rewritten whole on refresh, so there is nothing to prune
  yet.

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

## Cook for HungryRoot — released in v0.26.0, corrected in v0.26.1

A third button on the Cook tab, where Host Hub used to be. Paste the card
that came in the delivery, get the best way to cook exactly that food in
this kitchen. One screen in, one screen out.

The card is the reason this exists. HungryRoot writes for a kitchen with one
skillet, so it runs the burgers, then the zucchini, then the buns through the
same pan and calls the whole thing eight minutes, which is not possible. He
owns an air fryer, a Tovala, a grill and a stove. The feature is reassigning
those jobs to the appliances that are here, running them at once, and being
honest about the clock.

### The v0.26.0 mistake, and the rule that replaced it

v0.26.0 was a bad update and the fault was in the prompt, not the model. It
was told to "spread the jobs across the appliances that are here so they run
at once and finish together," and the example of a good verdict handed to it
was a THREE-appliance plan. It did as it was told: a griddle, an air fryer
and a Tovala for burgers, zucchini and buns. "Way more work than the original
instructions."

The error was treating the card's clock as the thing to beat. It isn't. One
pan used three times in a row is ONE PAN TO WASH, and the card is right to do
it. What costs him something is a second preheat, a second thing to watch and
a second thing to scrub, on a weeknight, for two servings.

So the standing rule is now **fewest things**, in both prompts and on screen:

- One appliance is the target, two is a ceiling that has to be justified,
  three is a wrong answer for a meal this size however well each part cooks.
- The only reason that reliably pays for a second appliance is that it runs
  UNATTENDED while his hands are busy elsewhere. Saving minutes does not pay.
- Dry heat no longer justifies a second appliance by itself. A teaspoon of
  olive oil in a pan that is already hot beats preheating the air fryer to
  save a few grams of fat, and a patty's own rendered fat is what the
  vegetables should cook in.
- Time is still reported honestly, but it is explicitly not the score, and
  the prompt now says not to chase the card's number.
- The verdict example in the prompt is a one-pan plan, because the old
  example was doing more damage than the rule it illustrated.
- On screen, the station heading was **ALL AT ONCE**, which made running
  three appliances look like the achievement. It is now **WHAT COOKS WHERE**
  with the appliance count under it, reading "One appliance, start to
  finish." when that is the answer.

If a future session is tempted to make this cleverer, that is the direction
the first version failed in.

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

### What CI caught, since nothing compiles locally

There is no Flutter SDK on the Windows machine, so the push was the first
analyze and test run this code had ever seen. It took three runs to go green,
and the faults are worth remembering:

- **An apostrophe in a single-quoted Dart string.** `'Tonight's delivery'`
  balances its braces perfectly and does not parse, so the local
  delimiter-balance script walked straight past it. Possessives take double
  quotes, the way `"Couldn't read the chef's reply"` already does in
  `chef.dart`.
- **`!` on a nullable the analyzer will not promote.** The time row asserted
  non-null on a local it had only tested through a separate bool. A missing
  card time now reads as a gap of zero, which is neither faster nor slower,
  so the comparison line stays absent with no `!` anywhere.
- **A widget test that pinned where a button lands.** Text wraps further in
  the test font than in Fraunces, so the Cooking mode button sat outside the
  built viewport and the assertion found nothing. The lower half of the page
  is now walked in page order with `scrollUntilVisible`, which asserts that
  it is reachable rather than where it sits.

Green on run three: analyze clean, 228 tests. v0.26.0 is built, signed and
published, so the in-app updater will offer it.

### Rebased onto two releases that landed first

v0.25.2 cut the option count to three and v0.25.3 moved the Opus setting back
to 4.8, where thinking is a per-call opt-in. `planHungryRoot` passes
`think: true`: it is the same class of call as the recipe, a judgement about
food he then stands at a counter and follows, not the picker he waits on.

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
