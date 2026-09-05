# CLAUDE.md

This file guides Claude Code (claude.ai/code) and other coding agents. The root `AGENTS.md`
is a symlink to it, so both have identical content — edit this file only.

HourGlow is a macOS menu bar wallpaper scheduler: it switches system aerial wallpapers or
local images at fixed times, relative to sunrise/sunset (with offsets), or in solar phases.
Swift 6.3 + SwiftUI, zero third-party dependencies, **no Xcode project** (`swiftc` compiles
directly and the `.app` bundle is assembled by hand). Version 1.5 is the current release.

For user-facing documentation, see `README.md` / `README.zh-CN.md`; for contributing, see
`CONTRIBUTING.md`. This file takes the implementer's perspective: how to build and verify,
which system facts to rely on, and which mistakes not to repeat. Reading it should be enough
to start cold without reconstructing conversation history; record conclusions here after
finishing a task.

## Building and verification

There is no XCTest and no `swift test`. Verification uses separately compiled check binaries,
all offline and without changing your real wallpaper (`panelshot` briefly shows a window,
as does the native visibility check listed below).

```bash
./build.sh                    # Build everything: CLI, eight check binaries, panelshot, build/HourGlow.app
./build/modelcheck            # Resolution: midnight wraparound, solar triggers, solar phases, Codable compatibility
./build/enginecheck           # Engine: assert-vs-stand-down decision matrix, timer scheduling
./build/importcheck           # Import: filename/subfolder classification, multi-resolution, even split, skips and cleanup
./build/appcheck              # App state: drafts, save boundaries, external config conflicts, onboarding rules
./build/appstartupcheck        # Startup recovery and visible/hidden refresh (about 2 minutes)
./build/panelvisibilitycheck   # Native window visibility and observer teardown; briefly shows a test window
./build/updatecheck           # Updater: SemVer, Release parsing, SHA-256
python3 Tests/verify-updater-location.py # Move a running app/parent directory, copies at the old path, missing helper
./build/l10ncheck Sources     # Catalogs: missing/empty/extra keys, placeholders, language selection, keys used in code
bash Tests/verify-updater-helper.sh build/HourGlow.app/Contents/Helpers/HourGlowUpdater
bash Tests/verify-app-signature.sh build/HourGlow.app   # Signature and stable designated requirement
./build/solarcheck            # Sunrise/sunset; invoked as the program under test by verify-solar.py
python3 Tests/verify-solar.py # Cross-check against ephem (requires pip install ephem, 30-second tolerance)
python3 Tests/verify-cli-boundaries.py # Invalid input and 23/25-hour daylight-saving days
./build/panelshot ~/Desktop   # Five pages + five guide steps as PNGs (extra clock-trigger shot); compare layout changes
./build/panelshot ~/Desktop --only timeline --now 2026-09-04T06:20   # Capture one page with time frozen
./build/panelshot ~/Desktop --appearance dark                        # Pin appearance (light | dark), ignoring the system
./build/panelshot ~/Desktop --only settings --update-rate-limit       # Rate-limit notice and recovery time, offline
Tools/makedemo.sh             # README's docs/demo.gif + website/GitHub share card (see Demo and share card below)
```

`HOURGLOW_HOME` redirects the entire config directory (`schedule.json`, `state.json`, and
`run.lock` move together). Use a throwaway configuration for end-to-end checks:

```bash
HOURGLOW_HOME=/tmp/hg ./build/hourglow-cli list   # An empty directory gets the four-slot Tahoe preset
```

`HOURGLOW_LANG` overrides the stored preference and system language for this run only, without
writing any settings:

```bash
HOURGLOW_LANG=en ./build/hourglow-cli list        # All three kinds of build output honor it
HOURGLOW_LANG=en ./build/panelshot ~/Desktop      # Inspect layout changes or a new language
./build/hourglow-cli language en                  # This actually saves the preference, shared by app and CLI
```

Launch at login and location **cannot be handled by the CLI**: registration and location
permission belong to the caller's own bundle, and the CLI is an unbundled binary. These
diagnostic entry points are on the app executable; they print their result and exit:

```bash
build/HourGlow.app/Contents/MacOS/HourGlow --login-item status   # status | on | off
build/HourGlow.app/Contents/MacOS/HourGlow --locate              # One fix, printed without changing the config
build/HourGlow.app/Contents/MacOS/HourGlow --guide status        # Onboarding: status | reset | show
```

`--guide show` is the sole exception that does not exit: it marks this launch to show the guide
unconditionally, useful for inspecting layout changes. The seen marker is in `UserDefaults`
(`onboarding.seenVersion`), outside `HOURGLOW_HOME`, so a clean first-launch demonstration
requires both steps:

```bash
HOURGLOW_HOME=/tmp/hg-guide build/HourGlow.app/Contents/MacOS/HourGlow --guide reset
HOURGLOW_HOME=/tmp/hg-guide build/HourGlow.app/Contents/MacOS/HourGlow   # Empty config directory → guide opens automatically
```

To run an individual assertion, edit the `check(...)` calls in `Tests/<Name>/main.swift`;
the check binaries have no filtering mechanism. They execute ordered assertion lists and
exit with status 1 when the failure count is nonzero.

Use the CLI for diagnostics and manual verification:

```bash
./build/hourglow-cli now                # Expected wallpaper, next switch, and whether reality matches
./build/hourglow-cli simulate 2026-12-21 # Time travel: print every switch on that date
./build/hourglow-cli import ~/Pictures/zhangjiajie  # A set of stills → solar-phase timeline
./build/hourglow-cli location 深圳      # Set coordinates by city name
./build/hourglow-cli apply --dry-run    # Show the proposed write without writing
./build/hourglow-cli run                # Foreground engine; Ctrl-C exits
./build/hourglow-cli status             # Engine's view: last wallpaper written, and whether it is still current
open build/HourGlow.app                 # Menu bar app
```

The app icon is drawn by `Tools/makeicon.swift`: an SF Symbol hourglass with a dawn-to-night
gradient, generating `Resources/HourGlow.icns`. The generated asset is committed; `build.sh`
only copies it into the bundle. Rerun the usage shown in that file's header only when changing
the icon.

### Demo and share card

