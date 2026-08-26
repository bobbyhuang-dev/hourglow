# Contributing to HourGlow

Thanks for taking an interest in HourGlow. This document covers how to report a problem,
how to build and verify a change, and the conventions this codebase follows.

Be civil. Assume the other person is trying to help.

## Ways to contribute

**Bug reports.** Open an [issue](https://github.com/bobbyhuang-dev/hourglow/issues) and
include:

- your macOS version and the HourGlow version (⋯ menu → about, or the release you downloaded);
- what you expected and what happened instead;
- the output of `hourglow-cli now` and `hourglow-cli list` if the wrong wallpaper was
  applied — those two show what HourGlow thinks should be active and whether reality agrees;
- your `~/Library/Application Support/HourGlow/schedule.json`, with local file paths
  redacted if you'd rather not share them.

Do **not** open a public issue for a security problem — see [SECURITY.md](SECURITY.md).

**Feature requests.** Open an issue describing the problem you hit, not just the feature you
have in mind. Check the non-goals list first (see below); if your request is on it, say why
the trade-off should change.

**Pull requests.** Small, focused changes are easiest to review. For anything larger than a
bug fix, open an issue first so we can agree on the approach before you write the code.

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
./build/updatecheck    # updater: SemVer ordering, Release parsing, SHA-256
bash Tests/verify-updater-helper.sh build/HourGlow.app/Contents/Helpers/HourGlowUpdater
bash Tests/verify-app-signature.sh build/HourGlow.app
python3 Tests/verify-solar.py   # sun times cross-checked against the ephem ephemeris
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
```

## Conventions

**Comments, documentation, CLI output and UI strings are written in Chinese.** The only
exceptions are the files aimed at outside readers: `README.md`, this file, and `SECURITY.md`.
`README.md` and `README.zh-CN.md` are a matched pair — if you change one, change the other in
the same PR.

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

- Write commit messages in the imperative mood. Chinese or English is fine; the existing
  history is Chinese.
- Keep one logical change per commit. Rebase rather than merge to update a branch.
- In the PR description, say what changed and how you verified it. If you skipped a check,
  say which and why.
- CI (`.github/workflows/ci.yml`) builds on `macos-26` and runs the check binaries plus the
  ephemeris cross-check on every push and PR. It has to be green before merge.

## Releases

Releases are cut by the maintainer. Pushing a `v*` tag triggers
`.github/workflows/release.yml`, which builds, verifies, packages and publishes a GitHub
Release. Version numbers come from the tag, overriding the defaults at the top of `build.sh`.
Contributors don't need to touch version numbers in a PR.

## License

HourGlow is licensed under the [Apache License 2.0](LICENSE). By submitting a pull request,
you agree that your contribution is licensed under the same terms — this is section 5 of the
license, and there is no separate CLA to sign.
