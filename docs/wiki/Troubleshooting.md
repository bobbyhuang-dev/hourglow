## The app does not appear

HourGlow normally lives in the menu bar without a Dock icon. Look for the hourglass icon. A fresh installation opens a guide; existing installations do not reopen it automatically.

If macOS blocks the first launch, follow [Getting started](https://github.com/bobbyhuang-dev/hourglow/wiki/Getting-Started). If launch at login does not work, first move the app to `/Applications`, then enable the setting from that copy and check its approval in System Settings. Registration uses the app's location, so a temporary build folder is unsuitable for daily use.

## The wallpaper or switch time seems wrong

1. Check that the schedule is running and the relevant slot is enabled.
2. Make sure you clicked **Apply** after editing a slot.
3. Check the location pill and your Mac's date and time zone. Time-zone inference is approximate; choose a city or coordinates for more accurate sun times.
4. If you changed the wallpaper manually, HourGlow waits until the next scheduled switch. See [Scheduling and location](https://github.com/bobbyhuang-dev/hourglow/wiki/Scheduling-and-Location).
5. For a local image, check that its file still exists. For an aerial, macOS may need to download the asset before it is available.

If you have the optional CLI on your `PATH`, these commands inspect the schedule and system state without applying a wallpaper:

```bash
hourglow-cli now
hourglow-cli list
hourglow-cli status
hourglow-cli solar
hourglow-cli apply --dry-run
```

For a source build, replace `hourglow-cli` with `./build/hourglow-cli`. `now` compares the expected wallpaper with reality; `list` prints today's slot times; `status` shows the engine's recorded state. Some diagnostics need an existing system wallpaper store and aerial catalog.

To inspect a different day without changing the wallpaper:

```bash
hourglow-cli simulate 2026-12-21
```

## Location is unavailable or stale

System location is optional. Check the app's Location Services permission, or choose a city or type coordinates. Automatic refresh needs the menu bar app running and keeps the last fix on failure. The unbundled CLI cannot obtain location permission or a system fix.

Coordinates saved before automatic location was introduced remain fixed after upgrade. Enable automatic location explicitly if you want them to follow your current location.

## An update failed

Read the full notice in Settings. For GitHub rate limiting, wait until the displayed recovery time before trying again. A denied request or an unwritable app directory has a different cause; repeated checks do not resolve either.

The updater log is `~/Library/Logs/HourGlow-Updater.log`. If in-app installation cannot complete, download the app from the [latest release](https://github.com/bobbyhuang-dev/hourglow/releases/latest) and replace your installed copy manually. After relaunch, check the version in About to confirm the update completed.

## An import skipped images

Check phase names in filenames or parent folders, using the examples in [Importing wallpaper sets](https://github.com/bobbyhuang-dev/hourglow/wiki/Importing-Wallpaper-Sets). Several copies at different resolutions are intentionally collapsed to one image at the largest resolution. Import replaces the timeline, so keep your original image set before importing another.

## Configuration and logs

| Path | Purpose |
| --- | --- |
| `~/Library/Application Support/HourGlow/schedule.json` | Saved slots, location, and pause state |
| `~/Library/Application Support/HourGlow/state.json` | The engine's last wallpaper write |
| `~/Library/Application Support/HourGlow/run.lock` | Scheduling ownership shared by the app and CLI |
| `~/Library/Application Support/HourGlow/Scenes/` | Imported image copies |
| `~/Library/Logs/HourGlow.log` | Optional headless LaunchAgent log |
| `~/Library/Logs/HourGlow-Updater.log` | Most recent updater installation log |

`HOURGLOW_HOME` redirects the configuration directory, including the state and lock files. Language and onboarding preferences live separately in UserDefaults and are not redirected. A malformed `schedule.json` is preserved rather than replaced with a preset; correct the file to let the app recover.

The menu bar app and CLI share one scheduling lock. Running both does not create two independent schedules: one leads and the other follows configuration changes.

## Report a problem

Open a [bug report](https://github.com/bobbyhuang-dev/hourglow/issues/new?template=bug_report.yml) with your HourGlow version, macOS version, steps to reproduce, and expected and actual behavior. Diagnostics are optional; you do not need to install the CLI to report a bug.

Before posting configuration, logs, or screenshots, remove personal paths, coordinates, location names, and other private information. For a security vulnerability, follow the [private reporting policy](https://github.com/bobbyhuang-dev/hourglow/security/policy) instead of opening a public issue.