`Tools/makedemo.sh` generates both `docs/demo.gif` (at the top of the README: 1000 × 625,
32 frames, about 10 seconds, 3.2 MB) and the website repository's `assets/og.png` (1200 × 630,
shared by `og:image`, Twitter Card, and GitHub Social Preview). It uses a throwaway config
(Shenzhen, four Tahoe slots, English, date fixed to 2026-09-04), captures twelve timeline
views throughout the day with `panelshot --only timeline --now …`, then uses
`Tools/makedemo.swift` and AppKit to composite the desktop, menu bar, and panel offscreen.
ImageIO encodes the GIF; no ffmpeg or gifsicle dependency is introduced.
Evening/Night panels are captured with `--appearance dark`, matching the darker wallpaper and
showing dark mode. `Phase.dark` in `makedemo.swift` gives those phases a lighter border;
keep the two phase lists in sync. Background images `tahoe-*.jpg` are not in this repository;
by default they come from the adjacent website repository's `../hourglow-web/assets/`.

All uses of “now” in the panel go through `AppModel.now` (`nonisolated(unsafe) static var`).
Only `panelshot --now` changes it; the app and CLI always use the real clock. Do not use
`Date()` directly in new time-dependent UI logic, or that part of a frozen screenshot will
show the real time.

**The website is a separate repository**, `bobbyhuang-dev/hourglow-web` (locally
`../hourglow-web`): static pages + Cloudflare Workers, deployed on pushes to `main`. GitHub
repository Social Preview has no API: upload `og.png` manually under Settings › General ›
Social preview. Homepage and Topics can be set with `gh repo edit`.

Versions come from `HOURGLOW_VERSION` / `HOURGLOW_BUILD` at the top of `build.sh` (defaults
`1.5.0` / `1`); the release workflow overrides them with the tag and run number. CI and
releases use GitHub Actions: `.github/workflows/ci.yml` builds, runs the main checks, and
cross-checks the ephemeris on every push/PR; `.github/workflows/release.yml` builds, verifies,
packages, and creates a Release for `v*` tags. See “CI and releases” below for past pitfalls.

`build.sh` lists the entry file separately as `ENTRY`: `@main` (`HourGlowApp.swift`) cannot
share a module with a `main.swift` containing top-level code, and `panelshot` needs to reuse
`UI/`. New UI files match `Sources/UI/*.swift`; new entry points require a script change.

## Architecture

Dependencies flow one way: `UI → AppModel → Scheduler → Resolver/WallpaperWriter`.
Resolution and writing logic exist **only once**, in `Engine` and `Model`; the UI has no
separate copy of the scheduling rules.

```
Sources/
├── L10n/                      // All UI and CLI strings, shared by all three kinds of build output
│   ├── L10n.swift             // Language selection (HOURGLOW_LANG > preference > system > en), lookup, plurals
│   └── Catalogs/<code>.swift  // One file per language; en is the source catalog
├── App/
│   ├── HourGlowApp.swift      // @main, MenuBarExtra scene; --login-item / --locate / --guide entry points
│   ├── AppModel.swift         // Sole layer between UI and engine, @MainActor @Observable
│   ├── SlotDraft.swift        // Slot editor draft model (edits do not take effect immediately)
│   ├── Onboarding.swift       // Guide steps, copy, and eligibility rules (Foundation only)
│   └── AppUpdater.swift       // GitHub Release checks, download, verification, and installation handoff
├── Model/                     // Pure data and resolution, no system interaction
│   ├── Schedule.swift         // Slot / Trigger / Wallpaper + handwritten Codable (flat JSON)
│   ├── Store.swift            // Atomic schedule.json I/O; writes Tahoe preset when missing
│   ├── Resolver.swift         // Resolution expands one day either side, naturally handling midnight wraparound
│   ├── TimeMap.swift          // Solar phases: evenly divide sunrise/day/sunset/night across today's twilight windows
│   └── SceneImport.swift      // Stills → solarPhase slots (filenames / subfolders / .sundialScene)
├── System/                    // macOS integration
│   ├── WallpaperWriter.swift  // Read/modify/write Index.plist + killall WallpaperAgent
│   ├── AerialCatalog.swift    // Parse system entries.json: names, categories, thumbnails, download state and size
│   ├── Solar.swift            // NOAA solar position algorithm, sunrise/sunset and twilight
│   ├── Location.swift         // Approximate coordinates from zone.tab (permission-free fallback)
│   ├── PreciseLocation.swift  // One CoreLocation fix; manual entry when denied
│   ├── Cities.swift           // Offline common-city table shared by guide and location page
│   ├── Geocode.swift          // Reverse-geocode coordinates for names only, never replace the coordinates
│   └── LaunchAtLogin.swift    // Launch at login, wrapping SMAppService.mainApp
├── Engine/
│   ├── Scheduler.swift        // Core: timer at next trigger + system observers + write decision
│   ├── EngineState.swift      // state.json: last wallpaper we wrote
│   ├── ConfigWatcher.swift    // Follow manual schedule.json edits immediately
│   ├── EngineLock.swift       // Single-instance lock shared by app and CLI
│   └── LaunchAgentInstaller.swift  // Headless service: register CLI run as a LaunchAgent
├── UI/                        // One panel with horizontal navigation; measurements centralized in PanelKit
│   ├── PanelRoot.swift        // Panel root
│   ├── PanelKit.swift         // Fixed measurements, font sizes, adaptive card colors, Sky palette, headers, cards, rows, thumbnail cache
│   ├── TimelineView.swift     // Main panel: timeline
│   ├── DayBar.swift           // Today's daylight bar: a 24-hour status graphic, not interactive
│   ├── SlotEditorView.swift   // Single-slot editor
│   ├── WallpaperPicker.swift  // Aerial thumbnail grid + local images
│   ├── SettingsView.swift     // Launch at login + location + automatic updates + help
│   ├── PlaceView.swift        // Choose location
│   ├── OnboardingView.swift   // Five-step guide layout
│   └── OnboardingWindow.swift // Its host window (the project's only independent window)
├── Updater/main.swift         // Replace the app in place after the main process exits, then relaunch
└── CLI/                       // Diagnostics and headless-service entry point
```

