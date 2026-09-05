# Pantry — Roadmap / Backlog

## Cost-conscious chef v2 — the chef reads the real ledger (landed, unreleased)

The chef used to know what a gram of chicken costs and nothing else. It now
sees what he actually spends. Conscientious, not budgeted: there is no target
anywhere in the app, nothing is capped, and no meal is ever rejected on price.

- `lib/spending.dart` — `SpendProfile`, the ledger boiled down to what is worth
  telling a chef: a normal week, last week, this week so far, whether the bill
  is climbing, and the named items the money is going to. Windows are CALENDAR
  weeks (a quiet stretch must not drag a July purchase in as "lately"), the
  current partial week never dilutes an average, and weeks with no spend are
  absent rather than counted as zero.
- `lib/chef.dart` — `formatSpending()` and `formatProteinValue()` build two new
  prompt blocks. The options call gets both; the recipe call gets protein value
  only, since that is the call where gram amounts decide the bill. COST
  AWARENESS in the system prompt was rewritten around them, and it is told
  explicitly never to mention money to him — the saving shows in what it
  proposes, not in what it says.
- **Protein value is the actual lever.** Protein is the dearest thing on the
  plate, so cost per GRAM OF PROTEIN (not per pound) is what makes proteins
  comparable. `PantryItem.costPerProteinGram`, and `PriceEntry` now records
  protein density so the figure survives an item leaving the pantry. On his
  real data this is stark: Just Bare chicken breast is $0.233 per g of protein
  against $0.056 for the Co-op fillets — the same food at a quarter the price,
  and Just Bare is his second biggest cost driver.

### Guards worth keeping (each one came from real data, not theory)
- **Implausible densities are refused.** A mis-scanned Parmesan label in his
  pantry claims 40 g of protein in a 5 g serving. Unguarded it ranked as the
  cheapest protein in the house and would have pushed dinners onto cheese,
  which the liver rules restrict. Nothing above 0.9 g protein per gram of food
  is believed.
- **Only real protein sources are ranked.** Priced per gram of protein, dried
  oregano looks like the most expensive protein he owns. Foods must carry
  10 g per 100 g (or 3 g per countable unit) to appear at all.
- **DST.** `weekStart` counted back with a `Duration`, which lands at 23:00 on
  the two changeover weekends and split one week across two buckets. Now built
  through the date constructor. This also fixes the existing Spending card.

Open: the price book has 80 entries and none carry protein yet — the field is
new. Items currently in the pantry backfill themselves on the next launch (the
startup `withPantry` seed records it); foods long since used up stay blank
until bought again.

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
