# Pantry — Roadmap / Backlog

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