- `Model/` — `Trigger`/`Wallpaper` in `Schedule.swift` use handwritten `Codable` for flat JSON
  that users can edit. `Resolver.swift` derives a reference day from each slot's offset, then
  expands one day on either side. `TimeMap` evenly distributes sunrise/day/sunset/night across
  that day's nautical-dawn-to-civil-dusk windows. `SceneImport` turns stills into `solarPhase`
  slots using filenames, or their parent folder names when a filename is unrecognized.
- `System/` — `WallpaperWriter` reads/modifies/writes `Index.plist`: preserve unknown top-level
  fields, back up before writing, force `linked`, skip writes when the target already matches
  to avoid flicker, then `killall WallpaperAgent`. Coordinates have three paths, with manually
  entered or location-service coordinates taking precedence over time-zone inference.
- `Engine/` — `Scheduler` schedules its timer directly at the next trigger, **without polling**.
  Four system notifications (wake / clock change / time-zone change / day rollover) handle
  disruptions, plus a safety net of at most 6 hours. `EngineState`'s `state.json` records the
  last wallpaper we wrote; it is the sole basis for recognizing manual wallpaper changes.
- `L10n/` — Foundation only, shared by `Model` / `System` / `Engine` / `UI` / `CLI` / `Updater`.
  It comes first in the dependency graph and is listed separately as `L10N` in `build.sh`.
  See “Language and localization.”
- `App/Onboarding.swift` — Foundation only, no UI or `Store`, so it can compile into `appcheck`
  independently.
- `App/AppUpdater.swift` — Finds stable GitHub Releases, compares SemVer, downloads and checks
  the asset digest, then verifies the unpacked bundle ID, version, and code signature.
  `Updater/main.swift` replaces the app in place after the main process exits.

### Two semantics that must hold

**1. Who wins after a manual wallpaper change** (`Scheduler.shouldAssert`; the type comment
contains the full reasoning): crossing a new trigger boundary (scheduled time, sleeping
through it, resuming from pause) writes normally. In-place re-evaluation without a boundary
crossing (launch, wake, time-zone change) writes only if the current wallpaper is still the
one we last wrote; otherwise it stands down. Compare `EngineState.lastFiredAt` with the
current `Resolution.since`. `enginecheck` covers the complete decision matrix.

Both extremes were tried and failed: checking only “same slot?” overwrites a manual choice
made ten minutes ago after an hour asleep; checking only “is it our last wallpaper?” disables
automatic switching forever after a single manual change, contradicting the goal of requiring
no extra user action. A manual choice lasts until the next scheduled switch, like a
thermostat's temporary hold.

**2. Leader/follower** (`Engine/EngineLock.swift`): the menu bar app and `hourglow-cli run`
may coexist. Two schedulers would mistake each other's writes for manual changes, so both
first compete for `run.lock`. The winner starts `Scheduler`; the loser becomes a follower,
only editing `schedule.json`, which the leader's `ConfigWatcher` picks up. Followers must
retry periodically and take over when the leader exits or its LaunchAgent is removed; never
leave a process that appears to be running while nothing actually schedules.

## Verified system facts

These conclusions were verified on a real machine, not inferred. Rely on them when
implementing rather than speculating again.

### Wallpaper configuration file

```
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist   # binary plist
```

Changes require `killall WallpaperAgent` to take effect. Testing showed that the system does
not revert our edits: a user's choice in System Settings overwrites ours, and our writes
can overwrite theirs. Arbitration therefore belongs entirely to the semantics above, not
to the system.

Four top-level scopes:

```
AllSpacesAndDisplays
SystemDefault
Spaces      { <space-uuid>: { Default: …, Displays: { <display-uuid>: … } } }
Displays    { <display-uuid>: … }
```

Each slot's `Type` determines whether desktop and screen saver are linked:

| Type | Structure |
|---|---|
| `linked` | One `Linked` key; desktop and screen saver share a choice |
| `individual` | Separate `Desktop` and `Idle` keys |

Each choice has the form `{ Provider: <string>, Files: [], Configuration: <nested binary plist> }`.

### Two providers

**Dynamic wallpaper (aerial)**

```
Provider:      com.apple.wallpaper.choice.aerials
Configuration: { assetID: "CF6347E2-4F81-4410-8892-4830991B6C5A" }
```

**Static image**

```
Provider:      com.apple.wallpaper.choice.image
Configuration: { type: "imageFile", url: { relative: "file:///path/to.heic" } }
```

The static-image format was reverse-engineered by calling the public
`NSWorkspace.setDesktopImageURL` API. It does write `Index.plist`, but its readback API,
`desktopImageURL(for:)`, returns stale values (`DefaultDesktop.heic` in testing) and **cannot
be trusted**. It also forces the slot from `linked` to `individual`; correct that when writing.

### Aerial library

```
~/Library/Application Support/com.apple.wallpaper/aerials/
├── manifest/entries.json      # Complete metadata for 156 assets
├── thumbnails/<uuid>.png      # 156 thumbnails, all cached locally
└── videos/<uuid>.mov          # Downloaded videos, about 430 MB each
```

Available asset fields in `entries.json`: `id`, `accessibilityLabel`, `shotID`,
`localizedNameKey`, `categories[]`, `subcategories[]`, `preferredOrder`, `previewImage`,
`includeInShuffle`, `showInTopLevel`, `url-4K-SDR-240FPS`.

There are five categories: Landscapes (18 subcategories) / Cities (6) / Underwater (17) /
Space (21) / Mac (1).

Check whether `videos/<id>.mov` exists to determine download state. An undownloaded asset can
still be written to the configuration; the system downloads it itself.

### Asset IDs for the four Tahoe wallpapers

The first-launch preset has four slots: sunrise → Morning, 09:00 → Day, 30 minutes before
sunset → Evening, 60 minutes after sunset → Night. This is preset data, not hardcoded logic.

| Period | Name | shotID | assetID |
|---|---|---|---|
| Morning | Tahoe Morning | TA_L_001 | `B2FC91ED-6891-4DEB-85A1-268B2B4160B6` |
| Day | Tahoe Day     | TA_L_002 | `4C108785-A7BA-422E-9C79-B0129F1D5550` |
| Evening | Tahoe Evening | TA_D_001 | `52ACB9B8-75FC-4516-BC60-4550CFF3B661` |
| Night | Tahoe Night   | TA_D_002 | `CF6347E2-4F81-4410-8892-4830991B6C5A` |

