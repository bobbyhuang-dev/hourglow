# HourGlow

> **English** · [中文](README.zh-CN.md)

A macOS wallpaper scheduler that follows the daylight.

macOS Tahoe ships four dynamic wallpapers — Tahoe Morning / Day / Evening / Night — but
unlike older versions of macOS, it can no longer switch between them as the day goes on.
HourGlow fills that gap. Rather than hardcoding those four, it is a general
"trigger → wallpaper" scheduler: you define any number of time slots, bind a wallpaper to
each, and it handles switching at the right moment.

Lives in the menu bar, no Dock icon. Swift 6.3 + SwiftUI, zero third-party dependencies,
under 5 MB.

## Features

- **Two kinds of trigger** — a fixed clock time, or relative to sunrise/sunset with a
  signed offset (e.g. "30 minutes before sunset")
- **Two wallpaper sources** — any of the 156 system aerials, or a local image file
- **Any number of slots** — the Tahoe four are just the preset written on first launch;
  edit or delete them freely
- **Sun times computed locally** — the NOAA solar position algorithm, no network. Coordinates
  are inferred from your time zone, or set by hand
- **No polling** — the timer is scheduled directly at the next trigger point. Sleep/wake,
  system clock changes, time zone changes and day rollover each have their own notification,
  so sleeping through a trigger means the wallpaper catches up on wake
- **It won't fight you** — if you change the wallpaper yourself in System Settings, HourGlow
  won't silently undo it on the next in-place re-evaluation. Your manual pick stands until
  the next scheduled switch (see below)
- **Human-readable JSON config** — edit `schedule.json` by hand and the engine follows
  immediately

## Requirements

macOS 26 (Tahoe) or later. Building needs only the command-line Swift toolchain
(`xcode-select --install`), not the full Xcode.

## Build and run

```bash
git clone https://github.com/bobbyhuang-dev/hourglow.git
cd hourglow
./build.sh
open build/HourGlow.app
```

`build.sh` compiles with `swiftc` and assembles the `.app` by hand (ad-hoc signed — fine for
personal use); there is no Xcode project. Everything lands in `build/`.

## Command line

`hourglow-cli` is the troubleshooting entry point, and doubles as a headless daemon:

```bash
./build/hourglow-cli now                 # what should be active now, next switch, whether reality agrees
./build/hourglow-cli list                # the timeline, with today's actual times per slot
./build/hourglow-cli catalog Space       # list system aerials (with download state and size)
./build/hourglow-cli simulate 2026-12-21 # time travel: print every switch across that day
./build/hourglow-cli solar               # today's sunrise and sunset
./build/hourglow-cli apply --dry-run     # show what would be written, without writing
./build/hourglow-cli run                 # run the engine in the foreground
./build/hourglow-cli agent install       # register as a LaunchAgent, survives reboot
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
    }
  ]
}
```

Other runtime paths: `state.json` and the single-instance lock `run.lock` sit in the same
directory; the LaunchAgent logs to `~/Library/Logs/HourGlow.log`.

## Verification

There is no XCTest. Verification runs through a few separately compiled check binaries, all
offline, none of which touch your real wallpaper:

```bash
./build/modelcheck             # resolution: midnight wraparound, solar triggers, Codable compatibility
./build/enginecheck            # engine: the assert-vs-stand-down matrix, and timer scheduling
python3 Tests/verify-solar.py  # sun times cross-checked against the ephem ephemeris (10 cases, max deviation 4s)
./build/panelshot ~/Desktop    # render the three panel pages to PNG, for comparing layout changes
```

## Status

M1 (logic layer), M2 (scheduling engine) and M3 (menu bar UI) are done; M4 is wrapping up:
launch at login, precise CoreLocation, acceptance checklist. The spec lives in `MVP.md`,
progress and implementation notes in `TODO.md` — both are written in Chinese, as are the
source comments.

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
