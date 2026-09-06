## Requirements and installation

HourGlow requires **macOS 26 (Tahoe) or later**. Universal 2 builds support Apple silicon
and Intel. The current 1.6.0 download supports Apple silicon only; Intel users can build from
source until the next release ships.

1. Open the [latest release](https://github.com/bobbyhuang-dev/hourglow/releases/latest) and download `HourGlow-x.y.z.zip`.
2. Unzip it and move `HourGlow.app` into `/Applications` before enabling launch at login.
3. Open the app. Releases are ad-hoc signed and not notarized, so macOS may block the first launch. After attempting to open it, use **System Settings → Privacy & Security → Open Anyway**. The [README](https://github.com/bobbyhuang-dev/hourglow/blob/main/README.md#download) documents the alternative command-line method.
4. Find the hourglass icon in the menu bar. Click it to open the timeline.

A fresh installation opens a five-step guide and creates the four-slot Tahoe preset. Existing installations keep their schedule. You can reopen the guide through the panel's **⋯** menu or the Help section in Settings.

## Set your location

Click the location pill at the top of the timeline. Automatic location is enabled for new configurations; grant location access if you want the app to refresh your coordinates. You can also pick a city or enter coordinates without granting permission. Choosing either keeps the location fixed.

If no coordinates are saved, HourGlow tries to infer an approximate location from your time zone. A city or coordinate pair gives more useful sunrise and sunset times when your time zone covers a large area. See [Scheduling and location](https://github.com/bobbyhuang-dev/hourglow/wiki/Scheduling-and-Location).

## Make it part of your day

- Open **⋯ → Settings** and enable **Launch at login** to start HourGlow after signing in. If macOS requests approval, enable the item in System Settings.
- Choose your language in Settings. English and Simplified Chinese are available, and the app and CLI share the preference.
- Select a timeline slot to change its time or wallpaper, then click **Apply** to save it.
- Automatic update checks are on by default. Settings lets you check manually and install an available release. The updater verifies the download and app signature before replacing the app and relaunching it.

The optional `hourglow-cli-x.y.z.zip` release asset is for diagnostics and headless use. You do not need it to use the menu bar app.

## Build from source

The command-line Swift toolchain is sufficient; there is no Xcode project and no third-party dependency.

```bash
git clone https://github.com/bobbyhuang-dev/hourglow.git
cd hourglow
./build.sh
open build/HourGlow.app
```

See [Contributing](https://github.com/bobbyhuang-dev/hourglow/blob/main/CONTRIBUTING.md#development-setup) for development setup and verification.