## UI conventions

Keep the UI native to macOS, simple, and **fixed in layout**. All measurements live in `Panel`
in `UI/PanelKit.swift`: width locked to 360 pt, wallpaper picker height fixed at 470 pt, other
pages sized to content. Change those first rather than scattering numbers through views.
Use only the six `Panel.Font` sizes (headline / body / control / secondary / caption /
section); `.font(.system(size:))` in views is reserved for SF Symbol icons. Card backgrounds,
input backgrounds, and thumbnail borders use `Panel.cardFill` / `fieldFill` / `hairline`,
dynamic `NSColor(name:)` colors resolved against the view's appearance.

Below the timeline status is **today's daylight bar** (`UI/DayBar.swift`): a 24-hour strip
whose gradient follows today's twilight/sunrise/sunset. Its colors come from `Sky`, shared
with the icon and guide header. Each slot has a white trigger marker; the active interval
has an accent-colored lower edge, and an accent cursor marks now. It is a status graphic,
**not clickable**: 2 pt markers often crowd the cursor, their destination would be ambiguous,
and the list is immediately below. Without coordinates, or during polar day/night, use
neutral gray rather than inventing sun times. If twilight cannot be computed, use 45 minutes
before sunrise/after sunset for the gradient endpoints — this is drawing behavior, independent
of `TimeMap`'s resolution fallback. Pausing dims the entire bar; the status subtitle turns
orange with a pause icon, without adding a separate paused badge.
Persistent row backgrounds mean “selected” on macOS, but these rows navigate rather than
select. Reserve backgrounds for hover/press; mark the currently active slot with a leading
accent bar (`Panel.nowBar`).

Settings (language + launch at login + location + automatic updates) and the slot page sit at
the same navigation level. Reach settings through the ⋯ menu or the missing-coordinates
banner: a notice explaining what is wrong should lead to where it is fixed. Changes take
**immediate effect**: a toggle, coordinate pair, or language choice is a single action, not
a batch waiting to be applied.

Slot edits are the opposite: they **do not take immediate effect**. They first enter
`AppModel.draft`, so the UI responds immediately, but only Apply writes `schedule.json` and
can change the wallpaper. Otherwise experimenting would actually switch the wallpaper.
The draft belongs in the model, not view `@State`: choosing wallpaper navigates to another
page, and the panel dismisses on losing focus, so the draft must outlive both. Returning to
the timeline ends editing (`endEditing`) and discards unapplied changes. Deletion uses an
inline two-stage confirmation, not a heavyweight dialog in a menu bar panel, and takes effect
immediately after confirmation.

Location is part of scheduling, not an appendix to settings: enter through the pill at the
timeline's upper right, then return directly to see today's switch times. Sunrise/sunset
offsets use preset menus (±120 / 90 / 60 / 45 / 30 / 15 / exactly), not steppers: 5-minute steps
imply false precision and need twelve clicks to go from exactly to one hour later. Values
outside those presets (manual config edits or an old 37-minute stepper value) are temporarily
inserted so the menu can select the current value.
The empty-search section on the location page is “Nearby”: sort the offline table (handwritten
entries + `zone.tab`) by spherical distance from `effectiveCoordinate`, then take
`Cities.nearbyCount`. CLI `cities` without arguments does the same. Previously, separate
China/overseas sections always put China first, hardcoding the developer's location: English
users in Portland saw a first screen full of Chinese cities. Without coordinates, fall back
to the handwritten table's original order. Coordinates do not affect ranking when a query
is present.

**The onboarding guide is the project's only independent window** (`UI/OnboardingWindow.swift`,
480 × 566; measurements in `PanelKit`'s `Guide`, separate from `Panel`). The sole reason for
this exception is discoverability: an `LSUIElement` app puts nothing on screen at first launch,
only an hourglass in the menu bar, and `MenuBarExtra` has no API to open it for the user. A
guide inside the panel would reach only people who already found the entrance, excluding those
who most need it. It **opens automatically only on a genuinely fresh install** (no
`schedule.json`), never bothering existing users after an upgrade. Manual entry points are
the ⋯ menu and Help in settings. Closing counts as seen, whether skipping, finishing, or
clicking the red close button. Do not use `OnboardingWindow` to open a second window.

## Language and localization

The UI supports Simplified Chinese and English, following the system by default. **No
user-visible string belongs directly in a view, command, or error**: use `L10n.t("key")`.
Write new text in `Catalogs/en.swift` (the source language) first, then add translations.

**Why not `.lproj/Localizable.strings`?** This repository has no Xcode project and produces
unbundled binaries (`hourglow-cli`, `panelshot`, eight check binaries).
`Bundle.main.localizedString` would return raw keys in those binaries, preventing checks from
finding missing translations. Compiling catalogs into the binaries gives all three kinds of
build output the same text; adding a language takes one Swift file.

**Adding a language = two changes**: create `Sources/L10n/Catalogs/<code>.swift` and add a line
to `L10n.catalogs`. Nothing else needs changing: `build.sh` finds the files by wildcard,
`CFBundleLocalizations` is derived from them, and so is CI's per-language smoke loop. Keep the
contributor instructions in `CONTRIBUTING.md`'s “Adding a language” section in sync.

**Language selection** (`L10n.resolve`, a pure function checked against a table by `l10ncheck`):
`HOURGLOW_LANG` > user preference from settings/CLI > system languages > `defaultCode` (English).
Each tier uses `match`: exact → language + script (`zh-Hans-CN` → `zh-Hans`) → language only
(`en-GB` → `en`, `zh-Hant` → `zh-Hans`). The final step is deliberate: Simplified Chinese is
closer for a Traditional Chinese reader than switching them to English.

**Source and default have distinct roles, even though both are `en`**: `sourceCode` defines
completeness and fallback for missing text; `defaultCode` chooses the language when no requested
language matches. A French system with only Chinese and English available gets English.
Do not combine these two settings just because their current values are equal.

**Singular forms are language-dependent**: English source entries may include `<key>.one`
for a count of exactly 1. These entries are optional in other languages: Chinese does not need
them and uses its base entry even at 1, rather than falling back to an English singular.
Only the one-vs-many split is supported; do not work around a richer plural system silently.

