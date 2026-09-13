# Pantry on iPad

One codebase, two shapes. The iPad is a cooking surface: on a screen whose
shortest side is 600pt or more the app is **Cook only**, with Settings one tap
away in the app bar. Pantry edits, Quick-Add and the shopping run stay on the
phone, and deducting what a meal used stays in bodycomp.

It reads and writes the same `pantry.json` in `scenicprints/pantry-data`, using
the same write token, so an item added on the phone is on the iPad's shelf.

There is no Mac here. The build runs on a GitHub Actions macOS runner, signs
itself with an App Store Connect API key, and lands on the iPad through
TestFlight. Same pipeline as the Marquee TV app in `scenicprints/mediaserver`.

The `ios/` folder is not in this repo. `.github/workflows/ios.yml` generates it
with `flutter create --platforms=ios` on every run and patches it there, so the
iOS config is one readable file instead of a hundred generated ones.

## One-time setup

1. **App Store Connect** (appstoreconnect.apple.com) → Apps → **+** → New App.
   - Platform: **iOS**
   - Name: `Pantry`
   - Bundle ID: create/pick `com.scenicprints.pantry`
   - SKU: `pantry`
2. **Repo secrets** (github.com/scenicprints/pantry → Settings → Secrets and
   variables → Actions). Same four values already in the mediaserver repo:
   - `APPLE_TEAM_ID`
   - `ASC_KEY_ID`
   - `ASC_ISSUER_ID`
   - `ASC_KEY_P8_BASE64`
3. **TestFlight** → Internal Testing → add yourself to a group, turn on
   automatic distribution.
4. Install **TestFlight** from the App Store on the iPad.

`PANTRY_DATA_TOKEN`, `ANTHROPIC_API_KEY` and `USDA_API_KEY` are already in this
repo for the Android release and are reused as-is.

## Shipping a build

Actions → **Build & Ship iOS (TestFlight)** → Run workflow.

- Leave **upload** checked to ship to TestFlight.
- Uncheck it for a build-only run: everything compiles, signs and exports, the
  `.ipa` lands as a run artifact, and nothing reaches TestFlight.

Apple takes about ten minutes to process a build before it appears. It then
installs on the iPad on its own if automatic distribution is on.

A scheduled run every two months keeps the build from lapsing (TestFlight
builds expire after 90 days).

**Batch the changes and ship once.** Apple caps uploads per app per day, and
altool reports some failures as success, so the workflow greps its output and
fails the step itself.

## What differs from Android

- **Updates.** iOS will not let an app install its own binary, so the APK
  updater is Android-only. On iOS the Settings card says updates come through
  TestFlight.
- **Timer alarm.** No full-screen intent and no notification channels on iOS.
  The cook timer rings as a banner with sound; the in-app countdown, the buzz
  and the wakelock do the rest. Raising it to a Time Sensitive alert needs an
  entitlement on the App ID, which is a deliberate next step, not a default.
- **Layout.** Reading screens are capped at a 640pt column so nothing stretches
  across the iPad. Cooking mode and the measuring screen deliberately take the
  whole width.
- **Minimum iPadOS 15.5**, set by the ML Kit text recogniser.

## What the iPad adds to Cook

- **Measure everything out.** A mise en place pass over any recipe, including
  ones already in the box. The chef groups ingredients into bowls: things that
  go in at the same moment and keep together until then share one. Tick items
  off as you measure; tick a bowl header to do the whole bowl. Plans are cached
  per recipe (last 30) because each one costs a call.
- **Two-pane cooking mode.** On a wide screen, the method down the left and the
  live step down the right. Toggle in the app bar, remembered per device.
- **Counter mode.** Bigger type, bigger buttons, tap anywhere to advance.
- **Timer rail.** Timers live in `CookTimers`, not in the step widget, so the
  rice, the oven and the pan run at once and a timer that ends three steps back
  still rings. Tap a chip to pause or reset, long-press to dismiss. Starting a
  different dish clears the old ones out.
- **"I'm out of this."** Tap an ingredient, on the recipe or in cooking mode,
  and the chef proposes a swap from what the pantry actually holds.
- **Opus 5** replaced Opus 4.8 in the model picker, same price per token.
- **One chef on every device.** The model, equipment list, avoid list and cook
  notes ride in `chef.json` beside `pantry.json`, so the iPad cooks with the
  same kitchen and the same avoid list as the phone. They used to live in
  per-device secure storage, which meant a fresh install started with an empty
  avoid list while the prompt was still told to respect it. The API key never
  goes in that file; the repo is public.
- **Measured weights go to BodyComp.** The Measure screen captures what really
  went in the pan, links each line to a pantry item, and "Done, send to
  BodyComp" writes `cooked.json`, then takes the raw grams off the shelf.
  BodyComp logs it and does not subtract again.
- **Cook notes that change the recipe.** Marking a meal cooked asks one
  optional line: too salty, wanted five more minutes. It shows on the recipe
  next time, and "Cook it again, fixed" hands the notes to the chef, which
  rewrites the same dish with those changes and nothing else. Notes are kept
  per recipe title, last six, so the app stops repeating a known flaw.
