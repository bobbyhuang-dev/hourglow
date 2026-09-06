# Contributing to HourGlow

Thanks for taking an interest in HourGlow. This document covers how to report a problem,
how to build and verify a change, and the conventions this codebase follows.

Be civil. Assume the other person is trying to help.

## Ways to contribute

**Bug reports.** Check the [troubleshooting guide](https://github.com/bobbyhuang-dev/hourglow/wiki/Troubleshooting), then use the [bug report form](https://github.com/bobbyhuang-dev/hourglow/issues/new?template=bug_report.yml) and
include:

- your macOS version and the HourGlow version (⋯ menu → about, or the release you downloaded);
- what you expected and what happened instead;
- the output of `hourglow-cli now` and `hourglow-cli list` if the wrong wallpaper was
  applied — those two show what HourGlow thinks should be active and whether reality agrees;
- your `~/Library/Application Support/HourGlow/schedule.json`, with local file paths
  redacted if you'd rather not share them.

Do **not** open a public issue for a security problem — see [SECURITY.md](SECURITY.md).

**Translations.** HourGlow speaks Simplified Chinese and English. Adding a third language is
one new file plus one line — see [Adding a language](#adding-a-language). No Swift beyond
filling in a dictionary, and you do not need to be able to build the app to start.

**Feature requests.** Use the [feature request form](https://github.com/bobbyhuang-dev/hourglow/issues/new?template=feature_request.yml) to describe the problem you hit, not just the feature you
have in mind. Check the non-goals list first (see below); if your request is on it, say why
the trade-off should change.

**Pull requests.** Small, focused changes are easiest to review. For anything larger than a
bug fix, open an issue first so we can agree on the approach before you write the code.

## Wiki documentation

The [wiki](https://github.com/bobbyhuang-dev/hourglow/wiki) contains installation, scheduling,
import, and troubleshooting guides. Its Markdown sources live in `docs/wiki/`, including
the shared `_Sidebar.md` and `_Footer.md`. Submit documentation changes there so they can
be reviewed alongside code changes.

GitHub stores the published wiki in a separate Git repository. After documentation changes
land on `main`, a maintainer publishes them from the main repository's root:

```bash
wiki_checkout="$(mktemp -d)/hourglow.wiki"
git clone https://github.com/bobbyhuang-dev/hourglow.wiki.git "$wiki_checkout"
cp docs/wiki/*.md "$wiki_checkout/"
git -C "$wiki_checkout" diff --check
git -C "$wiki_checkout" diff
git -C "$wiki_checkout" add -- '*.md'
git -C "$wiki_checkout" diff --cached
git -C "$wiki_checkout" commit -m "docs: update user guides"
git -C "$wiki_checkout" push origin HEAD
```

Check for direct wiki edits before copying and reconcile them with `docs/wiki/`. The copy
step does not remove old pages: review renames and deletions explicitly. Verify the published
pages and sidebar links after pushing. Committing `docs/wiki/` alone does not publish the wiki.

Issue forms live in `.github/ISSUE_TEMPLATE/`. Keep their labels aligned with existing GitHub
labels, leave diagnostics optional, and direct security reports to `SECURITY.md`'s policy.

## Non-goals

These are deliberately out of scope. A PR implementing one of them will likely be declined
unless the issue discussion changed the decision first:

- per-display or per-Space wallpapers (HourGlow always writes the slot as `linked`, so desktop
  and screen saver change together);
- controlling desktop and screen saver separately;
- random or folder shuffle;
- triggers based on light/dark mode, weather, or Focus;
- lock screen wallpaper;
- importing/exporting the whole `schedule.json`, or syncing it via iCloud.

Adding a third-party dependency is also a non-goal. HourGlow has none, and the sun position
math is about sixty lines of Swift.

## Development setup

You need macOS 26 (Tahoe) or later and the command-line Swift toolchain
(`xcode-select --install`). The full Xcode app is not required — there is no Xcode project.

```bash
git clone https://github.com/bobbyhuang-dev/hourglow.git
cd hourglow
./build.sh          # compiles the CLI, the app, and every check binary into build/
open build/HourGlow.app
```

`build.sh` drives `swiftc` directly and assembles `HourGlow.app` by hand, ad-hoc signed. If
you add a new file under `Sources/UI/`, the existing wildcard picks it up; a new entry point
(anything with `@main` or top-level code) needs an edit to the script.

## Verifying a change

There is no XCTest and no `swift test`. Verification runs through separately compiled check
binaries. They are all offline, and none of them touch your real wallpaper — `panelshot` is
the only one that puts anything on screen, and only briefly.

```bash
./build/modelcheck     # resolution: midnight wraparound, solar triggers, solar phases, Codable
./build/enginecheck    # engine: the assert-vs-stand-down matrix, timer scheduling
./build/importcheck    # import: filename and subfolder classification, multi-resolution, even split
./build/appcheck       # app state: drafts, save boundaries, config conflicts, onboarding rules
./build/appstartupcheck        # damaged-config startup and automatic recovery (about 30 seconds)
./build/updatecheck    # updater: SemVer ordering, Release parsing, SHA-256
./build/l10ncheck Sources   # strings: nothing missing, empty or extra; placeholders match; every key used in code exists
bash Tests/verify-updater-helper.sh build/HourGlow.app/Contents/Helpers/HourGlowUpdater
bash Tests/verify-app-signature.sh build/HourGlow.app
python3 Tests/verify-solar.py   # sun times cross-checked against the ephem ephemeris
python3 Tests/verify-cli-boundaries.py # invalid input and 23/25-hour daylight-saving days
```

`verify-solar.py` needs `pip install ephem`. Everything else runs as-is.

Run at least the checks covering what you touched, and **add a case for the behaviour you
changed**. Each check binary is a flat, ordered list of `check(...)` assertions in
`Tests/<Name>/main.swift`; append to it. A non-zero failure count exits 1.

To try things end to end without disturbing your own configuration, redirect the whole config
directory:

```bash
HOURGLOW_HOME=/tmp/hg ./build/hourglow-cli list   # an empty directory gets the default preset
```

If you changed the UI, render the panels and compare the layout before and after:

```bash
./build/panelshot ~/Desktop
./build/panelshot ~/Desktop --only timeline --now 2026-09-04T06:20   # one page, frozen at a moment
```

If the timeline's look changed, regenerate the README demo GIF and the share card too with
`Tools/makedemo.sh` (see the header of that script for what it needs).

## Adding a language

Every user-visible string lives in `Sources/L10n/`, and a language is one Swift file holding
one dictionary. Nothing else in the tree needs to change.

`Sources/L10n/Catalogs/en.swift` is the **source text**: write new strings in English there
first, then translate them; `l10ncheck` measures every other language against it. `sourceCode`
defines completeness and missing-text fallback, while `defaultCode` selects the language when
no requested language matches. Both are `en`, but these are distinct roles and settings.

### 1. Copy the English catalog

```bash
cp Sources/L10n/Catalogs/en.swift Sources/L10n/Catalogs/fr.swift
```

Use the [BCP 47](https://www.rfc-editor.org/rfc/rfc5646) tag as the file name: `fr`, `ja`,
`de`, `pt-BR`, `zh-Hant`. Include the script subtag only when it distinguishes something real
(`zh-Hant` yes, `fr-FR` no — a plain `fr` already matches `fr-CA` and `fr-BE`).

### 2. Fill it in

```swift
extension StringCatalog {
    static let fr = StringCatalog(
        code: "fr",              // must equal the file name
        name: "Français",        // the language's name *in that language* — see below
        placeNames: .latin,      // .latin or .chinese
        strings: [
            "common.ok": "OK",
            "slot.apply": "Appliquer",
            // …
        ])
}
```

- **`name`** is shown in the language picker, and the picker always lists every language under
  its own name. Someone who cannot read the current UI is exactly the person who needs to find
  their own row in that list, so write `Français`, not `French`.
- **`placeNames`** picks which column the built-in city and region names come from
  (`System/Cities.swift`): `.chinese` gives 深圳 / 广东, `.latin` gives Shenzhen / Guangdong.
  Translating a language does not mean translating a few hundred place names — pick `.latin`
  and move on.
- **Keys are never translated.** Only the values on the right.

### 3. Register it

One line in `Sources/L10n/L10n.swift`:

```swift
static let catalogs: [StringCatalog] = [.zhHans, .en, .fr]
```

Order affects only how the settings picker lists them. That is the whole wiring: the app, the
CLI and the onboarding guide all read the same table, `build.sh` picks the new file up by
wildcard, and it derives `CFBundleLocalizations` from these files so macOS knows the app
speaks your language too.

### 4. Check it

```bash
./build.sh
./build/l10ncheck Sources
```

`l10ncheck` fails on a required key that is missing, empty, or not in the source catalog; on a
`%` placeholder that does not match the source; and on a key used in code but absent from the
source table. Language-dependent `.one` forms are optional. Then look at it for real:

```bash
HOURGLOW_LANG=fr ./build/hourglow-cli list
HOURGLOW_LANG=fr ./build/hourglow-cli help
HOURGLOW_LANG=fr ./build/panelshot ~/Desktop      # every panel page and all five guide steps
```

`HOURGLOW_LANG` overrides both the stored preference and the system language, for the app and
the CLI alike, so you can look at a language without switching your Mac to it.

### Things that bite

- **The panel is 360 pt wide and the layout is fixed.** It does not grow to fit a longer
  translation. Render `panelshot` and read the pages before opening the PR; if a string cannot
  be made to fit, say so in the PR rather than letting it clip.
- **Placeholders must survive.** `%@` is a string, `%d` a number, `%.4f` a coordinate. You may
  reorder them, but only with the numbered form: `"%2$@ at %1$@"`. A string with more than one
  placeholder is *required* to number them, because word order changes between languages and
  the unnumbered form would then pull the wrong argument. Mixing `%@` and `%1$@` in one string
  is undefined behaviour; `l10ncheck` rejects all three mistakes.
- **Plurals.** If your language needs a singular form, keep or add a `<key>.one` entry next to
  the base key; it is used when the count is exactly 1. See `"cli.import.done"` /
  `"cli.import.done.one"` in the English source catalog. Chinese does not need these entries,
  even though English includes them. A translated base entry without `.one` is used for all
  counts rather than falling back to the English singular. This optional mechanism covers
  only the 1-vs-many split; raise an issue for a richer plural system rather than work around it.
- **`cli.help` is a multi-line block, and its columns are aligned by hand.** Keep the command
  names as they are — they are what the user types — and align the descriptions after them.
- **Terminal column widths.** The CLI pads its columns by display width and measures them from
  the strings themselves, so a long label widens its column rather than breaking the table. You
  do not have to count characters.
- **A partial translation is fine as a starting point, but not as a PR.** A missing key falls
  back to the source text, so nothing breaks, but `l10ncheck` — and therefore CI — will not go
  green until the table is complete.

The two check binaries with language-dependent scenarios (`modelcheck`, `appcheck`) explicitly
pin `HOURGLOW_LANG` to `en` and invalidate the language cache before those scenarios. Keep that
setup so stored and system preferences cannot change their results; `l10ncheck` tests language
selection and switching.

## Conventions

**Comments and developer documentation are written in English.** `README.md` and
`README.zh-CN.md` remain a matched English/Chinese pair — if you change one, change the other
in the same PR. Keep Chinese product translations and meaningful Chinese examples/data.

**No user-visible string is written in a view, a command or an error.** Every one of them is a
key looked up in `Sources/L10n/`, and new strings are written into
`Catalogs/en.swift` — the English source text — before being translated. This holds for CLI
output and error messages as much as for the panel. See
[Adding a language](#adding-a-language).

**Comments explain why, not what.** A comment that restates the line below it will be asked
about in review. A comment recording a system behaviour you had to discover the hard way is
exactly what belongs there.

**Scheduling logic exists in one place.** Evaluation lives in `Model/Resolver.swift` and
`Model/TimeMap.swift`; the decision to write lives in `Engine/Scheduler.swift`. The UI reads
`App/AppModel.swift` and calls into it — it must not grow its own copy of the scheduling
rules.

**UI measurements live in `UI/PanelKit.swift`.** The panel width is fixed at 360 pt. Don't
scatter numbers through the views.

**No license headers in source files.** The `LICENSE` at the repository root covers the whole
tree.

Read [CLAUDE.md](CLAUDE.md) before touching anything substantial. It documents the layering,
the two semantics that must hold (who wins when the user changes the wallpaper by hand, and
how the app and the CLI share a single scheduler), the verified facts about the macOS
wallpaper store, and a long list of mistakes already made once. It is worth the ten minutes.

## Commits and pull requests

- Write new commit messages in English, in the imperative mood. Existing history stays as it is.
- Keep one logical change per commit. Rebase rather than merge to update a branch.
- In the PR description, say what changed and how you verified it. If you skipped a check,
  say which and why.
- CI (`.github/workflows/ci.yml`) builds on `macos-26` and runs the check binaries plus the
  ephemeris cross-check on every push and PR. It has to be green before merge.
- CodeQL (`.github/workflows/codeql.yml`) scans Swift, Python, and GitHub Actions on pushes
  to `main`, pull requests, and weekly. Swift uses `./build.sh --production-only` with manual build
  mode on `macos-26` to trace the app, CLI, and updater without rebuilding verification targets,
  because this repository has no Xcode project or Swift package for autobuild.
  Maintainers must switch from default to advanced setup in Settings > Advanced Security
  when activating this workflow; default setup blocks uploads from advanced workflows.

## Releases

Releases are cut by the maintainer. Pushing a `v*` tag triggers
`.github/workflows/release.yml`, which builds, verifies, packages and publishes a GitHub
Release. Version numbers come from the tag, overriding the defaults at the top of `build.sh`.
Contributors don't need to touch version numbers in a PR.

## License

HourGlow is licensed under the [Apache License 2.0](LICENSE). By submitting a pull request,
you agree that your contribution is licensed under the same terms — this is section 5 of the
license, and there is no separate CLA to sign.