**Place names are not part of the translation workload**: `StringCatalog.placeNames` has only
`.chinese` / `.latin`, selecting a column in `System/Cities.swift`. Translating a language does
not require translating hundreds of place names individually.

**Language changes apply immediately**: `L10n.setPreference` writes to disk → clears caches →
posts `didChangeNotification`, in that order. `AppModel` increments `languageGeneration`;
`PanelRoot` uses it as `.id` to rebuild the panel tree. The `.id` belongs on the page rather
than `PanelRoot` itself, keeping users on settings after they change the language.

**Preferences live in `UserDefaults`, not `HOURGLOW_HOME`**, just like onboarding's `seenVersion`.
The app uses `.standard`; the unbundled CLI must explicitly use
`UserDefaults(suiteName: "dev.bobbyhuang.hourglow")`. Passing your own bundle ID to
`UserDefaults(suiteName:)` is undefined behavior, hence the separate paths.

**What `l10ncheck` protects**: missing/empty/extra keys, orphan singular forms, placeholders
that differ from the source, mixed `%@` and `%1$@` within one string, and unnumbered arguments
in multi-argument strings. Optional `.one` entries need not be present in every language.
With `Sources` as an argument it also checks literal `L10n.t("…")` keys against the source
catalog. A typo otherwise exposes unfinished text such as `slot.apply` in the UI; the compiler
will not catch it.

## Runtime paths

```
~/Library/Application Support/HourGlow/schedule.json   # Configuration (HOURGLOW_HOME redirects the whole directory)
~/Library/Application Support/HourGlow/state.json      # Last wallpaper written
~/Library/Application Support/HourGlow/run.lock        # Single-instance lock
~/Library/Application Support/HourGlow/Scenes/         # Imported wallpaper-set assets
UserDefaults dev.bobbyhuang.hourglow onboarding.seenVersion   # Whether the guide was seen (outside HOURGLOW_HOME)
UserDefaults dev.bobbyhuang.hourglow language                 # UI language preference; absent means follow the system
~/Library/Application Support/com.apple.wallpaper/Store/Index.plist  # System wallpaper configuration
~/Library/Application Support/com.apple.wallpaper/aerials/           # Aerial library
~/Library/LaunchAgents/app.hourglow.agent.plist        # Optional headless service (hourglow-cli agent install)
~/Library/Logs/HourGlow.log                            # LaunchAgent log
~/Library/Logs/HourGlow-Updater.log                    # Most recent helper installation result
~/Library/Caches/HourGlow/Updates/                     # Download/unpack staging (cleaned on success)
```

## Non-goals

The following are **out of scope**. Before implementing a request for one, confirm that the
boundary is deliberately changing:

- Per-display / per-Space settings (always write `linked`; desktop and screen saver change together)
- Separate desktop and screen saver controls
- Random / folder rotation
- Triggers following system light/dark mode
- Weather or Focus-mode triggers
- Lock screen wallpaper
- Whole-`schedule.json` import/export and iCloud sync (wallpaper-set folder import already exists;
  this is not referring to that)

## Past pitfalls (do not repeat them)

Read the relevant section before changing a module. Every item came from a failure on a real
machine, not a theoretical risk.

### Scheduling and engine

- **Schedule timers 1 second after the trigger time.** A few milliseconds early resolves to
  the previous slot and wastes a cycle.
- **Add `Timer` to `.common` mode.** Opening the menu bar panel changes run-loop mode;
  `.default` timers stop firing while the panel is open.
- **Call `NSTimeZone.resetSystemTimeZone()` after `NSSystemTimeZoneDidChange`.** Otherwise
  `TimeZone.current` still returns the old zone and sun times are wrong all day.
- **Directory-level vnode events miss in-place writes.** `ConfigWatcher` originally watched
  only the directory because `Store.save` atomically replaces the inode. But truncation and
  rewriting with `echo >` / `open(path,"w")` produce no directory event, and a config change
  was missed in testing. Watch both directory and file, reattaching the file source after
  each check because its inode may just have been replaced.
- **Self-triggering loops:** `state.json` shares a directory with `schedule.json`; each engine
  evaluation writes the former and the directory event triggers another evaluation. Compare
  the actual contents of `schedule.json` to stop the loop.
- **Resolve equal trigger times deterministically:** later configuration entries win, and the
  next-switch preview must match the result when that time arrives.
- launchd redirects stdout to a fully buffered file; `setvbuf(_IOLBF)` is needed for real-time logs.
- Default SIGINT/SIGTERM handling kills the process before `DispatchSource` receives them;
  first call `signal(sig, SIG_IGN)`, then handle them yourself.

### Solar phases and import

- **Recompute windows every day.** Approximating three sunrise images with a fixed “20 minutes
  after sunrise” offset fails when winter dawn shortens.
- The last night images have a `fireDate` in the following morning. Resolver's existing ±1-day
  expansion handles this; do not add another offset anchor around `solarPhase`.
- **Match filename tokens, not `contains("day")`:** that misclassifies `sunday.heic`.
- **The multi-resolution deduplication key is the complete path after removing the
  `5120x2880` directory component**, not just the basename. Basenames cannot distinguish two
  resolutions of one image from `sunrise/1.jpg` and `night/1.jpg`. Sets organized by phase
  subfolder with numbering from 1 lose most images: 12 go in, 3 come out, and import reports success.
- **Always use `canonicalPath` (`resolvingSymlinksInPath`) for directory identity.**
  `standardizedFileURL` handles `/private/tmp` inconsistently: a constructed URL keeps
  `/private`, while `contentsOfDirectory` returns `/tmp`. String comparison can then delete
  newly written assets as if they belonged to another directory.
- **Unrecognized-phase files may be skipped, but report their count.** Silently dropping them
  leaves an “Imported” dialog and an incomplete timeline, with no way for the user to know.
- **Do not fall back to sunrise/sunset themselves when twilight is unavailable.** That makes
  the dawn-to-sunrise window zero-length, inflated to 60 seconds by division-by-zero protection:
  three wallpapers flash past 20 seconds apart, with three consecutive `killall WallpaperAgent`
  calls. Use a nominal 45-minute duration only when computation fails; equatorial civil dusk
  legitimately lasts only about twenty minutes.
