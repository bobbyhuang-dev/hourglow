# HourGlow

> **English** · [中文](README.zh-CN.md)

[![CI](https://github.com/bobbyhuang-dev/hourglow/actions/workflows/ci.yml/badge.svg)](https://github.com/bobbyhuang-dev/hourglow/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/bobbyhuang-dev/hourglow?label=release)](https://github.com/bobbyhuang-dev/hourglow/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-26%2B-blue)](#requirements)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A macOS wallpaper scheduler that follows the daylight.

macOS Tahoe ships four dynamic wallpapers — Tahoe Morning / Day / Evening / Night — but
unlike older versions of macOS, it can no longer switch between them as the day goes on.
HourGlow fills that gap. Rather than hardcoding those four, it is a general
"trigger → wallpaper" scheduler: you define any number of time slots, bind a wallpaper to
each, and it handles switching at the right moment.

Lives in the menu bar, no Dock icon. Swift 6.3 + SwiftUI, zero third-party dependencies,
under 5 MB.

## Features

- **Three kinds of trigger** — a fixed clock time, relative to sunrise/sunset with a
  signed offset (e.g. "30 minutes before sunset"), or a solar-phase slice that
  evenly divides today's twilight / day / night window by how many frames that
  phase has (the 24 Hour Wallpaper model)
- **Two wallpaper sources** — any of the 156 system aerials, or a local image file
- **Any number of slots** — the Tahoe four are just the preset written on first launch;
  edit or delete them freely
- **Sun times computed locally** — the NOAA solar position algorithm, no network. Coordinates
  come from a one-shot system location fix, a city you pick, or a latitude/longitude you
  type in; with none of those, they are inferred from your time zone, which needs no
  permission at all. China is a single `Asia/Shanghai` zone, so picking Shenzhen vs Shanghai
  actually changes sunrise by tens of minutes.
- **No polling** — the timer is scheduled directly at the next trigger point. Sleep/wake,
  system clock changes, time zone changes and day rollover each have their own notification,
  so sleeping through a trigger means the wallpaper catches up on wake
- **It won't fight you** — if you change the wallpaper yourself in System Settings, HourGlow
  won't silently undo it on the next in-place re-evaluation. Your manual pick stands until
  the next scheduled switch (see below)
- **Edits are staged** — changing a slot's time or wallpaper only builds up a draft; nothing
  is written to the schedule, and no wallpaper changes, until you hit Apply
- **Launch at login** — a login item registered through `SMAppService`, visible and
  switchable in System Settings › Login Items
- **Built-in updates** — check manually or let HourGlow check GitHub Releases daily,
  verify the download and code signature, install it in place, and relaunch itself
- **Human-readable JSON config** — edit `schedule.json` by hand and the engine follows
  immediately
- **Import a 24-hour wallpaper set** — files named with sunrise / morning / day / sunset /
  evening / night (or `01_sunrise_1.heic`, or a 24 Hour Wallpaper `.sundialScene`), or sorted
  into per-phase subfolders (`sunrise/1.jpg`), become a full-day timeline that tracks local
  sun times. Each phase can have a different number of frames. Importing replaces the whole
  timeline and asks first; files whose phase cannot be determined are left out and reported
  back to you.

## Download

**[⬇ Download the latest release](https://github.com/bobbyhuang-dev/hourglow/releases/latest)**
— grab `HourGlow-x.y.z.zip`, unzip it, drag `HourGlow.app` into `/Applications`.

The app is ad-hoc signed but *not notarized* (no paid Apple developer account), so macOS
blocks the first launch. Clear the quarantine flag once:

```bash
xattr -dr com.apple.quarantine /Applications/HourGlow.app
```

Or double-click it once and then allow it under **System Settings › Privacy & Security ›
Open Anyway**.

It then lives in the menu bar — no Dock icon, no window. On first launch it writes the
Tahoe four-slot preset; edit or delete those freely. To have it come back after a reboot,
turn on **Launch at login** in the settings page (the ⋯ menu).

Automatic updates are on by default. The settings page can turn them off, check manually,
or install an available release immediately. Updates keep the app at its current location,
so move it into `/Applications` before enabling Launch at login.

Current builds use a stable code identity and a new bundle identifier to avoid a macOS 26
Control Center bug that could hide an updated ad-hoc-signed menu bar app even while Settings
showed it as allowed. Schedules from older builds are kept, but you may need to grant location
access and enable **Launch at login** once again after this identity migration.

`hourglow-cli-x.y.z.zip` on the same page is the optional command line tool (see below);
drop the binary anywhere on your `PATH`.

## Requirements

macOS 26 (Tahoe) or later. Building from source needs only the command-line Swift toolchain
(`xcode-select --install`), not the full Xcode.

## Build from source

```bash
git clone https://github.com/bobbyhuang-dev/hourglow.git
cd hourglow
./build.sh
open build/HourGlow.app
```

`build.sh` compiles with `swiftc` and assembles the `.app` by hand (ad-hoc signed — fine for
personal use); there is no Xcode project. The signature carries an explicit, stable designated
requirement so rebuilding or upgrading does not create a new menu-bar identity on macOS 26.
Everything lands in `build/`. Every push is built and checked the same way by GitHub Actions
(`.github/workflows/ci.yml`); pushing a `v*` tag builds, verifies and publishes a release
(`.github/workflows/release.yml`).

## Command line

`hourglow-cli` is the troubleshooting entry point, and doubles as a headless daemon:

```bash
./build/hourglow-cli now                 # what should be active now, next switch, whether reality agrees
./build/hourglow-cli list                # the timeline, with today's actual times per slot
./build/hourglow-cli catalog Space       # list system aerials (with download state and size)
./build/hourglow-cli simulate 2026-12-21 # time travel: print every switch across that day
./build/hourglow-cli solar               # today's sunrise, sunset, nautical dawn, civil dusk
./build/hourglow-cli location 深圳       # set coordinates by city name
./build/hourglow-cli import ~/Pictures/zhangjiajie   # folder of stills → solar-phase timeline
./build/hourglow-cli apply --dry-run     # show what would be written, without writing
./build/hourglow-cli run                 # run the engine in the foreground
./build/hourglow-cli agent install       # register as a LaunchAgent, survives reboot (headless use)
```

Launch-at-login and location can't be asked of the CLI: the login item is registered for —
and location permission granted to — *the caller's own bundle*, and the CLI is a bare
binary. Those two entry points live on the app's executable and exit as soon as they print:

```bash
build/HourGlow.app/Contents/MacOS/HourGlow --login-item status   # status | on | off
build/HourGlow.app/Contents/MacOS/HourGlow --locate              # one fix, printed, never written to the config
```

The menu bar app and `hourglow-cli run` compete for the same single-instance lock: whichever
starts first owns scheduling, the other falls back to follower mode — it only edits the
config, and the leader picks the change up.

## Who wins when you change the wallpaper yourself

You may well go into System Settings and pick a different wallpaper. HourGlow decides based
on whether a new trigger boundary has been crossed:

- **Crossed** (a trigger fired, you slept through one, or the schedule was resumed from
  pause) — write as usual. Your manual pick is valid until the next scheduled switch, the
  same way a thermostat's "temporary hold" works.
- **Not crossed** (launch, wake, time zone change — any in-place re-evaluation) — write only
  if the current wallpaper is still the one HourGlow last wrote. Otherwise it stands down
  rather than silently erasing the choice you made ten minutes ago.

## Configuration

`~/Library/Application Support/HourGlow/schedule.json`, safe to edit by hand:

```json
{
  "paused": false,
  "slots": [
    {
      "id": "…",
      "enabled": true,
      "trigger": { "type": "solar", "event": "sunrise", "offsetMinutes": 0 },
      "wallpaper": { "type": "aerial", "assetID": "B2FC91ED-6891-4DEB-85A1-268B2B4160B6" }
    },
    {
      "id": "…",
      "enabled": true,
      "trigger": { "type": "clock", "hour": 9, "minute": 0 },
      "wallpaper": { "type": "image", "path": "/Users/you/Pictures/noon.heic" }
    },
    {
      "id": "…",
      "enabled": true,
      "trigger": { "type": "solarPhase", "phase": "sunrise", "index": 0, "count": 3 },
      "wallpaper": { "type": "image", "path": "/Users/you/Library/Application Support/HourGlow/Scenes/zhangjiajie/sunrise_1.heic" }
    }
  ]
}
```

Other runtime paths: `state.json` and the single-instance lock `run.lock` sit in the same
directory; the LaunchAgent logs to `~/Library/Logs/HourGlow.log`. The whole config directory
can be moved with the `HOURGLOW_HOME` environment variable — handy for trying things out on a
throwaway config, leaving the real one alone.

## Verification

There is no XCTest. Verification runs through a few separately compiled check binaries, all
offline, none of which touch your real wallpaper:

```bash
./build/modelcheck             # resolution: midnight wraparound, solar triggers, solar-phase windows, Codable compatibility
./build/enginecheck            # engine: the assert-vs-stand-down matrix, and timer scheduling
./build/importcheck            # import: 24 Hour Wallpaper filenames, multi-resolution scenes, even split
./build/appcheck               # app state: drafts, save boundaries, external config conflicts
./build/updatecheck            # updater: SemVer ordering, Release parsing, SHA-256
bash Tests/verify-updater-helper.sh build/HourGlow.app/Contents/Helpers/HourGlowUpdater
python3 Tests/verify-solar.py  # sun times cross-checked against the ephem ephemeris (10 cases, max deviation 4s)
./build/panelshot ~/Desktop    # render the four panel pages to PNG, for comparing layout changes
```

## Status

**1.2 development — 24 Hour Wallpaper import and solar-phase scheduling.** The 1.0 MVP
(logic layer, scheduling engine, menu bar UI, launch at login, precise location and packaging)
is complete, and the acceptance checklist in section 9 of `MVP.md` has been run through.
The spec lives in `MVP.md`, progress and implementation notes in `TODO.md` — both are written
in Chinese, as are the source comments.

## How it actually changes the wallpaper

macOS keeps wallpaper configuration in
`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist` (a binary plist), and
applies it once `WallpaperAgent` is killed. HourGlow reads, modifies and writes that file:
preserving every unknown field, backing it up first, always writing the slot as `linked`
(desktop and screen saver change together), and skipping the write entirely when the target
already matches — which avoids the flicker. The format details are in section 2 of `MVP.md`,
all verified on a real machine.

This is not a public API. The risk of it changing across macOS point releases is yours.

## License

MIT