- **No slots can be scheduled during polar day/night**, leaving the wallpaper unchanged for
  weeks. `needsCoordinate` does not cover this because coordinates exist; show a separate
  timeline notice.
- **Never replace precise location coordinates with reverse-geocoded results.** Those are
  administrative centers, tens of kilometers away in large cities; location permission was
  granted precisely to get that accuracy. Reverse geocoding only supplies a name.
- **Import replaces the entire timeline irreversibly, so confirm before starting.** Copy assets
  in the background: a set of hundreds of MB otherwise freezes the panel.
- **Use a two-phase import commit.** Write new assets into a unique directory first, then clean
  old directories against the latest on-disk timeline only after saving the config succeeds.
  Failed copies/saves can remove the new directory, while same-name or concurrent imports
  cannot damage assets that are still referenced.
- **Clicking ⋯ also closes the menu bar panel.** An immediate `NSOpenPanel.runModal` is canceled
  along with it, making Import look broken. Wait until the panel finishes closing, temporarily
  switch `activationPolicy` to `.regular`, and allow files, folders, and `.sundialScene`, not
  just directories.

### UI

- **`@main` cannot share a module with a `main.swift` containing top-level code.**
  `Tests/PanelShot` reuses UI code, so `build.sh` separates `HourGlowApp.swift` into `ENTRY`.
- **`ImageRenderer` cannot draw `ScrollView` contents or AppKit-backed controls** (segmented
  controls, time steppers, text fields, menus). The first screenshot tool therefore captured
  empty panels. Use a real window + `NSView.cacheDisplay`. Its `alphaValue` **must be 1**:
  setting 0.02 to hide it yielded a black-backed partial image with pictures but no text.
- Top-level code is not main-actor isolated; neither are `Scheduler`'s `onLog` / `onEvaluate`
  or `Timer` callbacks. They do run on the main thread; bridge with `MainActor.assumeIsolated`.
- **The menu bar panel dismisses on losing focus, including when `NSOpenPanel` opens.** Save
  a chosen local image directly into configuration; do not assume the panel remains open.
- **`NSDatePicker` draws content against the bottom of its own box**, leaving fixed descender
  space below (6.5 pt with both 12 pt and 13 pt fonts); extra height goes entirely above. Times
  use only digits and colons, no descenders, so symmetric padding looks top-heavy. `TimeField`
  uses a 12 pt font (matching the label to its left), with 3.5 pt above / 3 pt below to balance
  it. Keep the pill background and padding inside `TimeField`, not at call sites.
- **`NSPopUpButton` sizes itself to its widest item**, ignoring `frame(width:)`, so switching
  presets does not change its width. At roughly 140 pt wide, a row of its own wastes the right
  side; place today's time at the right end of the same row. Missing-coordinate and polar-day/night
  notices must therefore be short enough to fit there.
- **`.fullSizeContentView` does not change the `contentRect:`-to-window-frame conversion.**
  Extending the daylight gradient upward turned 566 pt of content into a 598 pt window with
  an unmatched blank strip. `setFrame` could not shrink it because `NSHostingView` made the
  content size the minimum window size. Use the system title bar and give it a title.
- **The mock Mac in guide step one is a diagram, not a simulation.** At real proportions, its
  menu bar would be two or three pixels high on an 88 pt screen and the hourglass unrecognizable,
  defeating that step's only point: showing the entrance. The menu bar therefore occupies a
  third of the machine's height. A glowing sun formerly occupied the desktop center; it was
  removed because the brightest area drew attention away from the upper-right entrance.
  Make the thing being pointed out the most conspicuous thing.
- **In dark mode, `black.opacity(0.12)` borders disappear, and `quaternary` cards nearly match
  the window background.** Use `Panel.hairline` / `cardFill` / `fieldFill` for thumbnail borders,
  section cards, and fields. These dynamic `NSColor(name:)` colors also honor
  `panelshot --appearance`, which changes only the window appearance; no need to thread
  `colorScheme` through every view.
- **`frame(maxWidth: .infinity)` only centers segmented controls; it does not stretch them.**
  `NSSegmentedControl` sizes to content and ignores SwiftUI's width. Left-align the slot-page row.
- **Daylight gradient stops must be monotonic.** Near the equator or when nil twilight uses a
  fallback, adjacent stops may coincide or reverse, creating a hard edge in `Gradient`.
  Clamp them in order after computing them.
- `PlacePage` already has a view property called `search`; do not also name extracted
  `CitySearch` state `search`, or the duplicate name will fail compilation.
- `Cities.search("")` returns common cities. The full location-page list fits them, but the
  guide does not: a default list pushes the search action itself offscreen. In the guide,
  show results only after the user enters a query.
- Capturing only the first slot in `panelshot` never shows the clock-trigger controls when the
  first configured slot uses sunrise/sunset; their layouts differ completely. Capture the
  extra `2b-slot-clock.png` as well.
- **Set `panelshot --now` before the first access to `AppModel.shared`.** `init` already resolves
  using now; setting it later leaves the active-slot display on real time. Demo captures run
  on a machine with the real app active, so point `HOURGLOW_HOME` at a throwaway directory or
  failure to acquire `run.lock` adds a background-scheduler notice to the panel.
- **Photographic GIF frames are expensive:** a 1000 × 625 frame costs 200–300 KB, and every
  crossfade frame adds that much. Long holds (0.75 seconds) and just five short transition
  frames keep 32 frames within 3.2 MB. Add duration by extending holds, not adding transitions.

### Language

- **`Preference` must be `Hashable`, not just `Equatable`.** Settings `Picker` selection and
  `.tag(...)` require it; declaring only `Equatable` fails with an error pointing at SwiftUI.
- **Language-dependent checks must pin their language.** `modelcheck` and `appcheck` explicitly
  set `HOURGLOW_LANG` to `en` and call `L10n.invalidate()` before their English-dependent
  scenarios, so system or stored preferences cannot alter results. Do not remove this setup.
  `l10ncheck` is responsible for testing language switching.
- **Choose the catalog before choosing a plural form.** Switching `sourceCode` to `en`
  exposed an English `.one` fallback over an existing Chinese base entry: the single-wallpaper
  import string resolved to English in Chinese mode. `t(count:)` now selects the current catalog
  when its base key exists, otherwise the source catalog, then resolves the optional singular
  within that catalog. `l10ncheck` covers the boundary; isolated CLI imports verified
  `imported 1 wallpaper` in English and `已导入 1 张` in Chinese.
- **Use `getenv`, not `ProcessInfo.environment`.** The latter is a process-start snapshot and
  still returns the old value after a check calls `setenv` (`Store.directoryURL` has the same
  concern). Call `L10n.invalidate()` after changing environment variables because language
  selection is cached.
- **Include `CFBundleLocalizations` in Info.plist.** Otherwise macOS treats the app as supporting
  only its development language, and HourGlow does not appear under Language & Region ›
  Applications. `build.sh` derives it from `Catalogs/*.swift`; do not maintain a second list
  that will eventually be forgotten when adding a language.
  The development region is `en`; retain both `en` and `zh-Hans` in the generated language list.
- **A word inside a sentence and a button title are different strings.** `sun.sunrise` is an
  inline sun-event word and uses lowercase English; the segmented-control title beside the
  clock trigger is capitalized. Hence `slot.kind.sunrise` / `slot.kind.sunset` are separate.
  Chinese uses the same form in both places; do not merge them.
- **Compute CLI column widths from display width, not constants.** `配置` occupies four columns,
  `config` six, `日落前30分` ten, and `30 min before sunset` twenty. A fixed width of 14 presses
  the English arrow against the text. `column(_:min:)` takes the maximum among the current
  strings, and `padded(to:)` pads using `displayWidth`.
- **Multi-argument strings must use `%n$` indices.** Changing word order without indices selects
  the wrong arguments, producing garbage or a crash. `l10ncheck` catches it, but knowing first
  is quicker than waiting for a failure.

### Login items, location, and signing

- **`SMAppService.mainApp.status` returns `.notFound`, not `.notRegistered`, when never registered**
  (verified with a fresh ad-hoc-signed bundle). Reading that literally as a missing login-item
  app path produces a false warning immediately. Like `.notRegistered`, it just means off,
  and registration still succeeds. Only `.requiresApproval` (disabled by the user in System
  Settings) deserves a notice in the UI.
- **Registration records this bundle's current path.** `build.sh` rebuilds `build/HourGlow.app`
  with `rm -rf` every time, leaving the old login item pointing at a nonexistent bundle.
  Settings shows the bundle path as a reminder when launch at login is enabled; copy the app
  into `/Applications` before enabling it for daily use.
- **`--locate` must wait for the system callback by running its own run loop inside
  `applicationDidFinishLaunching`.** `willFinishLaunching` is too early.
- Declare `CLLocationManagerDelegate` methods `nonisolated`, then use
  `MainActor.assumeIsolated` inside them. The protocol is not isolated, so direct implementation
  by an `@MainActor` class warns about failing a nonisolated requirement. Callbacks really do
  run on the main thread because the manager was created there.
- **Without `NSLocationWhenInUseUsageDescription`, the system denies location immediately**,
  without even presenting permission UI. `build.sh` includes it in the generated Info.plist.
- **The default ad-hoc designated requirement is `cdhash`, unsuitable for menu bar app upgrades.**
  Every rebuild changes identity. macOS 26's `group.com.apple.controlcenter/trackedApplications`
  can then associate the new build with an old blocked record: “Allow in Menu Bar” is enabled,
  yet the app exits on launch. Even the system's Reset Control Center could not clear the
  contaminated `app.hourglow` record, so the official bundle ID migrated once to
  `dev.bobbyhuang.hourglow`. `build.sh` explicitly sets
  `designated => identifier "dev.bobbyhuang.hourglow"` so rebuilds/upgrades retain that identity.
  `Tests/verify-app-signature.sh` and CI/Release protect against regression.

### Onboarding

- **`MenuBarExtra`'s label constructs `AppModel` before `applicationWillFinishLaunching`.**
  A probe that called `exit(0)` in `willFinishLaunching` still left `schedule.json` in
  `HOURGLOW_HOME`, written by `AppModel.init → Store.load()`. The delegate is therefore too
  late to decide whether this is a fresh install; the first line of `AppModel.init` is the
  earliest opportunity. Both sites call `Onboarding.captureFirstRun`; the first call wins.
- **Never automatically show the guide to existing users.** Missing `seenVersion` means
  unseen, not newly installed. Explaining the timeline in a surprise window after an update
  is disruptive. Use configuration-file existence as the criterion.
- **Closing must count as seen**, whether skipping, finishing, or clicking the red close button.
  Omit one path and it returns next launch, more annoying than having no guide.

### Updater

- **403 does not always mean rate limiting.** Enter the waiting state only for zero remaining
  quota, 429, Retry-After, or an explicit rate-limit response body. Read `x-ratelimit-reset` /
  `Retry-After` and show local date, time, and time zone. If absent or invalid, do not invent
  a reset time; wait at least one minute. Store the deadline in UserDefaults and honor it for
  manual/automatic checks and after restart. Explain ordinary 403 separately as a denied
  request. Settings errors get a full, wrapping row so the recovery time is not truncated.
- **`Bundle.main` keeps the launch-time path.** If the app or its parent directory moves while
  running, a missing helper at the old path must not become a false “not launched from app”
  error. The updater gets the current executable path with `proc_pidpath`, verifies the bundle
  ID and executable, and uses that location consistently for checks, helper copying, and the
  installation target. A missing helper has its own error. `verify-updater-location.py` uses
  real subprocesses to cover moves, renames, copies at old paths, and helper permission changes.
- **The running main process must not overwrite itself.** The app downloads and verifies; a
  helper copied to the cache performs the move after the old PID disappears. Always move the
  old app to a backup first, deleting it only after the new app is in place and `open` succeeds.
- **The download hash alone is insufficient.** GitHub's asset digest detects transport damage,
  but release metadata and files share a trust domain. Also verify the unpacked bundle with
  `codesign --verify --deep --strict`, requiring the stable
  `designated => identifier "dev.bobbyhuang.hourglow"`.
- **Sign the nested helper first.** The outer app signature treats `Contents/Helpers` as nested
  code. `build.sh` must sign `HourGlowUpdater` before `HourGlow.app`, or deep verification fails.
- **Read output while waiting for `ditto` / `codesign`.** Calling `waitUntilExit` before draining
  the pipe deadlocks parent and child when the pipe buffer fills.
- Automatic updates use the app's current path. If the parent directory is unwritable (read-only
  volume or `/Applications` for some standard users), do not attempt privilege escalation.
  Settings explains the failure; users can still open the GitHub release page to install manually.

### CI and releases

- **Use the `macos-26` runner.** `LSMinimumSystemVersion` is 26.0 and older SDKs cannot compile it.
  `macos-latest` currently points there, but pinning avoids future drift.
- **Runners often contain multiple Xcode versions, and the default need not be newest.** Both
  workflows first run `ls -d /Applications/Xcode_*.app | sort -V | tail -1`, then `xcode-select -s`.
- **Package `.app` only with `ditto -c -k --keepParent`.** `zip` loses symlinks and extended
  attributes, breaking the unpacked signature. Conversely, `zip -qj` is enough for the bare
  CLI binary; `ditto --sequesterRsrc` adds unwanted `__MACOSX/` contents. Unpack the result and
  run `codesign --verify --deep --strict` to ensure packaging preserved the signature.
- **CI cannot run CLI subcommands that read system wallpaper files.** Runners have neither
  the aerial library nor `Index.plist`, so `catalog` / `now` / `status` / `apply` are meaningless
  there. Smoke only `list` / `solar` / `simulate`, with `HOURGLOW_HOME` under `$RUNNER_TEMP`.
- **GitHub runners use UTC, which has no coordinates in `zone.tab`.** Without explicit
  coordinates, `Location` time-zone lookup fails, so `solar` and solar slots in `list` correctly
  report unavailable coordinates and exit 1. This broke the first CI run. Smoke steps therefore
  set `TZ=Asia/Shanghai`. It is not a bug: UTC does not identify a geographic location.
- **Ad-hoc signing + no notarization = blocked first launch.** README and release notes offer
  two routes: `xattr -dr com.apple.quarantine`, or System Settings › Privacy & Security ›
  Open Anyway. Eliminating that step requires a paid developer account and `notarytool` notarization.

### Sunrise/sunset verification

- **ephem's `next_rising(horizon='-0:50')` subtracts the solar radius again beyond the supplied
  horizon**, counting 16 arcminutes twice and shifting the result by about 75 seconds.
  `verify-solar.py` therefore bisects directly for “geometric solar-center altitude = -50
  arcminutes,” with an unambiguous definition.
- `api.sunrise-sunset.org` differs from the NOAA definition by about 65 seconds, unsuitable as
  a seconds-level reference, and returns 403 for urllib's default User-Agent. Verification is
  now entirely offline.

## Writing language

Write code comments and developer documentation in English. Comments explain why and record
pitfalls; they do not restate the code. Write new commit messages in English, in the imperative
mood; existing history is not rewritten.

User-visible strings (UI copy, CLI output, error messages) **do not belong inline in code**:
use keys in `Sources/L10n/`. Write new text first in `Catalogs/en.swift`, the source catalog,
then translate it. See “Language and localization” above.

`CONTRIBUTING.md`, `SECURITY.md`, and `README.md` are English. README remains bilingual:
`README.md` (English, the repository landing page) and `README.zh-CN.md` (Chinese) contain
matching information and link to one another at the top. **Update both in the same change**;
never update only one. Keep Chinese product translations and meaningful Chinese examples/data.

### 2026-09-05 release-boundary regressions

- **A damaged configuration is not a fresh install.** When initial loading fails, `AppModel`
  uses an empty timeline and remains in follower-retry mode: no scheduling lock, no wallpaper
  replacement with Tahoe presets, and no settings action overwriting the original file.
  Watching and 30-second takeover retries recover after repair. `appstartupcheck` compiles
  the real AppModel to verify the full chain, using a paused config during recovery.
- **Validate configuration both on decode and before save.** Coordinates must be finite and in
  range, clock times cannot exceed 23:59, and slot IDs must be unique. Validate before saving
  and leave the original file untouched on failure. Legacy `id: null`, like an omitted ID,
  generates a UUID that must be written back or identity changes on every load.
- **Do not directly negate or multiply external integers.** Display solar-offset `Int.min`
  using `magnitude`; both English and Chinese placeholders use `%@` to avoid overflow and
  `%d`'s 32-bit truncation. Resolution-score multiplication checks for overflow. Scanning
  accepts only regular files; a directory named `night.jpg` is not an image.
- **A local day is not always 24 hours.** CLI `simulate` scans Calendar's day interval, covering
  23/25 hours at daylight-saving start/end. `verify-cli-boundaries.py` verifies through the
  real CLI.
- Update-helper regressions cover waiting for a live parent and restoring the old app after
  the second move fails, as well as successful replacement.

## Performance and idle power (2026-09-05)

- Display refresh runs every 30 seconds only while the menu panel is visible. A hidden leader
  has no display ticker; a hidden follower retains the same 30-second takeover retry without
  reading wallpaper/state files on every retry. Promotion cancels that ticker when hidden.
  Opening the panel refreshes immediately. Scheduler deadlines, manual override rules, and
  configuration watching remain independent of panel visibility.
- Use `PanelVisibilityObserver` to observe the host window's actual visibility. A retained
  `NSHostingView` does not necessarily call SwiftUI `onDisappear` on `orderOut`, or `onAppear`
  on reopening. `panelvisibilitycheck` verifies repeated show/hide, rapid closing, and teardown.
  `appstartupcheck` verifies hidden idle periods, visible updates, reopening, and takeover.
- Scene resolution shares `TimeMap.DayWindows` within one `firings` call, including nil results
  on polar days. Never retain these results across calls: the location, calendar, or date may
  change. The direct-trigger comparisons in `modelcheck` cover DST, polar days, missing location,
  mixed triggers, disabled slots, and ties.
- `Tools/benchmark-resolver.swift` measures offline scene resolution with 300 iterations per
  size. On the review machine with Swift 6.3.3 and `-O`, 120 slots improved from about 3.43 to
  0.31 ms per resolution; 480 slots improved from 13.94 to 1.36 ms. These are computation timings,
  not measurements of battery-life improvement or of macOS's aerial renderer.
